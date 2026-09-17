---
name: databricks-private-networking
description: "Set up private networking for Databricks. Use when the user asks about private link, hub-spoke architecture, NCC (Network Connectivity Configuration), serverless connectivity to private resources, VPC endpoints, or private endpoints."
---

# Databricks Private Networking

## How to interact with the customer

Apply MODERATE pushback -- private networking adds significant complexity and ongoing maintenance burden.

- **"I need private link" without scope** -- you must ask: "Backend-only (cluster traffic private, UI/API still public) or full private link (everything private, requires VPN/ExpressRoute/DirectConnect to access UI and API)?"
- **Full private link without VPN/private connectivity** -- warn once: "With full private link, the workspace UI and API are only accessible from inside the private network. You will need VPN, ExpressRoute, or DirectConnect to reach the workspace. Are you sure?"
- **Clear spec with backend-only or full PL and VPN confirmed** -- no further design pushback. But applying it is a remote mutation: run it through the approval gate below.

## Approval gate for remote mutations

Before you create, modify, or delete any remote network resource (Private Link / Private Endpoint / PSC endpoint, NCC, VPC/VNet, subnet, DNS, route -- any `terraform apply` or `databricks ... create|delete|update`), present ONE plan and get explicit approval:

1. **Target** -- the account/workspace, the `--profile` (or host), and the cloud.
2. **Change set** -- every network resource to be created / modified / deleted, batched for the whole task. One approval for the set (like reviewing a `terraform plan`), not one prompt per resource.
3. **Wait for explicit approval**, then execute **only** the approved scope; if it changes, re-present and re-approve.
4. **Retry / recovery** uses the same gate. **Cleanup** is limited to resources this workflow created in this session and is reported to the user -- never delete pre-existing networking without asking (it can cut off workspace access).

This governs *what gets changed*, not design choices. It is the default for interactive use; auto-approve / headless mode is the customer's choice and responsibility (see SECURITY.md).

## When do you need this?

Not every deployment needs private link. Match the solution to the actual requirement.

- **Default (VNet/VPC injection + SCC)** is sufficient for most workloads. Cluster nodes have no public IPs, traffic to the control plane goes through a secure tunnel. This is already production-grade for most compliance frameworks.
- **Private link** is needed when: compliance explicitly requires no public endpoints, the organization operates a zero-trust network, or security policy prohibits any traffic traversing the public internet.
- **NCC (Network Connectivity Configuration)** is needed when: serverless compute must connect to private or on-premises resources. Classic clusters running in a VNet/VPC can reach VNet-peered or VPC-peered resources directly -- they do not need NCC.

  **Examples NCC covers** (the VM-fronting-an-ILB pattern in AZURE.md is just the simplest case — substitute the target):
  - Serverless SQL warehouse → on-prem PostgreSQL / MySQL / SQL Server reachable via ExpressRoute or VPN
  - Serverless notebook → private REST APIs behind a VNet/VPC
  - Serverless → any cloud resource with Private Link Service in front of it (self-managed DBs, custom services, partner SaaS PLS)
  - Lakehouse Federation connections to self-managed databases (not Azure-managed PaaS — those have their own private endpoint flow)

  In every case the architecture is identical: **Serverless → NCC private endpoint → customer Private Link Service → customer Internal Load Balancer → target resource**. The target swaps out; the connectivity stack does not.

## Network baselines per cloud

The minimum recommended baseline for any production deployment is VNet/VPC injection with Secure Cluster Connectivity (no_public_ip enabled). This gives you private compute nodes without the operational complexity of private link.

Once you know the customer's cloud, read the cloud-specific file for architecture patterns, step-by-step deployment guides, and gotchas:

- **Azure** -- read AZURE.md for private link patterns (single workspace, hub-spoke), NCC setup, and Azure-specific DNS and networking gotchas.
- **AWS** -- read AWS.md for VPC endpoint patterns (backend-only, full frontend+backend), NCC setup, and AWS-specific IAM and routing gotchas.
- **GCP** -- read GCP.md for Private Service Connect (PSC) backend-only and full front+back patterns, service attachment lookup, DNS, and GCP-specific gotchas (UC API + PSC-backend-only limitation, the deprecated `ngrok-psc-endpoint` slot, public_access_enabled day-2 trap).

## Cross-links

- For workspace creation and infrastructure provisioning, see **platform-provisioning**.
- For Unity Catalog setup after workspace is provisioned, see **unity-catalog-setup**.
