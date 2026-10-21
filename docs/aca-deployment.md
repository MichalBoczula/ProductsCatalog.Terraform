# Manual Products deployment

Run from `ProductsCatalog.Terraform` using PowerShell 7.2+, Terraform 1.16.5 and Azure CLI.
The scripts do not run from GitHub Actions and do not automatically apply plans.
The existing state account/container stay outside this root's ownership.

## Continue an already working environment

Keep the existing `backend.hcl`, `terraform.tfvars` and
`products-deployment.tfvars.json`. That last file retains the image, deployment
stage, photo access and exact ACA-to-SQL firewall addresses. Do not replace it
with foundation defaults. Every deployment script passes it explicitly.

Restore the shell session. The initializer retains an existing SQL password in
`TF_VAR_sql_admin_password`; otherwise it prompts without displaying the value.
Enter the original password. A different password plans a SQL/Key Vault rotation.
It reuses the operator UUID in `TF_VAR_operator_object_id`, or looks up the signed-in
human user. Pass `-OperatorObjectId` explicitly when restoring a different shell/account.

```powershell
$session = .\scripts\Initialize-ProductsSession.ps1 `
    -SubscriptionId 'fcbf086b-8ce4-4ca5-a3d7-0c56489e25f6'
$ecommerceTerraform = $session.terraform_path
```

After the API and photos have been verified, remove temporary personal-IP access:

```powershell
.\scripts\Invoke-ProductsDeployment.ps1 -Step Internal
```

Review the plan. Expect internal app ingress and removal of the old personal-IP
SQL rule when present. Keep the existing ACA SQL egress rules, image, database,
photos and identity. Apply separately:

```powershell
.\scripts\Invoke-ProductsDeployment.ps1 -Step Internal -Action Apply
.\scripts\Test-ProductsDeployment.ps1 -InfrastructureOnly
```

`InfrastructureOnly` verifies Azure configuration and revision selection. It does
not claim to make a live API request or verify database connectivity.
The BFF can subsequently call Products inside the same ACA environment.

## First deployment from a fresh clone

Prepare local files once. Existing files are preserved:

```powershell
if (-not (Test-Path .\terraform.tfvars)) {
    Copy-Item .\terraform.tfvars.example .\terraform.tfvars
}
if (-not (Test-Path .\backend.hcl)) {
    @'
storage_account_name = "stecomtfstatemb261011"
container_name       = "tfstate"
key                  = "products/development.terraform.tfstate"
'@ | Set-Content .\backend.hcl -Encoding utf8
}
```

Check `terraform.tfvars` before the first apply: `name_suffix` must stay stable
for this state. The deployed photo seed uses `mb261013`. Keep North Europe for
ACA and France Central for this subscription's SQL Free offer. Other environments
need a separate state key. The initializer rejects an unedited backend placeholder;
it never migrates or reconfigures a backend automatically.

Initialize the session using the command above. For a new SQL server choose a
strong password once and keep it securely for later sessions and destroy plans.
The initializer runs `init` and `validate`, not `apply`.

### 1. Foundation

```powershell
.\scripts\Invoke-ProductsDeployment.ps1 -Step Foundation
```

Review the 15 foundation additions. This script opts into anonymous individual
photo reads for the portfolio; shared keys, anonymous writes and anonymous listing
remain disabled. A fresh foundation has no Container App or laptop SQL rule.
`Foundation` rejects an already enabled app in either the inputs or remote state.

```powershell
.\scripts\Invoke-ProductsDeployment.ps1 -Step Foundation -Action Apply
```

If Azure returns a provisioning timeout, retain the state and input file. Inspect
the Azure resource and create a fresh Foundation plan; do not delete state or
reuse a stale saved plan. A partial apply can already have created resources.

### 2. Import photos

The existing importer remains separate from Terraform apply:

```powershell
.\scripts\Import-ProductPhotos.ps1 -ValidateOnly
.\scripts\Import-ProductPhotos.ps1 -TerraformPath $ecommerceTerraform
```

Expect 15 models, 60 verified photos, and `photo-manifest.json`. Repeating the
import skips unchanged photos. See [the import guide](photo-import.md).

### 3. Prepare the app

Use a successfully published image digest or full master commit tag. PR-only
builds do not publish an image. The image must contain the Blob seed URLs and
`mainPhoto` API change. The initial tested image is
`mb0101/product-catalog-api@sha256:dd92571adbbe889faacca4c0a72b4296a64e234c0ca9d57c9cf85b08bbd054d8`;
update it deliberately after a successful publish.

```powershell
$productsImage = Read-Host 'Published immutable Products image reference'
.\scripts\Invoke-ProductsDeployment.ps1 -Step Prepare -Image $productsImage
```

Review one app addition. Prepare uses internal ingress, port 8080, migrations
`false`, and `/health/live` for startup/readiness. It starts before SQL access
exists. Apply separately:

```powershell
.\scripts\Invoke-ProductsDeployment.ps1 -Step Prepare -Action Apply
.\scripts\Test-ProductsDeployment.ps1 -InfrastructureOnly
```

### 4. Serve and bootstrap SQL

```powershell
.\scripts\Invoke-ProductsDeployment.ps1 -Step Serve
```

Serve calls `Set-ProductsSqlEgress.ps1` using the actual applied app outputs. Its
temporary output is nested under `.products-plans/`, so Terraform does not
automatically load it. The reviewed exact IP map is copied into the retained
`products-deployment.tfvars.json`; a previous empty map cannot override it.

Review one SQL rule per unique outbound IP plus the app update. No Azure-wide
`0.0.0.0` rule, inbound-IP substitution, NAT gateway or private endpoint is added.
The app revision waits for the SQL rules. Startup migrations are enabled for this
initial disposable database, and readiness switches to `/health/ready`.

```powershell
.\scripts\Invoke-ProductsDeployment.ps1 -Step Serve -Action Apply
.\scripts\Test-ProductsDeployment.ps1 -InfrastructureOnly
```

A ready revision and `/health/ready` check the SQL schema; a ready `prepare`
revision checks only the process. During a rollout, the previous revision can
remain ready until the new one passes its probes. Inspect the latest revision's
logs if its name differs from the ready revision. SQL auto-resume can take time.

### 5. Test Swagger, the seeded phones and photos

```powershell
$productsApiIpv4 = Read-Host 'Current public IPv4 for temporary API access'
.\scripts\Invoke-ProductsDeployment.ps1 -Step Swagger -ApiOperatorIpv4 $productsApiIpv4
```

Review the temporary `/32` API allowlist and removal of any old laptop SQL rule.
This exposes Swagger and the API only to that source IP. It does not publish only
Swagger: the same allowed client can reach the application's write endpoints.

```powershell
.\scripts\Invoke-ProductsDeployment.ps1 -Step Swagger -Action Apply
.\scripts\Test-ProductsDeployment.ps1
```

The verifier reads the current FQDN from Azure, waits for `/health/ready`, checks
15 phones with nonempty `mainPhoto`, and makes a fresh anonymous HEAD request to
one returned photo. No SAS, credential or Authorization header is supplied.
Its output includes the current Swagger URL. Opening an old internal URL can
return Azure's 404 page even while the app is healthy. A 401/403 stops the verifier
immediately for an access-rule check rather than waiting through cold-start retries.

### 6. Finish the bootstrap

The Swagger step already disables startup migrations after the Serve revision
has completed them. Both Swagger and Runtime first require the applied Serve
revision to match Azure's ready revision; an older healthy Prepare revision is
not accepted as evidence that migrations completed. Runtime is the explicit migration-free deployment step and
also accepts a new immutable `-Image` for a future code rollout:

```powershell
.\scripts\Invoke-ProductsDeployment.ps1 -Step Runtime
```

Review, then apply separately:

```powershell
.\scripts\Invoke-ProductsDeployment.ps1 -Step Runtime -Action Apply
.\scripts\Test-ProductsDeployment.ps1
```

Close direct API access with the Internal plan/apply commands at the beginning of
this guide. Then deploy BFF and Angular separately. A retained environment should
use a restricted database identity and a separate migration deployment step.

## Personal IP versus ACA egress

| Input | Purpose | After testing |
| --- | --- | --- |
| `products_api_operator_ipv4` | Temporary `/32` browser/API allowlist | Set null and disable external ingress |
| `operator_ipv4` | Optional direct SQL access from a laptop | Set null when local SQL access is finished |
| `products_sql_egress_ipv4` | Exact ACA outbound addresses permitted into SQL | Keep while Products runs |

The new Swagger step uses API-only access and clears `operator_ipv4`. Existing
configurations that use `operator_ipv4` for external API access keep working as
a compatibility fallback. No actual personal IP is committed to this repository;
local `*.tfvars*` files are ignored. `Internal` clears both personal-IP inputs,
disables external ingress and retains the current migration setting and ACA SQL
rules. Use Runtime to disable migrations after the Serve revision is ready.

## Saved plans and failure recovery

Each Plan action creates `.products-plans/products-<step>.tfplan` and a receipt
binding it to the selected step, inputs, Terraform configuration and initialized
backend. Apply does not create a new plan and refuses a changed/missing receipt,
modified binary or changed configuration. Successful apply consumes the receipt.
The binary remains available for diagnosis; Terraform also rejects stale state.

Review the plan before running Apply. If a command fails, retain state and
configuration and make a new reviewed plan after resolving the error. The scripts
never run `state rm`, force-unlock, delete a resource group, reset a backend, or
rotate a password automatically. Saved Terraform plans contain sensitive values;
the plan directory, receipts, inputs and generated manifests are ignored by Git.
Use the same `-InputsPath`, `-PlanPath` and `-TerraformDirectory` on both actions
when overriding defaults. InputsPath must be a non-auto `.tfvars.json` file.

If using the older root auto files, first merge all active rollout fields and the
actual egress map into `products-deployment.tfvars.json`. Rename the old files to
non-auto `*.saved.tfvars.json` names after checking their values. Do not combine
a foundation file that disables the app with a deployment file.

If Azure's outbound addresses change, review/apply a refresh-only plan with the
retained deployment inputs, then create a new Serve plan to recapture the map.
Set migrations back to false using Runtime after the rollout. Do not substitute
a VNet inbound IP or a broad SQL rule.

## Stop and resume between portfolio sessions

Products remains configured for zero to one replicas. `min: null` in an Azure CLI
response means no explicit minimum is returned; the platform default is zero.
Normal HTTP autoscaling can wake the app again on the next request.

To keep it off manually, without editing Terraform inputs:

```powershell
.\scripts\Set-ProductsAppState.ps1 -State Stop
```

Before API or BFF testing:

```powershell
.\scripts\Set-ProductsAppState.ps1 -State Start
```

The lifecycle script waits for the Azure running status. A manually stopped app
needs Start; HTTP requests do not wake it. CPU/memory use stops at zero replicas,
but SQL/storage and the ACA-managed load balancer/public IPs remain provisioned.
This is not a zero-cost shutdown of the whole environment.

## Destroy after the portfolio session

Remove/unlink Angular hosting first, then BFF, then Products and its shared ACA
environment. Restore the original local session and retain the deployment inputs.
Products destruction deletes SQL, imported photos and its disposable Key Vault;
the independently managed state account is retained.

```powershell
.\scripts\Invoke-ProductsDeployment.ps1 -Step Destroy
```

Review the full deletion list before applying:

```powershell
.\scripts\Invoke-ProductsDeployment.ps1 -Step Destroy -Action Apply
```

For an Azure deletion/polling error, inspect the actual resource status and create
a fresh destroy plan. This change does not alter the pinned providers or claim
to fix their previous deletion polling issue. Never remove state to hide an error.

## Offline checks

Run in a separate checkout when using backend-disabled initialization:

```powershell
pwsh -NoProfile -File .\tests\Test-ImportProductPhotos.ps1
pwsh -NoProfile -File .\tests\Test-ProductsSqlEgress.ps1
pwsh -NoProfile -File .\tests\Test-ManualProductsDeployment.ps1
```

CI validates provider schemas and mocked Terraform plans without Azure credentials.
Manual-script checks also run on Windows and Linux with fake Terraform/Azure/HTTP
commands. Live provisioning, SQL connectivity and browser access still require
the manual Azure checks above.

References: [ACA ingress](https://learn.microsoft.com/en-us/azure/container-apps/ingress-overview),
[scale rules](https://learn.microsoft.com/en-us/azure/container-apps/scale-app),
[billing](https://learn.microsoft.com/en-us/azure/container-apps/billing),
[managed networking](https://learn.microsoft.com/en-us/azure/container-apps/custom-virtual-networks),
[Stop](https://learn.microsoft.com/en-us/rest/api/resource-manager/containerapps/container-apps/stop?view=rest-resource-manager-containerapps-2025-07-01),
[Start](https://learn.microsoft.com/en-us/rest/api/resource-manager/containerapps/container-apps/start?view=rest-resource-manager-containerapps-2025-07-01).
