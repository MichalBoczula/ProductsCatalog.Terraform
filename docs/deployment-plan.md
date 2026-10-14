# Products deployment plan

Work through one stage at a time. Provisioning and application deployment remain manual until the complete Products flow works.

1. **Prepare the standalone Terraform foundation.** Define the Products resource group, VNet, delegated ACA subnet, Consumption ACA environment, SQL server/database, photo storage/container, managed identity, Key Vault, SQL connection secret and role assignments. Use a dedicated remote state key. Deliver configuration checks and the manual provisioning guide.
2. **Provision the foundation manually.** Log in locally, initialize the backend, validate/test, review a saved plan, apply, and verify the non-secret outputs. Azure resources are not provisioned merely by preparing this repository.
3. **Automate photo import.** The 15 model folders and 60 WebP files are now mapped in `assets/photos.catalog.json`. Run `scripts/Import-ProductPhotos.ps1 -ValidateOnly`, then import after apply as described in [the photo import guide](photo-import.md). The importer uses Azure CLI/Entra authentication and exports a verified product/photo URL manifest. This is an import tool, not a Terraform-managed collection of image files. Decide authenticated image delivery and resolve the S25 Black/Green review note before changing database URLs.
4. **Adjust Products migrations/seed data.** Use the actual imported manifest. Prefer a new migration when earlier migrations may already have run. Do not persist expiring SAS tokens in seeded data. Run migrations separately before the hosted app starts.
5. **Connect and deploy Products.** Configure Blob endpoint/container and the user-assigned identity in Products. Add the immutable Products image and internal ingress Container App to this foundation. The environment already exists, so discover its outbound addresses and add narrowly scoped SQL firewall rules before deployment. Resolve the SQL secret through Key Vault. Verify liveness, SQL readiness, catalog queries and image retrieval.

After Products works, add BFF and frontend in their own steps. The Docker image stays on Docker Hub; the foundation does not introduce another registry. This root creates only Products resources. The former whole-store foundation continues to own any resources already in its state.

## State and ownership

Use the existing independently managed Terraform state storage account and `tfstate` container, but a different blob: `products/development.terraform.tfstate`. Never initialize this root against `development.terraform.tfstate`, which belongs to the whole-store root. The state account/container are not managed here.

New Products names intentionally differ from the former whole-store names. This is a new environment; it does not import, move or delete existing resources. If the old environment is still present, both environments exist and can incur costs until you deliberately destroy the old one with its original configuration/state.

## First-stage boundaries

The ACA environment is created now; the Products Container App is created in stage 5. Foundation planning therefore does not depend on apply-time public IP discovery or an image that will change after migration work. Photo import, seed updates, SQL migrations and deployment automation are later stages.

Photos remain private. A canonical Blob URL identifies the object but does not authorize anonymous browser access. Image delivery will use an authenticated API path or a short-lived signed URL. If we choose user-delegation SAS, add the required account-level delegation permission explicitly in that stage; container-level data access alone does not grant permission to request a delegation key.
