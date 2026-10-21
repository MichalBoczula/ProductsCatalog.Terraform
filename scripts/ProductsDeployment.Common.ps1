#Requires -Version 7.2
Set-StrictMode -Version Latest

function Get-ProductsPath([string]$Root, [string]$Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $Root $Path))
}

function Get-ProductsContext([string]$Directory, [string]$TerraformPath) {
    $root = (Resolve-Path -LiteralPath $Directory).Path
    if ([string]::IsNullOrWhiteSpace($TerraformPath)) {
        $installed = if ($env:LOCALAPPDATA) {
            Join-Path $env:LOCALAPPDATA 'Programs/Terraform/1.16.5/terraform.exe'
        } else { $null }
        $TerraformPath = if ($installed -and (Test-Path -LiteralPath $installed)) { $installed } else { 'terraform' }
    }
    $command = Get-Command $TerraformPath -ErrorAction Stop
    $executable = if ($command.CommandType -in @('Function', 'Alias', 'Filter')) { $command.Name } else { $command.Source }
    $context = @{ Root = $root; Terraform = $executable }
    $version = Invoke-ProductsTerraform $context @('version', '-json') -Capture | ConvertFrom-Json
    if ($version.terraform_version -notmatch '^1\.16\.') { throw 'Use Terraform 1.16.x; the deployment guide and CI use 1.16.5.' }
    return $context
}

function Invoke-ProductsTerraform {
    param([hashtable]$Context, [string[]]$Arguments, [switch]$Capture)
    $nativeArguments = @("-chdir=$($Context.Root)") + $Arguments
    if ($Capture) {
        $raw = & $Context.Terraform @nativeArguments
    } else {
        & $Context.Terraform @nativeArguments | Out-Host
    }
    if ($LASTEXITCODE -ne 0) { throw "Terraform $($Arguments[0]) failed (exit $LASTEXITCODE). Keep state and inputs." }
    if ($Capture) { return ($raw -join [Environment]::NewLine) }
}

function Invoke-ProductsAz([string[]]$Arguments) {
    $raw = & az @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI $($Arguments[0]) failed (exit $LASTEXITCODE)." }
    return ($raw -join [Environment]::NewLine)
}

function Write-ProductsJson([string]$Path, $Value) {
    $directory = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $temporary = Join-Path $directory ('.products-input-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = ($Value | ConvertTo-Json -Depth 20) + [Environment]::NewLine
        [IO.File]::WriteAllText($temporary, $json, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $Path, $true)
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
    }
}

function Get-ProductsConfigurationHash([string]$Root, [string]$InputsPath) {
    $files = @(Get-ChildItem -LiteralPath $Root -File -Force | Where-Object {
        $_.Name -like '*.tf' -or $_.Name -like '*.tf.json' -or
        $_.Name -in @('.terraform.lock.hcl', 'backend.hcl', 'terraform.tfvars', 'terraform.tfvars.json') -or
        $_.Name -like '*.auto.tfvars' -or $_.Name -like '*.auto.tfvars.json'
    } | Sort-Object Name)
    $parts = @($files | ForEach-Object { $_.Name + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash })
    $parts += 'inputs:' + (Get-FileHash -LiteralPath $InputsPath -Algorithm SHA256).Hash
    $backendCache = Join-Path $Root '.terraform/terraform.tfstate'
    if (Test-Path -LiteralPath $backendCache) {
        $parts += 'initialized-backend:' + (Get-FileHash -LiteralPath $backendCache -Algorithm SHA256).Hash
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($parts -join "`n"))
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [Convert]::ToHexString($sha.ComputeHash($bytes)) } finally { $sha.Dispose() }
}

function Get-ProductsDeployment([hashtable]$Context) {
    return Invoke-ProductsTerraform $Context @('output', '-json', 'products_deployment') -Capture | ConvertFrom-Json -AsHashtable
}

function Assert-ProductsDatabaseRevisionReady([hashtable]$Context) {
    $deployment = Get-ProductsDeployment $Context
    if (-not $deployment.enabled -or $deployment.stage -ne 'serve') {
        throw 'Apply Serve and wait for its database-ready revision before disabling startup migrations.'
    }
    $foundation = Invoke-ProductsTerraform $Context @('output', '-json', 'products_foundation') -Capture | ConvertFrom-Json -AsHashtable
    $query = '{state:properties.provisioningState,latest:properties.latestRevisionName,ready:properties.latestReadyRevisionName}'
    $live = Invoke-ProductsAz @('containerapp', 'show', '--subscription', $foundation.subscription_id,
        '--resource-group', $deployment.resource_group_name, '--name', $deployment.name,
        '--query', $query, '--output', 'json') | ConvertFrom-Json -AsHashtable
    if ($live.state -ne 'Succeeded' -or [string]::IsNullOrWhiteSpace($live.latest) -or $live.latest -ne $live.ready) {
        throw 'The latest Serve revision is not ready yet. Inspect its migration/readiness logs before disabling migrations.'
    }
}

function Assert-ProductsPublicIpv4([string]$Address) {
    $parsed = $null
    if ($Address -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or
        -not [Net.IPAddress]::TryParse($Address, [ref]$parsed) -or
        $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        $parsed.ToString() -cne $Address) { throw 'Use your current public IPv4, without /32.' }
    $bytes = $parsed.GetAddressBytes()
    if ($bytes[0] -in @(0, 10, 127) -or $bytes[0] -ge 224 -or
        ($bytes[0] -eq 169 -and $bytes[1] -eq 254) -or
        ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
        ($bytes[0] -eq 192 -and $bytes[1] -eq 168)) { throw 'Use one public IPv4; broad and private rules are not supported.' }
}
