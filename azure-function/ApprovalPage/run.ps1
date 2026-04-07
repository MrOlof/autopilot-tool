using namespace System.Net

param($Request, $TriggerMetadata)

if ($env:ENABLE_QR_AUTH -ne 'true') {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::NotFound
        Body       = 'QR authentication is not enabled'
    })
    return
}

$htmlPath = Join-Path $PSScriptRoot 'index.html'
$html = Get-Content $htmlPath -Raw

# Build API base URL from the request
$requestUrl = $Request.Url.ToString()
$apiBase = $requestUrl.Substring(0, $requestUrl.IndexOf('/api/')) + '/api'

# Inject configuration from app settings
$html = $html.Replace('{{TENANT_ID}}', $env:ENTRA_TENANT_ID)
$html = $html.Replace('{{CLIENT_ID}}', $env:ENTRA_CLIENT_ID)
$html = $html.Replace('{{API_BASE_URL}}', $apiBase)
$companyName = if ($env:COMPANY_NAME) { $env:COMPANY_NAME } else { 'Autopilot' }
$html = $html.Replace('{{COMPANY_NAME}}', $companyName)

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode  = [HttpStatusCode]::OK
    ContentType = 'text/html; charset=utf-8'
    Body        = $html
})
