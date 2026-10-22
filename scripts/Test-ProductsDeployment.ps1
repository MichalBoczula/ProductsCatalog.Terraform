#Requires -Version 7.2
<#
.SYNOPSIS
Check the current Azure revision, then readiness, seeded phones and anonymous photo access.
.DESCRIPTION
Use InfrastructureOnly while ingress is internal. That mode checks Azure configuration,
not a live database connection. API checks run from this PC and require temporary Swagger access.
#>
[CmdletBinding()]
param(
    [string]$TerraformPath,
    [string]$TerraformDirectory = (Split-Path -Parent $PSScriptRoot),
    [switch]$InfrastructureOnly,
    [ValidateRange(1, 1000)][int]$ExpectedPhoneCount = 15,
    [ValidateRange(20, 900)][int]$StartupTimeoutSeconds = 300
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProductsDeployment.Common.ps1')
$context = Get-ProductsContext $TerraformDirectory $TerraformPath
$deployment = Get-ProductsDeployment $context
if (-not $deployment.enabled) { throw 'Apply the Products app before checking the deployment.' }
$foundation = Invoke-ProductsTerraform $context @('output', '-json', 'products_foundation') -Capture | ConvertFrom-Json -AsHashtable
$target = @('--subscription', $foundation.subscription_id, '--resource-group', $deployment.resource_group_name, '--name', $deployment.name)
$query = '{state:properties.provisioningState,running:properties.runningStatus,fqdn:properties.configuration.ingress.fqdn,external:properties.configuration.ingress.external,latest:properties.latestRevisionName,ready:properties.latestReadyRevisionName}'
$live = Invoke-ProductsAz (@('containerapp', 'show') + $target + @('--query', $query, '--output', 'json')) | ConvertFrom-Json -AsHashtable
if ($live.state -ne 'Succeeded' -or [string]::IsNullOrWhiteSpace($live.latest) -or $live.latest -ne $live.ready) {
    throw 'The latest Azure revision is not the ready revision. Inspect revision status and logs before continuing.'
}
if ($InfrastructureOnly) {
    [pscustomobject]@{ revision = $live.ready; running = $live.running; external_ingress = $live.external; api_verified = $false }
    return
}
if ($live.running -eq 'Stopped') { throw 'The app is manually stopped. Run Set-ProductsAppState.ps1 -State Start first.' }
if (-not $live.external) { throw 'Ingress is internal. Use -InfrastructureOnly, or apply the Swagger step for requests from this PC.' }
$baseUrl = "https://$($live.fqdn)"
$deadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
$ready = $false
$lastStatus = 'no response'
do {
    try {
        $response = Invoke-WebRequest "$baseUrl/health/ready" -SkipHttpErrorCheck -TimeoutSec 20
        $lastStatus = [string]$response.StatusCode
    } catch { $lastStatus = 'connection timeout/error' }
    if ($lastStatus -eq '200') { $ready = $true; break }
    if ($lastStatus -in @('401', '403')) { throw "HTTP ${lastStatus}: verify the current browser/API IPv4 allowlist and authentication." }
    if ([DateTime]::UtcNow -lt $deadline) { Start-Sleep -Seconds 5 }
} while ([DateTime]::UtcNow -lt $deadline)
if (-not $ready) { throw "SQL readiness did not become healthy; last result: $lastStatus. Inspect the latest revision logs and egress rules." }
$phones = @(Invoke-RestMethod "$baseUrl/mobile-phones?amount=$ExpectedPhoneCount" -TimeoutSec 45)
if ($phones.Count -ne $ExpectedPhoneCount -or @($phones | Where-Object { [string]::IsNullOrWhiteSpace($_.mainPhoto) }).Count -gt 0) {
    throw "Expected $ExpectedPhoneCount seeded phones, each with mainPhoto."
}
$photoUri = [uri]$phones[0].mainPhoto
if (-not $photoUri.IsAbsoluteUri -or $photoUri.Scheme -ne 'https' -or $photoUri.Query -or
    -not $photoUri.AbsoluteUri.StartsWith($foundation.photos_base_url, [StringComparison]::Ordinal)) {
    throw 'The sample photo must use the applied photos container URL, HTTPS and no SAS query.'
}
# A fresh request: no SAS, Authorization header, credential or web session.
$photo = Invoke-WebRequest $photoUri.AbsoluteUri -Method Head -SkipHttpErrorCheck -TimeoutSec 30
if ($photo.StatusCode -ne 200 -or [string]$photo.Headers['Content-Type'] -notlike 'image/*') {
    throw 'Anonymous photo access failed. Check photo import and the anonymous-read flag.'
}
[pscustomobject]@{
    revision = $live.ready; base_url = $baseUrl; api_verified = $true
    phones = $phones.Count; anonymous_photo_verified = $true
    swagger_url = "$baseUrl/swagger/index.html"
}
