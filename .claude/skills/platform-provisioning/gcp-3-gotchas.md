# GCP — Gotchas

Sharp edges that have bitten real deploys. Each one is a real finding from stress runs or field engagements.

## `custom_tags` is AWS-only on `databricks_mws_workspaces`

The Databricks accounts API for GCP rejects `custom_tags` with `custom_tags are only allowed for AWS workspaces`. Cross-cloud TF modules often set `custom_tags` for everyone — strip it on the GCP branch. Tag at GCP level via `google_compute_subnetwork.labels`, `google_storage_bucket.labels`, etc.

## `databricks_mws_vpc_endpoint` and `databricks_mws_networks` provider bugs under impersonation

Even with `google_service_account` + `auth_type = "google-id"` correctly set, the sdkv2 code path inside the Databricks Terraform provider can fall through to PAT/basic/oauth-m2m for these two specific resources. Symptom: `400 BAD_REQUEST: Failed to get oauth access token`.

Workaround:
1. Create the resource via the CLI under the same auth flow:
   ```bash
   NET_ID=$(DATABRICKS_AUTH_TYPE=google-id \
     DATABRICKS_GOOGLE_SERVICE_ACCOUNT=$SA_EMAIL \
     DATABRICKS_HOST=https://accounts.gcp.databricks.com \
     DATABRICKS_ACCOUNT_ID=<account-id> \
     databricks account networks create --json @network.json | jq -r .network_id)
   ```
2. `terraform import databricks_mws_networks.this $NET_ID` so subsequent applies are clean.

This is a provider bug. The other MWS resources (workspaces, credentials, private_access_settings, storage_configurations) honor `google_service_account` correctly via plugin-framework code paths.

## CMEK service-agent is created lazily — grant comes AFTER first workspace request

CMEK on GCP (`databricks_mws_customer_managed_keys`) requires the **Databricks GCP service agent** (`service-<projectnum>@gcp-sa-databricks.iam.gserviceaccount.com`) to have `roles/cloudkms.cryptoKeyEncrypterDecrypter` on the KMS key. **But this service agent doesn't exist in your project until Databricks bootstraps it on the FIRST workspace provision request.**

So a naive single-pass apply does:
1. Create KMS keyring + key
2. Try to grant `cloudkms.cryptoKeyEncrypterDecrypter` to `service-<num>@gcp-sa-databricks...` → 404, SA does not exist
3. Fails.

Two valid patterns:

**Pattern A — force-create the SA at plan time:**
```hcl
resource "google_project_service_identity" "databricks" {
  provider = google-beta
  project  = var.google_project
  service  = "databricksmanagedservices.googleapis.com"
}

resource "google_kms_crypto_key_iam_member" "managed_services" {
  crypto_key_id = google_kms_crypto_key.databricks.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_project_service_identity.databricks.email}"
}
```

**Pattern B — two-phase apply:**
1. Phase 1: KMS resources + workspace WITHOUT `customer_managed_keys` config.
2. Workspace creation bootstraps the service agent.
3. Phase 2: grant `cloudkms.cryptoKeyEncrypterDecrypter` to the now-existing service agent, then patch the workspace to attach CMEK via the account API.

Pattern A is cleaner if `google-beta` is acceptable. Pattern B is safer if you want each phase to fail loudly.

Also: the workspace-creator SA itself needs `roles/cloudkms.admin` (or a custom role with `cloudkms.cryptoKeys.create`, `cloudkms.cryptoKeyVersions.create`, `cloudkms.cryptoKeys.getIamPolicy`, `cloudkms.cryptoKeys.setIamPolicy`) on the keyring it will create keys in. Editor + serviceAccountAdmin + projectIamAdmin from `gcp-1-auth.md` does NOT include this — grant explicitly for CMEK personas.

## Two Databricks-managed SAs in Unity Catalog setups

Setting up UC on GCP generates TWO different Databricks-managed service accounts:
1. **Metastore data access SA** — from `databricks_metastore_data_access` (account-level). Used for managed locations of the metastore.
2. **Storage credential SA** — from `databricks_storage_credential` (workspace-level). Used for external locations.

They are SEPARATE identities with separate emails. You must grant bucket IAM to the right one. See [`../unity-catalog-setup/GCP.md`](../unity-catalog-setup/GCP.md) for the full pattern.

## Metastore-assignment race condition

When you create both a new metastore and immediately assign it to a workspace in the same apply, you can race against any orphan metastore that exists in the region. The orphan auto-binds first, then your assignment lands on top, and UC objects can end up routed against the orphan. Symptom: catalog data lands in the right bucket but `metastore_id` references the wrong UUID.

Detection:
```bash
databricks account metastores list --json | jq '.metastores[] | select(.region=="<region>") | {metastore_id, name, storage_root, created_at}'
```

If there's a metastore in the target region with `storage_root: null` or no recognizable owner, treat it as orphan. Either reassign via `metastore_assignment` PATCH, or `terraform state rm` the assignment + re-apply to force-rebind.

## GCS label-value character restrictions

GCS bucket labels reject `@` and `.` characters. The pattern of `labels = { owner = var.customer_email }` fails at apply with no obvious explanation if the email contains `.` or `@`. Map emails to safe slugs:
```hcl
locals {
  owner_slug = replace(replace(var.customer_email, "@", "_at_"), ".", "_")
}
resource "google_storage_bucket" "x" {
  ...
  labels = { owner = local.owner_slug }
}
```

## SQL warehouse tag regex (no `+` character)

Databricks SQL warehouse tag values match `^([A-Za-z0-9][-A-Za-z0-9_.]*)?[A-Za-z0-9]?$`. Tag values like `prod+gold` or `sandbox+verification` fail. Use `-` or `_` separators.

## BANNED workspace name reuse delay

Deleting a workspace puts the name in a `BANNED` state for approximately **1 hour**. You cannot reuse the name immediately after destroy. Either wait, or append a short random suffix to workspace names (`${var.prefix}-ws-${random_id.suffix.hex}`) so destroy/recreate cycles in stress tests and dev loops aren't blocked.

## PREMIUM vs ENTERPRISE tier availability

`pricing_tier = "PREMIUM"` may be unavailable in some GCP Databricks subscriptions (only ENTERPRISE offered). Ask the customer's account team if PREMIUM is rejected at apply time; do NOT silently downgrade. The intake skill should ask "PREMIUM or ENTERPRISE?" and surface the answer.

## Customer ID intake check — project_id ≠ account_id

GCP project IDs (like `gcp-sandbox-field-eng`) and Databricks GCP account IDs (UUID like `f187f55a-9d3d-...`) get confused by customers regularly. Always confirm both separately in intake:
- GCP project ID (string like `prod-customer-001`)
- Databricks account ID (UUID, fetch from `accounts.gcp.databricks.com/o/<account-id>/` URL)

Reject 12-digit numeric IDs offered as Databricks account IDs — that's the AWS account ID format.

## Workspace creation time

GKE control plane provisioning is the slow step. Empirical timing on `gcp-sandbox-field-eng`:
- Simple SERVERLESS workspace: ~25-40 seconds (GKE provisioned async)
- HYBRID workspace with BYOVPC: ~60-90 seconds for workspace create + ~10-15 min for first classic cluster boot
- PSC backend-only: same as HYBRID

The "10-15 min for workspace create" warning in older docs reflects the synchronous timing for HYBRID. Modern SERVERLESS-mode creates return quickly because GKE provisioning is decoupled from workspace creation.

## Workspace-level provider auth quirk

Even with `google_service_account` + `account_admin` role correctly set, the workspace-level provider can return `Unauthorized access to Org` on UC CREATE_* calls. Workaround on the workspace-level provider only:
```hcl
provider "databricks" {
  alias    = "workspace"
  host     = databricks_mws_workspaces.this.workspace_url
  profile  = "gcp-account"   # U2M cached profile
}
```
Keep `google-id` on the account-level provider; switch only the workspace provider. Or transfer UC object ownership to the SA explicitly via the account API before workspace-level applies.

## Cross-references

- [`gcp-1-auth.md`](gcp-1-auth.md) — auth fundamentals
- [`gcp-2-deploy.md`](gcp-2-deploy.md) — workspace deploy patterns
- [`../private-networking/GCP.md`](../private-networking/GCP.md) — PSC details and its UC gotcha
- [`../unity-catalog-setup/GCP.md`](../unity-catalog-setup/GCP.md) — orphan metastores, two-SA pattern
