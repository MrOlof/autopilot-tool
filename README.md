<div align="center">

# Autopilot Registration Tool

**v2.0.0**

Register devices into Windows Autopilot directly from OOBE — no admin credentials, no secrets on the USB.

https://mrolof.dev/ | [Read the full blog post](https://mrolof.dev/blog/autopilot-registration-tool)

</div>

---

## What's New in v2

- **QR Code Authentication** — technician scans a QR code on their phone, signs in with Entra ID on a hosted approval page, and approves the registration. No static keys needed on the USB.
- **Entra Security Group Gating** — only members of an `AutopilotRegistrators` security group can approve registrations. Works with Entra ID Governance and Entitlement Management for self-service access requests and time-limited access.
- **Teams Webhook Notifications** — Adaptive Card alerts sent to a Teams channel on every registration event (success, duplicate, failure) with serial number, group tag, and who registered it.
- **Audit Log** — every registration recorded in Azure Table Storage. Track who registered which device, when, from where, and whether it succeeded. Queryable by month, searchable by serial number.
- **Hosted Approval Page** — mobile-friendly Entra ID sign-in page served directly from the Azure Function. Techs scan the QR, authenticate, and approve — all in the browser.
- **Redesigned UI** — darker theme, resizable windows, focus highlights, rounded corners in both Builder and Field Tool.
- **Automated Entra Setup** — Builder creates the App Registration, security group, grants Graph permissions, and applies admin consent automatically.

---

## How It Works

### Legacy Mode (v1)

```
USB (API key) → Azure Function → Graph API → Autopilot
```

### QR Auth Mode (v2)

```
  OOBE Device                        Technician's Phone
  ============                       ====================
  1. Run field tool
  2. QR code appears on screen  -->  3. Scan QR code
                                     4. Sign in with Entra ID
                                     5. Approve registration
  6. Device receives token
  7. Upload hash with token     -->  Azure Function → Graph API → Autopilot
```

No secrets on the USB. Every registration tied to a user identity.

---

## Security Model

### What the USB contains

| Mode | USB contents | If USB is stolen |
|---|---|---|
| Legacy (v1) | Function URL + API key | Attacker can submit hashes (nothing else) |
| QR Auth (v2) | Function URL only | Useless without an authorized Entra account |

### What the attacker **cannot** do (either mode)

- Read Intune data
- Modify policies
- Access Graph API directly
- Extract credentials

### QR Auth security layers

- Entra ID authentication (MFA, Conditional Access apply)
- Security group membership check
- 15-minute session TTL
- Single-use tokens (consumed after upload)
- RSA signature verification on Entra tokens
- HS256 signed session JWTs

---

## Quick Start

### Admin (one-time setup)

```powershell
Install-Module Az -Scope CurrentUser
Install-Module Microsoft.Graph -Scope CurrentUser
.\Start-Builder.cmd
```

The Builder wizard will:

1. Deploy Azure Function backend
2. Configure Graph API permissions
3. Set up QR auth (App Registration, security group, admin consent) — optional
4. Configure branding and group tags
5. Generate the field tool for USB deployment

### Field usage

1. Boot device to OOBE
2. Press `Shift + F10`
3. Run:

```
d:\start.cmd
```

4. If QR auth is enabled: scan the QR code with your phone and approve
5. Device registers in Autopilot

---

## API Endpoints

### Core

| Endpoint | Auth | Purpose |
|---|---|---|
| `POST /api/upload` | Function key or session token | Upload hardware hash |
| `GET /api/status/{id}` | Function key | Check import status |
| `GET /api/health` | Anonymous | Health check + feature status |

### QR Auth (enabled via `ENABLE_QR_AUTH`)

| Endpoint | Auth | Purpose |
|---|---|---|
| `POST /api/session` | Anonymous | Create approval session |
| `GET /api/session/{id}/status` | Anonymous | Poll session state |
| `POST /api/session/{id}/approve` | Entra ID token | Approve a session |
| `GET /api/approve` | Anonymous | Approval page (HTML) |

Anything else returns **404**.

---

## Optional Features

All features are off by default. Enable via Function App settings:

| Feature | App Setting | Description |
|---|---|---|
| QR Authentication | `ENABLE_QR_AUTH=true` | Entra ID session-based auth |
| Audit Log | `ENABLE_AUDIT_LOG=true` | Registration history in Table Storage |
| Teams Notifications | `TEAMS_WEBHOOK_URL=<url>` | Adaptive Card alerts to Teams |
| Security Group | `SECURITY_GROUP_ID=<guid>` | Restrict approvals to group members |

---

## Components

| Component | Description |
|---|---|
| **Azure Function** | PowerShell 7.2 proxy to Graph API, Managed Identity |
| **Builder** | WPF wizard — deploys backend, configures features, generates field tool |
| **Field Tool** | WPF app — runs at OOBE, collects hash, handles QR flow, uploads |

---

## Graph API Permissions

Granted to the Function App's Managed Identity:

| Permission | Required | Purpose |
|---|---|---|
| `DeviceManagementServiceConfig.ReadWrite.All` | Always | Autopilot hash upload |
| `GroupMember.Read.All` | QR auth | Security group membership check |
| `User.Read.All` | QR auth | User lookup for group check |

```powershell
# Grant all permissions (QR auth)
.\setup\Grant-GraphPermission.ps1 -ManagedIdentityPrincipalId "<id>" -IncludeGroupRead

# Grant base permission only (legacy mode)
.\setup\Grant-GraphPermission.ps1 -ManagedIdentityPrincipalId "<id>"
```

---

## Manual Setup

<details>
<summary>CLI setup without Builder</summary>

```powershell
az login
az group create --name rg-autopilot-tool --location westeurope

az deployment group create \
  --resource-group rg-autopilot-tool \
  --template-file azure-function/deploy.json \
  --parameters namePrefix=autopilot-tool

# Grant permissions (add -IncludeGroupRead for QR auth)
.\setup\Grant-GraphPermission.ps1 -ManagedIdentityPrincipalId "<principalId>" -IncludeGroupRead

# Deploy code
cd azure-function
func azure functionapp publish <functionAppName>

# Get key from Azure Portal > Function App > App keys > default
```

</details>

---

## Optional Hardening

- **Rate limiting** — per-IP throttling via API Management or Table Storage counters
- **IP restrictions** — lock Function App to known office/VPN ranges
- **Application Insights** — full request logging (included in ARM template for manual deploys)
- **Conditional Access** — MFA and device compliance policies apply to QR auth sign-in
- **Workload Identity CA** — restrict Managed Identity token issuance to specific IPs (requires Entra Workload ID Premium)
- **Resource locks** — Read-Only lock on the resource group

---

## Requirements

- Azure subscription (Consumption plan)
- Intune license (Plan 1+)
- Windows 10 21H1+ or Windows 11
- PowerShell 5.1

---

## License

MIT — see [LICENSE](LICENSE).
