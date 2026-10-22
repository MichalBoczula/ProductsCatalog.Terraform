# EcommerceStore Products — Terraform

Standalone infrastructure and manual ACA rollout for the Products vertical slice.
The foundation remains the default. After importing photos, follow the
[ACA deployment guide](docs/aca-deployment.md) to enable the app and anonymous
photo reads. See [the deployment plan](docs/deployment-plan.md).

## Repeatable manual deployment scripts

Use the [manual ACA guide](docs/aca-deployment.md) for the complete repeatable
workflow and for continuing an already deployed environment. It uses one ignored,
explicitly selected `products-deployment.tfvars.json` file, separate Plan/Apply
commands and saved-plan checks. After enabling the app, use these scripts or pass
that file to every Terraform plan; the low-level foundation examples below use
foundation defaults and must not replace your working deployment inputs.

| Script | Responsibility |
| --- | --- |
| `Initialize-ProductsSession.ps1` | Restore executable, Azure subscription, operator/password environment variables and initialize the existing backend |
| `Invoke-ProductsDeployment.ps1` | Plan/apply Foundation, Prepare, Serve, Runtime, Swagger, Internal or Destroy separately |
| `Import-ProductPhotos.ps1` | Validate, upload and verify the 60 photos after foundation apply |
| `Test-ProductsDeployment.ps1` | Inspect the live revision, verify API/seed data and an anonymous photo request |
| `Set-ProductsAppState.ps1` | Explicit Stop/Start between testing sessions without editing Terraform inputs |

Use `products_api_operator_ipv4` for temporary Swagger access; `operator_ipv4`
is only needed for direct local SQL access. The existing operator-IP fallback
remains compatible. After testing, the Internal step removes both personal-IP
inputs while retaining `products_sql_egress_ipv4`, which the app needs for SQL.

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
| Photo container | `photos` (private by default; optional blob-only anonymous reads) |
| Key Vault | `kv-ecp-dev-mb261013` |
| SQL logical server | `sql-ecommercestore-products-dev-mb261013` |
| SQL database | `products` |
| SQL connection secret | `products-sql-connection` |
| Optional Container App | `ca-ecommercestore-products-dev` |

The VNet uses `10.43.0.0/16`, with a delegated `10.43.0.0/27` subnet. SQL uses France Central, preserving the subscription's selected SQL Free region; the other services default to North Europe. SQL and Blob use public service endpoints; photo reads can be enabled anonymously while SQL and photo writes retain authentication. The VNet hosts ACA; it does not place those public endpoints inside the VNet.

Products and your operator user receive `Storage Blob Data Contributor` scoped to `photos`. Products receives `Key Vault Secrets User`; the operator receives `Key Vault Secrets Officer`. SQL authentication uses the administrator password for the initial disposable environment. A later retained deployment should use a restricted database user before exposing application traffic.

The default plan creates **15 Terraform-managed resources**, or **16** with `operator_ipv4` set. Rollout adds one Container App and one SQL rule per supplied egress IP. Azure creates additional ACA networking resources in its managed group. There is no MongoDB, frontend, BFF, Terraform-managed image import or image registry. SQL uses the Free offer with `AutoPause` at its monthly limit. Storage, Key Vault and ACA-managed networking can still incur usage charges.

## Manual provisioning from PowerShell

Prerequisites: PowerShell **7.2+**, Terraform **1.16.5**, Azure CLI, an interactive
Entra user login, an existing remote state account/container, permission to
create resources/assign roles, and `Storage Blob Data Contributor` on the state
container/account. Terraform pins AzureRM **5.8.0** and AzAPI **2.13.0**.

Follow [the manual ACA guide](docs/aca-deployment.md) one step at a time. It covers
initial local files, reopening the shell, Foundation, photo import, Prepare,
Serve/migrations, API verification, Runtime, Internal, Stop/Start and Destroy.

For an existing environment, preserve `backend.hcl`, `terraform.tfvars` and
`products-deployment.tfvars.json`. The backend must point to the existing state
account and `products/development.terraform.tfstate`, never the whole-store key.
The initializer never copies example files over them or migrates the backend.

```powershell
$session = .\scripts\Initialize-ProductsSession.ps1 `
    -SubscriptionId 'fcbf086b-8ce4-4ca5-a3d7-0c56489e25f6'
$ecommerceTerraform = $session.terraform_path
```

Reuse the same operator Entra UUID and SQL administrator password across sessions.
The initializer retains existing `TF_VAR_*` values or prompts/looks up the human
operator when missing. A new password plans a rotation. Terraform state and saved
plans contain sensitive values even though CLI output masks the password; keep
them private and never commit or share them.

Every stage creates a plan first. Apply is a separate action, after reviewing
its resource list. For example, after testing a working environment:

```powershell
.\scripts\Invoke-ProductsDeployment.ps1 -Step Internal
```

Review the plan, then run separately:

```powershell
.\scripts\Invoke-ProductsDeployment.ps1 -Step Internal -Action Apply
```

New RBAC assignments can need propagation. If the Key Vault secret creation fails
after its role assignment succeeds, retain state and inputs, allow propagation,
and create a fresh reviewed plan. Do not delete state or rerun a stale saved plan.

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

The importer checks that actual access matches Terraform's `private` or `blob`
mode, uses your Azure login, uploads or repairs changed images, skips unchanged
images and verifies all 60 blobs before replacing the local **photo-manifest.json**.
That generated file is ignored by Git and contains stable, URL-encoded addresses
and product IDs. Import runs separately from Terraform apply. Changing read access
does not require reuploading existing photos.

See [the photo import guide](docs/photo-import.md) for repeat imports, failure recovery, manifest fields and the retained S25 color review note. Naming cleanup is separate from rollout. If you destroyed the environment, provision it again before running the upload command.

Run the importer checks offline:

```powershell
pwsh -NoProfile -File .\tests\Test-ImportProductPhotos.ps1
```

These checks use fake commands and temporary fixtures. They do not contact Azure, run Terraform or upload photos.

## Deploy the Products API

Follow [the ACA deployment guide](docs/aca-deployment.md) with your existing
backend and variables. Merge the API changes and wait for the immutable Docker Hub
image, apply `prepare`, capture actual app egress IPs, then review/apply `serve`.
Enable `photos_anonymous_read_enabled` for anonymous photo URLs. The API stays
internal unless you enable operator-only external testing. These repository
changes do not trigger Azure provisioning.

## Destroy only this Products environment

Restore the same three `TF_VAR_*` values and initialize the same Products backend before planning destruction. This deletes the database, imported photos and disposable Key Vault; retain original photos outside this environment.

```powershell
.\scripts\Invoke-ProductsDeployment.ps1 -Step Destroy
```

Review the resource list, then run separately:

```powershell
.\scripts\Invoke-ProductsDeployment.ps1 -Step Destroy -Action Apply
```

The external Terraform state account/container and earlier whole-store environment are outside this root's ownership. Delete an application resource group through Azure CLI only as a deliberate recovery step, then reconcile this root's state with a reviewed refresh-only plan/apply.

## References

- [Azure resource naming conventions](https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/ready/azure-best-practices/naming-and-tagging)
- [Azure resource naming limits](https://learn.microsoft.com/en-us/azure/azure-resource-manager/management/resource-name-rules)
- [ACA custom virtual networks](https://learn.microsoft.com/en-us/azure/container-apps/custom-virtual-networks)
- [SQL Database Free offer](https://learn.microsoft.com/en-us/azure/azure-sql/database/free-offer)
- [Blob data RBAC](https://learn.microsoft.com/en-us/azure/storage/blobs/assign-azure-role-data-access)
- [ACA Key Vault secret references](https://learn.microsoft.com/en-us/azure/container-apps/manage-secrets)
