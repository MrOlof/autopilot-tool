using namespace System.Net

param($Request, $TriggerMetadata)

# Health check - verifies the Function is running and Managed Identity is accessible

$health = @{
    status    = 'healthy'
    timestamp = (Get-Date -Format 'o')
    version   = '1.0.0'
}

# Check Managed Identity availability
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

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body       = $health | ConvertTo-Json
    Headers    = @{ 'Content-Type' = 'application/json' }
})
