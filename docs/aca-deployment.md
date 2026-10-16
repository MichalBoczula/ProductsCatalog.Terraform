# Deploy Products to ACA and serve public photos

This continues the existing Products environment and state. Run locally from
`ProductsCatalog.Terraform` with PowerShell 7.2+, Terraform 1.16.5 and Azure CLI.
Do not copy the example backend/tfvars files over your working files again.
Keep `stecomtfstatemb261011`, container `tfstate`, and key
`products/development.terraform.tfstate`. Keep the existing suffix and SQL password.
The state account is outside this root and remains private.

## 1. Publish the application image

Merge the Products API change [PR #198](https://github.com/MichalBoczula/ProductsCatalog/pull/198)
and wait for its **master push** CI run to finish the scanned Docker Hub publish.
PR CI validates images but does not publish them. The image repository is
`mb0101/product-catalog-api`; use the full master commit SHA tag from that run,
or its recorded sha256 digest. Do not use `latest` or the PR's head SHA tag.
ACA pulls the public image; Docker Hub credentials stored in GitHub are used
for the CI push, not automatically supplied to Azure.

The API image must contain the Blob seed URLs and list `mainPhoto` change.
No image files are embedded into Terraform state or the API image.

## 2. Prepare local rollout inputs

Pull this Terraform change. Restore the same Azure CLI subscription and
`TF_VAR_subscription_id`, `TF_VAR_operator_object_id`, and
`TF_VAR_sql_admin_password` values used to provision the environment. Use the
original SQL password; changing it would plan a password/connection-secret rotation.
Keep your existing `$ecommerceTerraform` executable path.

Create a separate ignored rollout file. Run this initial creation once; later
steps update this file rather than overwriting backend or foundation inputs.

```powershell
$productsImageCommit = Read-Host 'Published master image commit (full 40-character SHA)'
if ($productsImageCommit -cnotmatch '^[0-9a-f]{40}$') { throw 'Use the full published master commit SHA' }
if (Test-Path .\products-rollout.auto.tfvars.json) { throw 'Rollout file already exists; edit it instead of recreating it' }
@{
    photos_anonymous_read_enabled    = $true
    deploy_products_app              = $true
    products_image                   = "mb0101/product-catalog-api:$productsImageCommit"
    products_deployment_stage        = 'prepare'
    products_apply_migrations        = $false
    products_external_ingress_enabled = $false
} | ConvertTo-Json | Set-Content .\products-rollout.auto.tfvars.json -Encoding utf8

& $ecommerceTerraform init '-backend-config=backend.hcl'
if ($LASTEXITCODE -ne 0) { throw 'Initialization failed' }
& $ecommerceTerraform fmt '-check' '-recursive'
if ($LASTEXITCODE -ne 0) { throw 'Formatting failed' }
& $ecommerceTerraform validate
if ($LASTEXITCODE -ne 0) { throw 'Validation failed' }
& $ecommerceTerraform test
if ($LASTEXITCODE -ne 0) { throw 'Mocked tests failed' }
```

Photos use `blob` access: anyone with a photo URL can read it, while anonymous
container listing and writes remain unavailable. Storage Shared Key stays
disabled; uploads still use your Entra identity. Existing canonical URLs and
uploaded photos stay unchanged, so changing access needs no reimport or seed edit.

The API is internal to the ACA environment by default, ready for the later BFF.
For a temporary local Swagger/HTTP test, set
`products_external_ingress_enabled` to `true` in the rollout file and provide
your current public IPv4 through the existing `operator_ipv4` input. External
ingress is restricted to that address's `/32`; the unauthenticated write API is
not opened to everyone. This also retains the existing operator SQL rule until
you remove `operator_ipv4` after testing.

## 3. Review and apply prepare

```powershell
& $ecommerceTerraform plan '-input=false' '-out=products-prepare.tfplan'
if ($LASTEXITCODE -ne 0) { throw 'Prepare planning failed' }
```

Review the saved plan before running the next block. For an unchanged existing
foundation, preparation adds the Container App and updates photo account/container
access in place. It must not replace the VNet, ACA environment, SQL database,
storage account, or delete resources. Preserve any existing backend/state and
resolve unexpected changes before applying.

```powershell
& $ecommerceTerraform apply products-prepare.tfplan
if ($LASTEXITCODE -ne 0) { throw 'Prepare failed; retain state and inspect the error' }
& $ecommerceTerraform output -json products_deployment
if ($LASTEXITCODE -ne 0) { throw 'Deployment output lookup failed' }
```

Prepare starts the real pinned API image on port 8080 with migrations disabled.
Both startup and readiness use `/health/live` during this stage, allowing Azure
to start the app before SQL access exists. This is networking preparation, not
the completed database-ready rollout. The managed identity resolves the SQL
connection secret from Key Vault; no connection string is copied into CLI output
or the rollout input file.

## 4. Record exact SQL egress and review serve

```powershell
.\scripts\Set-ProductsSqlEgress.ps1 -TerraformPath $ecommerceTerraform
$rollout = Get-Content .\products-rollout.auto.tfvars.json -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
$rollout.products_deployment_stage = 'serve'
$rollout.products_apply_migrations = $true
$rollout | ConvertTo-Json | Set-Content .\products-rollout.auto.tfvars.json -Encoding utf8

& $ecommerceTerraform plan '-input=false' '-out=products-serve.tfplan'
if ($LASTEXITCODE -ne 0) { throw 'Serve planning failed' }
```

The helper reads the applied app's `outbound_ip_addresses` and writes an ignored
`products-egress.auto.tfvars.json` with stable map keys and exact IPv4 values.
Review that file and the plan. Expect one SQL firewall rule per unique outbound
address and an app revision update. No Azure-wide `0.0.0.0` rule, IP range,
inbound-IP substitution, or apply-time `for_each` is used.

This environment and SQL are in different regions, so this rollout retains
the public SQL endpoint with exact firewall rules. It does not move SQL, add
a paid NAT gateway/private endpoint, or change the SQL Free offer.

Once the plan is correct, apply separately:

```powershell
& $ecommerceTerraform apply products-serve.tfplan
if ($LASTEXITCODE -ne 0) { throw 'Serve failed; retain state and inspect the error' }
$deployment = (& $ecommerceTerraform output -json products_deployment) -join "`n"
if ($LASTEXITCODE -ne 0) { throw 'Deployment output lookup failed' }
$deployment = $deployment | ConvertFrom-Json

az containerapp show --resource-group $deployment.resource_group_name --name $deployment.name `
    --query '{state:properties.provisioningState,revision:properties.latestReadyRevisionName,image:properties.template.containers[0].image,egress:properties.outboundIpAddresses}' --output json
if ($LASTEXITCODE -ne 0) { throw 'Container App verification failed' }
```

Serve waits for the SQL rules before deploying the revision. Readiness now uses
`/health/ready`; liveness remains independent of SQL. Startup migrations are
enabled only for this disposable database bootstrap. The app uses Consumption,
0.25 vCPU/0.5 GiB, a single revision, and zero to one replicas.

## 5. Verify API and anonymous images

With internal ingress, verify the ready revision and later call the API through
the BFF in the same ACA environment. With the optional operator-only external
test enabled, run locally from the allowed public IPv4:

```powershell
$baseUrl = $deployment.base_url
$ready = $false
for ($attempt = 0; $attempt -lt 12; $attempt++) {
    try {
        $response = Invoke-WebRequest "$baseUrl/health/ready" -TimeoutSec 20
        if ($response.StatusCode -eq 200) { $ready = $true; break }
    } catch { }
    Start-Sleep -Seconds 10
}
if (-not $ready) { throw 'SQL readiness did not become healthy; inspect ACA logs and exact egress rules' }
$phones = @(Invoke-RestMethod "$baseUrl/mobile-phones?amount=15" -TimeoutSec 30)
if ($phones.Count -ne 15 -or @($phones | Where-Object { [string]::IsNullOrWhiteSpace($_.mainPhoto) }).Count -gt 0) {
    throw 'Expected 15 seeded phones with mainPhoto URLs'
}
# No Authorization header or SAS token: this is an anonymous photo request.
$photo = Invoke-WebRequest $phones[0].mainPhoto -Method Head -TimeoutSec 30
if ($photo.StatusCode -ne 200 -or [string]$photo.Headers['Content-Type'] -notlike 'image/*') { throw 'Anonymous photo verification failed' }
```

Anonymous photo access can also be tested independently of API ingress by opening
an existing manifest `mainPhoto` URL in a private browser window. Do not test
account keys, SAS links, or a signed-in Storage Explorer session as anonymous access.

Cold ACA/SQL starts can take time. SQL can also pause at its Free monthly limit;
that setting is preserved. If Azure changes the app's outbound IPs, refresh the
Terraform state with a reviewed refresh-only plan/apply, rerun the helper, review
the exact rule changes, and apply before verifying readiness again.

## 6. Finish the bootstrap

After verifying the database and photos, set `products_apply_migrations` back
to `false`. If you enabled temporary external ingress, set it back to `false`
and remove `operator_ipv4` when local SQL access is no longer needed. Review and
apply a new plan; do not reuse either saved plan above. Keep
`deploy_products_app=true`, the immutable image reference, the photo read flag,
and both ignored rollout/egress files for subsequent plans and destroy operations.

Future retained deployments should run migrations as a deployment step and use
a restricted SQL database identity. BFF, Angular hosting, and deployment automation
remain separate steps.

## Checks without Azure provisioning

```powershell
pwsh -NoProfile -File .\tests\Test-ImportProductPhotos.ps1
pwsh -NoProfile -File .\tests\Test-ProductsSqlEgress.ps1
```

GitHub `Terraform checks` initializes with the backend disabled, validates the
pinned provider schema, runs mocked Terraform plans, and runs both offline scripts.
It has no Azure credentials and never applies real resources.
