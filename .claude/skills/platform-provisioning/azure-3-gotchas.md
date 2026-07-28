# Azure — Gotchas & Error Handling

Read this when you hit an error during apply, or as a sanity-check pass before applying. Most entries are tied to a specific error message — search by that.

## Azure SKU is always "premium" in Terraform

The `azurerm_databricks_workspace` resource only accepts `sku` values of `standard`, `premium`, or `trial`. There is NO `enterprise` SKU value. "Enterprise tier" in Databricks refers to account-level licensing (enabling Private Link, CMK, ESC, IP ACLs), not a Terraform parameter. Always use `sku = "premium"` — even for workspaces that need Enterprise features. The SRA production template uses `sku = "premium"` with full CMK and Private Link.

## Customer-says-`tier=PREMIUM` vs Terraform's `sku="premium"` (intake-time call-out)

The customer will often say "we need Premium tier" or "we need Enterprise tier". Always translate at intake time:

- Customer "Standard tier" → `sku = "standard"`
- Customer "Premium tier" → `sku = "premium"`
- Customer "Enterprise tier" → `sku = "premium"` (Enterprise is account-level licensing, not a `sku` value)

Confirm with the customer in turn 1 of the conversation: "Just to confirm — by 'Enterprise' you mean the Enterprise account licensing for PrivateLink/CMK/IP-ACL, right? On Azure that maps to `sku = premium` at the workspace resource level."

## Avoid hyphens in Unity Catalog object names

Catalog, schema, and table names with hyphens (`fraud-poc`, `my-catalog`) require backtick escaping in every SQL query, confuse BI tools, and break hive_metastore compatibility. Use underscores: `fraud_poc` not `fraud-poc`. When deriving names from a prefix that contains hyphens, replace them: `lower(replace(var.prefix, "-", "_"))`. The SRA AWS templates do this explicitly.

## Databricks lowercases all names

Storage credentials, catalogs, external locations, schemas — the Databricks API lowercases everything. Always use `lower()` in Terraform for any Databricks resource name to avoid "Provider produced inconsistent final plan" errors.

## `databricks_mws_permission_assignment` does NOT work on Azure

This resource is AWS/GCP only. On Azure, account-level groups are visible in workspaces via UC identity federation — no explicit workspace permission assignment is needed.

## Storage container names must be lowercase

Azure storage container names reject uppercase characters. Use `lower()` when the naming prefix might contain uppercase.

## DNS zone collision for multiple workspaces

The private DNS zone `privatelink.azuredatabricks.net` is hardcoded. Without a hub-spoke pattern, multiple workspaces with private link MUST use separate resource groups. With hub-spoke, a single shared zone in the transit resource group avoids collisions.

## CIDR overlap

Each workspace's VNet CIDR must be unique across all workspaces in the same account and region. Overlapping CIDRs cause `NETWORK_CHECK_CONTROL_PLANE_FAILURE` on classic clusters. Auto-generate non-overlapping CIDRs (e.g., 10.1.0.0/16, 10.2.0.0/16, 10.3.0.0/16 for dev/stg/prod).

## Two-phase deploy for Private Link + Unity Catalog

Terraform provider configs cannot reference resource attributes for `host`. When deploying private link workspaces with UC:
- **Phase 1**: Create workspaces, networking, private endpoints
- **Phase 2**: Set workspace URLs in tfvars, apply again for catalogs, schemas, grants

## Key Vault `network_acls.default_action = "Deny"` blocks Terraform-driven CMK creation

When you lock down a customer-managed Key Vault with `network_acls.default_action = "Deny"`, Terraform's `azurerm_key_vault_key` create step (run from your local IP) fails with `ForbiddenByFirewall: Client address is not authorized` even when `network_acls.virtual_network_subnet_ids` includes the Databricks subnets. Reason: the Databricks subnets aren't where the deployer is calling from — your laptop / CI runner is. Putting the Databricks subnets in `virtual_network_subnet_ids` doesn't help the deployer's request.

**Two acceptable fixes:**

1. **Recommended for prod:** keep `default_action = "Allow"` until after the apply, OR add `network_acls.bypass = "AzureServices"` AND your deployer IP to `network_acls.ip_rules` for the duration of the apply, then PATCH to `Deny` after.
2. **For SRA-style deploys:** rely on access policies + private endpoint to the KV; don't set `network_acls` at all in the SRA template (it's permissive by default for the deployer; private endpoint provides the network restriction at runtime).

Either way: do NOT set `default_action = "Deny"` without adding the deployer's egress IP. The SRA reference template omits `network_acls` for exactly this reason.

## CMK for managed disks — DES Key Vault access

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

## CMK for managed services — AzureDatabricks first-party SP needs PRE-create AKV access

This is **separate from and earlier than** the DES managed-disk identity gotcha above. When `customer_managed_key_enabled = true` AND `managed_services_cmk_key_vault_key_id` is set (or `managed_disk_cmk_key_vault_key_id` is set with `managed_disk_cmk_rotation_to_latest_version_enabled`), Azure validates the key vault access of the **AzureDatabricks first-party service principal** (well-known appId `2ff814a6-3304-4ab8-85cb-cd0e6f879c1d`) **before** the workspace resource provisions. If the SP doesn't have `Get / WrapKey / UnwrapKey` on the AKV at apply time, workspace create returns 403 on the KV — and there is no DES identity yet to grant access to, because the workspace doesn't exist.

```hcl
data "azuread_service_principal" "azure_databricks" {
  client_id = "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d"
}

resource "azurerm_key_vault_access_policy" "azure_databricks_first_party" {
  key_vault_id    = azurerm_key_vault.this.id
  tenant_id       = data.azurerm_client_config.current.tenant_id
  object_id       = data.azuread_service_principal.azure_databricks.object_id
  key_permissions = ["Get", "WrapKey", "UnwrapKey"]
}

resource "azurerm_databricks_workspace" "this" {
  # ...
  customer_managed_key_enabled         = true
  managed_services_cmk_key_vault_key_id = azurerm_key_vault_key.managed_services.id

  depends_on = [azurerm_key_vault_access_policy.azure_databricks_first_party]
}
```

**Order of grants when CMK is enabled on managed services + managed disks + DBFS root:**

1. **Pre-create**: AzureDatabricks first-party SP (`2ff814a6-...`) gets `Get/WrapKey/UnwrapKey` on the AKV — required for managed-services CMK validation at workspace create time.
2. **Post-create**: workspace's `managed_disk_identity` (DES) gets `Get/WrapKey/UnwrapKey` — required for classic cluster volume encryption.
3. **Post-create (if DBFS CMK)**: workspace's `storage_account_identity` gets `Get/WrapKey/UnwrapKey` — required for DBFS root.

All three are independent identities; each needs its own `azurerm_key_vault_access_policy`. Missing #1 is the trap because it's a pre-create requirement and the failure message points at the workspace create rather than the missing access policy.

## PE-only subnets cannot be on AKV/storage `network_acls.virtual_network_subnet_ids`

When you set `private_endpoint_network_policies = "Disabled"` on a subnet (typical pattern for a dedicated PE subnet), Azure removes the service-endpoint plumbing from that subnet. Adding a PE-only subnet to an AKV's or storage account's `network_acls.virtual_network_subnet_ids` returns:

```
A virtual network rule with no service endpoint detected. The subnet must
have one or more service endpoints configured.
```

PE-only subnets are reachable from the workspace via the private endpoint; they do NOT need a service-endpoint allow-listing on the resource. The AKV/storage `network_acls` should list:

- subnets that have a service endpoint to that resource (e.g. cluster subnets with `Microsoft.KeyVault` service endpoint), OR
- the deployer's egress IP via `ip_rules`.

It should **not** list dedicated PE subnets. The private endpoint is the network path; the ACL entry is redundant and rejected by the platform.

## Databricks injects worker NSG rules at priorities 100–103

When `network_security_group_rules_required` defaults to `AllRules` (typical when not pinned), the Databricks control plane injects required worker rules into the customer NSG at priorities **100, 101, 102, 103**. Custom rules at those priorities collide and apply fails with `Priority X is in use by Databricks-managed rule`.

**Fix**: avoid priorities 100–103 in custom NSG rules. Start customer rules at 200+. If you absolutely need fine-grained control over those slots, set `network_security_group_rules_required = "NoAzureDatabricksRules"` and replicate the worker rules manually — but that's an SRA-only pattern and not recommended unless the customer's security team explicitly demands it.

## Concurrent private endpoint creation against the same workspace

Two private endpoints (e.g. `databricks_ui_api` + `browser_authentication`) created concurrently against the same `azurerm_databricks_workspace` cause:

```
Error: ConcurrentUpdateError on workspace ... — Workspace is being updated.
```

Azure serializes most workspace updates server-side, but PE attach is a workspace mutation and Terraform parallelism (default 10) tries to fan them out. **Fix**: add explicit `depends_on` between the two PE resources so Terraform serializes them.

```hcl
resource "azurerm_private_endpoint" "ui_api" { /* ... */ }

resource "azurerm_private_endpoint" "browser_authentication" {
  /* ... */
  depends_on = [azurerm_private_endpoint.ui_api]
}
```

This is also why the SRA hub-spoke template lays out PEs sequentially in `network.tf` rather than via `for_each`.

## Catalog `isolation_mode` cannot be set during creation

Attempting to set `isolation_mode` during `CREATE CATALOG` returns `INVALID_PARAMETER_VALUE`. Create the catalog first, then update isolation_mode via a separate PATCH call.

## Azure Policy / owner tag requirement

Many enterprise subscriptions enforce an `owner` tag on all resources. Ask the customer about required tags early. All templates propagate tags to all resources via `local.tags`.

## UDR/firewall — never hardcode firewall IPs

When creating UDR routes to send traffic through Azure Firewall, always reference the firewall resource's IP directly in Terraform (`azurerm_firewall.this.ip_configuration[0].private_ip_address`). Never hardcode a firewall IP. If the customer specifies a firewall that doesn't exist in the current subscription (e.g., test environment), use conditional creation (`count = var.firewall_enabled ? 1 : 0`) and skip the UDR subnet association. A UDR pointing to a non-existent appliance creates a traffic blackhole — all outbound connectivity is lost and clusters cannot start. The SRA uses this exact pattern in `modules/hub/firewall.tf`.

## DNS zone VNet link deletion is extremely slow

Azure DNS zone VNet link deletions take 30-60+ minutes. This is an Azure API limitation. Combined with token expiry, this can cause Terraform failures during refactors or destroys. Warn the customer before running `terraform destroy` on private link deployments.
