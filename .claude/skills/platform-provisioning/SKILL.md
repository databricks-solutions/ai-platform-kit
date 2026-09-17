---
name: databricks-platform-provisioning
description: "Provision and test Databricks workspaces. Use when the user asks to create a workspace, set up a new environment, provision infrastructure, bootstrap Databricks, test a workspace, verify a deployment, or run validation checks against a Databricks workspace. Covers Azure, AWS, and GCP."
---

# Databricks Platform Provisioning

## How to Interact with the Customer

**Pushback level: HIGH.** Infrastructure provisioning is expensive and hard to undo. Push back on incomplete or risky requests.

- **Vague request** (e.g., "set up Databricks"): You MUST ask for cloud, region, and whether they want Unity Catalog before writing any code. Do not guess.
- **Missing critical info** (account ID, subscription, credentials): Block until answered. Do not proceed with placeholders.
- **Default network posture**: Always recommend VNet/VPC injection with Secure Cluster Connectivity (no public IP). Do NOT recommend Private Link unless the customer explicitly asks for it or mentions compliance requirements that imply it (HIPAA, FedRAMP, PCI-DSS, etc.).
- **Suboptimal choice** (e.g., managed VNet in production, skipping UC): Suggest the better option once with a brief reason. If they insist, respect their decision and proceed.
- **Full spec given** (cloud, region, network tier, UC, groups all specified): don't re-litigate a complete specification -- proceed to write the HCL. But still run it through the approval gate below before applying.
- **Dangerous or irreversible actions** (terraform destroy, disabling public access, deleting metastore): Always confirm explicitly before executing. State what will be destroyed.

### Approval gate for remote mutations

Before `terraform apply` (or any `databricks ... create|delete|update`) that mutates remote infrastructure, present ONE plan and get explicit approval:

1. **Target** -- the account/workspace, the `--profile` (or host), and the cloud.
2. **Change set** -- the resources the plan will create / modify / destroy, batched for the whole deploy. One approval for the set (review it like a `terraform plan`), not one prompt per resource.
3. **Wait for explicit approval**, then apply **only** the approved scope; if it changes, re-present and re-approve.
4. **Retry / recovery** uses the same gate. **Cleanup** is limited to resources this workflow created in this session and is reported to the customer -- never delete pre-existing resources without asking.

This governs *what gets changed*, not design choices (already handled by intake). It is the default for interactive use; auto-approve / headless mode is the customer's choice and responsibility (see SECURITY.md).

## Resource naming convention

Examples in this skill use **`<prefix>`** as a placeholder for a customer-specific identifier (workspace, profile, storage). Substitute it with a unique value derived from the conversation — customer name, project name, or workspace name. **Never use `<prefix>` literally**, and never reuse a prefix across deployments in the same cloud account (cloud resource names like S3 buckets, Azure storage accounts, and Databricks workspaces are unique). See `unity-catalog-setup/SKILL.md` for the full convention.

## Overview

Provision Databricks workspaces end-to-end. Claude writes Terraform from scratch based on the customer's requirements, informed by reference templates and accumulated production gotchas.

**6-step workflow:**
1. **Intake** -- understand requirements before writing anything
2. **Auth check** -- verify credentials, gather all missing inputs in one shot
3. **Pre-flight permission check** (optional) -- offer the customer a read-only CLI sweep that returns a compatibility matrix (which deployment topologies their perms support) before we write any HCL
4. **Write Terraform** -- generate HCL tailored to the request, using reference templates as patterns
5. **Deploy** -- terraform init, plan (mandatory review), apply
6. **Verify** -- **MANDATORY**: follow `deployment-verification/SKILL.md`. Run **all three compute paths** (classic cluster + serverless SQL warehouse + serverless notebook job) against a UC table. One serverless test does not count as verified. Skipping classic is the most common reason real-world skill bugs reach customers. Read the verification skill BEFORE you finish step 5 — classic cluster cold-start is 10–15 min so start it early.

Once you know the customer's cloud, read the corresponding cloud file (AZURE.md, AWS.md, or GCP.md) in this directory for cloud-specific auth, providers, gotchas, and template details. Do NOT read other cloud files -- they add noise.

## Intake Questions

Ask these questions before deploying. Use plain language — the customer may not know Databricks-specific terms. Keep it conversational, not a checklist dump. Ask in logical groups, not all at once.

**Round 1: Basics** (always ask)

**1. Cloud and region**
> "Which cloud are you on (Azure / AWS / GCP) and what region should the workspace go in?"

**2. New or existing Databricks account?**
> "Do you already have a Databricks account, or do we need to set one up from scratch?"
- If new: note that they'll need marketplace subscription permissions (AWS) or resource provider registration (Azure)
- If existing: ask for the Account ID and confirm they have account admin access

**3. Environment strategy**
> "Is this a single workspace (e.g., for a POC or a small team), or do you need separate environments like dev, staging, and production?"

**4. What's the purpose?**
> "Is this for a quick proof-of-concept, or a production setup that needs to be hardened?"
- POC/evaluation → simpler setup, can use managed networking, skip some hardening
- Production → VNet/VPC injection, proper IAM, encryption, monitoring

**Round 2: Security and networking** (ask for production; skip or use defaults for POC)

**5. Network isolation level** (use plain language, not Databricks terms)
> "How locked down does the network need to be?"
> - **Standard** (recommended default): Your workspace runs in your own network (VPC/VNet), compute nodes have no public IPs, all outbound traffic goes through NAT. Data stays in your network.
> - **Private backend**: Same as standard, plus the communication between your compute and the Databricks control plane also stays private (no public internet). The web UI and API are still publicly accessible.
> - **Fully private**: Everything is private — web UI, API, and backend. You'll need VPN or ExpressRoute/DirectConnect to access the workspace at all.
> - **Fully private + data exfiltration protection**: Maximum lockdown. Prevents any data from leaving through the Databricks control plane. Requires Enterprise tier.

**6. Encryption requirements**
> "Do you need to manage your own encryption keys for data at rest? (If you're not sure, the default Databricks-managed encryption is fine for most use cases.)"
- Yes → need Customer Managed Keys (CMK), requires Enterprise tier
- No / not sure → use default encryption

**7. IP restrictions**
> "Do you want to restrict who can access the Databricks API and UI by IP address? For example, only allowing access from your corporate network?"
- Account-level (applies to all workspaces)
- Workspace-level (per-workspace)
- Not needed

**8. Compliance requirements**
> "Are there any compliance frameworks you need to meet — like HIPAA, PCI-DSS, FedRAMP, or internal security policies? This affects which features and tier we need."
- Yes → may need Enterprise tier, Enhanced Security and Compliance (ESC), specific network setup
- No → standard setup

**Round 3: Data governance** (always ask)

**9. Unity Catalog**
> "I'll set up Unity Catalog for data governance — this gives you access control, lineage tracking, and data discovery. For multi-env setups I'll create separate catalogs (dev/stg/prod), each with its own dedicated storage — this isolates environments so a mistake in dev can't affect production data. Sound good?"

**10. Groups and RBAC** (ask for production or multi-env)
> "Want me to set up standard access groups? I'd create: platform-admins (full control), data-engineers (build pipelines), data-analysts (read data), data-scientists (experiments). You can add users to these groups later."

**11. Tags** (ask once)
> "Any required tags for your cloud resources (e.g., owner, cost-center, environment)? I'll apply them to everything."

**Pricing tier logic — determine automatically, don't ask directly:**
- Need private link, CMK, IP ACLs, or compliance (ESC)? → **Enterprise** tier required (note: on Azure, the Terraform `sku` is still `"premium"` — "Enterprise" is an account-level licensing concept, not a Terraform SKU value. See AZURE.md.)
- Otherwise → **Premium** is sufficient (still includes Unity Catalog)
- Tell the customer: "Based on your requirements, you'll need Enterprise/Premium tier" — don't make them figure it out

**Permissions pre-check — verify after intake, before deploying:**
Once you know the cloud (read the cloud-specific file AWS.md/AZURE.md/GCP.md), verify the customer has the required permissions for their chosen deployment type. If they don't, tell them exactly what's missing before proceeding.

**Sensible defaults -- do NOT ask, just do:**
- CIDR ranges: auto-generate non-overlapping per environment
- Storage: **one storage account/bucket per environment** for catalog data (e.g., st-<prefix>-catalog-dev, st-<prefix>-catalog-stg, st-<prefix>-catalog-prod) + one for metastore. Create external locations per bucket, catalogs with MANAGED LOCATION.
- IAM role / access connector names: auto-generate
- Schemas: create bronze, silver, gold (medallion) in each catalog
- Network: VNet/VPC injection + no public IP (Secure Cluster Connectivity) as the default
- Metastore: self-managed with own storage (never rely on auto-provisioned/vending-machine metastore)
- Service principals for CI/CD: create per-env if multi-environment
- IaC: always use Terraform (recommend this as the deployment method)
- See `unity-catalog-setup` skill (especially the cloud-specific file) for detailed storage patterns, external location hygiene, and role assignments

## Security Pre-checks

Before deploying, verify the following. Warn the customer if any check fails.

1. **SSO/SCIM status**: Check if the Databricks account has SSO configured. If not, warn that users will need manual provisioning.
2. **Environment variable conflicts**: Run `env | grep -i DATABRICKS`. If DATABRICKS_CLIENT_ID, DATABRICKS_CLIENT_SECRET, or DATABRICKS_ACCOUNT_ID are set, warn that they will override Terraform provider auth. Recommend unsetting them or using `env -u` before terraform commands.
3. **Config file conflicts**: Check for `~/.databrickscfg` DEFAULT profile. If it contains OAuth M2M credentials, the Terraform provider may pick them up unexpectedly. Templates set `auth_type` explicitly to avoid this.
4. **Least-privilege admins**: Recommend that the deploying identity have account admin but not be the permanent workspace admin. Suggest creating a dedicated service principal for CI/CD post-provisioning.

## Workflow

### Step 1: Check auth and gather ALL inputs in one shot

This is MANDATORY. Never skip to writing Terraform without verifying auth first.

Run the cloud-specific auth check (detailed in the cloud file: AZURE.md, AWS.md, or GCP.md). Then present what you found and ask for ALL missing values at once:

> "I see you're logged in as alice@company.com on subscription abc-123. To set up the workspace, I also need:
> 1. Databricks Account ID
> 2. A prefix for resource names (e.g., 'acme')
> 3. Region (default: westeurope)"

Do not drip-feed questions across multiple turns.

### Step 2: Pre-flight permission check (optional)

Offer (do NOT auto-run) a cloud-permissions pre-check before writing Terraform. This runs read-only CLI calls and emits a JSON blob describing what the customer's identity can actually do. Claude then maps that to a compatibility matrix (Standard / Unity Catalog / Private Link / Full) and recommends a field-repo scenario.

**When to OFFER it:**
- Brand-new customer account or first Databricks deploy in this sub/project
- Customer creds came from a security/IT team and exact permissions are unknown
- Scoping conversation ("what deployment topology can this customer support?")
- A previous `terraform apply` failed with an IAM/RBAC error

**When to SKIP and proceed straight to Step 3:**
- Returning customer, already deployed successfully in this account this week
- Customer explicitly asked to skip preflight checks

Use **AskUserQuestion** to present three choices:
- **"Yes, run it"** — recommended for new accounts, first deploy in this sub, or scoping
- **"Skip — perms are known good"** — returning customer, second deploy in same account
- **"Show me the commands first"** — Claude prints what the script would run, then re-asks

**Execution recipe (run the cloud-matching one):**

```bash
# AWS
bash $SKILL_DIR/scripts/precheck-aws.sh --region <REGION> [--profile <NAME>] > /tmp/precheck.json

# Azure
bash $SKILL_DIR/scripts/precheck-azure.sh --subscription-id <SUB> --region <REGION> > /tmp/precheck.json

# GCP
bash $SKILL_DIR/scripts/precheck-gcp.sh --project <PROJECT> --region <REGION> > /tmp/precheck.json
```

The script writes a single JSON blob to stdout. Capture it to a temp file.

**Interpretation:** read the per-cloud matrix file (`aws-1.5-precheck.md` / `azure-1.5-precheck.md` / `gcp-1.5-precheck.md`) and apply its rules to the captured JSON. The matrix file owns the actual mapping logic — do not duplicate it here. Output is a compatibility matrix across Standard workspace, Unity Catalog, Private Link, and Full (all features) plus a recommended field-repo scenario.

**Present + decide.** Show the customer the matrix, list any specific permission gaps, name the recommended scenario, then ask via **AskUserQuestion**:
- **"Proceed with the recommended scenario"** — continue to Step 3 with that scenario as the template starting point
- **"Pause to request the missing perms"** — stop here; surface the exact missing permissions so the customer can take them to their security team
- **"Pick a different field-repo scenario"** — let the customer override; warn about any gaps that the matrix flagged for that path

**Failure handling.** If the script exits with `"status": "FAILED"` in its JSON (auth broken, subscription not accessible, CLI missing), surface the error verbatim to the customer and loop back to Step 1 / the relevant `*-1-auth.md` file. Do **not** proceed to Step 3 with a failed precheck.

### Step 3: Write Terraform

Write Terraform from scratch based on the customer's requirements. Use the official Databricks Terraform repos as reference for patterns, naming conventions, and provider config. The cloud-specific file (AZURE.md, AWS.md, GCP.md) has gotchas and patterns to bake into your Terraform. Always read it before writing.

### Step 4: Dry run (MANDATORY)

Run `terraform plan` and show the output to the customer. Get explicit confirmation before proceeding. Highlight:
- Number of resources to create
- Any resources being destroyed or modified
- Estimated deployment time (workspace creation: 5-15 min depending on cloud)

### Step 5: Apply

Run `terraform apply` only after the customer confirms the plan. Monitor for errors. If an error occurs:
- Check the error handling table below
- For transient errors (IAM propagation, token expiry), fix and re-run apply -- Terraform picks up where it left off
- For config errors, fix the HCL and re-run plan first

### Step 6: Show results and configure CLI access

Display prominently:
- **Workspace URL** (the most important output)
- Workspace ID
- Resource group / VPC / project created
- Storage account / bucket created
- Unity Catalog metastore (if deployed)

**Then update `~/.databrickscfg`** -- add a profile for each new workspace so the customer can immediately use the Databricks CLI and SDK. Always include comments labeling cloud, scope, and auth type:

```ini
# WORKSPACE LEVEL — Azure (westeurope)
# Scope: workspace operations
# Auth: az-cli
[<prefix>-dev]
host      = https://adb-1234567890.12.azuredatabricks.net
auth_type = azure-cli

# WORKSPACE LEVEL — Azure (westeurope)
[<prefix>-prod]
host      = https://adb-0987654321.12.azuredatabricks.net
auth_type = azure-cli
```

For AWS, use `token` or `oauth-m2m` auth. For GCP, use `google-credentials`. Check what already exists in `~/.databrickscfg` first — do not overwrite existing profiles. Ask the customer before writing if the file already has content.

### Step 7: Run verification (MANDATORY)

**Do NOT skip this step. Always run verification after a successful deploy.** It creates real resources, so present the verify-* plan and get approval first (see the approval gate in `deployment-verification/SKILL.md`). "Do not skip" means you must run verification -- not that you skip that approval.

Run the verification workflow below: create 3 test notebooks, launch them in parallel, report results. This confirms that the workspace, UC, storage, and compute are all working end-to-end. A deployment is not complete until verification passes.

## Reference Sources

**Databricks Terraform repos** — you MUST clone the relevant ones before writing any Terraform. Use them in this order of preference:

1. **`https://github.com/databricks-solutions/technical-services-solutions`** (path: `workspace-setup/terraform-examples/`) — **START HERE.** Self-contained, scenario-based templates curated by the Databricks Shared Technical Services team. Each scenario is a single dir with `tf/` + a per-scenario README (overview, architecture, prereqs, deploy steps, validation, cleanup, troubleshooting). Minimal modularization, designed to be copy-pasted and deployed as-is. Actively maintained.
2. **`https://github.com/databricks/terraform-databricks-sra`** — Production-hardened Security Reference Architecture. Use when the customer needs Enterprise features the field repo doesn't cover: CMK on managed services + managed disks, ESC / compliance profiles, hub-spoke with shared firewall, log delivery, system table exports, exfil protection lockdown patterns. Modularized. Actively maintained.
3. **`https://github.com/databricks/terraform-databricks-examples`** — Broad official examples catalog (workspaces, UC, VNet injection, Private Link, lakehouse patterns per cloud). Useful for niche modules. **Note: this repo updates more slowly than the other two — verify provider versions and check the commit log before relying on a template.**

**How to use them:**

1. Clone the field repo first; clone SRA only if you need enterprise hardening; clone the examples repo only if neither covers the request:
   ```bash
   git clone --depth 1 https://github.com/databricks-solutions/technical-services-solutions /tmp/tf-field
   git clone --depth 1 https://github.com/databricks/terraform-databricks-sra /tmp/tf-sra            # only if CMK / ESC / hub-spoke / exfil
   git clone --depth 1 https://github.com/databricks/terraform-databricks-examples /tmp/tf-examples  # only if nothing else matches
   ```
2. Find the closest matching template(s) from the Template Index below
3. Read the actual .tf files — pay attention to resource dependencies, access policies, provider config, and conditional logic
4. Adapt the template to the customer's requirements — change variables, add/remove resources, adjust naming
5. When combining features from multiple templates (e.g., the field-repo VNet-injection scenario + CMK from SRA), pull the specific resource blocks and merge them
6. Bake in gotchas from the cloud-specific files (AZURE.md, AWS.md, GCP.md)

**Why this is mandatory:** These repos contain production-tested patterns that handle edge cases (CMK DES access policies, NSG delegation, two-phase deploys, conditional firewall routing) that are easy to miss when writing from scratch. In stress testing, agents that skipped template fetching had a 3x higher failure rate than those that started from templates.

Do NOT write Terraform from memory. Always start from reference code.

## Template Index

These are the known Databricks Terraform patterns across the three repos. Always check the closest match before writing Terraform. Check the field repo first.

### Field Repo Scenarios — `databricks-solutions/technical-services-solutions/workspace-setup/terraform-examples/`

Self-contained, deploy-as-is. Each scenario has its own `tf/` dir and README.

| Cloud | Scenario | Path | Use Case |
|-------|----------|------|----------|
| AWS | `aws-byovpc` | `aws/aws-byovpc/` | BYOVPC workspace + Unity Catalog metastore. New VPC or use existing. |
| AWS | `aws-byovpc-classic-privatelink` | `aws/aws-byovpc-classic-privatelink/` | Classic Private Link (REST API + SCC relay). Modes: `standard` (VPC + NAT/IGW + S3/STS/Kinesis endpoints), `fully_private` (no NAT/IGW, dedicated endpoint subnet), `custom` (you supply VPC/subnets/SGs/backend VPCE IDs). Optional UC metastore create-or-attach. |
| Azure | `azure-vnet-injection` | `azure/azure-vnet-injection/` | VNet injection. New or existing VNet. Supports user login and SP auth. |
| Azure | `azure-vnet-injection-uc` | `azure/azure-vnet-injection-uc/` | VNet injection + NAT gateway + Unity Catalog (metastore, access connector, storage, external location, catalog). |
| Azure | `azure-privatelink-classic` | `azure/azure-privatelink-classic/` | Classic Private Link: VNet injection + NAT + private endpoints for control plane and DBFS. Optional public network access. |
| GCP | `gcp-byovpc-standalone` | `gcp/gcp-byovpc-standalone/` | Custom VPC + subnet + Cloud Router + Cloud NAT + SA impersonation. |
| GCP | `gcp-byovpc-shared-vpc` | `gcp/gcp-byovpc-shared-vpc/` | Custom VPC in shared-VPC host/service project topology. |

### Azure Templates — Examples Repo (`terraform-databricks-examples`) — may lag, verify before use

| Template | Path | Description | Use Case |
|----------|------|-------------|----------|
| `adb-vnet-injection` | `examples/adb-vnet-injection/` | Custom VNet + subnets + NSG + SCC | **Default for production** — start here for most deployments |
| `adb-lakehouse` | `examples/adb-lakehouse/` + `modules/adb-lakehouse/` | VNet injection + Key Vault + UC + storage + network | Full lakehouse with CMK pattern |
| `adb-unity-catalog-basic-demo` | `examples/adb-unity-catalog-basic-demo/` | Metastore + access connector + catalog + schemas | UC-only setup for existing workspace |
| `adb-private-links` | `examples/adb-private-links/` | VNet injection + private endpoints + private DNS | Full network isolation |
| `adb-with-private-link-standard` | `examples/adb-with-private-link-standard/` | Standard Private Link pattern | Simpler PL without exfil protection |
| `adb-exfiltration-protection` | `examples/adb-exfiltration-protection/` | VNet + PL + NSG lockdown + UC | Maximum security lockdown |
| `adb-data-storage-vnet-ncc-private-endpoint` | `examples/adb-data-storage-vnet-ncc-*` | NCC + private endpoint to storage | Serverless private connectivity to data |

### Azure Modules — SRA Repo (`terraform-databricks-sra`) — Enterprise/Compliance

Use these when the customer needs Enterprise features (CMK, Private Link, ESC, compliance profiles).

| Customer Need | SRA File | What It Contains |
|--------------|----------|-----------------|
| Workspace + VNet injection + SCC | `azure/tf/modules/workspace/main.tf` | Workspace resource with full custom_parameters, NSG rules, SCC |
| CMK — Key Vault + keys | `azure/tf/modules/hub/keyvault.tf` | Key Vault (premium, purge-protected) + RSA-2048 keys for managed services and managed disks |
| CMK — DES access policy | `azure/tf/modules/workspace/main.tf` (lines 114-140) | Post-workspace access policies for `storage_account_identity` and `managed_disk_identity` — **critical for managed disk CMK** |
| Private Link endpoints | `azure/tf/modules/workspace/main.tf` | Private endpoints (ui_api + browser_auth) + DNS zone links |
| Private DNS zones | `azure/tf/modules/hub/main.tf` | Shared DNS zone in hub resource group |
| Hub-spoke VNet peering | `azure/tf/spoke.tf` | VNet peering between hub and spoke |
| Unity Catalog metastore | `azure/tf/modules/hub/unitycatalog.tf` | Metastore + access connector + storage + role assignments |
| Compliance Security Profile | `azure/tf/modules/workspace/main.tf` | `enhanced_security_compliance` block with CSP + ESM |
| Firewall / UDR | `azure/tf/modules/hub/firewall.tf` | Conditional firewall creation + route table + UDR |
| Account groups | `azure/tf/modules/hub/unitycatalog.tf` | `databricks_group` resources |
| Log delivery | `azure/tf/modules/hub/log_delivery.tf` | Diagnostic settings + storage |

### AWS Templates — Examples Repo (`terraform-databricks-examples`) — may lag, verify before use

| Template | Path | Description | Use Case |
|----------|------|-------------|----------|
| `aws-workspace-basic` | `examples/aws-workspace-basic/` | VPC + IAM + S3 + workspace | Getting started |
| `aws-databricks-modular-privatelink` | `examples/aws-databricks-modular-privatelink/` | Modular VPC + Private Link | Production with PL |
| `aws-databricks-uc` | `examples/aws-databricks-uc/` | UC setup for AWS | Add UC to existing workspace |
| `aws-workspace-config` | `examples/aws-workspace-config/` | Cluster policies + IP ACLs | Day-2 workspace config |
| `aws-exfiltration-protection` | `examples/aws-exfiltration-protection/` | VPC + firewall + PL | Maximum lockdown |

### GCP Templates — Examples Repo (`terraform-databricks-examples`) — may lag, verify before use

| Template | Path | Description | Use Case |
|----------|------|-------------|----------|
| `gcp-basic` | `examples/gcp-basic/` | GCS + workspace (managed VPC) | Getting started |
| `gcp-byovpc` | `examples/gcp-byovpc/` | Custom VPC + subnet + Cloud NAT | Production with network control |

## When to Use a Template vs. Combine Templates

**ALWAYS clone the field repo first.** Clone SRA only if you need enterprise hardening. Clone the examples repo only as a last resort.

**Adapt a single template when:**
- The request maps 1:1 to a known scenario above
- Example: simple VNet injection → use the field repo's `azure/azure-vnet-injection/` directly
- Example: VNet injection + UC → use the field repo's `azure/azure-vnet-injection-uc/` directly
- Example: AWS BYOVPC + classic Private Link → use the field repo's `aws/aws-byovpc-classic-privatelink/` directly

**Combine templates when:**
- The request needs features from multiple patterns
- Example: field-repo VNet-injection-UC scenario + CMK → start from `azure/azure-vnet-injection-uc/`, add DES access policy pattern from SRA `modules/workspace/main.tf`
- Example: field-repo classic Private Link + compliance/ESC → start from `azure/azure-privatelink-classic/`, add ESC block from SRA `modules/workspace/main.tf`

**Matching guide:**

| Customer Need | Start From | Add From |
|--------------|------------|----------|
| Simple Azure POC (VNet injection) | Field repo `azure/azure-vnet-injection/` | — |
| Azure VNet injection + UC | Field repo `azure/azure-vnet-injection-uc/` | — |
| Azure classic Private Link | Field repo `azure/azure-privatelink-classic/` | — |
| AWS BYOVPC + UC | Field repo `aws/aws-byovpc/` | — |
| AWS classic Private Link | Field repo `aws/aws-byovpc-classic-privatelink/` | — |
| GCP BYOVPC | Field repo `gcp/gcp-byovpc-standalone/` (or `-shared-vpc`) | — |
| CMK encryption | Field repo cloud-matching scenario | SRA `keyvault.tf` + `workspace/main.tf` DES policy |
| HIPAA / FedRAMP / ESC | SRA `<cloud>/tf/` (full stack) | — |
| Hub-spoke + shared firewall | SRA `azure/tf/` (full stack) | — |
| Exfiltration protection | SRA `<cloud>/tf/` firewall patterns | Field repo for base workspace shape |
| Log delivery / system tables export | SRA `modules/.../log_delivery.tf` | Field repo for base workspace shape |

**Write from scratch ONLY when:**
- The request is something no template covers at all
- Even then, reference these repos for provider config, naming conventions, and access policy patterns

## Verification Workflow

**This is MANDATORY after every deployment. Do not skip.** Present the verification resource plan and get approval first (see the approval gate in `deployment-verification/SKILL.md`) — "mandatory" means you must run verification, not that you skip that approval.

Create 3 test notebooks via the Databricks REST API and launch them as parallel one-time job runs:

**Test 1: Classic cluster** (num_workers=1)
- Write and read a Unity Catalog table
- Compute: new_cluster with num_workers=1, latest LTS runtime, data_security_mode="USER_ISOLATION" (or "SINGLE_USER")
- CRITICAL: data_security_mode is REQUIRED for classic clusters to access Unity Catalog. Without it, the cluster starts but all UC queries fail with `[UC_NOT_ENABLED]`.
- **AWS:** Some node types (m5.large, etc.) require `ebs_volume_count >= 1`. Include EBS config in the cluster spec.
- **Note:** First classic cluster on a brand-new workspace may take 10-15 min to start (JVM warmup + UC metadata resolution). If it hangs >30 min with USER_ISOLATION, cancel and retry with SINGLE_USER — this is a known transient issue on fresh workspaces.

**Test 2: SQL warehouse** (PRO)
- Write and read a Unity Catalog table
- Compute: create or use existing SQL warehouse, PRO type
- **Alternative:** Use the Statement Execution API (`POST /api/2.0/sql/statements`) directly against a running warehouse. Faster and avoids notebook creation overhead.

**Test 3: Serverless notebook**
- Write and read a Unity Catalog table
- Compute: serverless
- **AWS:** Serverless job submission requires the multi-task `tasks` array format with `environment_key`, not the single-task format.

Each test notebook does:
```sql
CREATE TABLE `<catalog>`.`<schema>`.platform_kit_test (id INT, msg STRING);
INSERT INTO `<catalog>`.`<schema>`.platform_kit_test VALUES (1, 'provisioning verified');
SELECT * FROM `<catalog>`.`<schema>`.platform_kit_test;
-- assert row count = 1
DROP TABLE `<catalog>`.`<schema>`.platform_kit_test;
-- NOTE: backtick quoting handles catalog/schema names with hyphens.
-- Best practice: use underscores in names to avoid quoting issues entirely.
```

Submit all 3 as one-time job runs (`POST /api/2.1/jobs/runs/submit`), poll for completion, and report pass/fail per compute type. If a test fails, include the error message for diagnosis.

## Error Handling

| Error | Cause | Fix |
|-------|-------|-----|
| `ExpiredAuthenticationToken` | Cloud CLI token expired during long apply | Re-run cloud login (az login / aws sso login), then terraform apply |
| `Failed credential validation checks` | IAM role not yet propagated (AWS) | Wait 30s, re-run terraform apply |
| `NETWORK_CHECK_CONTROL_PLANE_FAILURE` | CIDR overlap or misconfigured VNet/VPC | Check CIDR ranges, ensure no overlap with existing workspaces |
| `IncorrectClaimException: Expected iss claim` | Tenant mismatch on Azure Databricks provider | Set azure_tenant_id on ALL Databricks provider blocks |
| `Provider produced inconsistent final plan` | Uppercase names lowercased by Databricks API | Use lower() in Terraform for all Databricks resource names |
| `INVALID_STATE: Metastore storage root URL does not exist` | Using auto-provisioned metastore without storage | Deploy self-managed metastore with own storage bucket |
| `has reached the limit for metastores in region` | Metastore limit hit | Reuse existing metastore or delete unused ones |
| `Internal error` on workspace creation | Transient Databricks API error | Re-run terraform apply |
| `INVALID_PARAMETER_VALUE` on catalog isolation_mode | Cannot set during creation | Create catalog first, then PATCH isolation_mode separately |
| `PARSE_SYNTAX_ERROR` on catalog/schema reference | Catalog or schema name contains hyphens | Use underscores instead of hyphens. Wrap existing hyphenated names in backticks: \`my-catalog\` |
| Classic cluster cannot see UC catalogs / `PERMISSION_DENIED` on UC table | Cluster running without data_security_mode | Set `data_security_mode = "USER_ISOLATION"` or `"SINGLE_USER"` on the cluster |
| `Azure key vault key is not found to unwrap the encryption key` | Managed disk DES identity lacks Key Vault access | Grant `Get`, `UnwrapKey`, `WrapKey` to `managed_disk_identity` — see CMK section in AZURE.md |
| `Failed storage configuration validation checks: Access Denied` (AWS) | S3 bucket missing policy for Databricks E2 account | Add bucket policy granting `arn:aws:iam::414351767826:root` S3 access + set `BucketOwnerPreferred` |
| `Authentication failed` on workspace token creation (AWS) | U2M auth cannot create PATs via MWS API | Remove `token {}` block, use profile-based workspace auth |
| `invalid_client` on Databricks OAuth (AWS) | SP secret obfuscated (`dose` prefix) or expired | Use U2M auth (`databricks auth login`) or original non-obfuscated SP secret |
| `APIs not available` on permission assignment (AWS) | Identity federation enabled on workspace | Remove `databricks_mws_permission_assignment` — groups auto-sync |
| Terraform state lock (`Error acquiring the state lock`) | Concurrent terraform process or stale lock | Wait for other process, or delete `.terraform.tfstate.lock.info` if stale |

## Cross-links

- **After provisioning** -- see `unity-catalog-setup` for detailed UC configuration (catalogs, schemas, external locations, storage credentials)
- **For groups and RBAC** -- see `identity-governance` for account groups, workspace assignments, UC grants
- **For Private Link** -- see `private-networking` for detailed private endpoint setup, DNS configuration, hub-spoke patterns
- **For day-2 configuration** (warehouses, cluster policies, IP access lists, secrets) -- see `workspace-config`
