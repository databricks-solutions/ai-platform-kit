# AWS — Deployment Options, Pre-checks, Network Posture, Templates

## AWS Deployment Options

Map the customer's answers from the intake questions to these deployment types:

| Customer says... | Deployment type | Tier needed | Key resources |
|-----------------|----------------|-------------|---------------|
| "Quick POC, don't want to manage infrastructure" | Serverless workspace (no customer VPC) | Premium | No cloud resources needed — fully managed |
| "POC but in our own account" | Classic with automated config | Premium | Databricks provisions VPC, S3, IAM in customer's account |
| "Production, we want control over networking" | **Customer-managed VPC (BYOVPC)** — this is the default | Premium | Customer creates VPC, subnets, S3, IAM cross-account role |
| "Production, backend traffic must stay private" | Backend Private Link | **Enterprise** | BYOVPC + VPC endpoints (REST API + relay) |
| "Everything must be private, no public access at all" | Full Private Link | **Enterprise** | BYOVPC + VPC endpoints + transit VPC + Route 53 private zone |
| "Maximum lockdown, prevent data exfiltration" | Full PL + data exfil protection | **Enterprise** | Full PL + restrictive firewall rules + SCC |

**Default recommendation: Customer-managed VPC (BYOVPC)** with Secure Cluster Connectivity. This is the standard production setup. Escalate to private link only if the customer's answers indicate they need it.

## AWS Permissions Pre-check

Verify the customer has these permissions BEFORE writing any Terraform. If they don't, tell them exactly what's missing.

**For new Databricks account:**
- AWS Marketplace subscription permission (`AWSMarketplaceManageSubscriptions` policy minimum) — needed to subscribe to Databricks
- Plus one of:
  - AWS Admin privilege (simplest), OR
  - S3 creation + VPC/networking creation + IAM creation privileges (least-privilege)

**For existing Databricks account:**
- Databricks Account Admin role (check at accounts.cloud.databricks.com)
- Plus one of:
  - AWS Admin privilege, OR
  - S3 creation + VPC/networking creation + IAM creation privileges

**For Private Link (in addition to above):**
- VPC endpoint creation privileges
- Route 53 hosted zone management (for full PL)
- Enterprise tier on the Databricks account

**For CMK (Customer Managed Keys):**
- KMS key creation and management privileges
- Enterprise tier on the Databricks account

Ask: "Can you confirm you have admin access to both the AWS account and the Databricks account? If not, what access do you have — I'll tell you exactly what permissions are needed."

## Default Network Posture

Recommend a custom VPC with Secure Cluster Connectivity as the default:
- VPC with 2 private subnets (one per AZ)
- NAT gateway for outbound internet
- S3 VPC gateway endpoint
- Security group allowing internal traffic only
- No public IP on cluster nodes

## AWS Template Patterns

| Pattern | When to Use |
|---------|-------------|
| `aws-workspace-basic` | Getting started — VPC + IAM + S3 + workspace |
| `aws-workspace-full` | Production with UC in a single deploy |
| `aws-workspace-privatelink` | Backend private link (cluster-to-control-plane stays private) |
| `aws-workspace-full-privatelink` | Full private link (frontend + backend), transit VPC, Route 53 |
| `aws-unity-catalog` | Adding UC to an existing workspace |

## Reference Repos

Fetch from these at runtime for AWS Terraform patterns, in this order:
1. **`https://github.com/databricks-solutions/technical-services-solutions`** (path `workspace-setup/terraform-examples/aws/`) — **START HERE.** Self-contained, deploy-as-is scenarios curated by Databricks Shared Technical Services. Covers `aws-byovpc` and `aws-byovpc-classic-privatelink` (with `standard`, `fully_private`, and `custom` modes). Actively maintained.
2. **`https://github.com/databricks/terraform-databricks-sra`** — AWS section for enterprise hardening (CMK, ESC/compliance profiles, hub-spoke, log delivery, exfil protection). Use when the field repo doesn't cover the security requirement.
3. **`https://github.com/databricks/terraform-databricks-examples`** — broader AWS examples catalog. **Updates more slowly — verify provider versions and commit log before relying on it.**
