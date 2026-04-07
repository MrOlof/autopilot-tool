# SessionManager.psm1 — QR session lifecycle + HS256 JWT token management
# Depends on TableStorage.psm1 for storage operations

Import-Module (Join-Path $PSScriptRoot 'TableStorage.psm1') -Force

$script:SESSION_TABLE = 'sessions'
$script:SESSION_TTL_MINUTES = 15

# --- Base64Url helpers ---

function ConvertTo-Base64Url {
    param([byte[]]$Bytes)
    return [System.Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

function ConvertFrom-Base64Url {
    param([string]$Value)
    $padded = $Value.Replace('-', '+').Replace('_', '/')
    switch ($padded.Length % 4) {
        2 { $padded += '==' }
        3 { $padded += '=' }
    }
    return [System.Convert]::FromBase64String($padded)
}

# --- Session CRUD ---

function New-Session {
    param(
        [Parameter(Mandatory)][string]$SerialNumber
    )

    $sessionId = [guid]::NewGuid().ToString()
    $partitionKey = (Get-Date -Format 'yyyy-MM-dd')
    $expiresAt = [DateTime]::UtcNow.AddMinutes($script:SESSION_TTL_MINUTES).ToString('o')

    Write-TableEntity -TableName $script:SESSION_TABLE `
        -PartitionKey $partitionKey `
        -RowKey $sessionId `
        -Properties @{
            Status       = 'pending'
            SerialNumber = $SerialNumber
            ExpiresAt    = $expiresAt
            ApprovedBy   = ''
            Token        = ''
            Consumed     = 'false'
        } | Out-Null

    return @{
        SessionId    = $sessionId
        PartitionKey = $partitionKey
        ExpiresAt    = $expiresAt
    }
}

function Get-Session {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$PartitionKey
    )

    return Get-TableEntity -TableName $script:SESSION_TABLE -PartitionKey $PartitionKey -RowKey $SessionId
}

function Approve-Session {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$PartitionKey,
        [Parameter(Mandatory)][string]$Upn,
        [Parameter(Mandatory)][string]$Token
    )

    Update-TableEntity -TableName $script:SESSION_TABLE `
        -PartitionKey $PartitionKey `
        -RowKey $SessionId `
        -Properties @{
            Status     = 'approved'
            ApprovedBy = $Upn
            Token      = $Token
            Consumed   = 'false'
        } | Out-Null
}

function Set-SessionConsumed {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$PartitionKey
    )

    Update-TableEntity -TableName $script:SESSION_TABLE `
        -PartitionKey $PartitionKey `
        -RowKey $SessionId `
        -Properties @{
            Status   = 'consumed'
            Consumed = 'true'
        } | Out-Null
}

# --- HS256 JWT ---

function New-SessionToken {
    param(
        [Parameter(Mandatory)][string]$SessionId,
        [Parameter(Mandatory)][string]$Upn,
        [Parameter(Mandatory)][string]$PartitionKey
    )

    $secret = $env:TOKEN_SECRET
    if (-not $secret) { throw 'TOKEN_SECRET app setting is not configured' }

    $header = '{"alg":"HS256","typ":"JWT"}'
    $now = [int]([DateTime]::UtcNow - [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)).TotalSeconds
    $exp = $now + ($script:SESSION_TTL_MINUTES * 60)

    $payload = @{
        sessionId = $SessionId
        pk        = $PartitionKey
        upn       = $Upn
        iat       = $now
        exp       = $exp
        jti       = [guid]::NewGuid().ToString()
    } | ConvertTo-Json -Compress

    $headerB64 = ConvertTo-Base64Url ([System.Text.Encoding]::UTF8.GetBytes($header))
    $payloadB64 = ConvertTo-Base64Url ([System.Text.Encoding]::UTF8.GetBytes($payload))
    $unsigned = "$headerB64.$payloadB64"

    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($secret)
    $hmac = New-Object System.Security.Cryptography.HMACSHA256(, $keyBytes)
    $sigBytes = $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($unsigned))
    $sigB64 = ConvertTo-Base64Url $sigBytes

    return "$unsigned.$sigB64"
}

function Test-SessionToken {
    param(
        [Parameter(Mandatory)][string]$Token
    )

    $secret = $env:TOKEN_SECRET
    if (-not $secret) { throw 'TOKEN_SECRET app setting is not configured' }

    $parts = $Token.Split('.')
    if ($parts.Count -ne 3) { throw 'Invalid token format' }

    # Verify signature
    $unsigned = "$($parts[0]).$($parts[1])"
    $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($secret)
    $hmac = New-Object System.Security.Cryptography.HMACSHA256(, $keyBytes)
    $expectedSig = ConvertTo-Base64Url ($hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($unsigned)))

    if ($expectedSig -ne $parts[2]) { throw 'Invalid token signature' }

    # Decode payload
    $payloadJson = [System.Text.Encoding]::UTF8.GetString((ConvertFrom-Base64Url $parts[1]))
    $claims = $payloadJson | ConvertFrom-Json

    # Check expiry
    $now = [int]([DateTime]::UtcNow - [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)).TotalSeconds
    if ($claims.exp -lt $now) { throw 'Token has expired' }

    # Check session not already consumed
    $session = Get-Session -SessionId $claims.sessionId -PartitionKey $claims.pk
    if (-not $session) { throw 'Session not found' }
    if ($session.Consumed -eq 'true') { throw 'Session token has already been used' }

    return @{
        sessionId = $claims.sessionId
        pk        = $claims.pk
        upn       = $claims.upn
        exp       = $claims.exp
        jti       = $claims.jti
    }
}

Export-ModuleMember -Function New-Session, Get-Session, Approve-Session, Set-SessionConsumed, New-SessionToken, Test-SessionToken
