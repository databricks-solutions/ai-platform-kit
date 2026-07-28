# Unity Catalog on GCP

GCP-specific patterns, resources, and gotchas for Unity Catalog setup.

## GCS Bucket Setup

One GCS bucket for the metastore root storage, plus one per environment for per-env catalogs.

```hcl
resource "google_storage_bucket" "metastore" {
  name          = "${var.prefix}-uc-metastore"
  project       = var.google_project
  location      = var.google_region
  force_destroy = true
}
```

**Metastore storage root format:**
```
gs://<bucket-name>
```

**Per-env catalog storage:**
```
gs://<prefix>-catalog-dev/
gs://<prefix>-catalog-stg/
gs://<prefix>-catalog-prod/
```

## Auto-Generated Service Account

GCP UC uses a Databricks-managed service account that is auto-generated when you create the metastore data access credential. You do not create an IAM role manually -- Databricks provisions a GCP service account for you.

```hcl
resource "databricks_metastore_data_access" "this" {
  provider     = databricks.workspace
  metastore_id = databricks_metastore.this.id
  name         = "${var.prefix}-data-access"
  is_default   = true

  databricks_gcp_service_account {}
}
```

After creation, grant the auto-generated SA access to the metastore GCS bucket:

```hcl
resource "google_storage_bucket_iam_member" "metastore_admin" {
  bucket = google_storage_bucket.metastore.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${databricks_metastore_data_access.this.databricks_gcp_service_account[0].email}"
}

resource "google_storage_bucket_iam_member" "metastore_reader" {
  bucket = google_storage_bucket.metastore.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${databricks_metastore_data_access.this.databricks_gcp_service_account[0].email}"
}
```

The auto-generated SA email is only available after the `databricks_metastore_data_access` resource is created, so the IAM bindings must depend on it.

## Storage Credential for External Catalogs

For per-env catalogs with dedicated storage, create a separate storage credential. This also auto-generates a GCP service account:

```hcl
resource "databricks_storage_credential" "this" {
  provider = databricks.workspace
  name     = "${var.prefix}-storage-credential"

  databricks_gcp_service_account {}
}
```

Grant this SA `roles/storage.objectAdmin` and `roles/storage.legacyBucketReader` on each catalog bucket, then create external locations and catalogs with `MANAGED LOCATION`.

## Per-Environment Catalog Pattern

```hcl
resource "google_storage_bucket" "catalog_dev" {
  name     = "${var.prefix}-catalog-dev"
  project  = var.google_project
  location = var.google_region
}

resource "google_storage_bucket_iam_member" "catalog_dev_admin" {
  bucket = google_storage_bucket.catalog_dev.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${databricks_storage_credential.this.databricks_gcp_service_account[0].email}"
}

resource "databricks_external_location" "dev" {
  provider        = databricks.workspace
  name            = "${var.prefix}-catalog-dev"
  url             = "gs://${google_storage_bucket.catalog_dev.name}/"
  credential_name = databricks_storage_credential.this.name
}

resource "databricks_catalog" "dev" {
  provider       = databricks.workspace
  name           = "dev"
  storage_root   = "gs://${google_storage_bucket.catalog_dev.name}/"
  isolation_mode = "OPEN"
}
```

## Read-only external locations need TWO IAM roles

When the external location is read-only (e.g., a customer's existing data lake bucket that UC must NOT write to), you need **both** of these roles on the bucket for the storage credential's SA:

```hcl
resource "google_storage_bucket_iam_member" "raw_reader_object" {
  bucket = google_storage_bucket.raw_data.name
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${databricks_storage_credential.read_only.databricks_gcp_service_account[0].email}"
}

resource "google_storage_bucket_iam_member" "raw_reader_legacy" {
  bucket = google_storage_bucket.raw_data.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${databricks_storage_credential.read_only.databricks_gcp_service_account[0].email}"
}
```

`objectViewer` alone is **not** enough — UC needs `legacyBucketReader` to enumerate the bucket. Mark the external location read-only on the Databricks side as well:

```hcl
resource "databricks_external_location" "raw_readonly" {
  provider        = databricks.workspace
  name            = "${var.prefix}-raw-readonly"
  url             = "gs://${google_storage_bucket.raw_data.name}/"
  credential_name = databricks_storage_credential.read_only.name
  read_only       = true
}
```

## Detect orphan metastores in the region

Each Databricks region can have at most one metastore per workspace. If an orphan metastore exists in your target region (created by another team, never properly torn down), workspace-assignment can auto-bind it instead of the new metastore you just created. The result: UC objects land in your new bucket but reference the wrong `metastore_id`.

**Always check first:**

```bash
databricks account metastores list --json | \
  jq '.metastores[] | select(.region=="<your-region>") | {metastore_id, name, storage_root, created_at, owner}'
```

Decision tree:
- **No metastore in region** — safe to create
- **One metastore with a clear owner + recent storage_root** — coordinate with the owner; reuse if possible
- **One metastore with `storage_root: null` or unknown owner** — orphan. Either adopt it (point your TF at the existing `metastore_id`) or `terraform state rm` your `databricks_metastore_assignment` after the assignment lands on the orphan and re-apply to force-rebind to your new metastore.

## Metastore owner when impersonation-created

When you create the metastore via `auth_type = "google-id"` impersonation, the SA becomes the recorded owner — NOT your human user. If you then try to manage the metastore from a U2M-authenticated session, you'll hit `Permission denied: only metastore owner can perform this operation`. Two fixes:

```bash
# Option A: transfer ownership to a human / group
databricks account metastores update <metastore-id> --json \
  '{"metastore_info":{"owner":"account-admin@example.com"}}'

# Option B: pre-create the human user as an account_admin and apply UC TF as that user
```

Option A is what you typically want — the SA created the resource as a side effect of automation; humans should own it day-2.

## Explicit metastore privilege grants for the SA

Even when the workspace-creator SA has `account_admin` role, it does NOT automatically inherit `CREATE_EXTERNAL_LOCATION` / `CREATE_STORAGE_CREDENTIAL` / `CREATE_CATALOG` privileges on a metastore. If your workspace-level TF is applied as the SA (which it usually is), you must grant explicitly:

```hcl
resource "databricks_grants" "metastore_sa" {
  provider  = databricks.workspace
  metastore = databricks_metastore.this.id

  grant {
    principal  = var.databricks_workspace_creator_sa
    privileges = [
      "CREATE_EXTERNAL_LOCATION",
      "CREATE_STORAGE_CREDENTIAL",
      "CREATE_CATALOG",
    ]
  }
}
```

This is one of the most common mistakes — workspace-level UC applies fail with `Permission denied on metastore <id>` and the immediate reaction is "wrong SA / wrong auth", but the actual fix is granting the privileges.

## Eventual-consistency race: `databricks_metastore_data_access` ↔ `databricks_storage_credential`

The two auto-generated SAs are created in parallel. If a downstream resource references the storage credential's SA before that SA is fully written to GCP IAM, you can get a transient `permission denied` on the first `terraform apply` that resolves on a re-apply. Mitigation:

```hcl
resource "null_resource" "wait_for_sa_propagation" {
  triggers = {
    sc_sa  = databricks_storage_credential.this.databricks_gcp_service_account[0].email
    mda_sa = databricks_metastore_data_access.this.databricks_gcp_service_account[0].email
  }
  provisioner "local-exec" {
    command = "sleep 30"
  }
}
```

Insert the `null_resource` between the storage credential and any `google_storage_bucket_iam_member` that references its SA. Ugly but reliable.

## GCS label-value character restrictions

GCS labels reject `@` and `.`. The pattern `labels = { owner = "user@example.com" }` errors at apply with a misleading message about value format. Slug the email:

```hcl
locals {
  owner_slug = replace(replace(var.customer_email, "@", "_at_"), ".", "_")
}
resource "google_storage_bucket" "x" {
  labels = { owner = local.owner_slug }
}
```

## Lakehouse Federation to CloudSQL (PostgreSQL)

GCP customers often have CloudSQL Postgres for OLTP. Lakehouse Federation lets UC query CloudSQL without ETL.

Prereqs:
- Workspace enabled for UC (this skill covers it)
- Network connectivity from your compute to CloudSQL (VPC peering or PSC to private CloudSQL IP)
- DBR 13.3 LTS+ and Shared or Single User access mode on the cluster running federated queries

Pattern:

```hcl
# 1. Store CloudSQL credentials in a Databricks secret scope (not in TF)
#    databricks secrets create-scope cloudsql-fed
#    databricks secrets put-secret cloudsql-fed pg-password --string-value "<password>"

# 2. Create the UC connection (account-level resource bound to workspace)
resource "databricks_connection" "cloudsql_pg" {
  provider        = databricks.workspace
  name            = "${var.prefix}-cloudsql-pg"
  connection_type = "POSTGRESQL"
  comment         = "Lakehouse Federation to CloudSQL Postgres ${var.cloudsql_instance}"

  options = {
    host     = var.cloudsql_private_ip      # private IP via VPC peering or PSC
    port     = "5432"
    user     = "databricks_reader"
    password = "{{secrets/cloudsql-fed/pg-password}}"
  }
}

# 3. Foreign catalog mirrors the Postgres database structure into UC
resource "databricks_catalog" "cloudsql_fed" {
  provider     = databricks.workspace
  name         = "${var.prefix}_cloudsql"
  comment      = "Federated catalog over CloudSQL"
  connection_name = databricks_connection.cloudsql_pg.name

  options = {
    database = var.cloudsql_database_name   # e.g. "ops_prod"
  }
}
```

After apply, you query as `${var.prefix}_cloudsql.<schema>.<table>` and UC handles the federation under the hood.

**CloudSQL network connectivity gotchas:**
- CloudSQL public IPs do NOT work for federation from a customer-VPC workspace — the workspace can't reach them without going through the public internet, which violates most compliance postures and may not be allowed by your egress firewall.
- CloudSQL private IPs require VPC peering between the workspace VPC and the CloudSQL service-networking-managed VPC. Set up via `google_service_networking_connection` + `google_compute_global_address`. Pair with private CloudSQL configuration.
- For cross-region or cross-org CloudSQL access, use PSC to the CloudSQL service attachment (Lakehouse Federation via NCC private endpoint to CloudSQL native PSC).
- Pre-create the `databricks_reader` Postgres user inside CloudSQL with **only** the SELECT privileges needed for the tables federated. Audit-log the connection's queries via UC system tables.

**Region check:** the CloudSQL instance must be in the same region as the workspace (or a peered/PSC-reachable region). Cross-region CloudSQL federation works but adds latency.

## GCP Gotchas (historical, retained)

**Metastore data access requires workspace provider.** Unlike Azure and AWS where metastore data access uses the account provider, GCP requires the workspace provider for `databricks_metastore_data_access` because of the auto-generated SA flow. The metastore must be assigned to a workspace first.

**Two service accounts are generated.** One for the metastore data access (default credential) and one for the storage credential (external locations). They are different SAs with different emails. Grant bucket access to the correct one.

**SA email not available until after creation.** The auto-generated SA email is an output of the resource, so IAM bindings on GCS buckets must use `depends_on` or reference the SA email attribute directly (Terraform handles the dependency automatically when you reference the attribute).

**Simpler than Azure/AWS.** No IAM role trust policies, no access connectors, no managed identity role assignments. The auto-generated SA pattern handles most of the complexity. The main manual step is granting GCS bucket IAM roles to the auto-generated SAs.

**Account-level groups.** Same as other clouds -- create groups via SCIM API at `accounts.gcp.databricks.com/api/2.0/accounts/{id}/scim/v2/Groups`. These are visible across all workspaces via UC identity federation.
