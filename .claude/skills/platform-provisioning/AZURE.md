# Azure Platform Provisioning

Cloud-specific guidance for provisioning Databricks workspaces on Azure.

## Azure Deployment Options

Map the customer's answers from the intake questions to these deployment types:

| Customer says... | Deployment type | Tier needed | Key resources |
|-----------------|----------------|-------------|---------------|
| "Quick POC, simplest setup" | Managed VNet (no VNet injection) | Premium | Resource group + storage account + workspace — Databricks manages the network |
| "Production, we want control over networking" | **VNet injection + SCC** — this is the default | Premium | Custom VNet, public/private subnets, NSG delegated to Databricks, no public IP |
| "Production, everything must be private" | VNet injection + Private Link | **Enterprise** | VNet injection + private endpoints (ui_api + browser_auth) + private DNS zone |
| "Multi-environment with full isolation" | Hub-spoke Private Link | **Enterprise** | Transit VNet + web auth workspace + per-env VNets + shared DNS zone + per-env PEs |
| "Maximum lockdown, prevent data exfiltration" | VNet injection + PL + NSG lockdown | **Enterprise** | Full PL + restrictive NSG egress rules + service endpoints |

**Default recommendation: VNet injection with Secure Cluster Connectivity.** This is the standard production setup. Escalate to private link only if the customer's answers indicate they need it.

## Azure Permissions Pre-check

Verify the customer has these permissions BEFORE writing any Terraform. If they don't, tell them exactly what's missing.

**For new Databricks account:**
- Azure Active Directory: ability to register the Databricks resource provider (`Microsoft.Databricks`)
- The person creating the account needs to accept the Azure Marketplace terms for Databricks

**For workspace deployment (all types):**
- **Contributor** role on the subscription (or on a specific resource group if scoped)
- If deploying Unity Catalog: also **User Access Administrator** (for role assignments on storage accounts)
- If the subscription has Azure Policies (common in enterprise): check what tags are mandatory — the `owner` tag is almost always required

**For Private Link (in addition to above):**
- Permissions to create private endpoints and private DNS zones
- Enterprise tier on the Databricks account
- If hub-spoke: permissions on both the transit and workspace resource groups

**For CMK (Customer Managed Keys):**
- Key Vault creation and management permissions
- Enterprise tier on the Databricks account

**Multi-tenant check (CRITICAL):**
> "Does your organization use multiple Azure AD tenants? If so, which tenant should the Databricks account live in?"
This matters because the Databricks Terraform provider must target the correct tenant. Tenant mismatch is the #1 cause of auth failures on Azure.

Ask: "Can you confirm you have Contributor access on the Azure subscription and admin access to the Databricks account? If not, what access do you have — I'll tell you exactly what's needed."

## Authentication

### Check current auth state

```bash
az account show  # subscription ID, tenant ID, logged-in user
env | grep -i DATABRICKS  # check for conflicting env vars
cat ~/.databrickscfg 2>/dev/null  # check for DEFAULT profile conflicts
```

### Required credentials

- **Azure CLI session**: `az login` (or `az login --use-device-code` for headless). All templates support az-cli auth -- service principal credentials are optional.
- **Databricks Account ID**: From the Databricks accounts console (accounts.azuredatabricks.net). Ask the customer if not known.
- **Subscription ID and Tenant ID**: From `az account show`. If the customer has multiple tenants, confirm which one hosts the Databricks account.

### Provider configuration

All Azure templates use two providers:

```hcl
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

provider "databricks" {
  host      = "https://accounts.azuredatabricks.net"
  account_id = var.databricks_account_id
  auth_type  = "azure-cli"
  azure_tenant_id = var.tenant_id  # CRITICAL -- see tenant mismatch gotcha
}
```

After workspace creation, a second Databricks provider block targets the workspace:

```hcl
provider "databricks" {
  alias     = "workspace"
  host      = azurerm_databricks_workspace.this.workspace_url
  auth_type = "azure-cli"
  azure_tenant_id = var.tenant_id  # CRITICAL -- must be on EVERY provider block
}
```

**GOTCHA: Always set `auth_type = "azure-cli"` explicitly.** Without it, the provider may pick up OAuth M2M credentials from `~/.databrickscfg` DEFAULT profile, causing auth failures or targeting the wrong account.

## Gotchas

### Tenant mismatch

Always set `azure_tenant_id` on ALL Databricks provider blocks -- both account-level and workspace-level. Without it, the provider fetches the management token from the user's home tenant, not the Databricks account tenant. This causes `IncorrectClaimException: Expected iss claim to be...` errors. Even if the user only has one tenant today, set it explicitly for safety.

**Environment variable alternative:** If all workspaces share the same non-home tenant, set `export ARM_TENANT_ID=<tenant-id>` before running Terraform. The Databricks provider reads this automatically for all provider blocks, removing the need to set `azure_tenant_id` in each one. Useful in CI/CD pipelines. CAUTION: Do NOT set ARM_TENANT_ID when using MSI auth (`azure_use_msi = true`) — it causes errors in some provider versions.

### Azure SKU is always "premium" in Terraform

The `azurerm_databricks_workspace` resource only accepts `sku` values of `standard`, `premium`, or `trial`. There is NO `enterprise` SKU value. "Enterprise tier" in Databricks refers to account-level licensing (enabling Private Link, CMK, ESC, IP ACLs), not a Terraform parameter. Always use `sku = "premium"` — even for workspaces that need Enterprise features. The SRA production template uses `sku = "premium"` with full CMK and Private Link.

### Avoid hyphens in Unity Catalog object names

Catalog, schema, and table names with hyphens (`fraud-poc`, `my-catalog`) require backtick escaping in every SQL query, confuse BI tools, and break hive_metastore compatibility. Use underscores: `fraud_poc` not `fraud-poc`. When deriving names from a prefix that contains hyphens, replace them: `lower(replace(var.prefix, "-", "_"))`. The SRA AWS templates do this explicitly.

### Databricks lowercases all names

Storage credentials, catalogs, external locations, schemas -- the Databricks API lowercases everything. Always use `lower()` in Terraform for any Databricks resource name to avoid "Provider produced inconsistent final plan" errors.

### databricks_mws_permission_assignment does NOT work on Azure

This resource is AWS/GCP only. On Azure, account-level groups are visible in workspaces via UC identity federation -- no explicit workspace permission assignment is needed.

### Storage container names must be lowercase

Azure storage container names reject uppercase characters. Use `lower()` when the naming prefix might contain uppercase.

### DNS zone collision for multiple workspaces

The private DNS zone `privatelink.azuredatabricks.net` is hardcoded. Without a hub-spoke pattern, multiple workspaces with private link MUST use separate resource groups. With hub-spoke, a single shared zone in the transit resource group avoids collisions.

### CIDR overlap

Each workspace's VNet CIDR must be unique across all workspaces in the same account and region. Overlapping CIDRs cause `NETWORK_CHECK_CONTROL_PLANE_FAILURE` on classic clusters. Auto-generate non-overlapping CIDRs (e.g., 10.1.0.0/16, 10.2.0.0/16, 10.3.0.0/16 for dev/stg/prod).

### Two-phase deploy for Private Link + Unity Catalog

Terraform provider configs cannot reference resource attributes for `host`. When deploying private link workspaces with UC:
- **Phase 1**: Create workspaces, networking, private endpoints
- **Phase 2**: Set workspace URLs in tfvars, apply again for catalogs, schemas, grants

### Key Vault `network_acls.default_action = "Deny"` blocks Terraform-driven CMK creation

When you lock down a customer-managed Key Vault with `network_acls.default_action = "Deny"`, Terraform's `azurerm_key_vault_key` create step (run from your local IP) fails with `ForbiddenByFirewall: Client address is not authorized` even when `network_acls.virtual_network_subnet_ids` includes the Databricks subnets. Reason: the Databricks subnets aren't where the deployer is calling from — your laptop / CI runner is. Putting the Databricks subnets in `virtual_network_subnet_ids` doesn't help the deployer's request.

**Two acceptable fixes:**

1. **Recommended for prod:** keep `default_action = "Allow"` until after the apply, OR add `network_acls.bypass = "AzureServices"` AND your deployer IP to `network_acls.ip_rules` for the duration of the apply, then PATCH to `Deny` after.
2. **For SRA-style deploys:** rely on access policies + private endpoint to the KV; don't set `network_acls` at all in the SRA template (it's permissive by default for the deployer; private endpoint provides the network restriction at runtime).

Either way: do NOT set `default_action = "Deny"` without adding the deployer's egress IP. The SRA reference template omits `network_acls` for exactly this reason.

### CMK for managed disks — DES Key Vault access

When enabling CMK for managed disks (`managed_disk_cmk_key_vault_key_id`), Azure creates a Disk Encryption Set (DES) in the managed resource group. The DES has a managed identity that needs Key Vault access — but this identity only exists AFTER workspace creation. Pattern from the SRA:

```hcl
resource "azurerm_key_vault_access_policy" "managed_disk" {
  key_vault_id = azurerm_key_vault.this.id
  tenant_id    = azurerm_databricks_workspace.this.managed_disk_identity[0].tenant_id
  object_id    = azurerm_databricks_workspace.this.managed_disk_identity[0].principal_id
  key_permissions = ["Get", "UnwrapKey", "WrapKey"]
}
```

Without this, classic clusters fail with "Azure key vault key is not found to unwrap the encryption key." Serverless is unaffected. Use access policies (not RBAC) on the Key Vault — do NOT set `enable_rbac_authorization = true` if using access policies for the DES identity. Do the same for `storage_account_identity` if using DBFS CMK.

### Catalog isolation_mode cannot be set during creation

Attempting to set `isolation_mode` during `CREATE CATALOG` returns `INVALID_PARAMETER_VALUE`. Create the catalog first, then update isolation_mode via a separate PATCH call.

### Azure Policy / owner tag requirement

Many enterprise subscriptions enforce an `owner` tag on all resources. Ask the customer about required tags early. All templates propagate tags to all resources via `local.tags`.

### UDR/firewall — never hardcode firewall IPs

When creating UDR routes to send traffic through Azure Firewall, always reference the firewall resource's IP directly in Terraform (`azurerm_firewall.this.ip_configuration[0].private_ip_address`). Never hardcode a firewall IP. If the customer specifies a firewall that doesn't exist in the current subscription (e.g., test environment), use conditional creation (`count = var.firewall_enabled ? 1 : 0`) and skip the UDR subnet association. A UDR pointing to a non-existent appliance creates a traffic blackhole — all outbound connectivity is lost and clusters cannot start. The SRA uses this exact pattern in `modules/hub/firewall.tf`.

### DNS zone VNet link deletion is extremely slow

Azure DNS zone VNet link deletions take 30-60+ minutes. This is an Azure API limitation. Combined with token expiry, this can cause Terraform failures during refactors or destroys. Warn the customer before running `terraform destroy` on private link deployments.

### Azure CLI token expiry (~60 min)

`az login` tokens expire after approximately 60 minutes. Long Terraform applies (workspace creation + DNS operations) can exceed this. If apply fails with `ExpiredAuthenticationToken`, re-run `az login` and `terraform apply` -- Terraform resumes from where it left off.

### .databrickscfg DEFAULT profile conflict

If `~/.databrickscfg` has a DEFAULT profile with OAuth M2M credentials, the Databricks Terraform provider may use those instead of az-cli auth. The templates set `auth_type = "azure-cli"` explicitly to prevent this.

### Stale `DATABRICKS_*` env vars override `auth_type = azure-cli`

Same trap as AWS, in reverse. If your shell has stale `DATABRICKS_HOST`, `DATABRICKS_CLIENT_ID`, `DATABRICKS_CLIENT_SECRET`, or `DATABRICKS_ACCOUNT_ID` set (often from a prior AWS or M2M session), they **silently override** the explicit `auth_type = "azure-cli"` provider config — Terraform tries to authenticate as the leftover SP and gets `invalid_client` against the Azure account host. **Fix:** prefix the apply with `env -u DATABRICKS_HOST -u DATABRICKS_CLIENT_ID -u DATABRICKS_CLIENT_SECRET -u DATABRICKS_ACCOUNT_ID terraform apply`, or `unset` them in your shell.

### Customer-says-`tier=PREMIUM` vs Terraform's `sku="premium"` (intake-time call-out)

The customer will often say "we need Premium tier" or "we need Enterprise tier". Always translate at intake time:

- Customer "Standard tier" → `sku = "standard"`
- Customer "Premium tier" → `sku = "premium"`
- Customer "Enterprise tier" → `sku = "premium"` (Enterprise is account-level licensing, not a `sku` value — see "Azure SKU is always 'premium' in Terraform")

Confirm with the customer in turn 1 of the conversation: "Just to confirm — by 'Enterprise' you mean the Enterprise account licensing for PrivateLink/CMK/IP-ACL, right? On Azure that maps to `sku = premium` at the workspace resource level."

## Default Network Posture

Recommend VNet injection with Secure Cluster Connectivity (SCC) as the default:
- Custom VNet with public and private subnets
- NSG delegated to Databricks
- `no_public_ip = true` (SCC enabled)
- No private link unless explicitly requested

## Azure Template Patterns

| Pattern | When to Use |
|---------|-------------|
| `azure-workspace-basic` | Quick start, dev/test, managed VNet is acceptable |
| `azure-workspace-vnet-injection` | Default for production — VNet injection + SCC |
| `azure-workspace-full` | Production with UC in a single deploy |
| `azure-workspace-privatelink` | Customer requires no public access to UI/API |
| `azure-multi-workspace-privatelink` | Enterprise multi-env (dev/stg/prod) with private link |
| `azure-unity-catalog` | Adding UC to an existing workspace |

## Reference Repos

Fetch from these at runtime for Azure Terraform patterns, in this order:
1. **`https://github.com/databricks-solutions/technical-services-solutions`** (path `workspace-setup/terraform-examples/azure/`) — **START HERE.** Self-contained, deploy-as-is scenarios curated by Databricks Shared Technical Services. Covers `azure-vnet-injection`, `azure-vnet-injection-uc` (workspace + NAT + full UC), and `azure-privatelink-classic` (VNet injection + NAT + PE for control plane and DBFS). Actively maintained.
2. **`https://github.com/databricks/terraform-databricks-sra`** — Azure section for enterprise hardening (CMK on managed services + managed disks, ESC/compliance profiles, hub-spoke + shared firewall, log delivery, exfil protection lockdown). Use when the field repo doesn't cover the security requirement.
3. **`https://github.com/databricks/terraform-databricks-examples`** — broader Azure examples catalog. **Updates more slowly — verify provider versions and commit log before relying on it.**
