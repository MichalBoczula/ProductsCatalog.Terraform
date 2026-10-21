#Requires -Version 7.2
<#
.SYNOPSIS
Plan or apply one explicitly selected step of the manual Products deployment.
.DESCRIPTION
Plan updates the ignored JSON inputs and creates a saved plan; it never applies.
Apply executes only the matching saved plan after checking its input/configuration hashes.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Foundation', 'Prepare', 'Serve', 'Runtime', 'Swagger', 'Internal', 'Destroy')][string]$Step,
    [ValidateSet('Plan', 'Apply')][string]$Action = 'Plan',
    [string]$TerraformPath,
    [string]$TerraformDirectory = (Split-Path -Parent $PSScriptRoot),
    [string]$InputsPath = 'products-deployment.tfvars.json',
    [string]$PlanPath,
    [string]$Image,
    [string]$ApiOperatorIpv4
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ProductsDeployment.Common.ps1')
$context = Get-ProductsContext $TerraformDirectory $TerraformPath
$inputsFile = Get-ProductsPath $context.Root $InputsPath
if (-not $inputsFile.EndsWith('.tfvars.json') -or $inputsFile.EndsWith('.auto.tfvars.json')) {
    throw 'Use a non-auto .tfvars.json input file; the script passes it explicitly to Terraform.'
}
if ([string]::IsNullOrWhiteSpace($PlanPath)) { $PlanPath = ".products-plans/products-$($Step.ToLowerInvariant()).tfplan" }
$planFile = Get-ProductsPath $context.Root $PlanPath
if (-not $planFile.EndsWith('.tfplan')) { throw 'Use a .tfplan saved plan path so plans remain ignored by Git.' }
$metadataFile = $planFile + '.metadata.json'

if ($Action -eq 'Apply') {
    if ($Image -or $ApiOperatorIpv4) { throw 'Apply uses the saved plan. Change parameters with a new Plan action first.' }
    foreach ($path in @($inputsFile, $planFile, $metadataFile)) {
        if (-not (Test-Path -LiteralPath $path)) { throw "Missing saved-plan input: $path. Create and review a new plan." }
    }
    $metadata = Get-Content -LiteralPath $metadataFile -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    if ($metadata.step -ne $Step -or $metadata.root -cne $context.Root -or $metadata.inputs_path -cne $inputsFile -or
        $metadata.plan_hash -cne (Get-FileHash -LiteralPath $planFile -Algorithm SHA256).Hash -or
        $metadata.configuration_hash -cne (Get-ProductsConfigurationHash $context.Root $inputsFile)) {
        throw 'The saved plan, backend, configuration, inputs, or selected step changed. Create and review a new plan.'
    }
    Invoke-ProductsTerraform $context @('apply', '-input=false', $planFile)
    # A reviewed plan is used once; retain the binary for diagnosis, invalidate its receipt.
    Remove-Item -LiteralPath $metadataFile
    Write-Host "$Step applied. Keep state, backend.hcl and $inputsFile."
    return
}

if ($Step -eq 'Destroy' -and -not (Test-Path -LiteralPath $inputsFile)) {
    throw 'Destroy requires the retained deployment inputs. Do not recreate them with foundation defaults.'
}
if (Test-Path -LiteralPath $inputsFile) {
    $inputs = Get-Content -LiteralPath $inputsFile -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    if ($inputs -isnot [Collections.IDictionary]) { throw 'Deployment inputs must be a JSON object.' }
} elseif ($Step -eq 'Foundation') {
    $inputs = [ordered]@{
        deploy_products_app = $false; products_image = $null
        products_deployment_stage = 'prepare'; products_apply_migrations = $false
        products_external_ingress_enabled = $false; products_api_operator_ipv4 = $null
        products_sql_egress_ipv4 = @{}; operator_ipv4 = $null
        photos_anonymous_read_enabled = $true
    }
} else { throw 'Run Foundation first, or adopt your existing products-deployment.tfvars.json.' }

foreach ($key in @('deploy_products_app', 'products_image', 'products_deployment_stage', 'products_sql_egress_ipv4')) {
    if (-not $inputs.Contains($key)) { throw "Missing $key in deployment inputs; restore the complete file before continuing." }
}
if ($Image -and $Step -in @('Foundation', 'Destroy')) { throw 'An image update belongs to an application deployment step.' }
if ($Image) { $inputs.products_image = $Image }
if ($ApiOperatorIpv4 -and $Step -ne 'Swagger') { throw 'ApiOperatorIpv4 is only used by the Swagger step.' }

if ($Step -eq 'Foundation') {
    # Empty state returns {}. Authentication/backend failures are not treated as empty state.
    $appliedOutputs = Invoke-ProductsTerraform $context @('output', '-json') -Capture | ConvertFrom-Json -AsHashtable
    if ($appliedOutputs.Contains('products_deployment') -and $appliedOutputs.products_deployment.value.enabled) {
        throw 'Foundation would remove an enabled app found in remote state. Use Runtime or Internal.'
    }
}

switch ($Step) {
    'Foundation' {
        if ($inputs.deploy_products_app) { throw 'Foundation would remove an enabled app. Use Runtime or Internal for an existing deployment.' }
        $inputs.products_apply_migrations = $false
        $inputs.products_external_ingress_enabled = $false
        $inputs.products_api_operator_ipv4 = $null
        $inputs.operator_ipv4 = $null
    }
    'Prepare' {
        if ($inputs.products_deployment_stage -eq 'serve') { throw 'Prepare is the initial app bootstrap. Use Runtime for a database-ready app.' }
        $inputs.deploy_products_app = $true
        $inputs.products_apply_migrations = $false
        $inputs.products_external_ingress_enabled = $false
        $inputs.products_api_operator_ipv4 = $null
        $inputs.operator_ipv4 = $null
    }
    'Serve' {
        if (-not $inputs.deploy_products_app) { throw 'Apply Prepare before capturing egress and enabling migrations.' }
        # A nested auto file satisfies the existing helper, but is never auto-loaded by the root.
        $egressFile = Join-Path $context.Root '.products-plans/egress.auto.tfvars.json'
        [IO.Directory]::CreateDirectory((Split-Path -Parent $egressFile)) | Out-Null
        & (Join-Path $PSScriptRoot 'Set-ProductsSqlEgress.ps1') -TerraformPath $context.Terraform `
            -TerraformDirectory $context.Root -OutputPath $egressFile | Out-Null
        $egress = Get-Content -LiteralPath $egressFile -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        $inputs.products_sql_egress_ipv4 = $egress.products_sql_egress_ipv4
        $inputs.products_deployment_stage = 'serve'
        $inputs.products_apply_migrations = $true
    }
    'Runtime' {
        if (-not $inputs.deploy_products_app -or $inputs.products_sql_egress_ipv4.Count -eq 0) {
            throw 'Runtime requires the prepared app and recorded SQL egress rules.'
        }
        Assert-ProductsDatabaseRevisionReady $context
        $inputs.products_deployment_stage = 'serve'
        $inputs.products_apply_migrations = $false
    }
    'Swagger' {
        if (-not $inputs.deploy_products_app -or $inputs.products_deployment_stage -ne 'serve' -or $inputs.products_sql_egress_ipv4.Count -eq 0) {
            throw 'Complete the database rollout before testing the catalogue in Swagger.'
        }
        Assert-ProductsDatabaseRevisionReady $context
        if ([string]::IsNullOrWhiteSpace($ApiOperatorIpv4)) { $ApiOperatorIpv4 = Read-Host 'Current public IPv4 for browser/API access only' }
        $ApiOperatorIpv4 = $ApiOperatorIpv4.Trim()
        Assert-ProductsPublicIpv4 $ApiOperatorIpv4
        $inputs.products_external_ingress_enabled = $true
        $inputs.products_api_operator_ipv4 = $ApiOperatorIpv4
        $inputs.operator_ipv4 = $null
        $inputs.products_apply_migrations = $false
    }
    'Internal' {
        $inputs.products_external_ingress_enabled = $false
        $inputs.products_api_operator_ipv4 = $null
        $inputs.operator_ipv4 = $null
    }
}
if ($inputs.deploy_products_app -and $inputs.products_image -cnotmatch '^mb0101/product-catalog-api(:[0-9a-f]{40}|@sha256:[0-9a-f]{64})$') {
    throw 'Supply the published immutable Products image through -Image; latest is not supported.'
}
if ($Step -ne 'Destroy') { Write-ProductsJson $inputsFile $inputs }
[IO.Directory]::CreateDirectory((Split-Path -Parent $planFile)) | Out-Null
# Invalidate the old receipt before planning; a failed plan cannot leave an older plan applyable.
if (Test-Path -LiteralPath $metadataFile) { Remove-Item -LiteralPath $metadataFile }
$arguments = @('plan', '-input=false', "-var-file=$inputsFile", "-out=$planFile")
if ($Step -eq 'Destroy') { $arguments += '-destroy' }
Invoke-ProductsTerraform $context $arguments
if (-not (Test-Path -LiteralPath $planFile)) { throw 'Terraform did not create a saved plan.' }
Write-ProductsJson $metadataFile @{
    step = $Step; root = $context.Root; inputs_path = $inputsFile
    plan_hash = (Get-FileHash -LiteralPath $planFile -Algorithm SHA256).Hash
    configuration_hash = Get-ProductsConfigurationHash $context.Root $inputsFile
}
Write-Host "Review the plan above. Apply separately with -Step $Step -Action Apply and the same input/plan paths."
[pscustomobject]@{ step = $Step; plan_path = $planFile; inputs_path = $inputsFile }
