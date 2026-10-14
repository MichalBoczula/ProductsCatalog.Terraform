# EcommerceStore Products — Terraform foundation

Standalone infrastructure for the Products vertical slice. See [the deployment plan](docs/deployment-plan.md). This first stage prepares infrastructure for photo import and SQL migrations; the Products Container App is added after those stages.

## Resources and naming

Use lowercase names in the form `<resource-prefix>-ecommercestore-products-<environment>`. Globally unique services also use a stable `name_suffix`. Key Vault uses `ecp` to fit its 24-character limit; Storage names contain only lowercase letters and digits.

For `environment = "dev"` and `name_suffix = "mb261013"`:

| Resource | Name |
| --- | --- |
| Resource group | `rg-ecommercestore-products-dev` |
| VNet | `vnet-ecommercestore-products-dev` |
| ACA subnet | `snet-aca` |
| ACA environment | `cae-ecommercestore-products-dev` |
| Azure-managed ACA group | `rg-ecommercestore-products-dev-aca-managed` |
| Products managed identity | `id-ecommercestore-products-dev` |
| Photo storage account | `stecproductsdevmb261013` |
| Photo container | `photos` (private) |
| Key Vault | `kv-ecp-dev-mb261013` |
| SQL logical server | `sql-ecommercestore-products-dev-mb261013` |
| SQL database | `products` |
| SQL connection secret | `products-sql-connection` |
| Future Container App (stage 5) | `ca-ecommercestore-products-dev` |

The VNet uses `10.43.0.0/16`, with a delegated `10.43.0.0/27` subnet. SQL uses France Central, preserving the subscription's selected SQL Free region; the other services default to North Europe. SQL and Blob currently use authenticated public service endpoints. The VNet hosts ACA; it does not place those public endpoints inside the VNet.

Products and your operator user receive `Storage Blob Data Contributor` scoped to `photos`. Products receives `Key Vault Secrets User`; the operator receives `Key Vault Secrets Officer`. SQL authentication uses the administrator password for the initial disposable environment. A later retained deployment should use a restricted database user before exposing application traffic.

The default plan creates **15 Terraform-managed resources**, or **16** with `operator_ipv4` set. Azure creates additional ACA networking resources in its managed group. There is no MongoDB, frontend, BFF, image import, Container App or image registry in this first stage. SQL uses the Free offer with `AutoPause` at its monthly limit. Storage, Key Vault and ACA-managed networking can still incur usage charges.

## Manual provisioning from PowerShell

Prerequisites: Terraform **1.16.5**, Azure CLI, an interactive Entra user login, an existing remote state account/container, subscription permissions to create the listed resources and assign RBAC roles, and `Storage Blob Data Contributor` on the remote state container/account. Terraform pins AzureRM **5.8.0** and AzAPI **2.13.0**.

### 1. Prepare local files

Work in a clean clone of **ProductsCatalog.Terraform**, not the earlier whole-store directory. Copy these files once:

```powershell
Copy-Item terraform.tfvars.example terraform.tfvars
Copy-Item backend.hcl.example backend.hcl
```

Edit `terraform.tfvars`: choose a stable globally unique suffix. Leave `operator_ipv4` unset until local SQL migrations are needed; it is not needed for photo import.

Edit `backend.hcl`: replace the state account placeholder with your existing state account name. Keep `container_name = "tfstate"` and the **new** key `products/development.terraform.tfstate`. The existing state account and container are not created, imported or destroyed by this root. Each other environment needs its own key. Do not copy `.terraform/` or state files from another repo.

### 2. Log in and set required inputs

```powershell
$ecommerceTerraform = Join-Path $env:LOCALAPPDATA `
    'Programs\Terraform\1.16.5\terraform.exe'
if (-not (Test-Path $ecommerceTerraform)) { throw 'Terraform 1.16.5 was not found' }

az login
if ($LASTEXITCODE -ne 0) { throw 'Azure login failed' }
az account set --subscription Portfolio
if ($LASTEXITCODE -ne 0) { throw 'Subscription selection failed' }

$env:TF_VAR_subscription_id = az account show --query id --output tsv
if ($LASTEXITCODE -ne 0) { throw 'Subscription lookup failed' }
$env:TF_VAR_operator_object_id = az ad signed-in-user show --query id --output tsv
if ($LASTEXITCODE -ne 0) { throw 'Operator lookup failed' }

$env:TF_VAR_sql_admin_password = [System.Net.NetworkCredential]::new(
    '', (Read-Host 'Products SQL administrator password' -AsSecureString)
).Password
```

Choose a strong password and retain it securely. Reuse it when reopening your shell or planning destruction; entering a different password plans a rotation. The operator UUID is your human Entra user object ID. Run this first manual apply as that user so it can use the assigned Key Vault role.

The password is marked sensitive and is not output. Terraform state and saved plans still contain sensitive values; keep them private and never commit or share them.

### 3. Initialize and check

```powershell
& $ecommerceTerraform version
if ($LASTEXITCODE -ne 0) { throw 'Version check failed' }
& $ecommerceTerraform init '-backend-config=backend.hcl'
if ($LASTEXITCODE -ne 0) { throw 'Initialization failed' }
& $ecommerceTerraform fmt '-check' '-recursive'
if ($LASTEXITCODE -ne 0) { throw 'Formatting check failed' }
& $ecommerceTerraform validate
if ($LASTEXITCODE -ne 0) { throw 'Validation failed' }
& $ecommerceTerraform test
if ($LASTEXITCODE -ne 0) { throw 'Tests failed' }
```

Tests use mock providers and test-only UUIDs/passwords; they do not create Azure resources. They cover naming, photo access, SQL Free settings, the ACA subnet/profile, operator access and rejected inputs.

### 4. Plan, review, then apply

```powershell
& $ecommerceTerraform plan '-input=false' '-out=products-foundation.tfplan'
if ($LASTEXITCODE -ne 0) { throw 'Planning failed; nothing was applied' }
```

Review the plan. For a clean default deployment, expect **15 to add, 0 to change, 0 to destroy**. If a new standalone deployment plans changes/deletions, stop and verify the backend key before applying.

Once the plan is correct, run separately:

```powershell
& $ecommerceTerraform apply products-foundation.tfplan
if ($LASTEXITCODE -ne 0) { throw 'Apply failed; inspect the error before retrying' }
& $ecommerceTerraform output -json products_foundation
if ($LASTEXITCODE -ne 0) { throw 'Output lookup failed' }
```

New RBAC assignments can take time to propagate. If creating the Key Vault secret fails with a permission error after the role was successfully assigned, allow propagation, then create/review a fresh plan and apply it. Terraform retains successfully created resources in state; do not delete the state or run a stale saved plan.

### 5. Verify and pause before photo import

```powershell
$products = (& $ecommerceTerraform output -json products_foundation) | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Output lookup failed' }

az storage container show `
    --account-name $products.storage_account_name `
    --name $products.photos_container_name `
    --auth-mode login --query name --output tsv
if ($LASTEXITCODE -ne 0) { throw 'Photo container access check failed' }

& $ecommerceTerraform plan '-input=false' '-detailed-exitcode'
if ($LASTEXITCODE -eq 1) { throw 'Verification plan failed' }
if ($LASTEXITCODE -eq 2) { throw 'Infrastructure still has changes to review' }
```

`photos_base_url` is the canonical address prefix, **not an anonymous-access URL**. Do not upload photo files into Terraform state or store expiring SAS tokens in migrations.

## Import catalog photos after apply

The repository contains 15 model folders and 60 WebP files under `assets/photos/`. Each folder has `Main`, `Front`, `Back` and `Side`. The explicit folder-to-Products-ID mapping is in [assets/photos.catalog.json](assets/photos.catalog.json).

Use PowerShell **7.2 or later**. Validate the local files first; this does not need Azure or an applied environment:

```powershell
.\scripts\Import-ProductPhotos.ps1 -ValidateOnly
```

After the foundation has been applied and you have selected its subscription in Azure CLI, upload:

```powershell
.\scripts\Import-ProductPhotos.ps1 -TerraformPath $ecommerceTerraform
```

The importer verifies the private target container, uses your Azure login, uploads or repairs changed images, skips unchanged images and verifies all 60 blobs before replacing the local **photo-manifest.json**. That generated file is ignored by Git. It includes stable, URL-encoded blob addresses and the product IDs needed for the next migration step. Files are imported separately from Terraform apply.

See [the photo import guide](docs/photo-import.md) for repeat imports, failure recovery, manifest fields and the S25 color difference requiring review before migrations. If you destroyed the environment, provision it again before running the upload command.

Run the importer checks offline:

```powershell
pwsh -NoProfile -File .\tests\Test-ImportProductPhotos.ps1
```

These checks use fake commands and temporary fixtures. They do not contact Azure, run Terraform or upload photos.

## Destroy only this Products environment

Restore the same three `TF_VAR_*` values and initialize the same Products backend before planning destruction. This deletes the database, imported photos and disposable Key Vault; retain original photos outside this environment.

```powershell
& $ecommerceTerraform plan '-destroy' '-input=false' '-out=products-destroy.tfplan'
if ($LASTEXITCODE -ne 0) { throw 'Destroy planning failed; nothing was deleted' }
```

Review the resource list, then run separately:

```powershell
& $ecommerceTerraform apply products-destroy.tfplan
if ($LASTEXITCODE -ne 0) { throw 'Destroy failed; keep the state and inspect the error' }
```

The external Terraform state account/container and earlier whole-store environment are outside this root's ownership. Delete an application resource group through Azure CLI only as a deliberate recovery step, then reconcile this root's state with a reviewed refresh-only plan/apply.

## References

- [Azure resource naming conventions](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/naming-and-tagging)
- [Azure resource naming limits](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/resource-name-rules)
- [ACA custom virtual networks](https://learn.microsoft.com/en-us/azure/container-apps/custom-virtual-networks)
- [SQL Database Free offer](https://learn.microsoft.com/en-us/azure/azure-sql/database/free-offer)
- [Blob data RBAC](https://learn.microsoft.com/en-us/azure/storage/blobs/assign-azure-role-data-access)
- [ACA Key Vault secret references](https://learn.microsoft.com/en-us/azure/container-apps/manage-secrets)
