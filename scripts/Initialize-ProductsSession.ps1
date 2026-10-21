#Requires -Version 7.2
<#
.SYNOPSIS
Restore the local Azure/Terraform session without changing infrastructure.
.DESCRIPTION
Returns terraform_path for use by the existing importer and egress helper.
Existing backend.hcl and terraform.tfvars files are required and never overwritten.
#>
[CmdletBinding()]
param(
    [string]$TerraformPath,
    [string]$TerraformDirectory = (Split-Path -Parent $PSScriptRoot),
    [string]$SubscriptionId = $env:TF_VAR_subscription_id,
    [string]$OperatorObjectId = $env:TF_VAR_operator_object_id
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProductsDeployment.Common.ps1')
$productsSession = Get-ProductsContext $TerraformDirectory $TerraformPath
foreach ($name in @('backend.hcl', 'terraform.tfvars')) {
    if (-not (Test-Path -LiteralPath (Join-Path $productsSession.Root $name))) {
        throw "Missing $name. Prepare your local configuration first; the initializer does not overwrite examples or existing files."
    }
}
$backendText = Get-Content -LiteralPath (Join-Path $productsSession.Root 'backend.hcl') -Raw
if ($backendText -match 'REPLACE_|CHANGE_ME') { throw 'Replace the backend placeholder with your existing state account before initializing.' }

$productsAccountFailed = $false
try {
    $productsAccountRaw = & az account show --output json 2>$null
    $productsAccountFailed = $LASTEXITCODE -ne 0
} catch { $productsAccountFailed = $true }
if ($productsAccountFailed) {
    Invoke-ProductsAz @('login', '--output', 'none') | Out-Null
    $productsAccountRaw = Invoke-ProductsAz @('account', 'show', '--output', 'json')
}
$productsAccount = ($productsAccountRaw -join "`n") | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace($SubscriptionId)) { $SubscriptionId = $productsAccount.id }
if ($SubscriptionId -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') { throw 'Supply the Azure subscription UUID.' }
Invoke-ProductsAz @('account', 'set', '--subscription', $SubscriptionId) | Out-Null
$env:TF_VAR_subscription_id = $SubscriptionId
if ([string]::IsNullOrWhiteSpace($OperatorObjectId)) {
    $OperatorObjectId = Invoke-ProductsAz @('ad', 'signed-in-user', 'show', '--query', 'id', '--output', 'tsv')
}
if ($OperatorObjectId -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') { throw 'Supply the same operator Entra object UUID used by this environment.' }
$env:TF_VAR_operator_object_id = $OperatorObjectId
if ([string]::IsNullOrWhiteSpace($env:TF_VAR_sql_admin_password)) {
    $env:TF_VAR_sql_admin_password = Read-Host 'Existing SQL administrator password (choose once for a new environment)' -MaskInput
}
if ([string]::IsNullOrWhiteSpace($env:TF_VAR_sql_admin_password)) { throw 'The SQL password is required; no resources were changed.' }

$ecommerceTerraform = $productsSession.Terraform
Invoke-ProductsTerraform $productsSession @('init', '-input=false', '-backend-config=backend.hcl')
Invoke-ProductsTerraform $productsSession @('validate')
Write-Host 'Session ready. Existing backend and local input files were preserved. No resources were applied.'
[pscustomobject]@{ terraform_path = $ecommerceTerraform; subscription_id = $SubscriptionId; operator_object_id = $OperatorObjectId }
