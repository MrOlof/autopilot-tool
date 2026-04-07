# TableStorage.psm1 — Azure Table Storage REST API helper
# Uses AzureWebJobsStorage connection string directly, no external modules

function Get-StorageContext {
    if ($script:storageContext) { return $script:storageContext }

    $connStr = $env:AzureWebJobsStorage
    if (-not $connStr) { throw 'AzureWebJobsStorage connection string not found' }

    $parts = @{}
    foreach ($segment in $connStr.Split(';')) {
        $idx = $segment.IndexOf('=')
        if ($idx -gt 0) {
            $parts[$segment.Substring(0, $idx)] = $segment.Substring($idx + 1)
        }
    }

    $script:storageContext = @{
        AccountName = $parts['AccountName']
        AccountKey  = $parts['AccountKey']
        Suffix      = if ($parts['EndpointSuffix']) { $parts['EndpointSuffix'] } else { 'core.windows.net' }
    }
    return $script:storageContext
}

function New-StorageAuthHeader {
    param(
        [string]$Method,
        [string]$Resource,
        [string]$Date,
        [hashtable]$Context
    )

    $stringToSign = "$Date`n/$($Context.AccountName)/$Resource"
    $keyBytes = [System.Convert]::FromBase64String($Context.AccountKey)
    $hmac = New-Object System.Security.Cryptography.HMACSHA256(, $keyBytes)
    $sig = [System.Convert]::ToBase64String(
        $hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($stringToSign))
    )
    return "SharedKeyLite $($Context.AccountName):$sig"
}

function Invoke-TableStorageRequest {
    param(
        [string]$Method,
        [string]$TableName,
        [string]$PathSuffix = '',
        [string]$Body = $null,
        [hashtable]$Context
    )

    $baseUrl = "https://$($Context.AccountName).table.$($Context.Suffix)"
    $uri = "$baseUrl/$TableName$PathSuffix"
    $date = [DateTime]::UtcNow.ToString('R')
    $resource = "$TableName$PathSuffix"

    $auth = New-StorageAuthHeader -Method $Method -Resource $resource -Date $date -Context $Context

    $headers = @{
        'Authorization' = $auth
        'x-ms-date'     = $date
        'x-ms-version'  = '2019-02-02'
        'Accept'        = 'application/json;odata=nometadata'
        'Content-Type'  = 'application/json'
    }

    $params = @{
        Uri         = $uri
        Method      = $Method
        Headers     = $headers
        ContentType = 'application/json'
    }
    if ($Body) { $params.Body = $Body }

    return Invoke-RestMethod @params
}

function Ensure-Table {
    param(
        [string]$TableName,
        [hashtable]$Context
    )

    $baseUrl = "https://$($Context.AccountName).table.$($Context.Suffix)"
    $date = [DateTime]::UtcNow.ToString('R')
    $auth = New-StorageAuthHeader -Method 'POST' -Resource 'Tables' -Date $date -Context $Context

    $headers = @{
        'Authorization' = $auth
        'x-ms-date'     = $date
        'x-ms-version'  = '2019-02-02'
        'Accept'        = 'application/json;odata=nometadata'
        'Content-Type'  = 'application/json'
    }

    $body = @{ TableName = $TableName } | ConvertTo-Json

    try {
        Invoke-RestMethod -Uri "$baseUrl/Tables" -Method POST -Headers $headers -Body $body -ContentType 'application/json' | Out-Null
    }
    catch {
        # 409 = table already exists, that's fine
        if ($_.Exception.Response.StatusCode.value__ -ne 409) { throw }
    }
}

function Write-TableEntity {
    param(
        [Parameter(Mandatory)][string]$TableName,
        [Parameter(Mandatory)][string]$PartitionKey,
        [Parameter(Mandatory)][string]$RowKey,
        [Parameter(Mandatory)][hashtable]$Properties
    )

    $ctx = Get-StorageContext

    $entity = @{
        PartitionKey = $PartitionKey
        RowKey       = $RowKey
    }
    foreach ($key in $Properties.Keys) {
        $entity[$key] = $Properties[$key]
    }

    $body = $entity | ConvertTo-Json -Depth 5

    try {
        Invoke-TableStorageRequest -Method 'POST' -TableName $TableName -Body $body -Context $ctx | Out-Null
    }
    catch {
        # If table doesn't exist, create it and retry
        if ($_.Exception.Response.StatusCode.value__ -eq 404) {
            Ensure-Table -TableName $TableName -Context $ctx | Out-Null
            Invoke-TableStorageRequest -Method 'POST' -TableName $TableName -Body $body -Context $ctx | Out-Null
        }
        else { throw }
    }
}

function Get-TableEntity {
    param(
        [Parameter(Mandatory)][string]$TableName,
        [Parameter(Mandatory)][string]$PartitionKey,
        [Parameter(Mandatory)][string]$RowKey
    )

    $ctx = Get-StorageContext
    $pathSuffix = "(PartitionKey='$PartitionKey',RowKey='$RowKey')"

    try {
        return Invoke-TableStorageRequest -Method 'GET' -TableName $TableName -PathSuffix $pathSuffix -Context $ctx
    }
    catch {
        if ($_.Exception.Response.StatusCode.value__ -eq 404) { return $null }
        throw
    }
}

function Update-TableEntity {
    param(
        [Parameter(Mandatory)][string]$TableName,
        [Parameter(Mandatory)][string]$PartitionKey,
        [Parameter(Mandatory)][string]$RowKey,
        [Parameter(Mandatory)][hashtable]$Properties
    )

    $ctx = Get-StorageContext
    $pathSuffix = "(PartitionKey='$PartitionKey',RowKey='$RowKey')"

    $entity = @{
        PartitionKey = $PartitionKey
        RowKey       = $RowKey
    }
    foreach ($key in $Properties.Keys) {
        $entity[$key] = $Properties[$key]
    }

    $body = $entity | ConvertTo-Json -Depth 5

    $baseUrl = "https://$($ctx.AccountName).table.$($ctx.Suffix)"
    $uri = "$baseUrl/$TableName$pathSuffix"
    $date = [DateTime]::UtcNow.ToString('R')
    $auth = New-StorageAuthHeader -Method 'POST' -Resource "$TableName$pathSuffix" -Date $date -Context $ctx

    $headers = @{
        'Authorization'  = $auth
        'x-ms-date'      = $date
        'x-ms-version'   = '2019-02-02'
        'Accept'         = 'application/json;odata=nometadata'
        'Content-Type'   = 'application/json'
        'If-Match'       = '*'
        'X-HTTP-Method'  = 'MERGE'
    }

    # X-HTTP-Method: MERGE with POST verb — merges properties, preserves the rest
    Invoke-RestMethod -Uri $uri -Method POST -Headers $headers -Body $body -ContentType 'application/json' | Out-Null
}

Export-ModuleMember -Function Write-TableEntity, Get-TableEntity, Update-TableEntity
