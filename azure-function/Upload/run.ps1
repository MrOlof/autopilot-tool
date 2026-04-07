using namespace System.Net

param($Request, $TriggerMetadata)

$ErrorActionPreference = 'Stop'

# Optional modules — loaded only when features are enabled
if ($env:ENABLE_AUDIT_LOG -eq 'true' -or $env:ENABLE_QR_AUTH -eq 'true') {
    Import-Module (Join-Path $PSScriptRoot '..\Modules\TableStorage.psm1') -Force
}

# Teams Workflow notification helper
function Send-TeamsNotification {
    param(
        [string]$SerialNumber,
        [string]$GroupTag,
        [string]$Status,
        [string]$RegisteredBy,
        [string]$ErrorDetail
    )
    $webhookUrl = $env:TEAMS_WEBHOOK_URL
    if (-not $webhookUrl) { return }

    $facts = @(
        @{ title = 'Serial Number'; value = $SerialNumber }
        @{ title = 'Group Tag'; value = if ($GroupTag) { $GroupTag } else { 'None' } }
        @{ title = 'Status'; value = $Status }
        @{ title = 'Timestamp'; value = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss UTC') }
    )
    if ($RegisteredBy) {
        $facts += @{ title = 'Registered By'; value = $RegisteredBy }
    }
    if ($ErrorDetail) {
        $facts += @{ title = 'Error'; value = $ErrorDetail }
    }

    $card = @{
        type        = 'message'
        attachments = @(@{
            contentType = 'application/vnd.microsoft.card.adaptive'
            content     = @{
                '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
                type      = 'AdaptiveCard'
                version   = '1.4'
                body      = @(
                    @{ type = 'TextBlock'; text = "Autopilot Device $Status"; weight = 'Bolder'; size = 'Medium' }
                    @{ type = 'FactSet'; facts = $facts }
                )
            }
        })
    }

    try {
        Invoke-RestMethod -Uri $webhookUrl -Method POST `
            -Body ($card | ConvertTo-Json -Depth 10) `
            -ContentType 'application/json' -TimeoutSec 10 | Out-Null
    }
    catch {
        Write-Warning "Teams notification failed: $_"
    }
}

# Identity tracking — populated by QR session auth when enabled
$registeredBy = $null

# QR session auth: if Bearer token present, validate and extract identity
$authHeader = $Request.Headers['Authorization']
if ($authHeader -and $authHeader -match '^Bearer (.+)$') {
    if ($env:ENABLE_QR_AUTH -eq 'true') {
        Import-Module (Join-Path $PSScriptRoot '..\Modules\SessionManager.psm1') -Force
        try {
            $claims = Test-SessionToken -Token $Matches[1]
            $registeredBy = $claims.upn
            Set-SessionConsumed -SessionId $claims.sessionId -PartitionKey $claims.pk
        }
        catch {
            Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::Unauthorized
                Body       = @{ error = "Session token validation failed: $_" } | ConvertTo-Json
                Headers    = @{ 'Content-Type' = 'application/json' }
            })
            return
        }
    }
}

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

    # Audit log
    if ($env:ENABLE_AUDIT_LOG -eq 'true') {
        try {
            Write-TableEntity -TableName 'registrations' `
                -PartitionKey (Get-Date -Format 'yyyy-MM') `
                -RowKey $response.id `
                -Properties @{
                    SerialNumber  = $serialNumber
                    GroupTag      = if ($groupTag) { $groupTag } else { '' }
                    RegisteredBy  = if ($registeredBy) { $registeredBy } else { '' }
                    ClientIP      = $clientIp
                    GraphImportId = $response.id
                    Status        = 'Success'
                }
        }
        catch { Write-Warning "Audit log write failed: $_" }
    }

    # Teams notification
    Send-TeamsNotification -SerialNumber $serialNumber -GroupTag $groupTag `
        -Status 'Registered' -RegisteredBy $registeredBy

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
        if ($env:ENABLE_AUDIT_LOG -eq 'true') {
            try {
                Write-TableEntity -TableName 'registrations' `
                    -PartitionKey (Get-Date -Format 'yyyy-MM') `
                    -RowKey ([guid]::NewGuid().ToString()) `
                    -Properties @{
                        SerialNumber = $serialNumber
                        GroupTag     = if ($groupTag) { $groupTag } else { '' }
                        RegisteredBy = if ($registeredBy) { $registeredBy } else { '' }
                        ClientIP     = $clientIp
                        Status       = 'Duplicate'
                        ErrorDetail  = $errorDetail
                    }
            }
            catch { Write-Warning "Audit log write failed: $_" }
        }
        Send-TeamsNotification -SerialNumber $serialNumber -GroupTag $groupTag `
            -Status 'Duplicate' -RegisteredBy $registeredBy -ErrorDetail 'Device already registered'

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

    if ($env:ENABLE_AUDIT_LOG -eq 'true') {
        try {
            Write-TableEntity -TableName 'registrations' `
                -PartitionKey (Get-Date -Format 'yyyy-MM') `
                -RowKey ([guid]::NewGuid().ToString()) `
                -Properties @{
                    SerialNumber = $serialNumber
                    GroupTag     = if ($groupTag) { $groupTag } else { '' }
                    RegisteredBy = if ($registeredBy) { $registeredBy } else { '' }
                    ClientIP     = $clientIp
                    Status       = 'Failed'
                    ErrorDetail  = $errorDetail
                }
        }
        catch { Write-Warning "Audit log write failed: $_" }
    }
    Send-TeamsNotification -SerialNumber $serialNumber -GroupTag $groupTag `
        -Status 'Failed' -RegisteredBy $registeredBy -ErrorDetail $errorDetail

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = @{
            error  = 'Failed to upload hardware hash to Autopilot'
            detail = $errorDetail
        } | ConvertTo-Json
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
