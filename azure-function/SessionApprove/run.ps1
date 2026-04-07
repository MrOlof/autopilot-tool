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
$partitionKey = $Request.Body.partitionKey

if (-not $sessionId -or -not $partitionKey) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = @{ error = 'sessionId and partitionKey are required' } | ConvertTo-Json
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

# --- Validate Entra ID token ---
$authHeader = $Request.Headers['Authorization']
if (-not $authHeader -or $authHeader -notmatch '^Bearer (.+)$') {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::Unauthorized
        Body       = @{ error = 'Entra ID token required in Authorization header' } | ConvertTo-Json
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}
$entraToken = $Matches[1]

try {
    $tokenParts = $entraToken.Split('.')
    if ($tokenParts.Count -ne 3) { throw 'Invalid token format' }

    # Decode payload
    $padded = $tokenParts[1].Replace('-', '+').Replace('_', '/')
    switch ($padded.Length % 4) { 2 { $padded += '==' } 3 { $padded += '=' } }
    $entraPayload = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($padded)) | ConvertFrom-Json

    # Validate issuer, audience, expiry
    $tenantId = $env:ENTRA_TENANT_ID
    $clientId = $env:ENTRA_CLIENT_ID

    $expectedIssuer = "https://login.microsoftonline.com/$tenantId/v2.0"
    if ($entraPayload.iss -ne $expectedIssuer) {
        throw "Invalid issuer: $($entraPayload.iss)"
    }
    if ($entraPayload.aud -ne $clientId) {
        throw "Invalid audience: $($entraPayload.aud)"
    }

    $now = [int]([DateTime]::UtcNow - [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)).TotalSeconds
    if ($entraPayload.exp -lt $now) {
        throw 'Entra token has expired'
    }

    # Validate RSA signature against Entra OIDC signing keys
    $oidcConfig = Invoke-RestMethod -Uri "https://login.microsoftonline.com/$tenantId/v2.0/.well-known/openid-configuration" -TimeoutSec 10
    $jwks = Invoke-RestMethod -Uri $oidcConfig.jwks_uri -TimeoutSec 10

    $headerPadded = $tokenParts[0].Replace('-', '+').Replace('_', '/')
    switch ($headerPadded.Length % 4) { 2 { $headerPadded += '==' } 3 { $headerPadded += '=' } }
    $tokenHeader = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($headerPadded)) | ConvertFrom-Json

    $signingKey = $jwks.keys | Where-Object { $_.kid -eq $tokenHeader.kid } | Select-Object -First 1
    if (-not $signingKey) { throw 'Signing key not found in JWKS' }

    $modBytes = [System.Convert]::FromBase64String(($signingKey.n.Replace('-', '+').Replace('_', '/') + ('=' * ((4 - $signingKey.n.Length % 4) % 4))))
    $expBytes = [System.Convert]::FromBase64String(($signingKey.e.Replace('-', '+').Replace('_', '/') + ('=' * ((4 - $signingKey.e.Length % 4) % 4))))

    $rsaParams = [System.Security.Cryptography.RSAParameters]::new()
    $rsaParams.Modulus = $modBytes
    $rsaParams.Exponent = $expBytes

    $rsa = [System.Security.Cryptography.RSACng]::new()
    $rsa.ImportParameters($rsaParams)

    $dataToVerify = [System.Text.Encoding]::UTF8.GetBytes("$($tokenParts[0]).$($tokenParts[1])")
    $sigPadded = $tokenParts[2].Replace('-', '+').Replace('_', '/')
    switch ($sigPadded.Length % 4) { 2 { $sigPadded += '==' } 3 { $sigPadded += '=' } }
    $signature = [System.Convert]::FromBase64String($sigPadded)

    $isValid = $rsa.VerifyData($dataToVerify, $signature, [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
    if (-not $isValid) { throw 'Invalid token signature' }

    $userOid = $entraPayload.oid
    $userUpn = if ($entraPayload.preferred_username) { $entraPayload.preferred_username } elseif ($entraPayload.upn) { $entraPayload.upn } else { $entraPayload.email }

    if (-not $userOid -or -not $userUpn) {
        throw 'Could not extract user identity from token'
    }
}
catch {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::Unauthorized
        Body       = @{ error = "Token validation failed: $_" } | ConvertTo-Json
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

# --- Check security group membership using Managed Identity ---
$groupId = $env:SECURITY_GROUP_ID
if ($groupId) {
    try {
        $tokenUri = "$($env:IDENTITY_ENDPOINT)?resource=https://graph.microsoft.com&api-version=2019-08-01"
        $tokenResponse = Invoke-RestMethod -Uri $tokenUri -Method GET -Headers @{
            'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER
        }
        $graphToken = $tokenResponse.access_token

        $checkBody = @{ groupIds = @($groupId) } | ConvertTo-Json

        $memberCheck = Invoke-RestMethod -Uri "https://graph.microsoft.com/v1.0/users/$userOid/checkMemberGroups" `
            -Method POST -Headers @{
                'Authorization' = "Bearer $graphToken"
                'Content-Type'  = 'application/json'
            } -Body $checkBody

        if ($groupId -notin $memberCheck.value) {
            Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::Forbidden
                Body       = @{ error = 'User is not a member of the authorized security group' } | ConvertTo-Json
                Headers    = @{ 'Content-Type' = 'application/json' }
            })
            return
        }
    }
    catch {
        Write-Warning "Group membership check failed: $_"
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::Forbidden
            Body       = @{ error = 'Unable to verify group membership. Approval denied.' } | ConvertTo-Json
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }
}

# --- Approve the session ---
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

    $expiresAt = [DateTime]::Parse($session.ExpiresAt).ToUniversalTime()
    if ([DateTime]::UtcNow -gt $expiresAt) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = 410
            Body       = @{ error = 'Session has expired' } | ConvertTo-Json
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    if ($session.Status -eq 'approved') {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = @{ approved = $true; approvedBy = $session.ApprovedBy } | ConvertTo-Json
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    if ($session.Status -ne 'pending') {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::Conflict
            Body       = @{ error = "Session cannot be approved (status: $($session.Status))" } | ConvertTo-Json
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    $token = New-SessionToken -SessionId $sessionId -Upn $userUpn -PartitionKey $partitionKey
    Approve-Session -SessionId $sessionId -PartitionKey $partitionKey -Upn $userUpn -Token $token

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = @{ approved = $true; approvedBy = $userUpn } | ConvertTo-Json
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
catch {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = @{ error = "Session approval failed: $_" } | ConvertTo-Json
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
