<div align="center">

# Autopilot Registration Tool

**v1.0.0**

Register devices into Windows Autopilot directly from OOBE — securely, without admin credentials on the device.

https://mrolof.dev/

</div>

---

## How It Works

An **Azure Function** sits between the device and Microsoft Graph API. The device never touches Graph credentials — it only has a Function URL and API key.

```
USB stick  ──>  Azure Function (Managed Identity)  ──>  Graph API (Autopilot Import)
```

**Anyone can run it** — field techs, end users, interns. No Intune admin role needed.

**If the API key leaks?** Attacker can submit hardware hashes. That's it. No policy access, no data exposure. Rotate the key in Azure Portal instantly.

## Getting Started

```powershell
# 1. Install prerequisites
Install-Module Az -Scope CurrentUser
Install-Module Microsoft.Graph -Scope CurrentUser

# 2. Run the Builder wizard
.\Start-Builder.cmd
```

The Builder walks you through 4 steps: deploy Azure backend, validate connection, set branding + group tags, generate the field tool.

Copy the output to a USB stick. At OOBE: `Shift+F10` → `d:` → `start.cmd`.

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

## Why Not Just Use an App Registration?

| Approach | Who can run it? | Risk if USB is stolen |
|----------|:-:|---|
| Delegated auth (admin signs in) | Admins only | None — but doesn't scale |
| App Registration + secret/cert | Anyone | Full `ReadWrite.All` — can modify Intune policies |
| DEM account | Anyone | Microsoft says DEM + Autopilot is unsupported |
| **This tool** | **Anyone** | **Can submit hardware hashes. That's it.** |

### But the Managed Identity has broad permissions?

Yes — the Managed Identity has `DeviceManagementServiceConfig.ReadWrite.All`. But the API key on the USB **is not a Graph API credential**. It's a key to the Azure Function, which only exposes 3 endpoints:

| Endpoint | What it does |
|----------|-------------|
| `POST /api/upload` | Submit a hardware hash |
| `GET /api/status/{id}` | Check import progress |
| `GET /api/health` | Health check |

If someone calls `/api/create-policy` or `/api/delete-device` — they get a **404**. Those endpoints don't exist. The Managed Identity token is generated inside the Function at runtime and is never returned in any response. The attacker never sees it and cannot use it.

## Components

| | Description |
|---|---|
| **Azure Function** | Proxy to Graph API with Managed Identity. Validates input, uploads hash, checks sync. |
| **Builder** | Admin wizard — deploys Azure resources, configures branding, generates the field tool. |
| **Field Tool** | OOBE client — collects hardware hash, picks group tag, uploads, polls for completion. |

## Requirements

- Azure subscription (Consumption plan — essentially free)
- Intune license on the tenant (any plan with Intune Plan 1)
- Windows 10 21H1+ or Windows 11
- PowerShell 5.1 (built into Windows)

## License

MIT — see [LICENSE](LICENSE).
