using namespace System.Net

param($Request, $TriggerMetadata)

$health = @{
    status    = 'healthy'
    timestamp = (Get-Date -Format 'o')
    version   = '2.0.0'
}

try {
    $tokenUri = "$($env:IDENTITY_ENDPOINT)?resource=https://graph.microsoft.com&api-version=2019-08-01"
    $null = Invoke-RestMethod -Uri $tokenUri -Method GET -Headers @{
        'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER
    }
    $health.identity = 'available'
}
catch {
    $health.status = 'degraded'
    $health.identity = 'unavailable'
}

# Report enabled features
$features = @{}
$features.auditLog = if ($env:ENABLE_AUDIT_LOG -eq 'true') { 'enabled' } else { 'disabled' }
$features.teamsNotify = if ($env:TEAMS_WEBHOOK_URL) { 'enabled' } else { 'disabled' }
$features.qrAuth = if ($env:ENABLE_QR_AUTH -eq 'true') { 'enabled' } else { 'disabled' }
$health.features = $features

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body       = $health | ConvertTo-Json
    Headers    = @{ 'Content-Type' = 'application/json' }
})
