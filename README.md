<div align="center">

# Autopilot Registration Tool

**v1.0.0**

A secure, open-source tool for uploading Windows Autopilot hardware hashes directly from OOBE.
Built with an Azure Function proxy architecture — no admin credentials on the device, ever.

---

</div>

## Features

- **Azure Function Proxy:** Hardware hash uploads go through an Azure Function — Graph API credentials never leave Azure
- **Builder Wizard:** Step-by-step admin GUI that deploys Azure resources, configures branding, and generates the field tool
- **Field Tool:** Branded WPF app that collects hardware hashes and uploads them at OOBE via `Shift+F10`
- **Group Tags:** Configurable dropdown for techs to assign Autopilot group tags during registration
- **Zero Dependencies:** Field tool requires no module installation — runs on built-in PowerShell 5.1
- **Instant Key Rotation:** Compromised API key? Rotate it in Azure Portal, all USBs stop working immediately

## Why Not Just Use an App Registration?

Existing tools store credentials (client secrets, certificates) directly on the USB stick. If that USB is lost or stolen, the attacker gets full `DeviceManagementServiceConfig.ReadWrite.All` access — they can modify Intune policies, enrollment configs, and compliance settings.

| Approach | Who can run it? | Risk if credentials leak |
|----------|:-:|---|
| **Delegated auth** (admin signs in) | Admins only | None — but doesn't scale |
| **App Registration + secret/cert** | Anyone | Full Graph API access to Intune service config |
| **DEM account** | Anyone | Enrollment abuse — Microsoft says DEM + Autopilot is unsupported |
| **This tool (Function proxy)** | Anyone | Can submit hardware hashes. That's it. |

This tool's approach: the USB only has a **Function URL + API key**. The key can only call your Azure Function, which only calls one Graph endpoint (device import). Even if the key leaks, an attacker cannot touch policies, configs, or data.

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

| Component | Description | Run by |
|-----------|-------------|--------|
| **Azure Function** | Proxy between device and Graph API. Validates input, uploads hash, checks sync status. Authenticates via System-Assigned Managed Identity. | Runs in Azure |
| **Builder** | WPF wizard that deploys Azure resources, configures company branding and group tags, generates the field tool. | IT Admin (one-time) |
| **Field Tool** | WPF app for OOBE. Collects hardware hash via WMI, lets user pick a group tag, uploads via Azure Function, polls for completion. | Tech / End User |

## Quick Start

### Option A: Use the Builder (recommended)

```powershell
# Install prerequisites
Install-Module Az -Scope CurrentUser
Install-Module Microsoft.Graph -Scope CurrentUser

# Launch the Builder wizard
.\builder\Build-AutopilotTool.ps1
```

The Builder walks you through 4 steps:

1. **Backend** — Deploy Azure Function automatically, or connect to an existing one
2. **Validate** — Enter Function URL + key, verify the connection works
3. **Branding** — Set company name, configure available group tags
4. **Generate** — Create the field tool, USB launcher, and printable instruction card

### Option B: Manual CLI setup

<details>
<summary>Click to expand manual setup instructions</summary>

```powershell
# 1. Create resource group
az login
az group create --name rg-autopilot-tool --location westeurope

# 2. Deploy Azure Function (ARM template — no Bicep CLI required)
az deployment group create \
  --resource-group rg-autopilot-tool \
  --template-file azure-function/deploy.json \
  --parameters namePrefix=autopilot-tool

# 3. Grant Graph API permission (requires Global Admin)
.\setup\Grant-GraphPermission.ps1 -ManagedIdentityPrincipalId "<principalId>"

# 4. Deploy function code
Compress-Archive -Path azure-function\host.json,azure-function\profile.ps1,azure-function\requirements.psd1,azure-function\Upload,azure-function\Status,azure-function\Health -DestinationPath $env:TEMP\func.zip -Force
Publish-AzWebApp -ResourceGroupName rg-autopilot-tool -Name <functionAppName> -ArchivePath $env:TEMP\func.zip -Force

# 5. Get the Function Key from Azure Portal > Function App > App keys > default
```

Then run the Builder with "I already have an Azure Function deployed" to generate the field tool.

</details>

### Use at OOBE

1. Copy the generated files to a USB stick
2. Boot device, reach OOBE keyboard selection screen
3. Press **Shift+F10** to open command prompt
4. Type `d:` then `start.cmd` (try `e:` or `f:` if `d:` doesn't work)
5. Select group tag, click **Upload to Autopilot**
6. Wait for sync confirmation (~2-5 minutes), restart OOBE

A printable instruction card is generated alongside the field tool.

## Security

| Layer | Protection |
|-------|-----------|
| **No Graph credentials on device** | Managed Identity lives in Azure, never on the USB |
| **API key authentication** | Function-level key required for all endpoints |
| **Input validation** | Rejects malformed hardware hashes and invalid serial numbers |
| **Instant key rotation** | Rotate in Azure Portal — all existing USBs stop working |
| **Minimal blast radius** | Worst case: junk hashes registered. No policy or data access |
| **Full audit trail** | Every request logged with IP, timestamp, and payload |

## Requirements

| Component | Requirement |
|-----------|------------|
| **Azure** | Azure subscription (Consumption plan — essentially free for this workload) |
| **Builder** | Windows, PowerShell 5.1+, Az and Microsoft.Graph modules |
| **Field Tool** | Windows 10 21H1+ or Windows 11, PowerShell 5.1 (built-in), network connectivity |
| **Intune** | Tenant must have Intune licensed (any plan including Intune Plan 1) |
| **Permissions** | `DeviceManagementServiceConfig.ReadWrite.All` (Application, on Managed Identity only) |

## How It Works

1. Tech boots a new device and reaches OOBE
2. `Shift+F10` opens command prompt, tech runs `start.cmd` from USB
3. Field tool collects hardware hash from WMI
4. Tech selects a group tag and clicks Upload
5. Field tool POSTs the hash to the Azure Function
6. Azure Function validates input and authenticates with Managed Identity
7. Azure Function calls Graph API to import the device into Autopilot
8. Field tool polls until the import syncs (typically 2-5 minutes)
9. Tech restarts OOBE — the device picks up its Autopilot profile

## Project Structure

```
autopilot-tool/
├── azure-function/
│   ├── deploy.json               # ARM template for deployment
│   ├── host.json                 # Function App config
│   ├── Upload/                   # POST /api/upload
│   ├── Status/                   # GET /api/status/{id}
│   └── Health/                   # GET /api/health
├── builder/
│   └── Build-AutopilotTool.ps1   # Admin wizard (WPF)
├── field-tool/
│   └── AutopilotTool.ps1         # OOBE field tool (WPF)
├── setup/
│   └── Grant-GraphPermission.ps1 # One-time permission grant
├── docs/
│   └── setup-guide.md
└── LICENSE
```

## Supported Platforms

| Windows Version | Status |
|----------------|--------|
| Windows 10 21H1+ | Supported |
| Windows 10 22H2 | Supported |
| Windows 11 (all versions) | Supported |

## License

MIT — see [LICENSE](LICENSE).

## Contributing

Contributions welcome. Please open an issue first to discuss proposed changes.
