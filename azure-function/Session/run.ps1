using namespace System.Net

param($Request, $TriggerMetadata)

$ErrorActionPreference = 'Stop'

# QR auth must be enabled
if ($env:ENABLE_QR_AUTH -ne 'true') {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::NotFound
        Body       = @{ error = 'QR authentication is not enabled' } | ConvertTo-Json
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

Import-Module (Join-Path $PSScriptRoot '..\Modules\SessionManager.psm1') -Force

$body = $Request.Body
$serialNumber = $body.serialNumber

if (-not $serialNumber) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = @{ error = 'serialNumber is required' } | ConvertTo-Json
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

if ($serialNumber -notmatch '^[A-Za-z0-9\-\s\._]{1,64}$') {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = @{ error = 'Invalid serial number format' } | ConvertTo-Json
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

try {
    $session = New-Session -SerialNumber $serialNumber
    $approvalPageUrl = $env:APPROVAL_PAGE_URL
    $qrUrl = "${approvalPageUrl}?session=$($session.SessionId)&pk=$($session.PartitionKey)"

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = @{
            sessionId    = $session.SessionId
            partitionKey = $session.PartitionKey
            qrUrl        = $qrUrl
            expiresAt    = $session.ExpiresAt
        } | ConvertTo-Json
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
catch {
    Write-Error "Session creation failed: $_"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = @{ error = 'Failed to create session' } | ConvertTo-Json
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
