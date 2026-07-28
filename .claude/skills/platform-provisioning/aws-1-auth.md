# AWS — Authentication & Provider Configuration

The canonical pattern, used by the official Databricks Security Reference Architecture (SRA — `databricks/terraform-databricks-sra`), is **OAuth M2M via an account-admin service principal, with credentials passed through environment variables**. Both the account-level (`mws`) and workspace-level (`created_workspace`) providers share the same SP creds. **No browser, no PAT, no separate workspace login required**, even on a freshly-created workspace.

## Pre-flight checks (run before any terraform command)

```bash
aws sts get-caller-identity                    # AWS account ID + IAM principal
env | grep -i DATABRICKS                       # check for conflicting env vars (see CRITICAL below)
databricks auth profiles 2>/dev/null           # lists profiles + DEFAULT; never echoes secrets
```

## Required credentials

- **AWS CLI session** — IAM user creds (`aws configure`), SSO (`aws sso login`), or env vars (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`).
- **Databricks account ID** — from the accounts console at `https://accounts.cloud.databricks.com`. Ask the customer if not known.
- **Databricks account-level service principal with Account Admin role**, plus its OAuth secret (client_id + client_secret). This is the load-bearing piece — see "One-time SP setup" below.

## One-time SP setup (per Databricks account, not per workspace)

If the customer doesn't already have an account-admin SP with an OAuth secret, create one **before** writing any deploy Terraform:

1. **Account console (UI)** — at `https://accounts.cloud.databricks.com`:
   - User Management → Service principals → Add service principal → name it (e.g. `terraform-deployer`).
   - Grant it the **Account admin** role (Roles tab on the SP detail page).
   - Generate an OAuth secret (Settings → Identity and access → Service principals → your SP → Secrets → Generate). Capture `client_id` (= application ID) and `client_secret`. **The secret is shown only once.**
2. **Or via Python SDK** (if you already have account-U2M auth):
   ```python
   from databricks.sdk import AccountClient
   from databricks.sdk.service.iam import Patch, PatchOp, PatchSchema
   ac = AccountClient(profile="<account-u2m-profile>")
   sp = ac.service_principals.create(display_name="terraform-deployer")
   # Grant Account Admin via SCIM PATCH (rule_set API does NOT accept account.admin role).
   ac.service_principals.patch(
       id=str(sp.id),
       schemas=[PatchSchema.URN_IETF_PARAMS_SCIM_API_MESSAGES_2_0_PATCH_OP],
       operations=[Patch(op=PatchOp.ADD, path="roles", value=[{"value": "account_admin"}])],
   )
   sec = ac.service_principal_secrets.create(service_principal_id=sp.id)
   print("CLIENT_ID:", sp.application_id, "  CLIENT_SECRET:", sec.secret)
   ```

Once you have `client_id` + `client_secret` for an Account Admin SP, you can deploy and re-deploy any number of workspaces in that account with no further auth work.

## Per-deploy auth (the only thing you actually run)

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

## Provider configuration (verbatim from SRA `aws/tf/provider.tf`)

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

## Workspace admin assignment for the deployer SP

How you grant your SP workspace admin depends on whether the workspace has Identity Federation enabled (see `aws-3-gotchas.md` "Identity federation"):

| Workspace state | What to use | Notes |
|---|---|---|
| **No metastore assigned (no IF)** | `databricks_mws_permission_assignment` Terraform resource | Standard SRA pattern. Resource succeeds. |
| **Metastore assigned (IF enabled)** | Account admin role only | `databricks_mws_permission_assignment` returns "APIs not available" — REMOVE the resource. Account admin SPs auto-resolve as workspace admin via IF. |

If you're not sure which state you'll be in mid-apply, use the SRA pattern: assign the metastore in the same plan, and skip explicit `mws_permission_assignment` (it will fail). The SRA's `aws/tf/main.tf` orders module dependencies so `unity_catalog_metastore_assignment` runs before workspace-level catalog operations precisely so IF is on by then.

## Common auth pitfalls (read these before debugging auth errors)

### Stale `DATABRICKS_*` env vars override provider config

Run `env | grep -i DATABRICKS` BEFORE any terraform command. If you have *stale* `DATABRICKS_CLIENT_ID`, `DATABRICKS_CLIENT_SECRET`, `DATABRICKS_HOST`, or `DATABRICKS_ACCOUNT_ID` set in your shell (often from prior Azure work), they **silently override** every provider config block including the explicit `host = "https://accounts.cloud.databricks.com"`. Symptom: "wrong account" or "invalid_client" errors. **Fix:** explicitly unset stale vars in the same command line: `env -u DATABRICKS_HOST DATABRICKS_CLIENT_ID="..." DATABRICKS_CLIENT_SECRET="..." terraform apply`.

### `dose`-prefixed secrets are real, just CLI-obfuscated

The Databricks CLI v2 obfuscates M2M OAuth secrets in `~/.databrickscfg` with a `dose` prefix when it writes them. **A `dose`-prefixed secret IS a real secret and DOES authenticate** — the prefix is just visual scrambling for at-rest display. Older skill prose said `dose` secrets "don't work" — that was a misread. **The actual rule:** don't paste `~/.databrickscfg` values into Terraform `*.tfvars` files (because the CLI may re-rotate them and the var file goes stale). Always source the SP secret from your secret manager / env at deploy time, never from cfg.

### Do NOT use `token {}` block in `databricks_mws_workspaces`

The `token {}` auto-PAT block requires the workspace creator to also have a workspace admin token, which depends on auth ordering. With M2M, just omit it — the workspace-level provider authenticates with the same SP creds via OAuth, and you generate workspace tokens via `databricks_obo_token` if needed.

### Azure SP credentials do NOT work on AWS

Azure (`accounts.azuredatabricks.net`) and AWS (`accounts.cloud.databricks.com`) are completely separate account consoles with separate service principals. Verify which account-console host you're targeting before reusing creds.
