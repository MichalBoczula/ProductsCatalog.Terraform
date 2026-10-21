# Products deployment plan

Work through one stage at a time. Provisioning and application deployment remain manual until the complete Products flow works.

1. **Prepare the standalone Terraform foundation.** Define the Products resource group, VNet, delegated ACA subnet, Consumption ACA environment, SQL server/database, photo storage/container, managed identity, Key Vault, SQL connection secret and role assignments. Use a dedicated remote state key. Deliver configuration checks and the manual provisioning guide.
2. **Provision the foundation manually.** Log in locally, initialize the backend, validate/test, review a saved plan, apply, and verify the non-secret outputs. Azure resources are not provisioned merely by preparing this repository.
3. **Import photos.** The 15 model folders and 60 WebP files are mapped in `assets/photos.catalog.json`. Import after foundation apply as described in [the photo import guide](photo-import.md). The operator has imported and verified all 60 photos. The S25 name cleanup remains deferred.
4. **Adjust Products migrations/seed data.** Products uses the verified canonical Blob URLs in its existing disposable-development seed migrations. Recreate that database when the edited migration IDs have already run; no expiring SAS tokens are stored in seed data. The list DTO includes `mainPhoto` in API PR #198; merge it and wait for the master image publish before rollout.
5. **Connect and deploy Products.** Follow [the manual ACA guide](aca-deployment.md). Enable blob-only anonymous photo reads. Deploy the pinned image with internal ingress, managed identity, and a Key Vault SQL secret reference. Apply `prepare` without SQL readiness or migrations, then capture actual app outbound IPs into plan-known inputs. Review/apply `serve` with exact SQL rules and SQL readiness. One-time startup migrations can seed this disposable database; disable them after verification. Operator-only external API testing is optional.

After Products works, add BFF and frontend in their own steps. The Docker image stays on Docker Hub; the foundation does not introduce another registry. This root creates only Products resources. The former whole-store foundation continues to own any resources already in its state.

The manual scripts now encode these stages with separate Plan and Apply actions.
Keep `products-deployment.tfvars.json` across sessions; it retains the immutable
image and exact ACA SQL rules. Use the Internal step after browser verification
to remove temporary personal-IP access. API and local SQL IP inputs are separate;
the existing operator-IP fallback remains compatible.

## State and ownership

Use the existing independently managed Terraform state storage account and `tfstate` container, but a different blob: `products/development.terraform.tfstate`. Never initialize this root against `development.terraform.tfstate`, which belongs to the whole-store root. The state account/container are not managed here.

New Products names intentionally differ from the former whole-store names. This is a new environment; it does not import, move or delete existing resources. If the old environment is still present, both environments exist and can incur costs until you deliberately destroy the old one with its original configuration/state.

## Foundation and rollout boundaries

The ACA environment belongs to the foundation; the Container App is optional.
Foundation defaults create neither app nor SQL egress rules. Rollout uses two
reviewed applies so firewall instance keys do not depend on unknown resource
attributes. SQL remains in France Central and retains its Free offer. No NAT
gateway or private endpoint is introduced in this disposable stage.

Set `photos_anonymous_read_enabled=true` to allow individual photo URLs without
a login or SAS. The default remains private. Uploads retain Entra RBAC, and
anonymous listing is not enabled. This affects only the Products photo account
and container; the independently managed state account remains unchanged.
