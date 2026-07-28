---
name: databricks-workspace-config
description: "Configure Databricks workspace settings. Use when the user asks to create SQL warehouses, cluster policies, secret scopes, IP access lists, manage tokens, update workspace settings, or destroy infrastructure."
---

# Databricks Workspace Configuration

> **POST-DEPLOYMENT VERIFICATION IS MANDATORY.** Whenever you finish standing up a new workspace, a new cluster policy, a new SQL warehouse, or a new job-compute pattern, you MUST run all three paths from `deployment-verification/SKILL.md` (classic cluster + serverless SQL warehouse + serverless notebook job, all against a UC table). One-path verification is incomplete work. Read that skill before you call anything "done."

## How to interact with the customer

Apply MINIMAL pushback. These are day-2 operations -- the customer generally knows what they want.

- **PAT with no expiry requested** -- suggest once: "Want to set a 90-day lifetime? Tokens without expiry are a security risk if leaked." If they say no, create it without expiry.
- **Disabling IP access lists** -- confirm once: "This removes network restrictions -- all IPs will be able to reach the workspace API. Proceed?" Then do it.
- **terraform destroy** -- ALWAYS confirm before executing. This is irreversible. List what will be destroyed and get explicit yes/no.
- **Everything else** -- just execute. No pushback on warehouse sizes, policy definitions, secret values, or config keys.

## SQL warehouses

Manage serverless and pro SQL warehouses for BI and ad-hoc queries.

- **List** existing warehouses to see names, sizes, states, and types.
- **Create** with name, cluster_size (2X-Small through 4X-Large), auto_stop_mins (default 15), and warehouse_type.
- **Start** a stopped warehouse by ID.
- **Stop** a running warehouse by ID.

Recommend PRO warehouse type for any workspace with Unity Catalog. PRO supports fine-grained access control, data lineage, and serverless scaling. CLASSIC warehouses lack UC-aware features.

## Cluster policies

Control what users can configure when creating clusters.

- **List** all policies in the workspace.
- **Create** a policy with a name and JSON definition that restricts spark_version, node_type_id, autoscale ranges, and other cluster attributes.
- **Get** a specific policy by ID to inspect its definition.
- **Delete** a policy by ID.

Example restrictions: fix Spark version to a specific LTS release, allowlist specific node types, cap max_workers to prevent runaway costs.

## Secret scopes

Store sensitive values (API keys, connection strings, passwords) that notebooks and jobs can reference without exposing plaintext.

- **Create scope** with a name. Scopes are workspace-level.
- **Put secret** into a scope with a key and string value.
- **List secrets** in a scope. Returns metadata only (keys and timestamps) -- secret values are never returned by the API.
- **Delete** a secret or scope.

## IP access lists

Restrict which IP addresses can reach the workspace API and UI.

- **Create** an allow list (only these IPs can connect) or deny list (block these IPs).
- **List** existing access lists to audit current restrictions.

IP access lists must be enabled via workspace settings before they take effect. Creating a list does not automatically enable enforcement.

**CRITICAL: Self-lockout prevention.** When creating an IP access list, ALWAYS include the deployer's current IP address. If the allow list is enabled without the deployer's IP, Terraform loses API access to the workspace and cannot fix the list — manual intervention via the Azure/AWS console is required.

Pattern — auto-detect and include deployer IP:
```hcl
data "http" "deployer_ip" {
  url = "https://ifconfig.me"
}

resource "databricks_ip_access_list" "allow_list" {
  label     = "allow_in"
  list_type = "ALLOW"
  ip_addresses = concat(
    var.allowed_ips,
    ["${chomp(data.http.deployer_ip.response_body)}/32"]
  )
}
```

Recovery if locked out: disable IP access lists via the cloud console (Azure portal > Databricks workspace > Networking), fix the Terraform config, then re-apply.

## Token management

Manage personal access tokens (PATs) for API authentication.

- **List** existing tokens to see comments, creation dates, and expiry.
- **Create** a token with a comment describing its purpose and lifetime_seconds for expiry. Best practice: always set lifetime_seconds. A 90-day lifetime (7776000 seconds) is a reasonable default.
- **Revoke** a token by ID to immediately invalidate it.

## Workspace settings

Read and update workspace-level configuration keys.

Common settings:
- `enableTokensConfig` -- enable/disable PAT creation for the workspace.
- `maxTokenLifetimeDays` -- enforce a maximum token lifetime (0 means no limit).
- `enableIpAccessLists` -- enable/disable IP access list enforcement.

Get a setting to see its current value. Set a setting to change it. Some settings require workspace restart to take effect.

## Destroying infrastructure

Tear down Terraform-managed infrastructure.

- **List** past Terraform runs to find the deployment you want to destroy.
- **Get outputs** from a run to see what resources exist (workspace URLs, resource IDs).
- **Destroy** a run to tear down all resources it created.

ALWAYS ask for user confirmation before destroying. Show the user what will be destroyed (workspace name, resource group, VPC, etc.) and wait for explicit approval. Terraform destroy is irreversible -- deleted workspaces, storage accounts, and networking resources cannot be recovered.

### Workspace name reuse after destroy

When you destroy a Databricks workspace, the workspace name enters a `BANNED` state on the account side for approximately **1 hour** before it can be reused. Symptom on immediate re-create:

```
Error: workspace name "<name>" is currently BANNED — try again later or pick a new name
```

- **GCP and AWS:** consistent ~1hr delay
- **Azure:** the workspace resource name is managed by Azure, but the Databricks-side display name follows the same rule

Two mitigation patterns for stress-test / dev-loop scenarios where destroy/recreate is common:
1. Append a short random suffix to the workspace name: `${var.prefix}-ws-${random_id.suffix.hex}`
2. Use a date-suffixed name: `${var.prefix}-ws-$(date +%Y%m%d-%H%M)`

For real production destroys, the 1-hour cool-down is rarely a blocker. Just communicate it to the customer if they want immediate recreation under the same name.

## Cross-links

- For workspace creation and infrastructure provisioning, see **platform-provisioning**.
- For permissions, groups, and access control, see **identity-governance**.
