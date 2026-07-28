# AWS Platform Provisioning

Cloud-specific guidance for provisioning Databricks workspaces on AWS.

## AWS Deployment Options

Map the customer's answers from the intake questions to these deployment types:

| Customer says... | Deployment type | Tier needed | Key resources |
|-----------------|----------------|-------------|---------------|
| "Quick POC, don't want to manage infrastructure" | Serverless workspace (no customer VPC) | Premium | No cloud resources needed — fully managed |
| "POC but in our own account" | Classic with automated config | Premium | Databricks provisions VPC, S3, IAM in customer's account |
| "Production, we want control over networking" | **Customer-managed VPC (BYOVPC)** — this is the default | Premium | Customer creates VPC, subnets, S3, IAM cross-account role |
| "Production, backend traffic must stay private" | Backend Private Link | **Enterprise** | BYOVPC + VPC endpoints (REST API + relay) |
| "Everything must be private, no public access at all" | Full Private Link | **Enterprise** | BYOVPC + VPC endpoints + transit VPC + Route 53 private zone |
| "Maximum lockdown, prevent data exfiltration" | Full PL + data exfil protection | **Enterprise** | Full PL + restrictive firewall rules + SCC |

**Default recommendation: Customer-managed VPC (BYOVPC)** with Secure Cluster Connectivity. This is the standard production setup. Escalate to private link only if the customer's answers indicate they need it.

## AWS Permissions Pre-check

Verify the customer has these permissions BEFORE writing any Terraform. If they don't, tell them exactly what's missing.

**For new Databricks account:**
- AWS Marketplace subscription permission (`AWSMarketplaceManageSubscriptions` policy minimum) — needed to subscribe to Databricks
- Plus one of:
  - AWS Admin privilege (simplest), OR
  - S3 creation + VPC/networking creation + IAM creation privileges (least-privilege)

**For existing Databricks account:**
- Databricks Account Admin role (check at accounts.cloud.databricks.com)
- Plus one of:
  - AWS Admin privilege, OR
  - S3 creation + VPC/networking creation + IAM creation privileges

**For Private Link (in addition to above):**
- VPC endpoint creation privileges
- Route 53 hosted zone management (for full PL)
- Enterprise tier on the Databricks account

**For CMK (Customer Managed Keys):**
- KMS key creation and management privileges
- Enterprise tier on the Databricks account

Ask: "Can you confirm you have admin access to both the AWS account and the Databricks account? If not, what access do you have — I'll tell you exactly what permissions are needed."

## Authentication

The canonical pattern, used by the official Databricks Security Reference Architecture (SRA — `databricks/terraform-databricks-sra`), is **OAuth M2M via an account-admin service principal, with credentials passed through environment variables**. Both the account-level (`mws`) and workspace-level (`created_workspace`) providers share the same SP creds. **No browser, no PAT, no separate workspace login required**, even on a freshly-created workspace.

### Pre-flight checks (run before any terraform command)

```bash
aws sts get-caller-identity                    # AWS account ID + IAM principal
env | grep -i DATABRICKS                       # check for conflicting env vars (see CRITICAL below)
databricks auth profiles 2>/dev/null           # lists profiles + DEFAULT; never echoes secrets
```

### Required credentials

- **AWS CLI session** — IAM user creds (`aws configure`), SSO (`aws sso login`), or env vars (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`).
- **Databricks account ID** — from the accounts console at `https://accounts.cloud.databricks.com`. Ask the customer if not known.
- **Databricks account-level service principal with Account Admin role**, plus its OAuth secret (client_id + client_secret). This is the load-bearing piece — see "One-time SP setup" below.

### One-time SP setup (per Databricks account, not per workspace)

If the customer doesn't already have an account-admin SP with an OAuth secret, create one **before** writing any deploy Terraform:

1. **Account console (UI)** — at `https://accounts.cloud.databricks.com`:
   - User Management → Service principals → Add service principal → name it (e.g. `terraform-deployer`).
   - Grant it the **Account admin** role (Roles tab on the SP detail page).
   - Generate an OAuth secret (Settings → Identity and access → Service principals → your SP → Secrets → Generate). Capture `client_id` (= application ID) and `client_secret`. **The secret is shown only once.**
2. **Or via Python SDK** (if you already have account-U2M auth):
   ```python
   from databricks.sdk import AccountClient
   from databricks.sdk.service.iam import Role
   ac = AccountClient(profile="<account-u2m-profile>")
   sp  = ac.service_principals.create(display_name="terraform-deployer")
   ac.account_access_control.update_rule_set(name=f"accounts/{ac.config.account_id}/ruleSets/default",
       rule_set={"grant_rules":[{"principals":[f"servicePrincipals/{sp.application_id}"],
                                 "role":"roles/account.admin"}]})
   sec = ac.service_principal_secrets.create(service_principal_id=sp.id)
   print("CLIENT_ID:", sp.application_id, "  CLIENT_SECRET:", sec.secret)
   ```

Once you have `client_id` + `client_secret` for an Account Admin SP, you can deploy and re-deploy any number of workspaces in that account with no further auth work.

### Per-deploy auth (the only thing you actually run)

```bash
# Set BEFORE every terraform invocation. Prefer one-shot env (NOT shell exports
# that linger across sessions). The Terraform provider auto-detects these.
env -u DATABRICKS_HOST \
    DATABRICKS_CLIENT_ID="<sp-client-id>" \
    DATABRICKS_CLIENT_SECRET="<sp-client-secret>" \
    AWS_PROFILE="<aws-profile>" \
    AWS_DEFAULT_REGION="<region>" \
    terraform apply
```

The `databricks` provider checks env first, then `~/.databrickscfg` profiles, then explicit HCL fields — env wins.

### Provider configuration (verbatim from SRA `aws/tf/provider.tf`)

```hcl
terraform {
  required_providers {
    databricks = { source = "databricks/databricks", version = "~> 1.84" }
    aws        = { source = "hashicorp/aws",         version = ">= 5.76, <7.0" }
  }
  required_version = "~>1.3"
}

provider "aws" {
  region = var.region
  default_tags {
    tags = { Resource = var.resource_prefix }
  }
}

# Account-level provider — for MWS resources (workspace, network, credential, storage,
# metastore, metastore_assignment, mws_permission_assignment, audit log delivery).
provider "databricks" {
  alias      = "mws"
  host       = "https://accounts.cloud.databricks.com"
  account_id = var.databricks_account_id
}

# Workspace-level provider — for catalog, schema, grants, cluster, IP ACL, etc.
# host references the URL exported by the workspace module — Terraform handles the dependency.
provider "databricks" {
  alias      = "created_workspace"
  host       = module.databricks_mws_workspace.workspace_url
  account_id = var.databricks_account_id
}
```

The same `DATABRICKS_CLIENT_ID` + `DATABRICKS_CLIENT_SECRET` env vars authenticate **both** providers — there is no per-workspace browser login. Account-admin SPs implicitly resolve workspace admin against any workspace in the account.

Pass providers explicitly to modules:

```hcl
module "databricks_mws_workspace" {
  source     = "./modules/databricks_workspace"
  providers  = { databricks = databricks.mws }
  # ...
}

module "uc_workspace_isolated_catalog" {
  source     = "./modules/unity_catalog/workspace_isolated_catalog"
  providers  = { databricks = databricks.created_workspace }
  # ...
}
```

### CRITICAL: Environment variable overrides

Run `env | grep -i DATABRICKS` BEFORE any terraform command. If you have *stale* `DATABRICKS_CLIENT_ID`, `DATABRICKS_CLIENT_SECRET`, `DATABRICKS_HOST`, or `DATABRICKS_ACCOUNT_ID` set in your shell (often from prior Azure work), they **silently override** every provider config block including the explicit `host = "https://accounts.cloud.databricks.com"`. Symptom: "wrong account" or "invalid_client" errors. **Fix:** explicitly unset stale vars in the same command line: `env -u DATABRICKS_HOST DATABRICKS_CLIENT_ID="..." DATABRICKS_CLIENT_SECRET="..." terraform apply`.

### CRITICAL: `dose`-prefixed secrets are real, just CLI-obfuscated

The Databricks CLI v2 obfuscates M2M OAuth secrets in `~/.databrickscfg` with a `dose` prefix when it writes them. **A `dose`-prefixed secret IS a real secret and DOES authenticate** — the prefix is just visual scrambling for at-rest display. Older skill prose said `dose` secrets "don't work" — that was a misread. **The actual rule:** don't paste `~/.databrickscfg` values into Terraform `*.tfvars` files (because the CLI may re-rotate them and the var file goes stale). Always source the SP secret from your secret manager / env at deploy time, never from cfg.

### CRITICAL: Do NOT use `token {}` block in `databricks_mws_workspaces`

The `token {}` auto-PAT block requires the workspace creator to also have a workspace admin token, which depends on auth ordering. With M2M, just omit it — the workspace-level provider authenticates with the same SP creds via OAuth, and you generate workspace tokens via `databricks_obo_token` if needed.

### Workspace admin assignment for the deployer SP

How you grant your SP workspace admin depends on whether the workspace has Identity Federation enabled (see "Identity federation" gotcha below):

| Workspace state | What to use | Notes |
|---|---|---|
| **No metastore assigned (no IF)** | `databricks_mws_permission_assignment` Terraform resource | Standard SRA pattern. Resource succeeds. |
| **Metastore assigned (IF enabled)** | Account admin role only | `databricks_mws_permission_assignment` returns "APIs not available" — REMOVE the resource. Account admin SPs auto-resolve as workspace admin via IF. |

If you're not sure which state you'll be in mid-apply, use the SRA pattern: assign the metastore in the same plan, and skip explicit `mws_permission_assignment` (it will fail). The SRA's `aws/tf/main.tf` orders module dependencies so unity_catalog_metastore_assignment runs before workspace-level catalog operations precisely so IF is on by then.

**GOTCHA: Azure SP credentials do NOT work on AWS.** Azure (`accounts.azuredatabricks.net`) and AWS (`accounts.cloud.databricks.com`) are completely separate account consoles with separate service principals. Verify which account-console host you're targeting before reusing creds.

## Gotchas

### CRITICAL: S3 bucket policy for Databricks E2 control plane

The workspace root S3 bucket MUST have a bucket policy granting the Databricks E2 control plane account (`414351767826`) direct access. The cross-account IAM role alone is NOT sufficient. Without this, workspace creation fails with: `Failed storage configuration validation checks: List, Put, PutWithBucketOwnerFullControl, Delete -- Access Denied`

```hcl
resource "aws_s3_bucket_policy" "root" {
  bucket = aws_s3_bucket.root.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DatabricksE2Access"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::414351767826:root" }
      Action    = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject",
                   "s3:ListBucket", "s3:GetBucketLocation", "s3:PutObjectAcl"]
      Resource  = [aws_s3_bucket.root.arn, "${aws_s3_bucket.root.arn}/*"]
    }]
  })
}
```

### CRITICAL: S3 bucket ownership must be BucketOwnerPreferred

New S3 buckets default to `BucketOwnerEnforced` (no ACLs). Databricks validation tests `PutWithBucketOwnerFullControl`, which requires ACLs. Set `object_ownership = "BucketOwnerPreferred"` on ALL S3 buckets (root, metastore, catalog).

### Supported AWS regions

Not all AWS regions are supported by Databricks. Notable unsupported: **eu-north-1 (Stockholm)**. If requested, recommend **eu-west-1 (Ireland)** as closest supported EU region. Always verify region support before writing Terraform.

### KMS key policy for EC2/EBS encryption

If using KMS CMK for workspace encryption, the key policy must also grant EC2/EBS permissions for cluster volume encryption. Add a statement allowing the account root principal `kms:CreateGrant`, `kms:Decrypt`, `kms:DescribeKey`, `kms:Encrypt`, `kms:GenerateDataKey*`, `kms:ReEncrypt*` with condition `kms:CallerAccount` = your account ID.

### Workspace import limitation

`databricks_mws_workspaces` cannot be imported after creation if Terraform state is lost. If the workspace exists but is missing from state, reference it by URL/ID in locals. Use `terraform state rm` to clean up stale references.

### Identity federation enables/disables APIs based on metastore_assignment

A workspace becomes Identity-Federation-enabled the moment a `databricks_metastore_assignment` is applied to it (for accounts created after 2023-11-08, this is the default; older accounts must opt in via account console). IF flips two API behaviours:

- `databricks_mws_permission_assignment` → returns `"Permission assignment APIs are not available for this workspace"` and FAILS the apply. Remove the resource. Account-admin SPs auto-resolve as workspace admin via IF.
- Account-level groups (created via `databricks_group` w/ account-level provider) → auto-sync to the workspace's principal table; you can grant them workspace-level resources via `databricks_permissions`.

The SRA `aws/tf/main.tf` orders modules so `unity_catalog_metastore_assignment` runs *before* any workspace-level catalog ops — this is intentional, so IF is on before workspace-level resources are touched.

**To enable IF on a workspace created via Terraform:**
```hcl
resource "databricks_metastore_assignment" "this" {
  provider     = databricks.mws
  workspace_id = module.databricks_mws_workspace.workspace_id
  metastore_id = databricks_metastore.this.id
}
```

### IF + freshly-created account groups: ACL propagation lag

When you create an account-level group via Terraform and immediately try to grant it permissions on workspace-scoped resources (e.g. `databricks_permissions` on a SQL warehouse), the workspace ACL plane reports `"Principal does not exist"` for 5–10 minutes even though `databricks_grants` (the UC plane) sees the group instantly. **Fix:** either (a) grant via `databricks_grants` only and let the customer set workspace-resource perms in the UI later, or (b) add a `time_sleep` of 5–10 min between group creation and `databricks_permissions`, or (c) split into two `terraform apply` runs.

### Account SDK `workspace_assignment.update` only works on non-IF workspaces

If you find yourself outside the SRA happy-path and need to grant workspace ADMIN to an SP imperatively (e.g. recovering a workspace whose Terraform state is lost), the `ac.workspace_assignment.update(workspace_id, principal_id, [WorkspacePermission.ADMIN])` Python SDK call is the documented escape hatch. **Important caveat from real-world use:** this call returns `"Permission assignment APIs are not available"` on IF-enabled workspaces, same as the Terraform resource. Use it only on workspaces without a metastore assignment yet. For IF-enabled workspaces, the only paths are: (i) make the SP an Account Admin (then it implicitly has workspace admin everywhere), or (ii) browser-based `databricks auth login --host <ws-url>` for U2M.

### IAM cross-account policy is missing `ec2:DescribeVpcAttribute`

The cross-account IAM policy template circulating in older docs omits `ec2:DescribeVpcAttribute`. The Databricks network validator calls this action; without it, workspace creation fails with the misleading message `"DNS Support is not enabled for this VPC"` — even though DNS Support actually IS enabled on the VPC. **Fix:** include `ec2:DescribeVpcAttribute` alongside the rest of the `ec2:Describe*` actions in the role's policy. The SRA `aws/tf/credential.tf` includes it; older `aws-workspace-basic` template excerpts may not.

### IAM trust policy propagation race vs UC external_location

After updating an IAM trust policy via `null_resource` + AWS CLI (e.g. to add the storage credential's auto-generated UUID as the `sts:ExternalId`), `databricks_storage_credential.validate()` may return PASS while a subsequent `databricks_external_location` create still 403s with `"AWS IAM role does not have READ permissions"`. The skill text used to call this transient — the actual cause is that IAM trust update is eventually-consistent (typically 30–60s) and `validate()` succeeds before the external_location's deeper read check does. **Fix:** insert a `time_sleep { create_duration = "60s" }` between the trust update and the `external_location` resource, OR retry the apply once on 403.

### Storage credential creation requires SP to own the metastore (or have CREATE_STORAGE_CREDENTIAL grant)

When the deploy SP is *not* the metastore owner and *not* an account admin with implicit ownership, `databricks_storage_credential` creation fails with auth errors. The cleanest fix is to make the SP the metastore owner immediately after metastore creation:

```python
from databricks.sdk import AccountClient
from databricks.sdk.service.catalog import UpdateAccountsMetastore
ac = AccountClient(profile="<account-profile>")
ac.metastores.update(metastore_id="<id>",
    metastore_info=UpdateAccountsMetastore(owner="<sp-application-id>"))
```

Or, if you have an account admin SP from the canonical pattern above, no extra step is needed — account admins implicitly own metastores they create.

### IAM propagation delay (cross-account role creation)

Cross-account IAM roles take 10-30 seconds to propagate after creation. If apply fails with "Failed credential validation checks", wait 30 seconds and re-run `terraform apply` — the role will be propagated by then. Templates include a `time_sleep` resource; if it's still failing intermittently, bump to 60s.

### Catalog 'main' auto-created on metastore assignment

Databricks auto-creates a `main` catalog when a metastore is assigned to a workspace. Use a different name for custom catalogs to avoid conflicts. If you need to manage the `main` catalog, import it into Terraform state.

### AWS session token expiry

AWS STS session tokens (from SSO or AssumeRole) expire after 1-12 hours depending on the role's max session duration. Unlike Azure CLI which auto-refreshes, expired AWS tokens cause immediate Terraform failures. Re-export fresh credentials before long Terraform runs.

### SP workspace permissions for classic clusters

If your deployer SP is *not* an Account Admin, you must explicitly grant it workspace ADMIN before it can execute Spark commands on classic clusters. Use `databricks_mws_permission_assignment` (non-IF workspace) or rely on auto-IF-sync (IF-enabled workspace, account admin SP). The raw API call `PUT /api/2.0/accounts/{id}/workspaces/{ws_id}/permissionassignments/principals/{sp_id}` with `["ADMIN"]` is the underlying primitive. Without admin, the SP can create clusters but may not execute commands on them. **The canonical pattern (Account Admin SP, see Authentication section) sidesteps this entirely.**

### Classic clusters need at least 1 worker for reliable testing

Single-node clusters (num_workers=0) cause command execution timeouts via the Commands API -- JVM warmup combined with UC metadata resolution on zero workers is unreliable. Always use num_workers=1 minimum for verification testing.

### Classic-cluster JVM warmup vs autotermination race on fresh workspaces

On a brand-new workspace, a classic cluster can reach `RUNNING` but stay in the `Starting Spark` phase for 15–30 minutes while the JVM finishes warming up. If the cluster's `autotermination_minutes` is 30 (the common default), the cluster can hit autotermination *before* a job task ever attaches — yielding an infinite restart loop that looks like "cluster never starts". This is a real bug that affects production deploys, not just testing.

**Fix for verification clusters specifically:** set `autotermination_minutes = 0` and destroy the cluster explicitly after the verification step. **Fix for production clusters:** ensure jobs are queued via `databricks jobs submit --wait` (queue-then-warm) rather than create-cluster-then-submit, so the first job attaches as soon as Spark is ready.

### AWS service quota exhaustion — STOP, do not work around

Cloud-quota errors during workspace deploy (VPC endpoints, EIPs, NAT gateways, KMS keys, IAM roles, etc.) are NOT something to silently work around by dropping features. They almost always mean the customer account has hit a real Service Quotas limit that needs to be raised before the workspace will function reliably.

**Pattern for any `*LimitExceeded` / `*QuotaExceeded` / `LimitExceededException` / `MaxNumber*Exceeded` error during apply:**

1. STOP. Do not retry, do not drop the resource that hit the cap.
2. Identify the quota from the error message (e.g. `VpcEndpointLimitExceeded` → "VPC endpoints per region").
3. Tell the customer:
   - which quota was hit (with current usage if available via `aws service-quotas get-service-quota --service-code <code> --quota-code <code>`)
   - the exact AWS Service Quotas page to request an increase: `https://console.aws.amazon.com/servicequotas/home/services/<service>/quotas/<quota-code>`
   - the recommended new limit (typical: 2× current usage)
4. Wait for the customer to confirm the quota increase has been applied (can take 0–48h depending on AWS).
5. THEN re-run `terraform apply`.

**Common quotas hit during a single workspace deploy:**

| Error | Quota | Service Quotas code |
|---|---|---|
| `VpcEndpointLimitExceeded` | VPC endpoints per region | `vpc/L-1B52E74A` (interface) / `L-AE2E3D54` (gateway) |
| `AddressLimitExceeded` | EIPs per region | `ec2/L-0263D0A3` |
| `NatGatewayLimitExceeded` | NAT gateways per AZ | `vpc/L-FE5A380F` |
| `LimitExceededException` on KMS CreateKey | Customer master keys per region | `kms/L-C2F1777E` |
| `LimitExceeded` on IAM CreateRole | IAM roles per account | `iam/L-FE177D64` |

**Do NOT** silently drop S3 VPC gateway endpoints, downgrade encryption, or skip PrivateLink to make a deploy succeed against a constrained account. The workspace might come up but the customer's intended security posture won't.

### Workspace creation transient errors

Workspace creation can occasionally return an internal error from the Databricks API. This is transient. Re-run `terraform apply` and it will either resume creation or detect the workspace was actually created.

### Vending machine (auto-provisioned) metastores

Many AWS accounts have auto-provisioned metastores with no storage root URL. Critical limitations:
- `CREATE CATALOG` fails with `INVALID_STATE: Metastore storage root URL does not exist` unless you provide `MANAGED LOCATION` pointing to an external location.
- Default storage is **serverless-only**. Data stored in the auto-provisioned metastore's default storage CANNOT be read by classic clusters. You get: `Databricks Default Storage cannot be accessed using Classic Compute.`
- **Always deploy a self-managed metastore** with the `aws-unity-catalog` template for production.

### Using someone else's metastore requires storage access

Attaching to an existing metastore you do not own causes `403 Forbidden from cloud storage provider` on `CREATE TABLE` because the metastore's IAM role does not grant access to your data. Deploy your own metastore for full control.

### SP needs explicit metastore permissions

If you assign a metastore that someone else owns, the SP needs `CREATE_CATALOG`, `CREATE_EXTERNAL_LOCATION`, and `CREATE_STORAGE_CREDENTIAL` grants on the metastore before it can create catalogs.

### Full Private Link: Route 53 scoping

Route 53 private hosted zones must be scoped to the workspace FQDN only (e.g., `dbc-xxx.cloud.databricks.com`), NOT the entire `cloud.databricks.com` domain. Otherwise, OAuth token requests to `accounts.cloud.databricks.com` get intercepted and auth breaks.

### Full Private Link: PAS immutability

Private Access Settings (PAS) cannot be modified after creation. To change `public_access_enabled`, create a new PAS and update the workspace to use it. Workspace re-provisioning takes 1-2 minutes when switching PAS.

## Default Network Posture

Recommend a custom VPC with Secure Cluster Connectivity as the default:
- VPC with 2 private subnets (one per AZ)
- NAT gateway for outbound internet
- S3 VPC gateway endpoint
- Security group allowing internal traffic only
- No public IP on cluster nodes

### BYOVPC sizing arithmetic — **the customer's CIDR has to fit everything**

When the customer dictates a small VPC CIDR (e.g. `/20`), do the subnet math at intake time, not at apply time. A `/20` is 4096 addresses; AWS reserves 5 per subnet; Databricks needs at minimum **two private subnets** (one per AZ) sized to the cluster fleet, plus a **public subnet for the NAT gateway**, plus a small **subnet for VPC endpoints** if you're using interface endpoints. Two `/21` private subnets alone exhaust a `/20` — there's no room left for the NAT public subnet. Symptom: `terraform apply` errors at the second `aws_subnet` create with `InvalidSubnet.Conflict: The CIDR ... conflicts with another subnet`.

**Reference sizing** (from the SRA AWS template, which uses a `/16`):

| Customer says | Use for private subnets | Use for public/NAT | Use for VPC endpoints (interface) |
|---|---|---|---|
| `/16` (recommended)  | 2× `/22` (1022 hosts each) | 1× `/24` | 1× `/26` |
| `/20`                | 2× `/23`  (510 hosts each) | 1× `/26` | 1× `/27` |
| `/22` (smallest workable) | 2× `/24` (254 hosts each) | 1× `/26` | n/a — use gateway endpoints only |

**Rule of thumb:** if the customer offers anything smaller than `/22`, push back — workspace serverless egress + NAT failover + 100-node cluster fleets eat addresses fast. If they insist on `/20`, use `/23`+`/23`+`/26` (or the gateway-endpoint-only variant); never `/21`+`/21`+anything-else, the math doesn't fit. The SRA explicitly uses `/16` because it's the only size that gives headroom for cluster scaling without a re-CIDR.

## AWS Template Patterns

| Pattern | When to Use |
|---------|-------------|
| `aws-workspace-basic` | Getting started — VPC + IAM + S3 + workspace |
| `aws-workspace-full` | Production with UC in a single deploy |
| `aws-workspace-privatelink` | Backend private link (cluster-to-control-plane stays private) |
| `aws-workspace-full-privatelink` | Full private link (frontend + backend), transit VPC, Route 53 |
| `aws-unity-catalog` | Adding UC to an existing workspace |

## Reference Repos

Fetch from these at runtime for AWS Terraform patterns, in this order:
1. **`https://github.com/databricks-solutions/technical-services-solutions`** (path `workspace-setup/terraform-examples/aws/`) — **START HERE.** Self-contained, deploy-as-is scenarios curated by Databricks Shared Technical Services. Covers `aws-byovpc` and `aws-byovpc-classic-privatelink` (with `standard`, `fully_private`, and `custom` modes). Actively maintained.
2. **`https://github.com/databricks/terraform-databricks-sra`** — AWS section for enterprise hardening (CMK, ESC/compliance profiles, hub-spoke, log delivery, exfil protection). Use when the field repo doesn't cover the security requirement.
3. **`https://github.com/databricks/terraform-databricks-examples`** — broader AWS examples catalog. **Updates more slowly — verify provider versions and commit log before relying on it.**
