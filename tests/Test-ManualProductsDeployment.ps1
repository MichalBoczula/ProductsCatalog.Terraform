#Requires -Version 7.2
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repository = Split-Path -Parent $PSScriptRoot
$deployScript = Join-Path $repository 'scripts/Invoke-ProductsDeployment.ps1'
$verifyScript = Join-Path $repository 'scripts/Test-ProductsDeployment.ps1'
$stateScript = Join-Path $repository 'scripts/Set-ProductsAppState.ps1'
$initializeScript = Join-Path $repository 'scripts/Initialize-ProductsSession.ps1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('products-manual-tests-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
$checks = 0
$image = 'mb0101/product-catalog-api@sha256:' + ('a' * 64)
$savedEnvironment = @{}
foreach ($key in @('TF_VAR_subscription_id', 'TF_VAR_operator_object_id', 'TF_VAR_sql_admin_password')) {
    $savedEnvironment[$key] = [Environment]::GetEnvironmentVariable($key)
}

function Assert-Check([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Fails([scriptblock]$Action, [string]$Pattern) {
    $message = $null
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    Assert-Check ($null -ne $message -and $message -like $Pattern) "Expected failure matching '$Pattern'; received '$message'."
}
function Invoke-Check([string]$Name, [scriptblock]$Action) {
    & $Action
    $script:checks++
    Write-Host "PASS $Name"
}
function Write-FixtureJson([string]$Path, $Value) {
    [IO.File]::WriteAllText($Path, ($Value | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
}
function Read-Inputs([string]$Root) {
    Get-Content -LiteralPath (Join-Path $Root 'products-deployment.tfvars.json') -Raw | ConvertFrom-Json -AsHashtable
}
function New-Fixture {
    $root = Join-Path $testRoot ('directory with spaces ' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($root) | Out-Null
    [IO.File]::WriteAllText((Join-Path $root 'backend.tf'), 'terraform {}')
    [IO.File]::WriteAllText((Join-Path $root 'backend.hcl'), 'storage_account_name = "fixturestate"')
    [IO.File]::WriteAllText((Join-Path $root 'terraform.tfvars'), 'name_suffix = "demo01"')
    $global:ProductsManualTest = @{
        calls = [Collections.Generic.List[object]]::new(); azCalls = [Collections.Generic.List[object]]::new()
        failCommand = ''; planNumber = 0; applyCount = 0; readyStatus = 200; running = 'Running'; existingApp = $false
        deployment = @{ enabled = $true; stage = 'serve'; name = 'ca-ecommercestore-products-dev'; resource_group_name = 'rg-ecommercestore-products-dev'; outbound_ipv4 = @('203.0.113.10', '198.51.100.20') }
        foundation = @{ subscription_id = '11111111-1111-1111-1111-111111111111'; photos_base_url = 'https://fixture.blob.core.windows.net/photos/' }
        live = @{ state = 'Succeeded'; running = 'Running'; external = $true; fqdn = 'products.example.test'; latest = 'products--new'; ready = 'products--new' }
        photoUrl = 'https://fixture.blob.core.windows.net/photos/model/Main.webp'
        photoStatus = 200; photoType = 'image/webp'; phoneCount = 15
    }
    return $root
}
function global:Invoke-ProductsTestTerraform {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $global:ProductsManualTest.calls.Add(@($Arguments))
    $global:LASTEXITCODE = 0
    $command = $Arguments[1]
    if ($command -eq $global:ProductsManualTest.failCommand) { $global:LASTEXITCODE = 1; return 'simulated native failure' }
    switch ($command) {
        'version' { return '{"terraform_version":"1.16.5"}' }
        'plan' {
            $global:ProductsManualTest.planNumber++
            $path = @($Arguments | Where-Object { $_.StartsWith('-out=') })[0].Substring(5)
            [IO.File]::WriteAllText($path, "plan $($global:ProductsManualTest.planNumber)")
        }
        'apply' { $global:ProductsManualTest.applyCount++ }
        'output' {
            if ($Arguments[-1] -eq '-json') {
                if ($global:ProductsManualTest.existingApp) { return @{ products_deployment = @{ value = @{ enabled = $true } } } | ConvertTo-Json -Depth 10 }
                return '{}'
            }
            if ($Arguments[-1] -eq 'products_deployment') { return $global:ProductsManualTest.deployment | ConvertTo-Json -Depth 10 }
            if ($Arguments[-1] -eq 'products_foundation') { return $global:ProductsManualTest.foundation | ConvertTo-Json -Depth 10 }
            throw 'Unexpected output lookup.'
        }
        'init' { }
        'validate' { }
        default { throw "Unexpected Terraform command: $command" }
    }
}
function global:az {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $global:ProductsManualTest.azCalls.Add(@($Arguments))
    $global:LASTEXITCODE = 0
    if (($Arguments[0..1] -join ' ') -eq 'account show') { return '{"id":"11111111-1111-1111-1111-111111111111"}' }
    if (($Arguments[0..1] -join ' ') -eq 'account set') { return }
    if (($Arguments[0..1] -join ' ') -eq 'containerapp show') { return $global:ProductsManualTest.live | ConvertTo-Json -Depth 10 }
    if ($Arguments[0] -eq 'rest') {
        $method = $Arguments[[Array]::IndexOf($Arguments, '--method') + 1]
        $url = $Arguments[[Array]::IndexOf($Arguments, '--url') + 1]
        if ($method -eq 'post') {
            Assert-Check ($url -match '/containerApps/ca-ecommercestore-products-dev/(stop|start)\?api-version=2025-07-01$') 'Use the documented app lifecycle endpoint.'
            $global:ProductsManualTest.running = if ($url.Contains('/stop?')) { 'Stopped' } else { 'Running' }
            return
        }
        return $global:ProductsManualTest.running
    }
    throw "Unexpected Azure command: $($Arguments -join ' ')"
}
function global:Invoke-WebRequest {
    param([Parameter(Position = 0)]$Uri, [switch]$SkipHttpErrorCheck, [int]$TimeoutSec, [string]$Method)
    if ([string]$Uri -like '*/health/ready') { return [pscustomobject]@{ StatusCode = $global:ProductsManualTest.readyStatus } }
    Assert-Check ($Method -eq 'Head' -and [string]$Uri -eq $global:ProductsManualTest.photoUrl) 'Verify only the returned anonymous photo URL.'
    return [pscustomobject]@{ StatusCode = $global:ProductsManualTest.photoStatus; Headers = @{ 'Content-Type' = $global:ProductsManualTest.photoType } }
}
function global:Invoke-RestMethod {
    param([Parameter(Position = 0)]$Uri, [int]$TimeoutSec)
    Assert-Check ([string]$Uri -eq 'https://products.example.test/mobile-phones?amount=15') 'Use the live Azure hostname and catalogue endpoint.'
    for ($index = 0; $index -lt $global:ProductsManualTest.phoneCount; $index++) {
        [pscustomobject]@{ id = $index; mainPhoto = $global:ProductsManualTest.photoUrl }
    }
}
function Invoke-Step([string]$Root, [string]$Step, [hashtable]$Extra = @{}) {
    & $deployScript -TerraformPath Invoke-ProductsTestTerraform -TerraformDirectory $Root -Step $Step @Extra 6>$null
}
function New-RuntimeFixture {
    $root = New-Fixture
    Invoke-Step $root Foundation | Out-Null
    Invoke-Step $root Prepare @{ Image = $script:image } | Out-Null
    Invoke-Step $root Serve | Out-Null
    Invoke-Step $root Runtime | Out-Null
    return $root
}
try {
    Invoke-Check 'fresh foundation plan never applies and creates explicit non-auto inputs' {
        $root = New-Fixture
        Invoke-Step $root Foundation | Out-Null
        $inputs = Read-Inputs $root
        Assert-Check (-not $inputs.deploy_products_app -and $inputs.photos_anonymous_read_enabled) 'Foundation must keep the app disabled and prepare anonymous photos.'
        Assert-Check ($global:ProductsManualTest.applyCount -eq 0) 'Plan must not apply.'
        $plan = @($global:ProductsManualTest.calls | Where-Object { $_[1] -eq 'plan' })[-1]
        Assert-Check (@($plan | Where-Object { $_ -like '-var-file=*products-deployment.tfvars.json' }).Count -eq 1) 'Always pass the retained deployment file explicitly.'
        Assert-Check (@(Get-ChildItem $root -Filter '*.auto.tfvars.json').Count -eq 0) 'Do not create root auto inputs.'
    }
    Invoke-Check 'prepare is migration-free and rejects floating images before writing inputs' {
        $root = New-Fixture
        Invoke-Step $root Foundation | Out-Null
        $before = Get-Content (Join-Path $root 'products-deployment.tfvars.json') -Raw
        Assert-Fails { Invoke-Step $root Prepare @{ Image = 'mb0101/product-catalog-api:latest' } } '*immutable*'
        Assert-Check ((Get-Content (Join-Path $root 'products-deployment.tfvars.json') -Raw) -ceq $before) 'An invalid image must preserve inputs.'
        Invoke-Step $root Prepare @{ Image = $image } | Out-Null
        $inputs = Read-Inputs $root
        Assert-Check ($inputs.deploy_products_app -and -not $inputs.products_apply_migrations) 'Prepare must not enable migrations.'
    }
    Invoke-Check 'foundation refuses to remove a deployed app even when local deployment inputs are missing' {
        $root = New-Fixture
        $global:ProductsManualTest.existingApp = $true
        Assert-Fails { Invoke-Step $root Foundation } '*enabled app found in remote state*'
        Assert-Check (-not (Test-Path (Join-Path $root 'products-deployment.tfvars.json'))) 'Do not replace a lost deployment file with disabled-app defaults.'
    }
    Invoke-Check 'serve records actual egress without leaking an auto file into root' {
        $root = New-Fixture
        Invoke-Step $root Foundation | Out-Null
        Invoke-Step $root Prepare @{ Image = $image } | Out-Null
        Invoke-Step $root Serve | Out-Null
        $inputs = Read-Inputs $root
        Assert-Check ($inputs.products_apply_migrations -and $inputs.products_deployment_stage -eq 'serve') 'Serve should bootstrap the database.'
        Assert-Check ($inputs.products_sql_egress_ipv4.Count -eq 2) 'Persist the actual firewall addresses in the retained inputs.'
        Assert-Check (@(Get-ChildItem $root -Filter '*.auto.tfvars.json').Count -eq 0) 'Keep egress discovery outside automatic root loading.'
    }
    Invoke-Check 'failed egress discovery preserves the previous inputs' {
        $root = New-RuntimeFixture
        $before = Get-Content (Join-Path $root 'products-deployment.tfvars.json') -Raw
        $global:ProductsManualTest.deployment.outbound_ipv4 = @()
        Assert-Fails { Invoke-Step $root Serve } '*no outbound*'
        Assert-Check ((Get-Content (Join-Path $root 'products-deployment.tfvars.json') -Raw) -ceq $before) 'Failed discovery must not reset the rollout.'
    }
    Invoke-Check 'runtime keeps image and exact firewall map while disabling migrations' {
        $root = New-RuntimeFixture
        $inputs = Read-Inputs $root
        Assert-Check (-not $inputs.products_apply_migrations -and $inputs.products_sql_egress_ipv4.Count -eq 2 -and $inputs.products_image -ceq $image) 'Runtime must retain the working app and SQL rules.'
        Assert-Fails { Invoke-Step $root Foundation } '*remove an enabled app*'
        Assert-Fails { Invoke-Step $root Prepare } '*initial app bootstrap*'
    }
    Invoke-Check 'Swagger uses API-only IP and Internal removes both temporary personal IPs' {
        $root = New-RuntimeFixture
        Invoke-Step $root Swagger @{ ApiOperatorIpv4 = '203.0.113.25' } | Out-Null
        $inputs = Read-Inputs $root
        Assert-Check ($inputs.products_external_ingress_enabled -and $inputs.products_api_operator_ipv4 -eq '203.0.113.25' -and $null -eq $inputs.operator_ipv4) 'Browser access must not grant local SQL access.'
        Invoke-Step $root Internal | Out-Null
        $inputs = Read-Inputs $root
        Assert-Check (-not $inputs.products_external_ingress_enabled -and $null -eq $inputs.products_api_operator_ipv4 -and $null -eq $inputs.operator_ipv4 -and $inputs.products_sql_egress_ipv4.Count -eq 2) 'Close personal access without deleting ACA SQL rules.'
    }
    Invoke-Check 'pending migrations cannot be disabled by Runtime or Swagger' {
        $root = New-RuntimeFixture
        $global:ProductsManualTest.live.ready = 'products--old'
        Assert-Fails { Invoke-Step $root Runtime } '*Serve revision is not ready*'
        Assert-Fails { Invoke-Step $root Swagger @{ ApiOperatorIpv4 = '203.0.113.25' } } '*Serve revision is not ready*'
    }
    foreach ($address in @('0.0.0.0', '192.168.1.1', '203.0.113.1/24', '::1')) {
        Invoke-Check "reject invalid Swagger address $address" {
            $root = New-RuntimeFixture
            Assert-Fails { Invoke-Step $root Swagger @{ ApiOperatorIpv4 = $address } } '*public IPv4*'
        }
    }
    Invoke-Check 'Apply uses the reviewed saved plan once' {
        $root = New-RuntimeFixture
        Invoke-Step $root Runtime @{ Action = 'Apply' } | Out-Null
        Assert-Check ($global:ProductsManualTest.applyCount -eq 1) 'Apply the saved plan exactly once.'
        $apply = @($global:ProductsManualTest.calls | Where-Object { $_[1] -eq 'apply' })[-1]
        Assert-Check ($apply[-1].EndsWith('products-runtime.tfplan') -and -not ($apply -contains '-auto-approve')) 'Apply the reviewed binary, not a new automatic plan.'
        Assert-Fails { Invoke-Step $root Runtime @{ Action = 'Apply' } } '*Missing saved-plan*'
    }
    Invoke-Check 'changed local inputs invalidate the saved plan' {
        $root = New-RuntimeFixture
        Add-Content (Join-Path $root 'products-deployment.tfvars.json') ' '
        Assert-Fails { Invoke-Step $root Runtime @{ Action = 'Apply' } } '*changed*'
        Assert-Check ($global:ProductsManualTest.applyCount -eq 0) 'Never apply a mismatched plan.'
    }
    Invoke-Check 'backend changes and plan tampering invalidate the saved plan' {
        $root = New-RuntimeFixture
        Add-Content (Join-Path $root 'backend.hcl') '# another backend'
        Assert-Fails { Invoke-Step $root Runtime @{ Action = 'Apply' } } '*changed*'
        $root = New-RuntimeFixture
        Add-Content (Join-Path $root '.products-plans/products-runtime.tfplan') 'tampered'
        Assert-Fails { Invoke-Step $root Runtime @{ Action = 'Apply' } } '*changed*'
    }
    Invoke-Check 'failed planning invalidates an older saved-plan receipt' {
        $root = New-RuntimeFixture
        $global:ProductsManualTest.failCommand = 'plan'
        Assert-Fails { Invoke-Step $root Runtime } '*plan failed*'
        Assert-Fails { Invoke-Step $root Runtime @{ Action = 'Apply' } } '*Missing saved-plan*'
    }
    Invoke-Check 'destroy preserves complete inputs and only plans deletion' {
        $root = New-RuntimeFixture
        $before = Get-Content (Join-Path $root 'products-deployment.tfvars.json') -Raw
        Invoke-Step $root Destroy | Out-Null
        $plan = @($global:ProductsManualTest.calls | Where-Object { $_[1] -eq 'plan' })[-1]
        Assert-Check ($plan -contains '-destroy') 'Destroy must create a destroy plan.'
        Assert-Check ($global:ProductsManualTest.applyCount -eq 0 -and (Get-Content (Join-Path $root 'products-deployment.tfvars.json') -Raw) -ceq $before) 'Destroy planning must retain the inputs and not apply.'
    }
    Invoke-Check 'verification checks readiness, fifteen phones and anonymous photo content' {
        $root = New-Fixture
        $result = & $verifyScript -TerraformDirectory $root -TerraformPath Invoke-ProductsTestTerraform
        Assert-Check ($result.api_verified -and $result.phones -eq 15 -and $result.anonymous_photo_verified) 'Complete the catalogue checks.'
        $global:ProductsManualTest.live.external = $false
        Assert-Fails { & $verifyScript -TerraformDirectory $root -TerraformPath Invoke-ProductsTestTerraform } '*Ingress is internal*'
        $result = & $verifyScript -TerraformDirectory $root -TerraformPath Invoke-ProductsTestTerraform -InfrastructureOnly
        Assert-Check (-not $result.api_verified) 'Control-plane checks must not claim to verify the live API.'
    }
    Invoke-Check 'verification rejects denied readiness, missing seeds and private photos' {
        $root = New-Fixture
        $global:ProductsManualTest.readyStatus = 403
        Assert-Fails { & $verifyScript -TerraformDirectory $root -TerraformPath Invoke-ProductsTestTerraform } '*HTTP 403*'
        $global:ProductsManualTest.readyStatus = 200
        $global:ProductsManualTest.phoneCount = 0
        Assert-Fails { & $verifyScript -TerraformDirectory $root -TerraformPath Invoke-ProductsTestTerraform } '*Expected 15*'
        $global:ProductsManualTest.phoneCount = 15
        $global:ProductsManualTest.photoStatus = 403
        Assert-Fails { & $verifyScript -TerraformDirectory $root -TerraformPath Invoke-ProductsTestTerraform } '*Anonymous photo*'
    }
    Invoke-Check 'manual Stop and Start use lifecycle endpoints without editing inputs' {
        $root = New-RuntimeFixture
        $before = Get-Content (Join-Path $root 'products-deployment.tfvars.json') -Raw
        $result = & $stateScript -State Stop -TerraformDirectory $root -TerraformPath Invoke-ProductsTestTerraform
        Assert-Check ($result.running_status -eq 'Stopped') 'Confirm stopped status.'
        $result = & $stateScript -State Start -TerraformDirectory $root -TerraformPath Invoke-ProductsTestTerraform
        Assert-Check ($result.running_status -eq 'Running') 'Confirm resumed status.'
        Assert-Check ((Get-Content (Join-Path $root 'products-deployment.tfvars.json') -Raw) -ceq $before) 'Do not change retained Terraform inputs for a runtime stop.'
    }
    Invoke-Check 'session initialization retains backend, inputs and existing credentials' {
        $root = New-Fixture
        $env:TF_VAR_sql_admin_password = 'FixtureOnly-Password-123!'
        $backendBefore = Get-Content (Join-Path $root 'backend.hcl') -Raw
        $result = & $initializeScript -TerraformDirectory $root -TerraformPath Invoke-ProductsTestTerraform `
            -SubscriptionId '11111111-1111-1111-1111-111111111111' -OperatorObjectId '33333333-3333-3333-3333-333333333333' 6>$null
        Assert-Check ($result.terraform_path -eq 'Invoke-ProductsTestTerraform' -and $env:TF_VAR_sql_admin_password -ceq 'FixtureOnly-Password-123!') 'Keep the existing SQL password and return the Terraform executable.'
        Assert-Check ((Get-Content (Join-Path $root 'backend.hcl') -Raw) -ceq $backendBefore -and $global:ProductsManualTest.applyCount -eq 0) 'Initialization cannot rewrite backend or provision resources.'
    }
    Write-Host "$checks offline manual deployment checks passed."
} finally {
    foreach ($key in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($key, $savedEnvironment[$key]) }
    foreach ($name in @('Invoke-ProductsTestTerraform', 'az', 'Invoke-WebRequest', 'Invoke-RestMethod')) { Remove-Item "Function:\$name" -ErrorAction SilentlyContinue }
    Remove-Variable ProductsManualTest -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
