# Unity Catalog on AWS

AWS-specific patterns, resources, and gotchas for Unity Catalog setup.

## IAM UC Role Setup

AWS UC uses a cross-account IAM role with a trust policy that allows the Databricks UC master role and self-assume.

```hcl
data "aws_iam_policy_document" "uc_assume_role" {
  # Allow Databricks UC master role to assume this role
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::414351767826:role/unity-catalog-prod-UCMasterRole-14S5ZJVKOTYTL"]
    }
    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [var.databricks_account_id]
    }
  }

  # Self-assume (required by Unity Catalog)
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${var.aws_account_id}:root"]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:PrincipalArn"
      values   = [local.uc_role_arn]
    }
  }
}
```

The IAM policy on the role needs S3 actions on the metastore bucket **plus `sts:AssumeRole` on the role's own ARN**. Both pieces are required — the trust policy alone is NOT sufficient.

```hcl
data "aws_iam_policy_document" "uc_role_inline" {
  # S3 access on the metastore + catalog buckets
  statement {
    effect    = "Allow"
    actions   = [
      "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
      "s3:ListBucket", "s3:ListBucketMultipartUploads",
      "s3:ListMultipartUploadParts", "s3:AbortMultipartUpload",
      "s3:GetBucketLocation", "s3:GetBucketTagging", "s3:GetBucketAcl",
    ]
    resources = [
      aws_s3_bucket.metastore.arn,        "${aws_s3_bucket.metastore.arn}/*",
      # plus per-catalog bucket ARNs
    ]
  }

  # CRITICAL: self-assume must be in the INLINE policy too — UC validates by having
  # the role assume itself. Trust policy alone fails with "non self-assuming role".
  statement {
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = [local.uc_role_arn]
  }
}
```

**Why both are required:** the trust policy says "this role MAY be assumed by ARN X"; the inline policy says "this role MAY call sts:AssumeRole on resource Y". UC's validation flow has the role call `sts:AssumeRole` against itself, which requires the *action* in its own inline policy in addition to the trust permission. If you only have the trust statement, `databricks_storage_credential.validate()` fails with `"IAM role for storage credential was found to be non self-assuming"`.

## S3 Bucket Setup

- One bucket for the metastore root storage.
- One bucket per environment for per-env catalogs.
- All buckets: server-side encryption (AES256), public access blocked, versioning disabled (UC manages its own versioning).

```hcl
resource "aws_s3_bucket" "metastore" {
  bucket        = "${var.prefix}-metastore"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "metastore" {
  bucket                  = aws_s3_bucket.metastore.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

## Vending Machine Metastore

Many AWS accounts have an auto-provisioned (vending machine) metastore with no storage root URL. This has critical limitations:

**Default storage is serverless-only.** Data in the auto-provisioned metastore cannot be read by classic clusters. Attempting `spark.sql("SELECT ...")` on classic returns: "Databricks Default Storage cannot be accessed using Classic Compute. Please use Serverless compute."

**`CREATE CATALOG` fails without storage.** On a vending machine metastore with no storage root, `CREATE CATALOG` returns `INVALID_STATE: Metastore storage root URL does not exist`. You must either provide `MANAGED LOCATION` with an external location, or deploy your own metastore.

**The `main` catalog works for serverless only.** It was auto-created with managed (default) storage, so it works on serverless SQL warehouses but not on classic clusters.

**Recommendation:** Always deploy your own metastore with the `aws-unity-catalog` template for production. The vending machine metastore is only suitable for quick serverless-only testing.

## Per-Environment Catalog Storage Pattern

This is the proven production pattern for multi-env catalogs on AWS:

**1. One S3 bucket per environment:**
```bash
aws s3api create-bucket --bucket <prefix>-catalog-dev --region us-east-1
aws s3api create-bucket --bucket <prefix>-catalog-stg --region us-east-1
aws s3api create-bucket --bucket <prefix>-catalog-prod --region us-east-1
```

**2. IAM policy on the UC role covering all catalog buckets:**
One policy, one role. No separate roles needed per catalog.
```json
{
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket", "s3:GetBucketLocation"],
    "Resource": [
      "arn:aws:s3:::<prefix>-catalog-dev", "arn:aws:s3:::<prefix>-catalog-dev/*",
      "arn:aws:s3:::<prefix>-catalog-stg", "arn:aws:s3:::<prefix>-catalog-stg/*",
      "arn:aws:s3:::<prefix>-catalog-prod", "arn:aws:s3:::<prefix>-catalog-prod/*"
    ]
  }]
}
```

**3. One storage credential (shared):**
References the UC IAM role. Reuse across all catalogs.

**4. External locations per bucket:**
One external location per environment bucket: `s3://<prefix>-catalog-dev/`, etc.

**5. Catalogs with `MANAGED LOCATION`:**
```sql
CREATE CATALOG dev MANAGED LOCATION 's3://<prefix>-catalog-dev/';
CREATE CATALOG stg MANAGED LOCATION 's3://<prefix>-catalog-stg/';
CREATE CATALOG prod MANAGED LOCATION 's3://<prefix>-catalog-prod/';
```

Use `CREATE CATALOG ... MANAGED LOCATION` (SQL), NOT `storage_root` in the REST API. `MANAGED LOCATION` correctly ties the catalog to the external location path. Data lands in `s3://bucket/__unitystorage/catalogs/<uuid>/`.

**6. Grant access:**
```sql
GRANT USE_CATALOG, USE_SCHEMA, SELECT ON CATALOG dev TO `account users`;
GRANT ALL_PRIVILEGES ON CATALOG dev TO `platform-admins`;
```
Without `USE_CATALOG` + `USE_SCHEMA` + `SELECT` on `account users`, catalogs do not appear in the UI even with `isolation_mode = OPEN`.

## AWS Gotchas

**IAM propagation delay.** Cross-account IAM roles take 10-30 seconds to propagate. The `time_sleep` in the template helps but is sometimes not enough. If apply fails with "Failed credential validation checks", re-run `terraform apply` -- the role will be propagated by then.

**Catalog `main` auto-created.** Databricks auto-creates a `main` catalog when a metastore is assigned. Always use a different name for your catalogs (e.g., `dev`, `stg`, `prod`).

**Metastore limit per region.** Each account can have a limited number of metastores per region. If you hit "has reached the limit for metastores in region", reuse an existing metastore or delete unused ones.

**Metastore assignment via REST API is unreliable.** The `PUT /api/2.0/accounts/{id}/workspaces/{ws_id}/metastores/{ms_id}` endpoint returns `Invalid UUID string` errors even with valid UUIDs. Use Terraform (`databricks_metastore_assignment`) instead -- it works reliably.

**SP needs explicit metastore permissions on foreign metastores.** If you assign a metastore someone else owns, the SP needs `CREATE_CATALOG`, `CREATE_EXTERNAL_LOCATION`, `CREATE_STORAGE_CREDENTIAL` grants on the metastore before it can create catalogs.

**Storage credential creation requires the SP to own the metastore (or have CREATE_STORAGE_CREDENTIAL).** When the deploying SP is *not* the metastore owner and not an Account Admin, `databricks_storage_credential` creation fails with auth errors. Cleanest fix: transfer metastore ownership to the SP immediately after metastore creation:

```python
from databricks.sdk import AccountClient
from databricks.sdk.service.catalog import UpdateAccountsMetastore
ac = AccountClient(profile="<account-profile>")
ac.metastores.update(
    metastore_id="<id>",
    metastore_info=UpdateAccountsMetastore(owner="<sp-application-id>"),
)
```

If you're following the canonical Account-Admin-SP pattern from `platform-provisioning/AWS.md`, no extra step is needed — Account Admin SPs implicitly own metastores they create.

**IAM trust policy propagation race vs `databricks_external_location`.** After updating an IAM trust policy via `null_resource` + AWS CLI (e.g. to add the storage credential's auto-generated UUID as the `sts:ExternalId`), `databricks_storage_credential.validate()` may return PASS while a subsequent `databricks_external_location` create still 403s with `"AWS IAM role does not have READ permissions"`. The cause is eventual consistency on the IAM trust update (typically 30–60s). **Fix:** insert a `time_sleep { create_duration = "60s" }` between the trust update and the `external_location` resource, OR retry the apply once on 403.

**External location required for catalogs on foreign metastores.** If using a metastore with no storage root (vending machine) or one you do not own, you must create a storage credential + external location for your own S3 bucket first, then `CREATE CATALOG ... MANAGED LOCATION 's3://...'`.

**Use modern privilege names.** The API rejects old names. Use `USE_CATALOG` (not `USAGE`), `USE_SCHEMA` (not `USAGE`), `CREATE_TABLE` (not `CREATE`), `CREATE_FUNCTION`, `CREATE_SCHEMA`.

**Using someone else's metastore requires storage access.** If you attach to an existing metastore you do not own, `CREATE TABLE` fails with `403 Forbidden from cloud storage provider` because the metastore's IAM role does not grant access to your data. Always deploy your own metastore for full control.

**AWS session token expiry.** AWS STS session tokens (from SSO or AssumeRole) expire after 1-12 hours. Unlike Azure CLI which auto-refreshes, expired AWS tokens cause immediate failures. Re-export fresh credentials before long Terraform runs.

**Account-level groups on AWS.** Create groups via SCIM API at `accounts.cloud.databricks.com/api/2.0/accounts/{id}/scim/v2/Groups`. These are visible across all workspaces via UC identity federation. Grant catalog/schema permissions using these group names as principals.

**Classic cluster UC access requires data_security_mode.** Classic clusters MUST have `data_security_mode` set to `SINGLE_USER` or `USER_ISOLATION` to access Unity Catalog tables. Without this, all UC queries return `[UC_NOT_ENABLED]`. This applies to verification tests and production clusters alike.

**First classic cluster on a new workspace may hang.** The first classic cluster with `USER_ISOLATION` on a brand-new workspace can hang 30-40 minutes during initial UC metadata resolution. This is transient — cancel, wait 5 minutes, retry. Or use `SINGLE_USER` mode which resolves faster.

**S3 bucket ownership on UC buckets.** All S3 buckets used by Unity Catalog (metastore root, catalog storage) must use `BucketOwnerPreferred` ownership — not the default `BucketOwnerEnforced`. Without this, Databricks storage validation fails with `PutWithBucketOwnerFullControl` errors.
