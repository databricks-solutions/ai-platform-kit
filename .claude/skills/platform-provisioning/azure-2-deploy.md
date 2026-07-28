# Azure — Deployment Options, Pre-checks, Network Posture, Templates

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
