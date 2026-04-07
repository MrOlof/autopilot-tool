<#
.SYNOPSIS
    Grants the Azure Function's Managed Identity the required Graph API permissions.

.DESCRIPTION
    Run this ONCE after deploying the Azure Function.
    Assigns DeviceManagementServiceConfig.ReadWrite.All (Application) to the
    Function App's System-Assigned Managed Identity.

    When -IncludeGroupRead is specified, also grants GroupMember.Read.All
    (required for QR auth security group membership checks).

    Requires: Microsoft.Graph PowerShell module + Global Administrator role.

.PARAMETER ManagedIdentityPrincipalId
    The Object ID of the Function App's Managed Identity.
    (Output from the Bicep deployment: managedIdentityPrincipalId)

.PARAMETER IncludeGroupRead
    Also grant GroupMember.Read.All for security group membership checks.

.EXAMPLE
    .\Grant-GraphPermission.ps1 -ManagedIdentityPrincipalId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.EXAMPLE
    .\Grant-GraphPermission.ps1 -ManagedIdentityPrincipalId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -IncludeGroupRead

.AUTHOR
    MrOlof
    https://mrolof.dev
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ManagedIdentityPrincipalId,

    [switch]$IncludeGroupRead
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

# Build the list of required roles
$roleNames = @('DeviceManagementServiceConfig.ReadWrite.All')
if ($IncludeGroupRead) {
    $roleNames += 'GroupMember.Read.All'
    $roleNames += 'User.Read.All'
}

# Get existing assignments
$existingAssignments = Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $ManagedIdentityPrincipalId

foreach ($roleName in $roleNames) {
    $appRole = $graphSp.AppRoles | Where-Object { $_.Value -eq $roleName }

    if (-not $appRole) {
        Write-Error "Could not find $roleName app role."
        continue
    }

    Write-Host "Found app role: $($appRole.Value) (ID: $($appRole.Id))" -ForegroundColor Green

    $existing = $existingAssignments | Where-Object { $_.AppRoleId -eq $appRole.Id }

    if ($existing) {
        Write-Host "$roleName already granted. Skipping." -ForegroundColor Green
        continue
    }

    $params = @{
        PrincipalId = $ManagedIdentityPrincipalId
        ResourceId  = $graphSp.Id
        AppRoleId   = $appRole.Id
    }

    New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $ManagedIdentityPrincipalId -BodyParameter $params
    Write-Host "$roleName granted." -ForegroundColor Green
}

Write-Host ""
Write-Host "Done! Managed Identity permissions configured." -ForegroundColor Green
if ($IncludeGroupRead) {
    Write-Host "Granted: DeviceManagementServiceConfig.ReadWrite.All + GroupMember.Read.All + User.Read.All" -ForegroundColor Green
} else {
    Write-Host "Granted: DeviceManagementServiceConfig.ReadWrite.All" -ForegroundColor Green
}
Write-Host ""

Disconnect-MgGraph
