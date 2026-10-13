# Foundation validation

## Completed checks

- Terraform 1.16.5 initializes the pinned AzureRM 5.8.0 and AzAPI 2.13.0 providers with `init -backend=false`.
- `terraform fmt -check -recursive` checks the Terraform files and test syntax/formatting.
- Ten checks pass in a provider-free harness using copies of the repository's actual `variables.tf`, `locals.tf` and input test run blocks. These cover maximum-length names and invalid subscription/operator IDs, environment, suffixes, password and SQL operator addresses.
- All eight PowerShell blocks in the manual guide parse with PowerShell 7.5.3.
- The ACA schema and subnet delegation block shape were checked against the pinned AzureRM provider source. Resource definitions reuse the settings validated in the earlier whole-store foundation.
- The operator confirmed successful remote backend initialization, full `terraform validate`, and all ten input tests on Windows. The first foundation run exposed explicit overrides still defaulting to apply; each override now explicitly uses `override_during = plan`.
- A provider-free Terraform 1.16.5 regression reproduces the same unknown-condition error with only provider-level timing. Its two identity-reference/photo-endpoint checks pass after explicit resource-level plan timing is added. This checks override behavior, not the full Azure foundation suite.

## Required on the operator's Windows machine

After pulling the test override correction, rerun `terraform test` before creating a deployment plan. The full suite has 12 mocked test runs (2 foundation checks and 10 input checks). The corrected full suite still requires confirmation on Windows: the preparation runtime prevents providers from opening their plugin sockets (`listen unix ...: socket: operation not permitted`). Provider-free checks do not substitute for full provider schema validation or foundation assertions.

Remote backend access, Azure RBAC propagation, globally unique name availability, SQL Free eligibility and actual provisioning must be verified during the manual deployment. No Azure apply was performed while preparing this repository.
