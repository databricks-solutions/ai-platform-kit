---
name: databricks-identity-governance
description: "Manage Databricks identity and governance. Use when the user asks to create groups, users, service principals, set up RBAC, manage permissions, workspace assignments, or configure access control."
---

# Databricks Identity & Governance

## How to interact with the customer

Apply LIGHT pushback on identity decisions, with hard rules on UC identity requirements.

- **One admin group proposed** -- suggest once that tiered groups (platform-admins, data-engineers, data-analysts, etc.) are better for least-privilege. If the customer insists on a flat structure, do it.
- **Specific group structure requested** -- just do it. Do not second-guess naming or hierarchy.
- **Individual user grants** -- suggest once that group-only grants are best practice (easier to audit, rotate, onboard). If they insist on user-level grants, do it.
- **Workspace-local groups** -- hard no. Account-level SCIM groups are mandatory for Unity Catalog. Workspace-local groups are invisible to UC and will silently fail on grants.
- **Jobs running as user identity** -- suggest once that service principals are the correct pattern. User identities cause failures when the user leaves or their token expires.
- **Everyone gets admin** -- warn once that least-privilege is strongly recommended. Only the platform team should have ADMIN.

## Hard rules (always enforce)

These are not suggestions. Violating them causes silent failures or security gaps.

1. **ONLY account-level SCIM groups.** Workspace-local groups are invisible to Unity Catalog. Every grant, every assignment must use account-level groups created via the Account SCIM API.
2. **Group-only grants.** Never grant catalog/schema/table permissions to individual users. Always grant to groups. This is the only auditable, maintainable pattern.
3. **Service principals for all automated jobs.** CI/CD pipelines, scheduled jobs, and orchestration must use service principals, not user identities. User tokens expire, users leave the org, and user-based jobs break silently.
4. **Least-privilege admin model.** Only the platform team gets ADMIN on workspaces. Everyone else gets USER. Data access is controlled through UC grants, not workspace roles.
5. **Pre-existing groups: check before creating.** Account-level groups persist across deployments and workspace deletions. Always list existing groups before creating new ones to avoid SCIM conflict errors.
6. **When an SP creates UC objects, the human admins do NOT inherit access.** Workspace admin is the workspace ACL plane. UC privileges are a separate plane. An SP that creates a catalog/external-location/storage-credential becomes its **owner**; nobody else sees it in the UI until you explicitly grant. **Every deploy that uses an SP MUST include an explicit grant block** giving the human admin group `ALL_PRIVILEGES` on the catalog, `MANAGE` on external locations, and `MANAGE` on storage credentials — OR transfer ownership to that group. Otherwise the customer's human admins log in to a workspace where they can't see their own catalog.

## Recommended group structure

This is the default recommendation for multi-environment deployments. Adjust based on customer needs.

| Group | Dev | Stg | Prod |
|-------|-----|-----|------|
| platform-admins | ADMIN, ALL_PRIVILEGES | ADMIN, ALL_PRIVILEGES | ADMIN, ALL_PRIVILEGES |
| data-engineers | USER, full CRUD | USER, full CRUD | USER, full CRUD |
| data-analysts | -- | USER, read silver/gold | USER, read silver/gold |
| data-scientists | USER, full CRUD | USER, read only | -- |
| ml-ops | USER, read+write | USER, read | USER, read |

- **platform-admins**: workspace ADMIN + ALL_PRIVILEGES on catalogs. Owns metastore, manages infra.
- **data-engineers**: workspace USER + USE_CATALOG, USE_SCHEMA, CREATE_TABLE, CREATE_FUNCTION, SELECT, MODIFY on all schemas.
- **data-analysts**: workspace USER + USE_CATALOG, USE_SCHEMA, SELECT on silver and gold schemas only. No dev access.
- **data-scientists**: workspace USER + full CRUD in dev, read-only in staging for validation. No prod access.
- **ml-ops**: workspace USER + read/write in dev (experiment tracking), read in staging/prod.

## Workflow: Create groups and users

### Step 1: Create account-level groups via Account SCIM API

Create groups at the account level. These are visible across all UC-enabled workspaces automatically.

Account console URLs by cloud:
- **Azure:** accounts.azuredatabricks.net
- **AWS:** accounts.cloud.databricks.com
- **GCP:** accounts.gcp.databricks.com

Before creating, list existing groups to avoid conflicts. Account-level groups persist even after workspaces are deleted.

### Step 2: Create users

Create users at the account level via SCIM. Users need a valid email (userName) and displayName.

### Step 3: Add users to groups

Add users as members of the appropriate groups. A user can belong to multiple groups. Group membership determines all access -- workspace assignment, catalog grants, schema permissions.

## Workflow: Service principals

### Per-environment service principals

Create one SP per environment for CI/CD pipelines:
- `{prefix}-cicd-dev`
- `{prefix}-cicd-stg`
- `{prefix}-cicd-prod`

Each SP gets added to the appropriate groups for its environment (e.g., cicd-dev joins data-engineers in dev workspace).

### Platform admin service principal

Create a single platform admin SP for infrastructure automation:
- `{prefix}-platform-admin-sp`

Add this SP to the platform-admins group. It manages metastores, workspace config, and cross-environment operations.

## Workflow: Workspace assignments

Assign groups and users to specific workspaces with a permission level (USER or ADMIN).

- **List** existing assignments to see who has access.
- **Assign** a principal (group or user) with USER or ADMIN permission.
- **Unassign** to revoke workspace access.

On workspaces with identity federation enabled, `databricks_mws_permission_assignment` does not work — the API returns "APIs not available." Account-level groups are visible in workspaces automatically via identity federation — no explicit assignment needed. This affects Azure (always) and many newer AWS/GCP workspaces. Check if your workspace has identity federation enabled before adding permission assignment resources. If you get the error, simply remove them.

## Workflow: UC grants

Grant permissions at the catalog and schema level to groups. Never to individual users.

### Tiered grant pattern

- **Engineers** get full CRUD: USE_CATALOG, USE_SCHEMA, CREATE_TABLE, CREATE_FUNCTION, CREATE_SCHEMA, SELECT, MODIFY
- **Analysts** get read on silver/gold: USE_CATALOG, USE_SCHEMA, SELECT (scoped to silver and gold schemas)
- **Platform admins** get ALL_PRIVILEGES on catalogs

Use modern privilege names only. Legacy names (e.g., USAGE instead of USE_CATALOG) cause confusing errors.

## One `databricks_grants` per securable — never two

The Databricks `databricks_grants` resource is **authoritative** for the entire ACL of a single securable (catalog, schema, external_location, storage_credential, etc.). If you write **two** `databricks_grants` resources targeting the **same securable** — say one for the human admin group and another for `account users` — they race during `terraform apply` and the second one fails:

```
permissions for <principal> are [USE_CATALOG, ...] but have to be [USE_CATALOG, ..., MODIFY, ...]
```

The provider re-reads after applying the first resource, sees a state delta from the second's intended ACL, and rejects. The race is inherent to the resource's "I own the whole ACL" semantics — not a TF parallelism bug.

**Wrong** (will race):
```hcl
resource "databricks_grants" "admins_on_catalog" {
  catalog = databricks_catalog.this.name
  grant { principal = var.human_admin_group, privileges = ["ALL_PRIVILEGES"] }
}

resource "databricks_grants" "users_on_catalog" {     # SAME securable, second resource
  catalog = databricks_catalog.this.name
  grant { principal = "account users", privileges = ["USE_CATALOG"] }
}
```

**Right** — one resource per securable, multiple `grant {}` blocks:
```hcl
resource "databricks_grants" "catalog" {
  catalog = databricks_catalog.this.name
  grant { principal = var.human_admin_group, privileges = ["ALL_PRIVILEGES"] }
  grant { principal = "account users",       privileges = ["USE_CATALOG"] }
}
```

**Permitted exception**: two `databricks_grants` resources can coexist if they target *different* securables (e.g. one for the catalog, one for an external_location of the same catalog). The earlier "human admins" example in this skill (catalog + external_location) is fine because the securables differ.

## Push back on placeholder account IDs

Customers sometimes hand you a literal placeholder string for the Databricks account ID — `xxxxxxxx-xxxx-...`, `abcd1234`, `<your-account-id>`, or just a free-text "I don't have it handy, use the default". **All of those should fail the intake check, not the apply.** Account IDs are UUIDs (8-4-4-4-12 hex). Anything that doesn't match `[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}` is a placeholder.

When this happens, do NOT plug a "well-known" account ID from a prior deploy without confirming. Either:
- Pull it yourself from the customer's account console (`accounts.cloud.databricks.com` or `accounts.azuredatabricks.net` → top-right user menu → "Account ID"), OR
- Ask the customer to pull it and paste it back, OR
- For internal Databricks demo-eng work specifically, look up the demo account ID via your own auth (`databricks current-user me --profile <my-account-profile>` — config block has `account_id`).

A wrong account ID can make the apply succeed against the *wrong* account silently — far worse than a hard failure on a placeholder.

## Error handling

- **"SCIM conflict"** -- the user or group already exists at the account level. List first, then update the existing object instead of creating a new one.
- **"Group with name X already exists"** -- account-level groups persist across deployments AND workspace deletions. **Always list existing groups first** via `GET /api/2.0/accounts/{id}/scim/v2/Groups` before creating. If the group exists, use `data.databricks_group` (data source) instead of `databricks_group` (resource) in Terraform. Alternatively, delete the stale group via SCIM API if it's from a previous deployment. Do NOT blindly create groups without checking — SCIM conflicts halt the entire terraform apply.
- **"permissions are [...] but have to be [...]"** -- you used a legacy privilege name. Switch to modern names: USE_CATALOG, USE_SCHEMA, CREATE_TABLE, CREATE_FUNCTION, CREATE_SCHEMA, SELECT, MODIFY.
- **"Principal does not exist" on `databricks_permissions` for a freshly-created account group** -- account-level SCIM groups created in the same `terraform apply` are visible to the UC plane (`databricks_grants`) immediately, but the **workspace ACL plane** (`databricks_permissions` on `sql_endpoint`, `cluster`, `job`, etc.) takes 5–10 minutes to see the new group. Symptom: UC grants succeed, then a workspace-resource grant a few resources later fails with `"Principal: GroupName(name=...) does not exist"`. **Three fixes:** (a) use `databricks_grants` only and let the customer set workspace-resource permissions in the UI later, (b) add `time_sleep { create_duration = "10m" }` between the group creation and the `databricks_permissions` resource, or (c) split into two `terraform apply` runs (group + UC grants in run 1, workspace ACLs in run 2).
- **Customer claims "the group already exists" but it doesn't** -- happens when the customer is thinking of a group that exists in another workspace, in their IdP, or in a stale memory of a prior deployment. Always verify with `databricks account groups list --output json | jq '.[] | select(.displayName == "X")'` before deciding to use `data.databricks_group` vs `databricks_group`. If the group genuinely doesn't exist yet in the Databricks account, create it with `databricks_group` and bring the customer along.
- **"You do not have permission to access this page in workspace ..."** when a human admin tries to view a catalog/external-location an SP just created -- workspace admin entitles access to the workspace UI but does NOT grant UC privileges. The SP that created the UC object owns it; nobody else sees it. **Fix:** add explicit grant blocks in the deploy:
  ```hcl
  resource "databricks_grants" "human_admins_on_catalog" {
    catalog = databricks_catalog.this.name
    grant {
      principal  = var.human_admin_group  # account-level SCIM group containing humans
      privileges = ["ALL_PRIVILEGES"]
    }
  }
  resource "databricks_grants" "human_admins_on_external_location" {
    external_location = databricks_external_location.this.name
    grant {
      principal  = var.human_admin_group
      privileges = ["MANAGE", "BROWSE", "READ_FILES", "WRITE_FILES", "CREATE_EXTERNAL_TABLE", "CREATE_MANAGED_STORAGE"]
    }
  }
  ```
  Or transfer ownership via `databricks_metastore.this.owner = var.human_admin_group` for the metastore root, and `databricks_catalog.this.owner` / `databricks_external_location.this.owner` for child objects.

## Cross-links

- For workspace creation, see **platform-provisioning**.
- For Unity Catalog metastore and catalog setup, see **unity-catalog-setup**.
