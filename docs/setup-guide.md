# Setup Guide

Complete setup guide for deploying the Autopilot Registration Tool.

## Prerequisites

- Azure subscription with contributor access
- Global Administrator role in Entra ID (for one-time Graph permission grant)
- Azure CLI or Azure PowerShell installed
- PowerShell 5.1+ on admin workstation

## Step 1: Deploy Azure Function

### Option A: Azure CLI

```bash
# Login
az login

# Create resource group
az group create --name rg-autopilot-tool --location westeurope

# Deploy infrastructure
az deployment group create \
  --resource-group rg-autopilot-tool \
  --template-file azure-function/deploy.bicep \
  --parameters namePrefix=autopilot-tool

# Note the outputs:
# - functionAppName
# - functionAppUrl
# - managedIdentityPrincipalId
```

### Option B: Azure PowerShell

```powershell
Connect-AzAccount

New-AzResourceGroup -Name 'rg-autopilot-tool' -Location 'westeurope'

New-AzResourceGroupDeployment `
  -ResourceGroupName 'rg-autopilot-tool' `
  -TemplateFile 'azure-function/deploy.bicep' `
  -namePrefix 'autopilot-tool'
```

## Step 2: Grant Graph API Permission

This grants the Managed Identity permission to upload Autopilot hardware hashes.

```powershell
.\setup\Grant-GraphPermission.ps1 -ManagedIdentityPrincipalId "<principalId>"
```

You will be prompted to sign in as a Global Administrator.

## Step 3: Deploy Function Code

Install Azure Functions Core Tools if not already installed:

```bash
npm install -g azure-functions-core-tools@4
```

Deploy:

```bash
cd azure-function
func azure functionapp publish <functionAppName>
```

## Step 4: Verify Deployment

Open a browser and navigate to:

```
https://<functionAppName>.azurewebsites.net/api/health
```

You should see:

```json
{
  "status": "healthy",
  "identity": "available",
  "version": "1.0.0"
}
```

## Step 5: Get Function Key

### Via Azure Portal

1. Navigate to your Function App
2. Click **App Keys** in the left menu
3. Copy the **default** function key

### Via Azure CLI

```bash
az functionapp keys list \
  --name <functionAppName> \
  --resource-group rg-autopilot-tool \
  --query "functionKeys.default" -o tsv
```

## Step 6: Run the Builder

```powershell
.\builder\Build-AutopilotTool.ps1
```

1. Enter your company name
2. Browse for your company logo (PNG, 210x110px recommended)
3. Enter the Function App URL (e.g., `https://autopilot-tool-abc123.azurewebsites.net`)
4. Enter the Function Key from Step 5
5. Add your group tags (e.g., Standard, Kiosk, Shared, VIP)
6. Set the default tag
7. Click **Test Connection** to verify
8. Click **Generate Field Tool**

The configured script is saved to `field-tool/output/`.

### Optional: Generate .exe

Install PS2EXE first:

```powershell
Install-Module ps2exe -Scope CurrentUser
```

Then re-run the Builder — it will automatically generate an `.exe` alongside the `.ps1`.

## Step 7: Prepare USB Stick

Copy the generated file(s) to a USB stick:

```
USB:\
  AutopilotTool-YourCompany.ps1
  AutopilotTool-YourCompany.exe  (optional)
```

## Step 8: Use at OOBE

1. Boot the device
2. At the keyboard selection screen, press **Shift+F10**
3. Type `powershell` and press Enter
4. Navigate to the USB drive: `cd D:\` (try E:\, F:\ if D doesn't work)
5. Run: `.\AutopilotTool-YourCompany.ps1`
6. Select a group tag from the dropdown
7. Click **Upload to Autopilot**
8. Wait for the sync confirmation
9. Close the tool
10. Type `shutdown /r /t 0` to restart, or close the command prompt and continue OOBE

The device will now pick up its Autopilot profile on the next OOBE run.

## Troubleshooting

### "Connection failed" in Builder

- Verify the Function App URL is correct (include `https://`)
- Ensure the Function App is running (check Azure Portal)
- Check if your network allows outbound HTTPS

### "Authentication failed" during upload

- Run `Grant-GraphPermission.ps1` again
- Verify the Managed Identity is enabled on the Function App
- Check Application Insights for detailed error logs

### "Device already registered"

The device hash is already in Autopilot. No action needed — restart OOBE.

### Upload succeeds but sync times out

The hash was uploaded successfully. Autopilot sync can take up to 15 minutes. Restart OOBE and wait — the profile will be assigned.

### No network at OOBE

The device needs internet connectivity. Connect via Ethernet or configure Wi-Fi before running the tool.
