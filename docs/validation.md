# Terraform and deployment validation

## Reproducible checks

The GitHub `Terraform checks` workflow uses Terraform 1.16.5 and the checked-in
AzureRM 5.8.0 / AzAPI 2.13.0 lock file. It runs backend-disabled initialization,
formatting, full provider schema validation, 24 mocked plan tests, and both
PowerShell test scripts. It has no Azure credentials and never applies real resources.

The Terraform suite covers foundation/naming, private and blob-only anonymous
photo access, prepare/serve behavior, exact SQL rules, identity-based Key Vault
references, bounded Consumption scaling, operator-only external testing, and
rejected image/network/stage inputs.

## Local preparation checks

- Backend-disabled initialization installs the pinned providers successfully.
- Terraform formatting and `git diff --check` pass.
- A provider-free harness using copies of the actual `variables.tf`, `locals.tf`,
  and input run blocks passes all 18 input checks.
- PowerShell 7.6.7 passes 28 offline importer checks, including all 60 source
  photos, Unicode native output, public-read compatibility and repeat imports.
- The egress helper passes 12 offline checks, including stable deduplicated keys,
  invalid/empty outputs and preserving the previous input on errors.
- Full local provider schema/test execution is blocked by the preparation
  runtime's provider plugin handshake/socket restriction. The provider-free
  checks do not replace the full mocked suite; GitHub runs it with real plugins.

## Verify during manual Azure rollout

The operator must verify the existing backend/state key, unchanged resource
ownership, RBAC propagation, the published image tag, actual app egress, SQL
readiness and anonymous photo HTTP responses. Review every saved plan before
applying it. No Azure resources were provisioned while preparing these files.
