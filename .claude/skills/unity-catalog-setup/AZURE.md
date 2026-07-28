# Unity Catalog on Azure

Azure-specific patterns, resources, and gotchas for Unity Catalog setup.

## Access Connector Setup

Azure UC uses an **Access Connector with System-Assigned Managed Identity** to access ADLS Gen2 storage. This replaces the IAM role pattern used on AWS.

```hcl
resource "azurerm_databricks_access_connector" "unity_catalog" {
  name                = "${var.prefix}-uc-access-connector"
  resource_group_name = var.resource_group_name
  location            = var.location
  identity {
    type = "SystemAssigned"
  }
}
```

The access connector's managed identity principal ID is used for all role assignments.

## ADLS Gen2 Storage

Each metastore and each per-env catalog needs its own storage account + container.

- Storage accounts must have `is_hns_enabled = true` (hierarchical namespace = ADLS Gen2).
- Replication: `GRS` for production, `LRS` acceptable for dev.
- Container access type: always `private`.

**Metastore storage root format:**
```
abfss://<container>@<storage_account>.dfs.core.windows.net/
```

**Per-env catalog storage:**
```
abfss://dev@st<prefix>catalogdev.dfs.core.windows.net/
abfss://stg@st<prefix>catalogstg.dfs.core.windows.net/
abfss://prod@st<prefix>catalogprod.dfs.core.windows.net/
```

## Required Role Assignments

The access connector MI needs these roles on EACH storage account:

| Role | Scope | Purpose |
|------|-------|---------|
| Storage Blob Data Contributor | Storage account | Read/write data |
| Storage Queue Data Contributor | Storage account | Auto Loader file event notifications |
| Storage Account Contributor | Storage account | Auto-create queues for file events |
| EventGrid Data Contributor | Resource group | Event Grid subscriptions for file notifications |

The first three go on the storage account. EventGrid Data Contributor goes on the **resource group**, not the storage account. Without the Queue, Account Contributor, and EventGrid roles, Auto Loader file notification mode fails silently.

```hcl
locals {
  uc_storage_roles = [
    "Storage Blob Data Contributor",
    "Storage Queue Data Contributor",
    "Storage Account Contributor",
  ]
}

resource "azurerm_role_assignment" "uc_storage" {
  for_each             = toset(local.uc_storage_roles)
  scope                = azurerm_storage_account.catalog.id
  role_definition_name = each.value
  principal_id         = azurerm_databricks_access_connector.unity_catalog.identity[0].principal_id
}

resource "azurerm_role_assignment" "uc_eventgrid" {
  scope                = "/subscriptions/${var.subscription_id}/resourceGroups/${var.resource_group_name}"
  role_definition_name = "EventGrid Data Contributor"
  principal_id         = azurerm_databricks_access_connector.unity_catalog.identity[0].principal_id
}
```

## Metastore Data Access

Register the access connector as the metastore's default data access credential:

```hcl
resource "databricks_metastore_data_access" "this" {
  provider     = databricks.accounts
  metastore_id = databricks_metastore.this.id
  name         = "${var.prefix}-uc-access-connector"
  azure_managed_identity {
    access_connector_id = azurerm_databricks_access_connector.unity_catalog.id
  }
  is_default = true
}
```

## Two-Phase Deploy

When deploying UC alongside workspace creation (especially with private link), the Terraform Databricks provider cannot reference the workspace URL from a resource attribute in the provider config block. This requires a two-phase deploy:

- **Phase 1:** Create workspaces, metastore, access connector, storage, role assignments, metastore assignment.
- **Phase 2:** Set workspace URLs in `tfvars`, re-apply to create catalogs, schemas, grants (workspace-level resources).

This applies to `azure-multi-workspace-privatelink` and `azure-workspace-full` templates.

## Storage Credential for External Catalogs

For per-env catalogs with dedicated storage, create a storage credential referencing the access connector, then external locations per container:

```hcl
resource "databricks_storage_credential" "this" {
  provider = databricks.workspace
  name     = lower("${var.prefix}-uc-credential")
  azure_managed_identity {
    access_connector_id = azurerm_databricks_access_connector.unity_catalog.id
  }
}

resource "databricks_external_location" "dev" {
  provider        = databricks.workspace
  name            = lower("${var.prefix}-catalog-dev")
  url             = "abfss://dev@${azurerm_storage_account.catalog_dev.name}.dfs.core.windows.net/"
  credential_name = databricks_storage_credential.this.name
}

resource "databricks_catalog" "dev" {
  provider         = databricks.workspace
  name             = "dev"
  storage_root     = databricks_external_location.dev.url
  isolation_mode   = "OPEN"
}
```

## Azure Gotchas

**Databricks lowercases all names.** Storage credentials, catalogs, external locations, schemas -- all get lowercased by the API. Always use `lower()` in Terraform for any name that might contain uppercase characters. Without this, Terraform reports "Provider produced inconsistent final plan" on every apply.

**Catalog `isolation_mode` cannot be set during creation.** The API returns `INVALID_PARAMETER_VALUE` if you set `isolation_mode` in the create call. Create the catalog first, then PATCH it to `ISOLATED`, then immediately add the workspace binding. In Terraform, use a `null_resource` with `local-exec` or the REST API directly for the two-step flow.

**Two-phase deploy for private link + UC.** Terraform provider config blocks cannot reference resource attributes for `host`. If the workspace URL comes from a `databricks_mws_workspace` resource, the workspace provider cannot be initialized in the same apply. Deploy workspaces first, then set URLs in tfvars and re-apply.

**Storage container names must be lowercase AND have no underscores.** Azure container naming is `^[a-z0-9](?:[a-z0-9-]{1,61}[a-z0-9])$` — lowercase alphanumerics + hyphens only, 3–63 chars, must start/end alphanumeric. **No underscores allowed.** This collides directly with UC catalog naming convention (which requires underscores: `acme_prod` not `acme-prod`). Symptom: `400 BadRequest: only lowercase alphanumeric characters and hyphens allowed`.

**Pattern**: keep the catalog name as-is and DERIVE the container name with `replace(name, "_", "-")`:
```hcl
locals {
  catalog_name   = "${var.prefix}_prod"               # acme_prod  (UC: underscore)
  container_name = replace(local.catalog_name, "_", "-")  # acme-prod  (Azure: hyphen)
}
```
Use `lower()` on top of that if the prefix might have uppercase. Do NOT cargo-cult lowercase from the rest of this file without also handling the underscore rewrite — `lower("acme_prod")` is still `acme_prod` and Azure rejects it.

**`storage_account_name` is deprecated on `azurerm_storage_container` (AzureRM 4.x).** Use `storage_account_id` instead. Old:
```hcl
resource "azurerm_storage_container" "uc" {
  name                  = "uc-metastore"
  storage_account_name  = azurerm_storage_account.uc.name   # DEPRECATED on 4.x
  container_access_type = "private"
}
```
New (AzureRM 4.x):
```hcl
resource "azurerm_storage_container" "uc" {
  name               = "uc-metastore"
  storage_account_id = azurerm_storage_account.uc.id        # required on 4.x
}
```
Old form throws `Error: Unsupported argument` on AzureRM provider >= 4.0. Pin provider version explicitly in `required_providers` if you need to control which form applies.

**`databricks_mws_permission_assignment` does NOT work on Azure.** It is AWS/GCP only. On Azure, account-level groups are visible in workspaces via UC identity federation automatically -- no explicit workspace assignment needed.

**Azure CLI token expiry (~60 min).** Long Terraform applies (workspace creation + DNS operations) can exceed the token lifetime. If apply fails with `ExpiredAuthenticationToken`, re-run `az login` and `terraform apply` -- Terraform picks up where it left off.

**Tenant mismatch.** Always set `azure_tenant_id` on ALL Databricks provider blocks. Without it, the provider fetches the management token from the user's home tenant, not the Databricks account tenant, causing `IncorrectClaimException` errors.

**Metastore ownership transfer.** If a service principal creates the metastore, the SP owns it and human admins cannot create catalogs. Transfer ownership via:
```bash
TOKEN=$(az account get-access-token --resource "2ff814a6-3304-4ab8-85cb-cd0e6f879c1d" --query accessToken -o tsv)
curl -X PATCH "https://{workspace_url}/api/2.1/unity-catalog/metastores/{metastore_id}" \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"owner": "admin@company.com"}'
```
