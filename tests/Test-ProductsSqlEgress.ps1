#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$helper = Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/Set-ProductsSqlEgress.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('products-egress-tests-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$checks = 0

function Assert-Check([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function global:Invoke-EgressTestTerraform {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $global:LASTEXITCODE = if ($global:ProductsEgressTest.failure) { 1 } else { 0 }
    if ($global:ProductsEgressTest.failure) { return 'native failure' }
    Assert-Check (($Arguments[-3..-1] -join ' ') -ceq 'output -json products_deployment') 'Read only the Products deployment output.'
    return $global:ProductsEgressTest.deployment | ConvertTo-Json -Depth 10
}
function Invoke-Check([string]$Name, [scriptblock]$Action) {
    & $Action
    $script:checks++
    Write-Host "PASS $Name"
}
function New-Fixture([string]$Name) {
    $root = Join-Path $testRoot $Name
    [IO.Directory]::CreateDirectory($root) | Out-Null
    $global:ProductsEgressTest = @{
        failure = $false
        deployment = @{ enabled = $true; name = 'ca-ecommercestore-products-dev'; outbound_ipv4 = @('203.0.113.10', '198.51.100.20', '203.0.113.10') }
    }
    return @{ TerraformPath = 'Invoke-EgressTestTerraform'; TerraformDirectory = $root }
}
function Assert-PreservedFailure([hashtable]$Options) {
    $path = Join-Path $Options.TerraformDirectory 'products-egress.auto.tfvars.json'
    $previous = '{"products_sql_egress_ipv4":{"egress01":"203.0.113.99"}}'
    [IO.File]::WriteAllText($path, $previous)
    $failed = $false
    try { & $helper @Options 6>$null | Out-Null }
    catch { $failed = $true }
    Assert-Check $failed 'The helper must reject the invalid output.'
    Assert-Check ((Get-Content -LiteralPath $path -Raw) -ceq $previous) 'A failed lookup must preserve the previous firewall input.'
}
try {
    Invoke-Check 'deduplicate and sort actual egress with stable plan-known keys' {
        $options = New-Fixture 'success with spaces'
        $result = & $helper @options 6>$null
        $value = Get-Content -LiteralPath $result.output_path -Raw | ConvertFrom-Json -AsHashtable
        Assert-Check ($result.rules -eq 2) 'Expected two unique IP rules.'
        Assert-Check ($value.products_sql_egress_ipv4.egress01 -ceq '198.51.100.20') 'The first sorted address should have a stable key.'
        Assert-Check ($value.products_sql_egress_ipv4.egress02 -ceq '203.0.113.10') 'The second address must not be lost.'
        $again = & $helper @options 6>$null
        Assert-Check ($again.rules -eq 2) 'Repeating the helper must preserve the rule set.'
    }
    Invoke-Check 'native Terraform failure preserves input' {
        $options = New-Fixture 'native failure'
        $global:ProductsEgressTest.failure = $true
        Assert-PreservedFailure $options
    }
    Invoke-Check 'disabled app preserves input' {
        $options = New-Fixture 'disabled'
        $global:ProductsEgressTest.deployment.enabled = $false
        Assert-PreservedFailure $options
    }
    Invoke-Check 'empty egress preserves input' {
        $options = New-Fixture 'empty'
        $global:ProductsEgressTest.deployment.outbound_ipv4 = @()
        Assert-PreservedFailure $options
    }
    foreach ($invalid in @('0.0.0.0', '10.0.0.1', '127.0.0.1', '192.168.1.1', '203.0.113.1/32', '::1', 'not-an-ip')) {
        Invoke-Check "reject $invalid" {
            $options = New-Fixture ([Guid]::NewGuid().ToString('N'))
            $global:ProductsEgressTest.deployment.outbound_ipv4 = @($invalid)
            Assert-PreservedFailure $options
        }
    }
    Invoke-Check 'refuse to overwrite unrelated configuration' {
        $options = New-Fixture 'unrelated'
        $path = Join-Path $options.TerraformDirectory 'products-egress.auto.tfvars.json'
        [IO.File]::WriteAllText($path, '{"environment":"test"}')
        $failed = $false
        try { & $helper @options 6>$null | Out-Null } catch { $failed = $true }
        Assert-Check $failed 'A mixed-purpose configuration file must be preserved.'
        Assert-Check ((Get-Content -LiteralPath $path -Raw) -ceq '{"environment":"test"}') 'Unrelated input was modified.'
    }
    Write-Host "$checks offline SQL egress checks passed."
}
finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
    Remove-Item Function:\Invoke-EgressTestTerraform -ErrorAction SilentlyContinue
    Remove-Variable ProductsEgressTest -Scope Global -ErrorAction SilentlyContinue
}
