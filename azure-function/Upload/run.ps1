using namespace System.Net

param($Request, $TriggerMetadata)

$ErrorActionPreference = 'Stop'

$body = $Request.Body

if (-not $body) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = @{ error = 'Request body is required' } | ConvertTo-Json
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

$hardwareHash = $body.hardwareHash
$serialNumber = $body.serialNumber
$groupTag     = $body.groupTag

if (-not $hardwareHash -or -not $serialNumber) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = @{ error = 'hardwareHash and serialNumber are required' } | ConvertTo-Json
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

# Validate hardware hash is valid Base64 and reasonable size (4KB - 200KB)
try {
    $hashBytes = [System.Convert]::FromBase64String($hardwareHash)
    if ($hashBytes.Length -lt 100 -or $hashBytes.Length -gt 200000) {
        throw 'Hash size out of expected range'
    }
}
catch {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = @{ error = 'Invalid hardware hash format. Must be valid Base64, 4-200KB.' } | ConvertTo-Json
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

if ($groupTag -and $groupTag -notmatch '^[A-Za-z0-9\-\s]{1,128}$') {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = @{ error = 'Invalid group tag format' } | ConvertTo-Json
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

$clientIp = $Request.Headers['X-Forwarded-For']
if (-not $clientIp) { $clientIp = 'unknown' }
Write-Information "Upload request from $clientIp for serial: $serialNumber"

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
        Body       = @{ error = 'Authentication with Graph API failed. Check Managed Identity configuration.' } | ConvertTo-Json
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

$graphUri = 'https://graph.microsoft.com/beta/deviceManagement/importedWindowsAutopilotDeviceIdentities'

$importBody = @{
    '@odata.type'        = '#microsoft.graph.importedWindowsAutopilotDeviceIdentity'
    hardwareIdentifier   = $hardwareHash
    serialNumber         = $serialNumber
    state                = @{
        '@odata.type'            = 'microsoft.graph.importedWindowsAutopilotDeviceIdentityState'
        deviceImportStatus       = 'pending'
        deviceRegistrationId     = ''
        deviceErrorCode          = 0
        deviceErrorName          = ''
    }
}

if ($groupTag) {
    $importBody.groupTag = $groupTag
}

$graphHeaders = @{
    'Authorization' = "Bearer $accessToken"
    'Content-Type'  = 'application/json'
}

try {
    $response = Invoke-RestMethod -Uri $graphUri -Method POST -Headers $graphHeaders -Body ($importBody | ConvertTo-Json -Depth 5)

    Write-Information "Successfully submitted import for serial: $serialNumber, import ID: $($response.id)"

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = @{
            success  = $true
            importId = $response.id
            message  = "Hardware hash submitted for import. Use /api/status/$($response.id) to check progress."
            serial   = $serialNumber
            groupTag = $groupTag
        } | ConvertTo-Json
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
catch {
    $errorDetail = $_.Exception.Message
    Write-Error "Graph API call failed: $errorDetail"

    if ($errorDetail -match '409' -or $errorDetail -match 'already exists') {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::Conflict
            Body       = @{
                error   = 'Device already registered in Autopilot'
                serial  = $serialNumber
                detail  = $errorDetail
            } | ConvertTo-Json
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = @{
            error  = 'Failed to upload hardware hash to Autopilot'
            detail = $errorDetail
        } | ConvertTo-Json
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
