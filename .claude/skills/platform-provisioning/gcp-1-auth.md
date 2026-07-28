# GCP — Authentication (canonical)

The auth path Databricks GCP actually requires is **different** from AWS and Azure. AWS uses a Databricks-issued OAuth M2M client; Azure uses `azure-cli` provider auth. GCP uses **Google service account impersonation** with `auth_type = "google-id"`. M2M client_id/secret and U2M cached tokens both fail at the `databricks_mws_workspaces` / `databricks_mws_networks` server-side call with a misleading `400 BAD_REQUEST: Failed to get oauth access token` error.

This file documents the only pattern that works end-to-end for Terraform-driven workspace creation.

## TL;DR — what you set on the provider

```hcl
provider "databricks" {
  alias                  = "mws"
  host                   = "https://accounts.gcp.databricks.com"
  account_id             = var.databricks_account_id
  google_service_account = var.databricks_workspace_creator_sa   # e.g. databricks-workspace-creator@<project>.iam.gserviceaccount.com
  auth_type              = "google-id"
}

provider "databricks" {
  alias                  = "workspace"
  host                   = databricks_mws_workspaces.this.workspace_url
  google_service_account = var.databricks_workspace_creator_sa
  auth_type              = "google-id"
}
```

Both blocks need `auth_type = "google-id"` explicitly. Without it, the SDK v2 code path in the provider drops `google_service_account` and falls through to PAT/basic/oauth-m2m — at which point the server-side OAuth check rejects the request. With it, the provider mints an ID token for the impersonated SA on every call and the accounts API authorizes correctly.

## Prerequisites checklist (run all before you write any TF)

```bash
# 1. gcloud + ADC
gcloud auth list                              # active user account
gcloud auth application-default print-access-token >/dev/null && echo "ADC: ok" || echo "ADC: missing"
gcloud config get-value project               # active project
# If ADC quota project mismatches active project:
gcloud auth application-default set-quota-project <project-id>

# 2. APIs enabled on the workspace project
for api in compute.googleapis.com container.googleapis.com iam.googleapis.com \
           iamcredentials.googleapis.com cloudresourcemanager.googleapis.com \
           servicenetworking.googleapis.com storage.googleapis.com cloudkms.googleapis.com; do
  gcloud services enable $api --project=<project-id>
done

# 3. No conflicting Databricks env vars in your shell
env | grep -i DATABRICKS    # should be empty; if not, `unset` them before terraform
```

## The Workspace Creator service account (SA2 / "privileged SA")

A customer-owned GCP service account that the Databricks accounts API impersonates to create workspaces. The SA's identity is what gets authorized on the Databricks side, and the SA also operates against GCP IAM to provision the workspace's resources.

### Create the SA

```bash
PROJECT_ID=<your-project>
SA_NAME=databricks-workspace-creator
SA_EMAIL=$SA_NAME@$PROJECT_ID.iam.gserviceaccount.com

gcloud iam service-accounts create $SA_NAME \
  --project=$PROJECT_ID \
  --display-name="Databricks Workspace Creator"
```

### Grant the SA project-level IAM (must have ALL of these)

```bash
for ROLE in \
  roles/editor \
  roles/iam.serviceAccountAdmin \
  roles/resourcemanager.projectIamAdmin \
  roles/iam.roleAdmin \
  roles/compute.networkAdmin ; do
  gcloud projects add-iam-policy-binding $PROJECT_ID \
    --member="serviceAccount:$SA_EMAIL" \
    --role="$ROLE" \
    --condition=None
done
```

Why each role:
- `roles/editor` — base permissions on compute, storage, GKE
- `roles/iam.serviceAccountAdmin` — workspace creation needs to create the workspace SA inside the project
- `roles/resourcemanager.projectIamAdmin` — to bind roles to the workspace SA
- `roles/iam.roleAdmin` — bootstrap of the Databricks GCP service agent custom role on first workspace request
- `roles/compute.networkAdmin` — only required for BYOVPC and Shared VPC paths; can be omitted on managed-VPC POCs

If your org policy blocks `roles/owner` (common at Databricks Field-Eng), the five roles above are the documented equivalent. Do not skip `iam.roleAdmin` and `iam.serviceAccountAdmin` — workspace create will fail with opaque OAuth errors if either is missing.

### Grant your user impersonation rights on the SA

```bash
gcloud iam service-accounts add-iam-policy-binding $SA_EMAIL \
  --member="user:<your-email>@databricks.com" \
  --role="roles/iam.serviceAccountTokenCreator" \
  --project=$PROJECT_ID
```

For CI/CD, replace `user:` with the SA email of the CI runner (and grant the CI SA `roles/iam.serviceAccountUser` on the workspace-creator SA too).

### Register the SA email on the Databricks side

The SA email must exist as a Databricks **account user** with **`account_admin`** role. Do this once per Databricks GCP account.

```bash
# As an existing account admin (browser-cached profile or another SP), source creds and:
USER_ID=$(databricks account users create --user-name "$SA_EMAIL" | jq -r .id)

databricks account users patch $USER_ID --json '{
  "schemas": ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
  "Operations": [{
    "op": "add",
    "path": "roles",
    "value": [{"value": "account_admin"}]
  }]
}'
```

Verify:
```bash
databricks account users get $USER_ID | jq '{userName, roles}'
# Expect: roles = [{"value": "account_admin"}]
```

The SA goes in the **Users** SCIM table, NOT the **Service Principals** SCIM table — the `databricks account service-principals create` endpoint rejects `applicationId` for GCP SA emails. Treat the SA as a non-human user identity in the Databricks account.

## Quick self-test before any TF apply

After all the above, this end-to-end smoke test should pass:

```bash
# Get an impersonated Google ID token (provider does this internally on every call):
gcloud auth print-access-token --impersonate-service-account=$SA_EMAIL > /dev/null && echo "impersonation: ok"

# Confirm Databricks accepts that identity for write APIs:
DATABRICKS_AUTH_TYPE=google-id \
DATABRICKS_GOOGLE_SERVICE_ACCOUNT=$SA_EMAIL \
DATABRICKS_HOST=https://accounts.gcp.databricks.com \
DATABRICKS_ACCOUNT_ID=<account-id> \
  databricks account workspaces list   # must succeed
```

If the smoke test fails, do NOT start `terraform apply` — fix the auth chain first.

## Known auth gotchas

- **A DEFAULT profile in `~/.databrickscfg` will override impersonation.** If your `~/.databrickscfg` has a `[DEFAULT]` block (very common — it's what `databricks auth login` writes), the provider's auth-detection picks it up BEFORE `google_service_account` and falls through to that profile's `databricks-cli` auth, then fails on workspace creation with the misleading "Failed to get oauth access token". Two defenses, used together:
  ```bash
  export DATABRICKS_AUTH_TYPE=google-id
  export DATABRICKS_CONFIG_FILE=/dev/null   # or a path to an empty file
  ```
  The env var pins the auth path; the empty config file removes the cached-profile temptation. Set these BEFORE `terraform plan` / `apply`. Without them, even an HCL block with `auth_type = "google-id"` can be silently bypassed at provider init time.

- **Stale Databricks env vars override impersonation.** `DATABRICKS_CLIENT_ID`, `DATABRICKS_CLIENT_SECRET`, `DATABRICKS_TOKEN`, and `DATABRICKS_HOST` (without trailing component) are detected before `google_service_account` and will trigger an "more than one authorization method configured" error or silently pick the wrong path. Either `unset` them or prefix every command with `env -u DATABRICKS_CLIENT_ID -u DATABRICKS_CLIENT_SECRET -u DATABRICKS_ACCOUNT_ID -u DATABRICKS_HOST -u DATABRICKS_TOKEN ...`.
- **`auth_type = "oauth-u2m"` is not a valid literal.** The provider rejects it with `auth type oauth-u2m not found`. Valid values include `google-id`, `google-credentials`, `databricks-cli`, `pat`, `oauth-m2m` — use `google-id` for the impersonation pattern.
- **`auth_type = "databricks-cli"` does NOT work for `databricks_mws_workspaces` create**, even with a fresh U2M browser session. Reads succeed; writes fail with "Failed to get oauth access token". This was confirmed across U2M cache refresh + multiple regions in stress runs.
- **M2M (`DATABRICKS_CLIENT_ID` + `_SECRET` from a Databricks SP) doesn't work for workspace create either** — same error surface. M2M is fine for account-level group/metastore CRUD but not workspace provisioning.
- **CLI version matters.** `databricks --version` should be `>= 0.296.0`. Older CLIs lack `--force-refresh` and can serve stale tokens from `~/.databricks/token-cache.json`, which makes troubleshooting nondeterministic.
- **ADC quota project mismatch.** Run `gcloud auth application-default set-quota-project <project-id>` if the active project doesn't match the ADC quota project — otherwise Google client libraries will hit billing/quota errors that look like permission errors.
- **The workspace-level provider sometimes fails with `Unauthorized access to Org` on UC calls** even when the SA is account_admin. Workaround: use a U2M `profile = "gcp-account"` on the workspace-level provider only (the account-level provider still uses google-id), or transfer UC object ownership to the SA via the account API before applying workspace-level resources.

## When to fall back to the "out-of-band" pattern

In rare cases the TF provider's sdkv2 codepath for `databricks_mws_vpc_endpoint` or `databricks_mws_networks` will still hit the OAuth wall even with google-id. The workaround is to create the resource via the CLI then `terraform import` it:

```bash
NETWORK_ID=$(DATABRICKS_AUTH_TYPE=google-id \
  DATABRICKS_GOOGLE_SERVICE_ACCOUNT=$SA_EMAIL \
  databricks account networks create --json @network.json | jq -r .network_id)
terraform import databricks_mws_networks.this $NETWORK_ID
```

This is a provider bug, not an architecture issue. The CLI + imported pattern is reliable. Log a skill_gap if you hit it.

## Cross-references

- See [`gcp-2-deploy.md`](gcp-2-deploy.md) for workspace + UC deploy patterns once auth works.
- See [`gcp-3-gotchas.md`](gcp-3-gotchas.md) for HYBRID vs SERVERLESS, CMEK timing, custom_tags, BYOVPC sizing.
- See [`../private-networking/GCP.md`](../private-networking/GCP.md) for PSC backend/frontend patterns.
- See [`../unity-catalog-setup/GCP.md`](../unity-catalog-setup/GCP.md) for metastore + catalog + grants.
