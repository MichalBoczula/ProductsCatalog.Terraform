# Terraform and deployment validation

## CI checks

The GitHub `Terraform checks` workflow uses Terraform 1.16.5 and the committed
AzureRM 5.8.0 / AzAPI 2.13.0 lock file. It runs backend-disabled initialization,
formatting, full provider schema validation, 29 mocked Terraform plans, and the
photo importer/SQL egress offline checks. It has no Azure credentials and never
applies real resources.

Mocked test baselines explicitly set all inputs. CI creates conflicting local
auto inputs to verify that a developer's rollout file cannot turn on external
ingress, require their personal IP or break the input rejection scenarios.
Tests cover the legacy operator-IP fallback and API-only access with no laptop
SQL firewall rule, as well as separate API and SQL operator addresses.

A separate Linux/Windows matrix parses all PowerShell scripts and runs 21 offline
manual deployment checks using fake Terraform, Azure CLI and HTTP commands.
They check that plans never apply, failed egress lookup preserves inputs,
Foundation cannot remove an existing app, pending migrations cannot be disabled,
Internal retains ACA SQL access while clearing personal IPs, changed inputs/backend
or plan bytes invalidate a saved plan, failed planning invalidates an older
receipt, and successful Apply consumes it. Destroy retains complete inputs.
The verifier rejects missing seeds, denied readiness and inaccessible photos;
lifecycle/session checks preserve inputs and the existing SQL password.

## Local checks

Use a separate checkout for backend-disabled provider checks so an initialized
Azure deployment backend remains intact:

```powershell
& $ecommerceTerraform init '-backend=false' '-input=false' '-lockfile=readonly'
if ($LASTEXITCODE -ne 0) { throw 'Provider initialization failed' }
& $ecommerceTerraform fmt '-check' '-recursive'
if ($LASTEXITCODE -ne 0) { throw 'Formatting failed' }
& $ecommerceTerraform validate
if ($LASTEXITCODE -ne 0) { throw 'Schema validation failed' }
& $ecommerceTerraform test '-no-color'
if ($LASTEXITCODE -ne 0) { throw 'Mocked Terraform tests failed' }

pwsh -NoProfile -File .\tests\Test-ImportProductPhotos.ps1
pwsh -NoProfile -File .\tests\Test-ProductsSqlEgress.ps1
pwsh -NoProfile -File .\tests\Test-ManualProductsDeployment.ps1
```

The importer checks all 60 source photos, repeat imports, Unicode command output,
public-read compatibility and manifest preservation. The egress helper checks
stable deduplication and rejects invalid/empty outputs without overwriting its
previous result. These scripts do not contact Azure or upload photos.

## Manual Azure verification

The operator verifies the intended backend/state key, resource ownership, RBAC,
immutable image, actual outbound addresses, latest ready revision, live SQL
readiness, 15 seeded phones and an anonymous photo request. InfrastructureOnly
checks Azure configuration; it does not claim to verify the live API/database.
See [the manual guide](aca-deployment.md) for exact commands and teardown order.
