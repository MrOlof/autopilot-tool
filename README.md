# Autopilot Registration Tool

Open-source Windows Autopilot device registration tool with a secure Azure Function proxy architecture.

Register devices into Windows Autopilot directly from OOBE — no admin credentials on the device, no broad API permissions exposed, no modules to install.

## Why This Exists

Existing Autopilot hash upload tools either require an admin to sign in at OOBE (limiting who can run them) or store API credentials directly on the device (security risk).

### The Problem with Existing Approaches

| Approach | Who can run it? | What's at risk if credentials leak? |
|----------|----------------|-------------------------------------|
| **Delegated auth** (admin signs in) | Only Intune admins | N/A — no stored credentials |
| **App Registration + client secret** | Anyone | Full `DeviceManagementServiceConfig.ReadWrite.All` — attacker can modify Intune policies, enrollment configs, compliance settings |
| **App Registration + certificate** | Anyone | Same as above — broad Graph API access |
| **DEM account** | Anyone | Enrollment abuse + Microsoft explicitly says DEM is unsupported with Autopilot |

### This Tool's Approach: Azure Function Proxy with Managed Identity

This tool uses an **Azure Function as a security boundary** between the device and Graph API:

- The **Managed Identity** holds the Graph API permission (`DeviceManagementServiceConfig.ReadWrite.All`) but it lives inside Azure — never on a device or USB stick
- The **Azure Function code** only calls one specific Graph endpoint (Autopilot device import) — even though the Managed Identity *could* do more, the code doesn't expose it
- The **device/USB** only has a Function URL + API key — this key can only call your Function, not Graph API directly

**If the API key leaks:** an attacker can submit hardware hashes to your Autopilot. That's it. They cannot read or modify Intune policies, compliance settings, enrollment configurations, or anything else. Rotate the key in Azure Portal and all existing USBs stop working instantly.

**This means anyone** — field techs, end users, interns — can safely run the tool at OOBE without needing admin credentials or understanding Intune permissions.

## Architecture

```
Device at OOBE                    Azure Function                  Microsoft Graph
+------------------+             +---------------------+         +-------------------+
|  Field Tool      |  HTTPS POST |  Upload endpoint    |  Graph  |  Autopilot        |
|  (USB stick)     | ----------> |  Managed Identity   | ------> |  Device Import    |
|                  |  API key    |  Input validation   |  Token  |                   |
+------------------+             +---------------------+         +-------------------+
     Only has:                        Has:                            Requires:
     - Function URL                   - System Managed Identity       - DeviceManagement
     - API key                        - Graph API token                 ServiceConfig
                                      - Input validation                .ReadWrite.All
                                      - Only calls import endpoint
                                      - Full audit logging
```

## Components

| Component | Purpose | Run by |
|-----------|---------|--------|
| **Azure Function** | Proxy between device and Graph API. Validates input, uploads hardware hash, checks sync status. Authenticates via Managed Identity. | Runs in Azure |
| **Builder** | Wizard-style admin GUI. Deploys Azure Function, configures company branding and group tags, generates the field tool. | IT Admin (one-time) |
| **Field Tool** | OOBE client. Collects hardware hash via WMI, lets user pick a group tag, uploads via Azure Function, polls for completion. | Tech / End User |

## Quick Start

### Option A: Use the Builder (recommended)

The Builder handles everything — Azure deployment, Graph permissions, code deployment, and field tool generation.

```powershell
# Prerequisites
Install-Module Az -Scope CurrentUser
Install-Module Microsoft.Graph -Scope CurrentUser

# Run the Builder
.\builder\Build-AutopilotTool.ps1
```

The Builder walks you through 4 steps:
1. **Backend** — Deploy Azure Function (automated or manual)
2. **Validate** — Enter Function URL + key, test connection
3. **Branding** — Set company name, configure group tags
4. **Generate** — Create field tool + USB launcher + instruction card

### Option B: Manual setup

```powershell
# 1. Create resource group
az login
az group create --name rg-autopilot-tool --location westeurope

# 2. Deploy Azure Function (ARM template, no Bicep CLI required)
az deployment group create \
  --resource-group rg-autopilot-tool \
  --template-file azure-function/deploy.json \
  --parameters namePrefix=autopilot-tool

# 3. Grant Graph API permission to the Managed Identity (requires Global Admin)
.\setup\Grant-GraphPermission.ps1 -ManagedIdentityPrincipalId "<principalId from step 2>"

# 4. Deploy function code
$zipPath = "$env:TEMP\autopilot-function.zip"
Compress-Archive -Path azure-function\host.json,azure-function\profile.ps1,azure-function\requirements.psd1,azure-function\Upload,azure-function\Status,azure-function\Health -DestinationPath $zipPath -Force
Publish-AzWebApp -ResourceGroupName rg-autopilot-tool -Name <functionAppName> -ArchivePath $zipPath -Force

# 5. Get the Function Key
# Azure Portal > Function App > App keys > default
```

Then run the Builder with "I already have an Azure Function deployed" to generate the field tool.

### Use at OOBE

1. Copy the generated files to a USB stick (`AutopilotTool-YourCompany.ps1` + `start.cmd`)
2. Boot device, wait for OOBE keyboard selection screen
3. Press **Shift+F10** to open command prompt
4. Type `d:` and press Enter (try `e:` or `f:` if not found)
5. Type `start.cmd` and press Enter
6. Select group tag, click **Upload to Autopilot**
7. Wait for sync confirmation, then restart OOBE

A printable instruction card is generated alongside the field tool for techs.

## Security Model

| Layer | Protection |
|-------|-----------|
| **No Graph credentials on device** | Managed Identity lives in Azure, never on the USB |
| **API key authentication** | Function-level key required for upload/status endpoints |
| **Input validation** | Rejects malformed hardware hashes and invalid serial numbers |
| **Instant key rotation** | Rotate in Azure Portal — all USBs stop working immediately |
| **Minimal blast radius** | Worst case: junk hashes registered. No policy or data access. |
| **Full audit trail** | Every request logged with IP, timestamp, and payload |

## Requirements

| Component | Requirement |
|-----------|------------|
| **Azure Function** | Azure subscription (Consumption plan, essentially free) |
| **Builder** | Windows, PowerShell 5.1+, Az module, Microsoft.Graph module |
| **Field Tool** | Windows 10 21H1+ or Windows 11, PowerShell 5.1 (built-in), network at OOBE |
| **Intune** | Tenant must have Microsoft Intune licensed (any plan that includes Intune Plan 1) |
| **Graph Permission** | `DeviceManagementServiceConfig.ReadWrite.All` (Application, on Managed Identity) |

## Project Structure

```
autopilot-tool/
├── azure-function/
│   ├── deploy.json               # ARM template for Azure deployment
│   ├── host.json                 # Function App configuration
│   ├── profile.ps1               # Function App startup profile
│   ├── requirements.psd1         # No external modules needed
│   ├── Upload/                   # POST /api/upload - submit hardware hash
│   ├── Status/                   # GET /api/status/{id} - check import progress
│   └── Health/                   # GET /api/health - health check
├── builder/
│   └── Build-AutopilotTool.ps1   # Admin wizard (WPF)
├── field-tool/
│   └── AutopilotTool.ps1         # OOBE field tool template (WPF)
├── setup/
│   └── Grant-GraphPermission.ps1 # One-time Graph permission grant
├── docs/
│   └── setup-guide.md            # Detailed setup instructions
├── LICENSE                       # MIT
└── README.md
```

## How It Works

1. **Tech boots a new device** and reaches the OOBE screen
2. **Shift+F10** opens a command prompt, tech runs `start.cmd` from USB
3. **Field tool** collects the hardware hash from WMI (`MDM_DevDetail_Ext01`)
4. Tech **selects a group tag** and clicks Upload
5. Field tool **POSTs** the hash to the Azure Function with the API key
6. Azure Function **validates** the input and **authenticates** with Managed Identity
7. Azure Function calls **Graph API** to import the device into Autopilot
8. Field tool **polls** the status endpoint until the import syncs (typically 2-5 minutes)
9. Tech **restarts OOBE** — the device picks up its Autopilot profile automatically

## License

MIT — see [LICENSE](LICENSE).

## Contributing

Contributions welcome. Please open an issue first to discuss changes.
