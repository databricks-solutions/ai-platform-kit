# Azure — Authentication & Provider Configuration

## Check current auth state

```bash
az account show              # subscription ID, tenant ID, logged-in user
env | grep -i DATABRICKS     # check for conflicting env vars
cat ~/.databrickscfg 2>/dev/null  # check for DEFAULT profile conflicts
```

## Required credentials

- **Azure CLI session**: `az login` (or `az login --use-device-code` for headless). All templates support az-cli auth — service principal credentials are optional.
- **Databricks Account ID**: From the Databricks accounts console (accounts.azuredatabricks.net). Ask the customer if not known.
- **Subscription ID and Tenant ID**: From `az account show`. If the customer has multiple tenants, confirm which one hosts the Databricks account.

## Provider configuration

All Azure templates use two providers:

```hcl
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

provider "databricks" {
  host            = "https://accounts.azuredatabricks.net"
  account_id      = var.databricks_account_id
  auth_type       = "azure-cli"
  azure_tenant_id = var.tenant_id  # CRITICAL — see tenant mismatch gotcha
}
```

After workspace creation, a second Databricks provider block targets the workspace:

```hcl
provider "databricks" {
  alias           = "workspace"
  host            = azurerm_databricks_workspace.this.workspace_url
  auth_type       = "azure-cli"
  azure_tenant_id = var.tenant_id  # CRITICAL — must be on EVERY provider block
}
```

**GOTCHA: Always set `auth_type = "azure-cli"` explicitly.** Without it, the provider may pick up OAuth M2M credentials from `~/.databrickscfg` DEFAULT profile, causing auth failures or targeting the wrong account.

## Common auth pitfalls (read these before debugging auth errors)

### Tenant mismatch (#1 cause of Azure auth failures)

Always set `azure_tenant_id` on ALL Databricks provider blocks — both account-level and workspace-level. Without it, the provider fetches the management token from the user's **home** tenant, not the Databricks account tenant. Causes `IncorrectClaimException: Expected iss claim to be...` errors. Even if the user only has one tenant today, set it explicitly for safety.

**This trap also fires for the `databricks` CLI itself, not just the Terraform provider.** Even after `az login --tenant <target-tenant>` and confirming `az account show` reports the right tenant, the `databricks` CLI can still mint a token against the user's home tenant when there are multiple. Symptom: `databricks workspaces list` returns workspaces from the wrong account. **Fix**: set `ARM_TENANT_ID=<target-tenant-id>` in the same shell as the CLI, or pass `--profile <profile>` with `azure_tenant_id` baked into the profile.

**Environment variable belt-and-suspenders pattern:** for ANY long-running Azure-Databricks shell session, export `ARM_TENANT_ID` *and* set `azure_tenant_id` on every provider block. Both are read by the Databricks provider; both are read by the `databricks` CLI v2. Setting only one and trusting it is how you find this bug at hour 3 of an apply, not hour 0.

```bash
export ARM_TENANT_ID=<tenant-id>      # affects databricks CLI + databricks TF provider
export ARM_SUBSCRIPTION_ID=<sub-id>   # also useful — locks azurerm provider in the same shell
```

CAUTION: Do NOT set `ARM_TENANT_ID` when using MSI auth (`azure_use_msi = true`) — it causes errors in some provider versions.

### `.databrickscfg` DEFAULT profile conflict

If `~/.databrickscfg` has a DEFAULT profile with OAuth M2M credentials, the Databricks Terraform provider may use those instead of az-cli auth. The templates set `auth_type = "azure-cli"` explicitly to prevent this.

### Stale `DATABRICKS_*` env vars override `auth_type = azure-cli`

Same trap as AWS, in reverse. If your shell has stale `DATABRICKS_HOST`, `DATABRICKS_CLIENT_ID`, `DATABRICKS_CLIENT_SECRET`, or `DATABRICKS_ACCOUNT_ID` set (often from a prior AWS or M2M session), they **silently override** the explicit `auth_type = "azure-cli"` provider config — Terraform tries to authenticate as the leftover SP and gets `invalid_client` against the Azure account host. **Fix:** prefix the apply with `env -u DATABRICKS_HOST -u DATABRICKS_CLIENT_ID -u DATABRICKS_CLIENT_SECRET -u DATABRICKS_ACCOUNT_ID terraform apply`, or `unset` them in your shell.

### Azure CLI token expiry (~60 min)

`az login` tokens expire after approximately 60 minutes. Long Terraform applies (workspace creation + DNS operations) can exceed this. If apply fails with `ExpiredAuthenticationToken`, re-run `az login` and `terraform apply` — Terraform resumes from where it left off.
