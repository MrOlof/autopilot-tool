using namespace System.Net

param($Request, $TriggerMetadata)

$ErrorActionPreference = 'Stop'

if ($env:ENABLE_QR_AUTH -ne 'true') {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::NotFound
        Body       = @{ error = 'QR authentication is not enabled' } | ConvertTo-Json
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

Import-Module (Join-Path $PSScriptRoot '..\Modules\SessionManager.psm1') -Force

$sessionId = $Request.Params.sessionId
$partitionKey = $Request.Query['pk']

if (-not $sessionId -or -not $partitionKey) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = @{ error = 'sessionId and pk query parameter are required' } | ConvertTo-Json
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

if ($sessionId -notmatch '^[0-9a-fA-F\-]{36}$') {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = @{ error = 'Invalid session ID format' } | ConvertTo-Json
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

try {
    $session = Get-Session -SessionId $sessionId -PartitionKey $partitionKey

    if (-not $session) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::NotFound
            Body       = @{ error = 'Session not found' } | ConvertTo-Json
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    # Check expiry
    $expiresAt = [DateTime]::Parse($session.ExpiresAt).ToUniversalTime()
    if ([DateTime]::UtcNow -gt $expiresAt) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = @{
                status       = 'expired'
                sessionId    = $sessionId
                serialNumber = $session.SerialNumber
            } | ConvertTo-Json
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    $responseBody = @{
        status       = $session.Status
        sessionId    = $sessionId
        serialNumber = $session.SerialNumber
    }

    if ($session.Status -eq 'approved' -and $session.Token) {
        $responseBody.token = $session.Token
        $responseBody.approvedBy = $session.ApprovedBy
    }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = $responseBody | ConvertTo-Json
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
catch {
    Write-Error "Session status check failed: $_"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = @{ error = 'Failed to check session status' } | ConvertTo-Json
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
