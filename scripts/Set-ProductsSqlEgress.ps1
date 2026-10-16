#Requires -Version 7.2
[CmdletBinding()]
param(
    [string]$TerraformPath = 'terraform',
    [string]$TerraformDirectory = (Split-Path -Parent $PSScriptRoot),
    [string]$OutputPath = 'products-egress.auto.tfvars.json'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = (Resolve-Path -LiteralPath $TerraformDirectory).Path
$destination = if ([IO.Path]::IsPathRooted($OutputPath)) { $OutputPath } else { Join-Path $root $OutputPath }
$destination = [IO.Path]::GetFullPath($destination)
if (-not $destination.EndsWith('.auto.tfvars.json', [StringComparison]::Ordinal)) {
    throw 'OutputPath must end with .auto.tfvars.json so Terraform loads the reviewed local input.'
}

$raw = & $TerraformPath "-chdir=$root" output -json products_deployment
if ($LASTEXITCODE -ne 0) { throw 'Reading Products deployment outputs failed; the previous egress file was preserved.' }
$deployment = ($raw -join [Environment]::NewLine) | ConvertFrom-Json -AsHashtable
if ($null -eq $deployment -or $deployment.enabled -ne $true -or
    $deployment.name -notmatch '^ca-ecommercestore-products-(dev|test|prod)$') {
    throw 'Apply the Products prepare stage first; no enabled Products Container App was found.'
}
$addresses = @($deployment.outbound_ipv4 | Sort-Object -Unique)
if ($addresses.Count -eq 0) { throw 'ACA returned no outbound IPv4 addresses. Keep prepare stage and inspect the app; never substitute its inbound IP or an Azure-wide SQL rule.' }

$rules = [ordered]@{}
foreach ($address in $addresses) {
    $parsed = $null
    if ($address -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or
        -not [Net.IPAddress]::TryParse($address, [ref]$parsed) -or
        $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        $parsed.ToString() -cne $address) {
        throw "Invalid ACA outbound IPv4: $address. The previous egress file was preserved."
    }
    $bytes = $parsed.GetAddressBytes()
    if ($bytes[0] -in @(0, 10, 127) -or $bytes[0] -ge 224 -or
        ($bytes[0] -eq 169 -and $bytes[1] -eq 254) -or
        ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
        ($bytes[0] -eq 192 -and $bytes[1] -eq 168)) {
        throw "Non-public ACA outbound IPv4: $address. The previous egress file was preserved."
    }
    $rules[('egress{0:d2}' -f ($rules.Count + 1))] = $address
}
if (Test-Path -LiteralPath $destination) {
    $previous = Get-Content -LiteralPath $destination -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    if ($previous.Keys.Count -ne 1 -or -not $previous.ContainsKey('products_sql_egress_ipv4')) {
        throw 'The destination contains other configuration. Refusing to overwrite it.'
    }
}
$json = @{ products_sql_egress_ipv4 = $rules } | ConvertTo-Json -Depth 5
$temporary = Join-Path (Split-Path -Parent $destination) ('.products-egress-' + [Guid]::NewGuid().ToString('N') + '.tmp')
try {
    [IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary, $destination, $true)
}
finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
}
Write-Host "Recorded $($rules.Count) exact ACA outbound IPs in $destination. Review a new Terraform plan before applying."
[pscustomobject]@{ rules = $rules.Count; output_path = $destination }
