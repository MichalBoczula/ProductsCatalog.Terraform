# Import Products photos

This stage imports the checked-in catalog photos into the existing private `photos` container and exports a verified manifest for the later Products migration. Run the importer manually **after** Terraform apply. It does not provision infrastructure, change the database or deploy an application.

## Source layout and mapping

The current collection has **15 models and 60 WebP images**. Each model has its own folder under `assets/photos/` with exactly four files: `Main.webp`, `Front.webp`, `Back.webp` and `Side.webp`. The script also supports JPEG and PNG, detects extensions, and checks image signatures before cloud operations. File-header checks do not fully decode an image; visually review the source photos when replacing them.

The mapping in `assets/photos.catalog.json` records the folder, existing Products product UUID, seeded product name and any review notes. It is pinned to Products source commit `5fa6966327dbc7894ce8156cf222b28a0cdf52f5`. Folder-to-product matching is explicit because local folder names contain Polish colors and filesystem-friendly memory sizes, while the API seed uses English colors and slash-separated sizes.

Keep the folder component in each blob name. For example, the source `assets/photos/Apple iPhone 16 128GB Biały/Main.webp` becomes blob `Apple iPhone 16 128GB Biały/Main.webp` inside `photos`. The manifest URL escapes each path segment, including spaces and `ł`, while the actual blob name preserves the readable folder name. Supported source filenames are matched without case sensitivity; blob role names are normalized to `Main`, `Front`, `Back` and `Side` and extensions to lowercase.

`mainPhoto` is `Main`; `otherPhotos` is ordered **Front, Back, Side**. The manifest retains all four per-image records with SHA256, Base64 MD5, byte count and MIME type.

### S25 variant review

The folder **Samsung Galaxy S25 12256GB Czarny** identifies black photos, but seeded product `3c1c2b2e-0a63-4a6d-8f0c-5d3a1e8f9a21` is named **Samsung Galaxy S25 12/256GB Green**. Its mapping has a review note, and its manifest entry has `catalog_review_required: true`. Importing the files is valid, but reconcile the photo/product color in the later migration step. The importer does not rename or recolor the product.

## 1. Validate locally

From the repository root in PowerShell 7.2 or later:

```powershell
.\scripts\Import-ProductPhotos.ps1 -ValidateOnly
```

Expected: 15 models, 60 photos, plus the known S25 review warning. No Azure CLI or Terraform command runs in this mode. Missing/extra photos, duplicate roles, unmapped folders, duplicate product IDs and invalid image signatures fail before any cloud operation.

Optional paths: `-PhotosPath` and `-CatalogPath` let you validate another local collection with its matching catalog.

## 2. Ensure the foundation exists

Use the manual foundation sequence in the README. If last night's environment was destroyed, reconcile any manual Azure deletions with a reviewed refresh-only plan/apply, then create and review a **fresh** foundation plan and apply it. Do not reuse the old destroy or foundation plan.

The upload stage reads only `terraform output -json products_foundation` from this repository. It checks that outputs refer to the expected Products group/account and private `photos` container; verifies the Azure CLI subscription, provisioned storage endpoint and actual container access; and stops if those checks fail. The importer does not need the SQL password directly, but a foundation plan/apply still needs the original required inputs described in the README.

Log in with the operator user granted container-scoped `Storage Blob Data Contributor`. Blob operations always specify `--auth-mode login`, account, container and subscription. No storage key, SQL password or SAS token is passed to the importer.

## 3. Import

Use your locally installed Terraform executable:

```powershell
$ecommerceTerraform = Join-Path $env:LOCALAPPDATA 'Programs\Terraform\1.16.5\terraform.exe'
if (-not (Test-Path $ecommerceTerraform)) { throw 'Terraform 1.16.5 was not found' }
.\scripts\Import-ProductPhotos.ps1 -TerraformPath $ecommerceTerraform
```

The script lists existing blobs with metadata. For the mapped photos only, it skips objects when SHA256 metadata, product/role metadata, content MD5, byte count, MIME type and cache control match. Changed or legacy blobs are uploaded with service-side transfer checksums, explicit MIME type and checksum metadata. Existing replacements use an ETag condition; new uploads use a create-only condition. Concurrent modifications fail instead of silently overwriting a newly changed blob.

After uploads, a fresh listing verifies every mapped photo. Only then is **photo-manifest.json** written via a temporary file in the same destination directory and replaced atomically. A successful first import should report **uploaded 60; skipped 0**. A repeat import should report **uploaded 0; skipped 60**.

The importer does not delete blobs outside the mapping or prune old names. If you rename model folders or change extensions, previous blob names remain until a separate cleanup is deliberately performed.

## 4. Inspect the manifest

```powershell
$manifest = Get-Content .\photo-manifest.json -Raw -Encoding utf8 | ConvertFrom-Json
$manifest.products | Select-Object product_id, product_name, mainPhoto, catalog_review_required
```

The manifest includes:

- Schema version, generation timestamp and pinned Products source commit.
- Subscription, application group, storage account, container and private access mode.
- Upload/skip counts and one record per product.
- Product UUID/name, source folder and review notes.
- `mainPhoto` and three `otherPhotos` canonical URLs.
- Four photo records containing blob names, encoded URLs, source paths, hashes, sizes and MIME types.

Canonical URLs identify private objects; they do not authorize anonymous browser access. The later API/BFF or short-lived signed-URL delivery step must provide access. Do not store expiring SAS tokens in SQL seed data. Do not commit environment-specific generated manifests; the mapping and original images are the versioned inputs.

## Windows Unicode handling

Captured Azure CLI JSON can use a Windows ANSI encoding while PowerShell decodes it differently. This can make a correctly uploaded name such as `Apple iPhone 16 128GB Biały/Main.webp` disappear from the importer's name lookup. A repeat upload then hits `BlobAlreadyExists` because the create-only condition correctly protects the existing blob.

For the official Windows MSI/ZIP launchers, the importer discovers their bundled `python.exe` and runs Azure CLI with explicit `-X utf8 -IBm azure.cli`. The standard launcher's `-I` flag ignores Python encoding environment variables, so setting `PYTHONUTF8` alone is insufficient. Captured native output is decoded as UTF-8, with the caller's console encoding restored even after errors. The installed launchers and global Windows settings are unchanged.

If an earlier run uploaded the collection but failed on `Biały`, pull this correction and rerun:

```powershell
git pull --ff-only origin main
if ($LASTEXITCODE -ne 0) { throw 'Git pull failed' }
.\scripts\Import-ProductPhotos.ps1 -TerraformPath $ecommerceTerraform
```

If all 60 blobs already match, expect **uploaded 0; skipped 60**. A failed first import does not create `photo-manifest.json`; it appears only after every mapped blob passes verification. Verification errors now identify the mismatched fields, such as `contentMd5`, or a missing blob name. Keep these checks enabled when diagnosing a remaining failure.

## Failure recovery

- New role assignments may take time to propagate. If Azure returns an authorization error, verify the signed-in operator and assigned role, allow propagation, then rerun the importer.
- Failed imports can leave successfully uploaded photos in the container. The script preserves the previous completed manifest and does not roll back uploads. Rerunning verifies/skips completed objects and resumes remaining work.
- If the collection changes while importing or an ETag condition fails, stabilize the source/concurrent uploader and rerun. The script rebuilds local hashes and rereads remote properties.
- If the environment is missing, apply the foundation first. Stale Terraform outputs cannot substitute for existing Azure resources.
- A MIME mismatch or missing checksum metadata causes the mapped blob to be repaired on the next run.

## Validation performed

All **26 offline checks** pass using PowerShell 7.5.3. They exercise the actual 60-image collection and native-command-shaped fake responses, repeat imports, single-image changes, URL encoding, role ordering, legacy/MIME repair, target checks, partial failure, failed verification, concurrent writes and manifest preservation. An additional native child process emits UTF-8 JSON containing `Biały` while the caller uses Windows code page 1250; the original importer reproduces the reported verification failure, and the corrected importer verifies and skips those blobs on repeat. Encoding restoration is checked on success and failure. Azure CLI response shapes, Base64 MD5 handling and list options were checked against the official Azure CLI source.

The operator's Windows run reported successful upload calls for all 60 images, followed by a Unicode-name verification failure. The correction has been checked offline; a live operator retry is still required to confirm the actual Windows Azure CLI installation and Azure data path. The Terraform resources and provider lock are unchanged by this stage.

References: [Azure CLI blob commands](https://learn.microsoft.com/en-us/cli/azure/storage/blob?view=azure-cli-latest), [Blob data RBAC](https://learn.microsoft.com/en-us/azure/storage/blobs/assign-azure-role-data-access), [Azure CLI storage transformers](https://github.com/Azure/azure-cli/blob/dev/src/azure-cli/azure/cli/command_modules/storage/_transformers.py).

Unicode references: [Azure CLI Windows MSI launcher](https://github.com/Azure/azure-cli/blob/dev/build_scripts/windows/scripts/az_msi.cmd), [Python isolated and UTF-8 options](https://docs.python.org/3/using/cmdline.html).
