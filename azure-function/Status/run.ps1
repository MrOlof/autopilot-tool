using namespace System.Net

param($Request, $TriggerMetadata)

$ErrorActionPreference = 'Stop'

$importId = $Request.Params.importId

if (-not $importId) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = @{ error = 'importId is required' } | ConvertTo-Json
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

# Validate importId format (GUID)
if ($importId -notmatch '^[0-9a-fA-F\-]{36}$') {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = @{ error = 'Invalid importId format' } | ConvertTo-Json
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

# --- Get Managed Identity Token ---

try {
    $tokenUri = "$($env:IDENTITY_ENDPOINT)?resource=https://graph.microsoft.com&api-version=2019-08-01"
    $tokenResponse = Invoke-RestMethod -Uri $tokenUri -Method GET -Headers @{
        'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER
    }
    $accessToken = $tokenResponse.access_token
}
catch {
    Write-Error "Failed to acquire Managed Identity token: $_"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = @{ error = 'Authentication failed' } | ConvertTo-Json
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

# --- Query Import Status ---

$graphUri = "https://graph.microsoft.com/beta/deviceManagement/importedWindowsAutopilotDeviceIdentities/$importId"

try {
    $response = Invoke-RestMethod -Uri $graphUri -Method GET -Headers @{
        'Authorization' = "Bearer $accessToken"
        'Content-Type'  = 'application/json'
    }

    $state = $response.state

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = @{
            importId     = $importId
            status       = $state.deviceImportStatus
            errorCode    = $state.deviceErrorCode
            errorName    = $state.deviceErrorName
            serialNumber = $response.serialNumber
            groupTag     = $response.groupTag
        } | ConvertTo-Json
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
catch {
    $errorDetail = $_.Exception.Message

    if ($errorDetail -match '404') {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::NotFound
            Body       = @{ error = 'Import not found'; importId = $importId } | ConvertTo-Json
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = @{ error = 'Failed to check import status'; detail = $errorDetail } | ConvertTo-Json
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
