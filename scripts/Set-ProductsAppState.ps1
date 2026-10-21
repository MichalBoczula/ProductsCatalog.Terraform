#Requires -Version 7.2
<#
.SYNOPSIS
Manually stop or start the applied Products app without changing Terraform inputs.
.DESCRIPTION
Stop leaves the app unavailable until Start; HTTP requests do not start a stopped app.
Networking, SQL and stored data remain provisioned. This does not destroy resources.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Stop', 'Start')][string]$State,
    [string]$TerraformPath,
    [string]$TerraformDirectory = (Split-Path -Parent $PSScriptRoot),
    [ValidateRange(1, 600)][int]$TimeoutSeconds = 180
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProductsDeployment.Common.ps1')
$context = Get-ProductsContext $TerraformDirectory $TerraformPath
$deployment = Get-ProductsDeployment $context
if (-not $deployment.enabled) { throw 'No enabled Products app was found in the applied outputs.' }
$foundation = Invoke-ProductsTerraform $context @('output', '-json', 'products_foundation') -Capture | ConvertFrom-Json -AsHashtable
$resourceId = "/subscriptions/$($foundation.subscription_id)/resourceGroups/$($deployment.resource_group_name)/providers/Microsoft.App/containerApps/$($deployment.name)"
$base = "https://management.azure.com$resourceId"
$operation = $State.ToLowerInvariant()
Invoke-ProductsAz @('rest', '--method', 'post', '--url', "$base/${operation}?api-version=2025-07-01", '--output', 'none') | Out-Null
$expected = if ($State -eq 'Stop') { 'Stopped' } else { 'Running' }
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
do {
    $actual = Invoke-ProductsAz @('rest', '--method', 'get', '--url', "${base}?api-version=2025-07-01", '--query', 'properties.runningStatus', '--output', 'tsv')
    if ($actual -eq $expected) {
        [pscustomobject]@{ name = $deployment.name; running_status = $actual }
        return
    }
    Start-Sleep -Seconds 3
} while ([DateTime]::UtcNow -lt $deadline)
throw "Azure accepted $State but has not reported $expected yet (last state: $actual). Check Azure status before retrying."
