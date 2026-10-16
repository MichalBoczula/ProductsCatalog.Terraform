#Requires -Version 7.2
# Offline checks: fake commands never log in to Azure, run Terraform or upload data.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent $PSScriptRoot
$importer = Join-Path $repoRoot 'scripts/Import-ProductPhotos.ps1'
$sourceCatalog = Get-Content (Join-Path $repoRoot 'assets/photos.catalog.json') -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('products-photo-tests-' + [Guid]::NewGuid().ToString('N'))
$checkCount = 0

function Assert-Check {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Get-TestArgument {
    param([string[]]$Arguments, [string]$Name)
    $index = [Array]::IndexOf($Arguments, $Name)
    if ($index -lt 0 -or $index + 1 -ge $Arguments.Count) { throw "Missing command argument: $Name" }
    return $Arguments[$index + 1]
}

function global:Invoke-PhotoTestTerraform {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $state = $global:PhotoImportTestState
    $state.terraform_calls++
    $global:LASTEXITCODE = 0
    if ($state.mode -eq 'TerraformFailure') { $global:LASTEXITCODE = 1; return 'error' }
    if ($state.mode -eq 'EmptyFoundation') { return 'null' }
    return $state.foundation | ConvertTo-Json -Depth 10 -Compress
}

function global:Invoke-PhotoTestAzure {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Arguments)
    $state = $global:PhotoImportTestState
    [void]$state.calls.Add(@($Arguments))
    $global:LASTEXITCODE = 0
    $operation = ($Arguments | Select-Object -First 3) -join ' '
    if ($Arguments[0] -eq 'account') {
        $id = if ($state.mode -eq 'WrongSubscription') { '99999999-9999-9999-9999-999999999999' } else { $state.foundation.subscription_id }
        return @{ id = $id } | ConvertTo-Json -Compress
    }
    if ($operation -eq 'storage account show') {
        if ($state.mode -eq 'MissingStorage') { $global:LASTEXITCODE = 3; return 'not found' }
        $endpoint = if ($state.mode -eq 'WrongEndpoint') { 'https://other.blob.core.windows.net/' } else { $state.foundation.storage_blob_endpoint }
        return @{ primaryEndpoints = @{ blob = $endpoint } } | ConvertTo-Json -Compress
    }
    Assert-Check ((Get-TestArgument $Arguments '--auth-mode') -ceq 'login') 'Storage commands must use Azure login.'
    Assert-Check ((Get-TestArgument $Arguments '--account-name') -ceq $state.foundation.storage_account_name) 'Wrong upload account.'
    Assert-Check ((Get-TestArgument $Arguments '--subscription') -ceq $state.foundation.subscription_id) 'Wrong data-plane subscription.'
    if ($operation -eq 'storage container show') {
        if ($state.mode -eq 'ContainerDenied') { $global:LASTEXITCODE = 4; return '403' }
        $access = if ($state.mode -eq 'PublicContainer') { 'blob' } elseif ($state.mode -eq 'ContainerListing') { 'container' } elseif ($state.foundation.photos_access -eq 'blob') { 'blob' } else { $null }
        return @{ name = 'photos'; properties = @{ publicAccess = $access } } | ConvertTo-Json -Compress
    }
    if ($operation -eq 'storage blob list') {
        $state.list_calls++
        if ($state.mode -eq 'ListFailure') { $global:LASTEXITCODE = 5; return 'list error' }
        if ($state.mode -eq 'ChangedDuringImport' -and $state.list_calls -eq 1) {
            Copy-Item -LiteralPath (Join-Path $state.first_folder 'Front.webp') -Destination (Join-Path $state.first_folder 'Main.webp') -Force
        }
        if ($state.mode -eq 'VerificationFailure' -and $state.list_calls -eq 2) {
            $state.remote[$state.first_blob].properties.contentSettings.contentMd5 = 'invalid'
        }
        if ($state.mode -eq 'NativeUnicode') {
            # Exercise actual native stdout decoding, not just PowerShell strings.
            [IO.File]::WriteAllText($state.native_json, (ConvertTo-Json -InputObject @($state.remote.Values) -Depth 10 -Compress), [Text.UTF8Encoding]::new($false))
            return & ([Environment]::ProcessPath) -NoProfile -File $state.native_writer $state.native_json
        }
        return ConvertTo-Json -InputObject @($state.remote.Values) -Depth 10 -Compress
    }
    if ($operation -eq 'storage blob upload') {
        $state.upload_attempts++
        if ($state.mode -eq 'UploadFailure' -and $state.upload_attempts -eq 2) { $global:LASTEXITCODE = 6; return 'upload error' }
        $name = Get-TestArgument $Arguments '--name'
        $file = Get-TestArgument $Arguments '--file'
        if ('--if-none-match' -in $Arguments) {
            Assert-Check ((Get-TestArgument $Arguments '--if-none-match') -ceq '*') 'New objects need a creation condition.'
            if ($state.mode -eq 'CreationRace' -or $state.remote.ContainsKey($name)) { $global:LASTEXITCODE = 7; return 'conflict' }
        }
        else {
            $etag = Get-TestArgument $Arguments '--if-match'
            if ($state.mode -eq 'ReplacementRace' -or $etag -cne $state.remote[$name].properties.etag) { $global:LASTEXITCODE = 8; return 'etag changed' }
        }
        Assert-Check ('--validate-content' -in $Arguments) 'Service-side transfer checksum verification is required.'
        $metadata = @{}
        $index = [Array]::IndexOf($Arguments, '--metadata') + 1
        while ($index -lt $Arguments.Count -and -not $Arguments[$index].StartsWith('--')) {
            $pair = $Arguments[$index].Split('=', 2)
            $metadata[$pair[0]] = $pair[1]
            $index++
        }
        $actualHash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        $actualMd5 = [Convert]::ToBase64String([Convert]::FromHexString((Get-FileHash -LiteralPath $file -Algorithm MD5).Hash))
        Assert-Check ($metadata.sha256 -ceq $actualHash) 'Incorrect SHA256 metadata.'
        Assert-Check ((Get-TestArgument $Arguments '--content-md5') -ceq $actualMd5) 'Incorrect MD5 upload property.'
        $state.successful_uploads++
        $state.remote[$name] = @{
            name = $name
            metadata = $metadata
            properties = @{
                etag = '"test-etag-' + $state.successful_uploads + '"'
                contentLength = (Get-Item -LiteralPath $file).Length
                contentSettings = @{
                    contentType = Get-TestArgument $Arguments '--content-type'
                    contentMd5 = $actualMd5
                    cacheControl = Get-TestArgument $Arguments '--content-cache-control'
                }
            }
        }
        return '{}'
    }
    throw "Unexpected fake Azure operation: $operation"
}

function New-TestFixture {
    param([string]$Name)
    $root = Join-Path $testRoot $Name
    $photos = Join-Path $root 'photos'
    [IO.Directory]::CreateDirectory($photos) | Out-Null
    $models = @($sourceCatalog.models[0], $sourceCatalog.models[5])
    foreach ($model in $models) {
        Copy-Item -LiteralPath (Join-Path $repoRoot "assets/photos/$($model.folder)") -Destination $photos -Recurse
    }
    $catalogPath = Join-Path $root 'catalog.json'
    @{ schema_version = 1; products_source_commit = $sourceCatalog.products_source_commit; models = $models } |
        ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $catalogPath -Encoding utf8
    $global:PhotoImportTestState = @{
        mode = 'Normal'
        terraform_calls = 0
        calls = [Collections.Generic.List[object]]::new()
        remote = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        list_calls = 0
        upload_attempts = 0
        successful_uploads = 0
        native_json = Join-Path $root 'native.json'
        native_writer = Join-Path $root 'native-writer.ps1'
        first_blob = "$($models[0].folder)/Main.webp"
        first_folder = Join-Path $photos $models[0].folder
        foundation = @{
            subscription_id = '11111111-1111-1111-1111-111111111111'
            resource_group_name = 'rg-ecommercestore-products-dev'
            storage_account_name = 'stecproductsdevfixture'
            storage_blob_endpoint = 'https://stecproductsdevfixture.blob.core.windows.net/'
            photos_container_name = 'photos'
            photos_access = 'private'
        }
    }
    [IO.File]::WriteAllText($global:PhotoImportTestState.native_writer, @'
param([string]$InputPath)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::Write([IO.File]::ReadAllText($InputPath, [Text.Encoding]::UTF8))
'@, [Text.UTF8Encoding]::new($false))
    return @{ PhotosPath = $photos; CatalogPath = $catalogPath; ManifestPath = (Join-Path $root 'photo-manifest.json'); TerraformPath = 'Invoke-PhotoTestTerraform'; AzureCliPath = 'Invoke-PhotoTestAzure' }
}

function Invoke-TestImport {
    param([hashtable]$Options)
    & $importer @Options 6>$null 3>$null
}

function Assert-ImportFailure {
    param([hashtable]$Options, [string]$Pattern)
    $failed = $false
    try { Invoke-TestImport $Options | Out-Null }
    catch {
        $failed = $true
        Assert-Check ($_.Exception.Message -match $Pattern) "Unexpected failure: $($_.Exception.Message)"
    }
    Assert-Check $failed 'Expected the importer to reject this scenario.'
}

function Invoke-Check {
    param([string]$Name, [scriptblock]$Action)
    & $Action
    $script:checkCount++
    Write-Host "PASS $Name"
}

try {
    Invoke-Check 'actual uploaded collection validates offline' {
        $result = & $importer -ValidateOnly -TerraformPath 'not-a-real-tool' -AzureCliPath 'not-a-real-tool' 6>$null 3>$null
        Assert-Check ($result.models -eq 15 -and $result.photos -eq 60) 'Expected all 15 models and 60 uploaded photos.'
    }
    Invoke-Check 'first import, URL encoding and role ordering' {
        $options = New-TestFixture 'success'
        $result = Invoke-TestImport $options
        Assert-Check ($result.uploaded -eq 8 -and $result.skipped -eq 0) 'First import must upload every photo.'
        $manifest = Get-Content $options.ManifestPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        Assert-Check ($manifest.products.Count -eq 2) 'Expected two manifest products.'
        Assert-Check ($manifest.products[0].mainPhoto.EndsWith('/Main.webp')) 'Main photo mapping is incorrect.'
        Assert-Check ($manifest.products[0].otherPhotos[0].EndsWith('/Front.webp') -and $manifest.products[0].otherPhotos[1].EndsWith('/Back.webp') -and $manifest.products[0].otherPhotos[2].EndsWith('/Side.webp')) 'Gallery ordering is incorrect.'
        Assert-Check ($manifest.products[1].mainPhoto.Contains('Bia%C5%82y') -and $manifest.products[1].mainPhoto.Contains('%20')) 'Spaces and Polish characters must be URL-encoded.'
        Assert-Check (-not $manifest.products[0].mainPhoto.Contains('?')) 'Canonical URLs must not contain SAS tokens.'
    }
    Invoke-Check 'all 60 real photos import, repeat and record the S25 review' {
        $options = New-TestFixture 'full-collection'
        $options.PhotosPath = Join-Path $repoRoot 'assets/photos'
        $options.CatalogPath = Join-Path $repoRoot 'assets/photos.catalog.json'
        $result = Invoke-TestImport $options
        Assert-Check ($result.models -eq 15 -and $result.uploaded -eq 60) 'The complete uploaded collection should produce 60 blobs.'
        $manifest = Get-Content $options.ManifestPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        $s25 = @($manifest.products | Where-Object { $_.product_id -eq '3c1c2b2e-0a63-4a6d-8f0c-5d3a1e8f9a21' })[0]
        Assert-Check ($s25.catalog_review_required -and $s25.notes.Count -eq 1) 'The S25 variant mismatch must be visible in the manifest.'
        $result = Invoke-TestImport $options
        Assert-Check ($result.uploaded -eq 0 -and $result.skipped -eq 60) 'All 60 real photos should be skipped on a repeat import.'
    }
    Invoke-Check 'repeat import skips all unchanged blobs' {
        $options = New-TestFixture 'repeat'
        Invoke-TestImport $options | Out-Null
        $global:PhotoImportTestState.upload_attempts = 0
        $result = Invoke-TestImport $options
        Assert-Check ($result.uploaded -eq 0 -and $result.skipped -eq 8 -and $global:PhotoImportTestState.upload_attempts -eq 0) 'Second import must not upload unchanged photos.'
    }
    Invoke-Check 'changed photo replaces only one blob with ETag condition' {
        $options = New-TestFixture 'changed'
        Invoke-TestImport $options | Out-Null
        Copy-Item -LiteralPath (Join-Path $global:PhotoImportTestState.first_folder 'Front.webp') -Destination (Join-Path $global:PhotoImportTestState.first_folder 'Main.webp') -Force
        $result = Invoke-TestImport $options
        Assert-Check ($result.uploaded -eq 1 -and $result.skipped -eq 7) 'Only the changed photo should be uploaded.'
    }
    Invoke-Check 'missing photo fails before calling external tools' {
        $options = New-TestFixture 'missing'
        Remove-Item -LiteralPath (Join-Path $global:PhotoImportTestState.first_folder 'Side.webp')
        Assert-ImportFailure $options 'exactly Main'
        Assert-Check ($global:PhotoImportTestState.terraform_calls -eq 0 -and $global:PhotoImportTestState.calls.Count -eq 0) 'Validation must precede external operations.'
    }
    Invoke-Check 'unmapped folder is rejected' {
        $options = New-TestFixture 'unmapped'
        New-Item -ItemType Directory -Path (Join-Path $options.PhotosPath 'Extra phone') | Out-Null
        Assert-ImportFailure $options 'Unmapped item'
        Assert-Check ($global:PhotoImportTestState.calls.Count -eq 0) 'No uploads are allowed with an incomplete mapping.'
    }
    Invoke-Check 'invalid image content is rejected' {
        $options = New-TestFixture 'invalid-image'
        Set-Content -LiteralPath (Join-Path $global:PhotoImportTestState.first_folder 'Main.webp') -Value 'not an image'
        Assert-ImportFailure $options 'Image header'
    }
    Invoke-Check 'duplicate product ID is rejected' {
        $options = New-TestFixture 'duplicate-id'
        $catalog = Get-Content $options.CatalogPath -Raw | ConvertFrom-Json -AsHashtable
        $catalog.models[1].product_id = $catalog.models[0].product_id
        $catalog | ConvertTo-Json -Depth 10 | Set-Content $options.CatalogPath
        Assert-ImportFailure $options 'Duplicate'
    }
    foreach ($case in @(
        @('TerraformFailure', 'Reading Products Terraform outputs failed'),
        @('EmptyFoundation', 'foundation outputs are empty'),
        @('WrongSubscription', 'subscription differs'),
        @('MissingStorage', 'Checking the provisioned Products storage account failed'),
        @('WrongEndpoint', 'storage endpoint differs'),
        @('ContainerDenied', 'Checking photo container access failed'),
        @('PublicContainer', 'access differs'),
        @('ContainerListing', 'access differs'),
        @('ListFailure', 'Listing photo blobs failed'),
        @('CreationRace', 'Uploading .* failed'),
        @('ChangedDuringImport', 'Image changed during import')
    )) {
        Invoke-Check $case[0] {
            $options = New-TestFixture $case[0]
            $global:PhotoImportTestState.mode = $case[0]
            Assert-ImportFailure $options $case[1]
            Assert-Check (-not (Test-Path $options.ManifestPath)) 'Failed imports must not publish a manifest.'
        }
    }
    foreach ($mode in @('UploadFailure', 'VerificationFailure')) {
        Invoke-Check "$mode preserves an existing manifest" {
            $options = New-TestFixture $mode
            [IO.File]::WriteAllText($options.ManifestPath, 'previous complete manifest')
            $global:PhotoImportTestState.mode = $mode
            $pattern = if ($mode -eq 'VerificationFailure') { 'Mismatched fields: properties.contentSettings.contentMd5' } else { 'failed' }
            Assert-ImportFailure $options $pattern
            Assert-Check ((Get-Content $options.ManifestPath -Raw) -ceq 'previous complete manifest') 'The last complete manifest must survive a failed import.'
        }
    }
    Invoke-Check 'concurrent replacement preserves manifest' {
        $options = New-TestFixture 'replacement-race'
        Invoke-TestImport $options | Out-Null
        $previous = Get-Content $options.ManifestPath -Raw
        Copy-Item -LiteralPath (Join-Path $global:PhotoImportTestState.first_folder 'Front.webp') -Destination (Join-Path $global:PhotoImportTestState.first_folder 'Main.webp') -Force
        $global:PhotoImportTestState.mode = 'ReplacementRace'
        Assert-ImportFailure $options 'Uploading .* failed'
        Assert-Check ((Get-Content $options.ManifestPath -Raw) -ceq $previous) 'A concurrent replacement must preserve the previous manifest.'
    }
    Invoke-Check 'blob-only public access preserves idempotent authenticated uploads' {
        $options = New-TestFixture 'public-photos'
        Invoke-TestImport $options | Out-Null
        $global:PhotoImportTestState.foundation.photos_access = 'blob'
        $result = Invoke-TestImport $options
        Assert-Check ($result.uploaded -eq 0 -and $result.skipped -eq 8) 'Changing read access must not reupload unchanged photos.'
        $manifest = Get-Content $options.ManifestPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
        Assert-Check ($manifest.photos_access -ceq 'blob') 'The manifest must record the applied access mode.'
    }
    Invoke-Check 'existing legacy blob is repaired' {
        $options = New-TestFixture 'legacy'
        Invoke-TestImport $options | Out-Null
        $global:PhotoImportTestState.remote[$global:PhotoImportTestState.first_blob].metadata = @{}
        $result = Invoke-TestImport $options
        Assert-Check ($result.uploaded -eq 1 -and $result.skipped -eq 7) 'A legacy object without checksum metadata should be repaired.'
    }
    Invoke-Check 'remote MIME mismatch is repaired without deleting unrelated blobs' {
        $options = New-TestFixture 'repair-mime'
        Invoke-TestImport $options | Out-Null
        $global:PhotoImportTestState.remote[$global:PhotoImportTestState.first_blob].properties.contentSettings.contentType = 'application/octet-stream'
        $global:PhotoImportTestState.remote['unrelated.txt'] = @{ name = 'unrelated.txt'; metadata = @{ marker = 'keep' } }
        $result = Invoke-TestImport $options
        Assert-Check ($result.uploaded -eq 1 -and $result.skipped -eq 7) 'Only the blob with incorrect MIME settings should be repaired.'
        Assert-Check ($global:PhotoImportTestState.remote['unrelated.txt'].metadata.marker -ceq 'keep') 'Unrelated blobs must remain intact.'
    }
    Invoke-Check 'native Unicode output verifies and repeats under a legacy console encoding' {
        $options = New-TestFixture 'native-unicode'
        $global:PhotoImportTestState.mode = 'NativeUnicode'
        $savedEncoding = [Console]::OutputEncoding
        try {
            [Console]::OutputEncoding = [Text.Encoding]::GetEncoding(1250)
            $result = Invoke-TestImport $options
            Assert-Check ($result.uploaded -eq 8) 'Native JSON must preserve the Biały blob names during verification.'
            Assert-Check ([Console]::OutputEncoding.CodePage -eq 1250) 'The importer must restore the console encoding.'
            $result = Invoke-TestImport $options
            Assert-Check ($result.uploaded -eq 0 -and $result.skipped -eq 8) 'Correctly decoded Unicode blobs must be skipped on repeat.'
            Assert-Check ([Console]::OutputEncoding.CodePage -eq 1250) 'Repeat import must restore the console encoding.'
        }
        finally { [Console]::OutputEncoding = $savedEncoding }
    }
    Invoke-Check 'failed command restores the caller console encoding' {
        $options = New-TestFixture 'encoding-on-failure'
        $global:PhotoImportTestState.mode = 'TerraformFailure'
        $savedEncoding = [Console]::OutputEncoding
        try {
            [Console]::OutputEncoding = [Text.Encoding]::GetEncoding(1250)
            Assert-ImportFailure $options 'Reading Products Terraform outputs failed'
            Assert-Check ([Console]::OutputEncoding.CodePage -eq 1250) 'A failed command must restore the console encoding.'
            Assert-Check (-not (Test-Path $options.ManifestPath)) 'A failed command must not create a manifest.'
        }
        finally { [Console]::OutputEncoding = $savedEncoding }
    }
    Write-Host "Success: $checkCount offline photo-import checks passed."
}
finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
    Remove-Item Function:\Invoke-PhotoTestAzure -ErrorAction SilentlyContinue
    Remove-Item Function:\Invoke-PhotoTestTerraform -ErrorAction SilentlyContinue
    Remove-Variable PhotoImportTestState -Scope Global -ErrorAction SilentlyContinue
}
