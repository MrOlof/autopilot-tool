<div align="center">

# Autopilot Registration Tool

**v1.0.0**

Register devices into Windows Autopilot directly from OOBE - without exposing admin credentials.

https://mrolof.dev/

</div>

---

## What This Solves

- No admin login on device
- No Graph credentials on USB
- Safe for field techs, vendors, or end users
- Works directly from OOBE (Shift+F10)

---

## Quick Start

**Admin (one-time setup):**

```powershell
Install-Module Az -Scope CurrentUser
Install-Module Microsoft.Graph -Scope CurrentUser
.\Start-Builder.cmd
```

**Field usage:**

1. Boot device to OOBE
2. Press `Shift + F10`
3. Run:

```
d:\start.cmd
```

Done. Device registers in Autopilot.

---

## How It Works

```
USB → Azure Function (Managed Identity) → Microsoft Graph → Autopilot
```

- Device sends hardware hash to Azure Function
- Function authenticates using Managed Identity
- Graph API import happens server-side

Device never touches Graph credentials.

---

## Security Model

### What the USB contains

- Function URL
- API key

### If the USB leaks

Attacker can:

- Submit hardware hashes

Attacker **cannot**:

- Read Intune data
- Modify policies
- Access Graph API
- Extract credentials

### Why this is safe

- API key only talks to Azure Function
- Function exposes **only 3 endpoints**
- Managed Identity token never leaves Azure

---

## API Surface

| Endpoint | Purpose |
|---|---|
| `POST /api/upload` | Upload hardware hash |
| `GET /api/status/{id}` | Check import status |
| `GET /api/health` | Health check |

Anything else → **404**

---

## Why Not Use Other Methods?

| Approach | Who can run it | Risk if USB is stolen |
|---|---|---|
| Delegated admin login | Admins only | None |
| App registration (secret/cert) | Anyone | Full Graph access (dangerous) |
| DEM account | Anyone | Unsupported by Microsoft |
| **This tool** | **Anyone** | **Can only upload hashes** |

---

## Components

| Component | Description |
|---|---|
| **Azure Function** | Secure proxy to Graph API |
| **Builder** | Deploys backend + generates tool |
| **Field Tool** | Runs in OOBE and uploads hash |

---

## Setup (Detailed)

### 1. Install prerequisites

```powershell
Install-Module Az -Scope CurrentUser
Install-Module Microsoft.Graph -Scope CurrentUser
```

### 2. Run builder

```powershell
.\Start-Builder.cmd
```

Builder will:

1. Deploy Azure backend
2. Configure permissions
3. Set branding + group tags
4. Generate field tool

<details>
<summary>Manual CLI setup (without Builder)</summary>

```powershell
az login
az group create --name rg-autopilot-tool --location westeurope

az deployment group create \
  --resource-group rg-autopilot-tool \
  --template-file azure-function/deploy.json \
  --parameters namePrefix=autopilot-tool

.\setup\Grant-GraphPermission.ps1 -ManagedIdentityPrincipalId "<principalId>"

# Deploy code, then get key from Azure Portal > Function App > App keys > default
```

</details>

---

## Optional Hardening

Not enabled by default, but available if your environment requires it:

- **Rate limiting** - add per-IP request throttling via Azure Table Storage or API Management
- **IP restrictions** - lock the Function App to known office/VPN IP ranges
- **Application Insights** - enable full request logging and alerting (included in ARM template for manual deploys)
- **Conditional Access for Workload Identities** - restrict Managed Identity token issuance to specific IPs (requires Entra Workload ID Premium)
- **Resource locks** - apply a Read-Only lock on the resource group to prevent Function code changes

The default setup is intentionally minimal. The blast radius of a leaked API key is already limited to submitting hardware hashes.

---

## Requirements

- Azure subscription (Consumption plan)
- Intune license (Plan 1+)
- Windows 10 21H1+ or Windows 11
- PowerShell 5.1

---

## License

MIT - see [LICENSE](LICENSE).
