<#
.SYNOPSIS
    Grants the Azure Function's Managed Identity the required Graph API permission.

.DESCRIPTION
    Run this ONCE after deploying the Azure Function.
    Assigns DeviceManagementServiceConfig.ReadWrite.All (Application) to the
    Function App's System-Assigned Managed Identity.

    Requires: Microsoft.Graph PowerShell module + Global Administrator role.

.PARAMETER ManagedIdentityPrincipalId
    The Object ID of the Function App's Managed Identity.
    (Output from the Bicep deployment: managedIdentityPrincipalId)

.EXAMPLE
    .\Grant-GraphPermission.ps1 -ManagedIdentityPrincipalId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.AUTHOR
    MrOlof
    https://mrolof.dev
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ManagedIdentityPrincipalId
)

$ErrorActionPreference = 'Stop'

# Check for Microsoft.Graph module
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Applications)) {
    Write-Host "Installing Microsoft.Graph module..." -ForegroundColor Yellow
    Install-Module Microsoft.Graph -Scope CurrentUser -Force
}

# Connect to Graph with required scopes
Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
Write-Host "You will be prompted to sign in as a Global Administrator." -ForegroundColor Yellow
Connect-MgGraph -Scopes 'Application.ReadWrite.All', 'AppRoleAssignment.ReadWrite.All'

# Microsoft Graph service principal (well-known App ID)
$graphAppId = '00000003-0000-0000-c000-000000000000'
$graphSp = Get-MgServicePrincipal -Filter "appId eq '$graphAppId'"

# Find the DeviceManagementServiceConfig.ReadWrite.All app role
$appRole = $graphSp.AppRoles | Where-Object {
    $_.Value -eq 'DeviceManagementServiceConfig.ReadWrite.All'
}

if (-not $appRole) {
    Write-Error "Could not find DeviceManagementServiceConfig.ReadWrite.All app role."
    return
}

Write-Host "Found app role: $($appRole.Value) (ID: $($appRole.Id))" -ForegroundColor Green

# Check if already assigned
$existing = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $ManagedIdentityPrincipalId | Where-Object {
    $_.AppRoleId -eq $appRole.Id
}

if ($existing) {
    Write-Host "Permission already granted. No action needed." -ForegroundColor Green
    return
}

# Assign the role
$params = @{
    PrincipalId = $ManagedIdentityPrincipalId
    ResourceId  = $graphSp.Id
    AppRoleId   = $appRole.Id
}

New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $ManagedIdentityPrincipalId -BodyParameter $params

Write-Host ""
Write-Host "Done! Managed Identity has been granted DeviceManagementServiceConfig.ReadWrite.All." -ForegroundColor Green
Write-Host "The Azure Function can now upload Autopilot hardware hashes via Graph API." -ForegroundColor Green
Write-Host ""

Disconnect-MgGraph
