#Requires -Version 7.2
[CmdletBinding()]
param(
    [string]$PhotosPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'assets/photos'),
    [string]$CatalogPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'assets/photos.catalog.json'),
    [string]$ManifestPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'photo-manifest.json'),
    [string]$TerraformPath = 'terraform',
    [string]$AzureCliPath = 'az',
    [switch]$ValidateOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoRoot = Split-Path -Parent $PSScriptRoot
$roles = @('Main', 'Front', 'Back', 'Side')
$mimeTypes = @{
    '.webp' = 'image/webp'
    '.jpg'  = 'image/jpeg'
    '.jpeg' = 'image/jpeg'
    '.png'  = 'image/png'
}
$cacheControl = 'private, max-age=3600'

function Invoke-ImportJsonCommand {
    param([string]$Command, [string[]]$CommandArguments, [string]$Operation)
    # Native errors are checked explicitly; keep stdout separate from diagnostics.
    $PSNativeCommandUseErrorActionPreference = $false
    $raw = @(& $Command @CommandArguments)
    if ($LASTEXITCODE -ne 0) {
        throw "$Operation failed (exit $LASTEXITCODE). Resolve the error above and rerun the importer."
    }
    try {
        return ConvertFrom-Json -InputObject ($raw -join [Environment]::NewLine) -AsHashtable -Depth 100 -NoEnumerate
    }
    catch {
        throw "$Operation returned invalid JSON."
    }
}

function Assert-ImageHeader {
    param([System.IO.FileInfo]$File)
    $stream = $File.OpenRead()
    try {
        $bytes = [byte[]]::new(12)
        $read = $stream.Read($bytes, 0, $bytes.Length)
    }
    finally { $stream.Dispose() }
    $extension = $File.Extension.ToLowerInvariant()
    $valid = switch ($extension) {
        '.webp' {
            $read -eq 12 -and
            [Text.Encoding]::ASCII.GetString($bytes, 0, 4) -eq 'RIFF' -and
            [Text.Encoding]::ASCII.GetString($bytes, 8, 4) -eq 'WEBP'
        }
        '.png' {
            $read -ge 8 -and [Convert]::ToHexString($bytes[0..7]) -eq '89504E470D0A1A0A'
        }
        default {
            $read -ge 3 -and $bytes[0] -eq 255 -and $bytes[1] -eq 216 -and $bytes[2] -eq 255
        }
    }
    if (-not $valid) { throw "Image header does not match its extension: $($File.FullName)" }
}

function Get-PhotoInventory {
    $photoRoot = Get-Item -LiteralPath $PhotosPath
    if (-not $photoRoot.PSIsContainer) { throw 'PhotosPath must be a directory.' }
    $catalog = Get-Content -LiteralPath $CatalogPath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    if ($catalog.schema_version -ne 1 -or $catalog.products_source_commit -notmatch '^[0-9a-f]{40}$') {
        throw 'The photo catalog needs schema_version 1 and a pinned Products source commit.'
    }
    $models = @($catalog.models)
    if ($models.Count -eq 0) { throw 'The photo catalog contains no models.' }
    $folders = @{}
    $productIds = @{}
    $photos = [Collections.Generic.List[object]]::new()

    foreach ($model in $models) {
        $folder = [string]$model.folder
        $productId = [string]$model.product_id
        if ([string]::IsNullOrWhiteSpace($folder) -or $folder -in @('.', '..') -or $folder -match '[/\\]') {
            throw "Invalid model folder in photo catalog: $folder"
        }
        if ($productId -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') {
            throw "Invalid product ID for folder: $folder"
        }
        if ($folders.ContainsKey($folder) -or $productIds.ContainsKey($productId)) {
            throw "Duplicate folder or product ID in photo catalog: $folder"
        }
        if ([string]::IsNullOrWhiteSpace([string]$model.product_name)) {
            throw "Missing product name for folder: $folder"
        }
        $folders[$folder] = $true
        $productIds[$productId] = $true
        $modelDirectory = Get-Item -LiteralPath (Join-Path $photoRoot.FullName $folder)
        if (-not $modelDirectory.PSIsContainer) { throw "Model folder is not a directory: $folder" }
        $items = @(Get-ChildItem -LiteralPath $modelDirectory.FullName -Force)
        if ($items.Count -ne 4 -or @($items | Where-Object PSIsContainer).Count -gt 0) {
            throw "Model folder must contain exactly Main, Front, Back and Side image files: $folder"
        }
        foreach ($role in $roles) {
            $matches = @($items | Where-Object { $_.BaseName -ieq $role })
            if ($matches.Count -ne 1) { throw "Expected exactly one $role image in: $folder" }
            $file = $matches[0]
            if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Image links are not supported: $($file.FullName)"
            }
            $extension = $file.Extension.ToLowerInvariant()
            if (-not $mimeTypes.ContainsKey($extension)) {
                throw "Unsupported image extension in: $($file.FullName)"
            }
            Assert-ImageHeader -File $file
            $sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            $md5Hex = (Get-FileHash -LiteralPath $file.FullName -Algorithm MD5).Hash
            $md5 = [Convert]::ToBase64String([Convert]::FromHexString($md5Hex))
            $photos.Add([pscustomobject]@{
                model = $model
                role = $role
                file_path = $file.FullName
                source_path = "$folder/$($file.Name)"
                blob_name = "$folder/$role$extension"
                bytes = $file.Length
                sha256 = $sha256
                content_md5 = $md5
                content_type = $mimeTypes[$extension]
            })
        }
    }
    $actualFolders = @(Get-ChildItem -LiteralPath $photoRoot.FullName -Force)
    foreach ($item in $actualFolders) {
        if (-not $item.PSIsContainer -or -not $folders.ContainsKey($item.Name)) {
            throw "Unmapped item under assets/photos: $($item.Name). Update photos.catalog.json explicitly."
        }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Model folder links are not supported: $($item.Name)"
        }
    }
    return [pscustomobject]@{ catalog = $catalog; models = $models; photos = $photos.ToArray() }
}

function Get-RemotePhotos {
    $items = Invoke-ImportJsonCommand -Command $AzureCliPath -Operation 'Listing photo blobs' -CommandArguments @(
        'storage', 'blob', 'list',
        '--account-name', $foundation.storage_account_name,
        '--container-name', $foundation.photos_container_name,
        '--auth-mode', 'login', '--subscription', $foundation.subscription_id,
        '--include', 'm', '--num-results', '*',
        '--only-show-errors', '--output', 'json'
    )
    if ($items -isnot [array]) { throw 'Azure Blob list returned an unexpected shape.' }
    # Azure Blob names are case-sensitive, including Main/Front/Back/Side.
    $index = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($item in $items) { $index.Add([string]$item.name, $item) }
    return ,$index
}

function Test-RemotePhoto {
    param($Remote, $Photo)
    if ($null -eq $Remote) { return $false }
    $properties = $Remote.properties
    $settings = $properties.contentSettings
    $metadata = $Remote.metadata
    return (
        $null -ne $metadata -and
        [string]$metadata['sha256'] -ceq $Photo.sha256 -and
        [string]$metadata['source_product_id'] -ieq $Photo.model.product_id -and
        [string]$metadata['photo_role'] -ceq $Photo.role -and
        [long]$properties.contentLength -eq $Photo.bytes -and
        [string]$settings.contentMd5 -ceq $Photo.content_md5 -and
        [string]$settings.contentType -ceq $Photo.content_type -and
        [string]$settings.cacheControl -ceq $cacheControl
    )
}

# Validate the complete local collection before running any Terraform/Azure command.
$inventory = Get-PhotoInventory
Write-Host "Validated $($inventory.models.Count) models and $($inventory.photos.Count) photos."
foreach ($model in $inventory.models) {
    foreach ($note in @($model.notes)) { Write-Warning "$($model.product_name): $note" }
}
if ($ValidateOnly) {
    return [pscustomobject]@{
        models = $inventory.models.Count
        photos = $inventory.photos.Count
        validation_only = $true
    }
}

Get-Command $TerraformPath -ErrorAction Stop | Out-Null
Get-Command $AzureCliPath -ErrorAction Stop | Out-Null
$foundation = Invoke-ImportJsonCommand -Command $TerraformPath -Operation 'Reading Products Terraform outputs' -CommandArguments @(
    "-chdir=$repoRoot", 'output', '-json', 'products_foundation'
)
if ($null -eq $foundation) {
    throw 'Products foundation outputs are empty. Apply the Products infrastructure before importing photos.'
}
if (
    $foundation.subscription_id -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' -or
    $foundation.resource_group_name -notmatch '^rg-ecommercestore-products-(dev|test|prod)$' -or
    $foundation.storage_account_name -notmatch '^stecproducts[a-z0-9]+$' -or
    $foundation.photos_container_name -cne 'photos' -or $foundation.photos_access -cne 'private'
) {
    throw 'Terraform outputs do not describe the expected private Products photo storage.'
}
$expectedEndpoint = "https://$($foundation.storage_account_name).blob.core.windows.net/"
if ($foundation.storage_blob_endpoint -cne $expectedEndpoint) {
    throw 'Terraform Blob endpoint does not match the Products storage account.'
}
$account = Invoke-ImportJsonCommand -Command $AzureCliPath -Operation 'Reading Azure login context' -CommandArguments @(
    'account', 'show', '--only-show-errors', '--output', 'json'
)
if ($account.id -ine $foundation.subscription_id) {
    throw 'Azure CLI subscription differs from Products Terraform outputs. Select the intended subscription and retry.'
}
$storage = Invoke-ImportJsonCommand -Command $AzureCliPath -Operation 'Checking the provisioned Products storage account' -CommandArguments @(
    'storage', 'account', 'show', '--name', $foundation.storage_account_name,
    '--resource-group', $foundation.resource_group_name, '--subscription', $foundation.subscription_id,
    '--only-show-errors', '--output', 'json'
)
if ($storage.primaryEndpoints.blob -cne $expectedEndpoint) {
    throw 'Azure storage endpoint differs from Terraform outputs.'
}
$container = Invoke-ImportJsonCommand -Command $AzureCliPath -Operation 'Checking photo container access' -CommandArguments @(
    'storage', 'container', 'show', '--account-name', $foundation.storage_account_name,
    '--name', $foundation.photos_container_name, '--auth-mode', 'login',
    '--subscription', $foundation.subscription_id, '--only-show-errors', '--output', 'json'
)
if ($container.name -cne 'photos' -or -not [string]::IsNullOrEmpty([string]$container.properties.publicAccess)) {
    throw 'The expected photos container is missing or allows anonymous access.'
}

$before = Get-RemotePhotos
$uploaded = 0
$skipped = 0
foreach ($photo in $inventory.photos) {
    $remote = if ($before.ContainsKey($photo.blob_name)) { $before[$photo.blob_name] } else { $null }
    if (Test-RemotePhoto -Remote $remote -Photo $photo) {
        $skipped++
        continue
    }
    # Refuse a concurrent replacement rather than clobbering an unseen upload.
    $condition = if ($null -eq $remote) {
        @('--if-none-match', '*')
    }
    else {
        if ([string]::IsNullOrWhiteSpace([string]$remote.properties.etag)) {
            throw "Existing blob has no usable ETag: $($photo.blob_name)"
        }
        @('--if-match', [string]$remote.properties.etag)
    }
    # Detect local edits made after validation and hashing.
    if ((Get-FileHash -LiteralPath $photo.file_path -Algorithm SHA256).Hash.ToLowerInvariant() -cne $photo.sha256) {
        throw "Image changed during import: $($photo.source_path). Rerun with a stable photo directory."
    }
    Write-Host "Uploading $($photo.blob_name)"
    $uploadArguments = @(
        'storage', 'blob', 'upload',
        '--account-name', $foundation.storage_account_name,
        '--container-name', $foundation.photos_container_name,
        '--name', $photo.blob_name, '--file', $photo.file_path,
        '--auth-mode', 'login', '--subscription', $foundation.subscription_id,
        '--type', 'block', '--overwrite', 'true',
        '--content-type', $photo.content_type, '--content-md5', $photo.content_md5,
        '--content-cache-control', $cacheControl, '--validate-content',
        '--metadata', "sha256=$($photo.sha256)", "source_product_id=$($photo.model.product_id)", "photo_role=$($photo.role)",
        '--no-progress', '--only-show-errors', '--output', 'json'
    ) + $condition
    Invoke-ImportJsonCommand -Command $AzureCliPath -Operation "Uploading $($photo.blob_name)" -CommandArguments $uploadArguments | Out-Null
    $uploaded++
}

$after = Get-RemotePhotos
foreach ($photo in $inventory.photos) {
    if (-not $after.ContainsKey($photo.blob_name) -or -not (Test-RemotePhoto -Remote $after[$photo.blob_name] -Photo $photo)) {
        throw "Uploaded image verification failed: $($photo.blob_name). The previous manifest was preserved."
    }
}

$manifestProducts = foreach ($model in $inventory.models) {
    $images = foreach ($photo in @($inventory.photos | Where-Object { $_.model.product_id -ieq $model.product_id })) {
        $encodedName = ($photo.blob_name.Split('/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
        [ordered]@{
            role = $photo.role
            blob_name = $photo.blob_name
            url = "$expectedEndpoint$($foundation.photos_container_name)/$encodedName"
            source_path = $photo.source_path
            sha256 = $photo.sha256
            content_md5 = $photo.content_md5
            bytes = $photo.bytes
            content_type = $photo.content_type
        }
    }
    [ordered]@{
        product_id = $model.product_id
        product_name = $model.product_name
        source_folder = $model.folder
        catalog_review_required = @($model.notes).Count -gt 0
        notes = @($model.notes)
        mainPhoto = $images[0].url
        otherPhotos = @($images[1..3] | ForEach-Object { $_.url })
        photos = @($images)
    }
}
$manifest = [ordered]@{
    schema_version = 1
    generated_at_utc = [DateTimeOffset]::UtcNow.ToString('o')
    products_source_commit = $inventory.catalog.products_source_commit
    subscription_id = $foundation.subscription_id
    resource_group_name = $foundation.resource_group_name
    storage_account_name = $foundation.storage_account_name
    photos_container_name = $foundation.photos_container_name
    photos_access = 'private'
    uploaded = $uploaded
    skipped = $skipped
    products = @($manifestProducts)
}
$destination = [IO.Path]::GetFullPath($ManifestPath)
$manifestDirectory = Split-Path -Parent $destination
[IO.Directory]::CreateDirectory($manifestDirectory) | Out-Null
$temporaryManifest = Join-Path $manifestDirectory ('.photo-manifest-' + [Guid]::NewGuid().ToString('N') + '.tmp')
try {
    [IO.File]::WriteAllText($temporaryManifest, ($manifest | ConvertTo-Json -Depth 20) + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporaryManifest, $destination, $true)
}
finally {
    if (Test-Path -LiteralPath $temporaryManifest) { Remove-Item -LiteralPath $temporaryManifest -Force }
}
Write-Host "Verified $($inventory.photos.Count) photos: uploaded $uploaded; skipped $skipped."
Write-Host "Manifest: $destination"
return [pscustomobject]@{
    models = $inventory.models.Count
    photos = $inventory.photos.Count
    uploaded = $uploaded
    skipped = $skipped
    manifest_path = $destination
}
