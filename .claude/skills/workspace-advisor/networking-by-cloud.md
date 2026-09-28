# Networking and permissions by cloud

Load this file when the assessment involves a customer-managed network (Standard posture or higher), subnet sizing, private connectivity, egress, CMK, deployer IAM, or **any serverless connectivity requirement**.

Always use the customer's cloud vocabulary. Never assume parity.

Every cloud consumes approximately **2 IPs per classic compute node**. Serverless compute in a hybrid workspace does not consume customer-subnet addresses.

## Serverless connectivity options

Serverless connectivity has matured well beyond "no private networking." Check this matrix before concluding a requirement forces hybrid/classic — prefer the serverless path when it meets the need, because it is faster to launch and lower to operate. Label every Preview/Beta feature and apply the Preview-explanation rule from `SKILL.md`: state the status, explain the implications, and explain how it unblocks the customer's use case.

Foundation: a **Network Connectivity Configuration (NCC)** is an account-level object attached to one or more workspaces (**GA**, all clouds). It carries the serverless egress and private-endpoint rules below.

| Customer need | Serverless capability | AWS | Azure | GCP |
| --- | --- | --- | --- | --- |
| Stable egress IPs to allowlist | NCC stable IPs / service tag | GA — stable CIDR blocks | GA — `AzureDatabricksServerless` service tag or NCC | via Cloud NAT / PSC |
| Restricted / firewalled egress by domain | Serverless network policies (egress firewall) with dry-run | GA | GA | GA where available |
| Private egress to your cloud resources | NCC private endpoint rules | GA — PrivateLink + NLB | GA — private endpoint rules | **Public Preview** — outbound PSC |
| Private egress to on-premises / hub network | Routed private egress | via an NLB target that routes onward to on-prem | **Preview** — Private Network Gateway over ExpressRoute/VPN | **Preview** — Google NCC + Interconnect/VPN, propagation caveats |
| Private workspace UI/API (front-end) | Inbound (front-end) Private Link / PSC — independent of the compute model, so it applies to serverless-only workspaces | **GA** | **GA** | **GA** — inbound PSC |

Front-end (inbound) private connectivity is **compute-agnostic**: users reach the workspace UI/API the same way whether the workspace runs serverless or classic. That is why a serverless-only workspace can still have a private front end. Narrower advanced controls are still Beta — see the caveats.

This means a customer who needs **private front-end access**, **restricted egress**, or **private reach to their own resources** may not need a customer-managed network at all — serverless plus NCC, network policies, or inbound Private Link can satisfy several of these. Reconcile against the posture before defaulting to classic.

Limits and caveats to state plainly:

- Front-end private connectivity itself is GA, but some advanced ingress controls are Beta: **context-based ingress policies** (identity/network-source-aware access) and private access via a **custom "general access" URL**, plus private access to **account-level resources / unified login**. Front-end private access requires the Enterprise (AWS/GCP) or Premium (Azure) plan.
- **Full "no public access" privatization** of the compute-to-control-plane path additionally requires a **classic compute-plane Private Link** connection; front-end privacy for users does not. State this when a customer wants "fully private, nothing on the internet" with serverless.
- Serverless network policies cap at roughly 100 FQDNs and 100 storage destinations per policy (2500 total, account-level), with ~10-minute propagation.
- The Azure Private Network Gateway preview is REST-API-only (no UI/Terraform), same-region as the NCC, and limited in gateways and destinations.
- GCP serverless outbound PSC must be enabled as an account preview; serverless cannot use PSC to reach Google-managed services (GCS/BigQuery) — those use Private Google Access.
- The Databricks Terraform provider does not create serverless private endpoint rules today; create them in the account console/API.
- Stable egress is published as shared CIDR pools / service tags, not a single per-customer static IP.
- Always confirm GA status and regional availability for the customer's account before committing a Preview/Beta feature to a plan.

## Gated network questions

Run the gated network-implementation questions when the posture reaches Standard or higher, hybrid/classic is selected, or an existing landing zone applies. Ask only the applicable ones, one at a time. Never dump them all at once.

Skip gates:

- **Compute subnet size:** skip for serverless-only.
- **On-premises CIDRs:** ask only if on-premises connectivity is required.
- **Secondary-region CIDR:** ask only if the customer already raised DR. Do not mention a second region or secondary CIDR otherwise.
- **Dedicated private-endpoint subnet:** ask only at Private-storage-connectivity or higher.

Each question carries an *If unsure* gloss. Offer it whenever the customer hesitates, and route to their network team as a named readiness gap rather than guessing a CIDR or DNS answer.

- **Compute subnet size:** Roughly how large is classic compute at a busy time? Ask for S/M/L/XL, not an exact node count unless the customer already has one.
  - *If unsure:* This sizes the subnet, which is a hard ceiling on how many nodes can run. Pick a rough t-shirt size — a handful of analysts (S), one data team (M), several teams/heavy ETL (L), or platform-wide (XL). We bias upward because growing a subnet later is disruptive.
- **Existing CIDR/subnet plan:** Do you have a VPC/VNet CIDR and subnet plan, or do you need a recommendation?
  - *If unsure:* A CIDR is the private IP range the network uses (e.g. `10.4.0.0/16`). If your cloud/network team already assigns these, get theirs; otherwise we'll propose one. Answering "need a recommendation" is fine.
- **Subnet sizing:** Explain that subnet size is a hard compute ceiling and can be disruptive to change. What VPC/VNet CIDR and subnet sizes should be used?
  - *If unsure:* The subnet's size caps your maximum concurrent nodes (roughly 2 IPs per classic node). Too small and you hit a wall you can't easily move; we size for peak plus headroom. Our default recommendation is **/24 host and container subnets** (~120 nodes) unless you have a small fixed workload or a larger known peak — see the sizing bands and best-practice rules below.
- **Literal CIDR:** What literal CIDR should be used, or should one be proposed?
  - *If unsure:* The exact range to assign. If you don't own IP planning, we'll propose a non-overlapping range and your network team confirms it.
- **Overlap and IPAM:** Which cloud, hub/transit, and on-premises ranges must not overlap? Is there an IPAM registry?
  - *If unsure:* Overlapping IP ranges break routing between networks. An IPAM registry is the system your org uses to track which ranges are taken. If you don't know, your network team owns this — capture it as a gap.
- **On-premises CIDRs** (when on-premises connectivity is required): What are the on-premises CIDRs?
  - *If unsure:* The IP ranges of your data-center networks the workspace must reach. Needed so we pick a range that doesn't collide with them. Your network team has these.
- **Reserve ranges for other environments:** Is this the only workspace, or should ranges be reserved for dev/staging/prod or other workspaces?
  - *If unsure:* If you'll add more workspaces or environments later, we reserve address space now so they don't overlap. If it's genuinely a one-off, we size just for this one.
- **Secondary-region CIDR** (when DR is in scope): What non-overlapping CIDR will the secondary region use?
  - *If unsure:* For disaster recovery, the backup region needs its own range that doesn't overlap the primary. Only relevant if cross-region DR is in scope.
- **Egress path:** Central hub/transit with shared egress firewall, or standalone outbound?
  - *If unsure:* "Hub" means outbound traffic flows through a shared, inspected exit point your org already runs; "standalone" means this workspace has its own exit. If you have a cloud landing zone, it's usually hub. Ask your network team.
- **DNS ownership:** Who owns DNS, and can they create/delegate private zones or forwarding?
  - *If unsure:* Private connectivity depends on DNS resolving workspace hostnames to private addresses. We need the person/team who can create private DNS zones or forwarding rules. DNS is the most common cause of private-link failures, so identify the owner early.
- **Dedicated private-endpoint subnet** (Private-storage-connectivity or higher): Are dedicated private-endpoint subnets reserved separately from compute?
  - *If unsure:* Private endpoints (the private on-ramps to storage/control plane) usually sit in their own small subnet, separate from where clusters run, so they don't compete for addresses. If you haven't planned one, we'll size it.
- **Deployer network permissions:** Can the deployer create network resources, or is a separate cloud/network team required?
  - *If unsure:* Whether whoever runs Terraform has cloud permissions to create VPCs, subnets, endpoints, and DNS — or whether a separate network team must build those first. If unclear, assume a network team is involved and capture the handoff.

## Workload bands

Use the scale answer (people/teams) to suggest a band, then confirm:

| Band | Recognition | Planning nodes |
| --- | --- | ---: |
| S | A handful of analysts; mostly SQL/dashboards | 32 |
| M | One data team; mixed notebooks and jobs | 128 |
| L | Several teams or concurrent ETL | 200 |
| XL / unknown | Platform-wide or leave room to grow | 500 |

Skip the compute-subnet-size question for serverless-only. If the customer already has a numeric peak, use it. Subnet size is a hard ceiling; bias upward.

## Subnet sizing rules

Keep the platform's **hard limits** (verified against the Databricks docs) separate from **our recommended best practice**. State which is which to the customer — a limit is non-negotiable; a recommendation is our advice they can adjust.

### Platform hard limits (do not violate)

- **AWS:** workspace subnet netmask **/17–/26**; at least **two subnets in separate availability zones** (and no more than one workspace subnet per AZ); the **VPC netmask is not constrained** by Databricks but must contain the subnets; AWS reserves **5 IPs per subnet**; **2 IPs per node** (one for management/host, one for the Spark container).
- **Azure:** VNet **/16–/24**; two subnets (host and container) delegated to `Microsoft.Databricks/workspaces`; subnet **hard minimum /28**; Azure reserves **5 IPs per subnet**; **2 IPs per node** (one host, one container). After **March 31, 2026**, new VNets need an explicit outbound method such as a NAT gateway.
- **GCP:** one subnet with one primary IP range (no secondary ranges or delegation); Google reserves **4 IPs per subnet**; **2 IPs per node**. Approximate maximum nodes: /25→60, /24→120, /23→250, /22→500, /21→1000, /20→2000, /19→4000.

### Recommended best practice (our guidance — size up front)

- **Default to /24 for the host and container (driver/executor) subnets.** A /24 supports roughly 120 nodes per subnet, leaves headroom to grow, and avoids the disruptive re-size a smaller subnet forces (subnet size is a hard ceiling and cannot be changed in place). This is our recommendation, one step larger than Azure's documented /26 floor and /28 minimum — hold to /24 unless the customer confirms a small, fixed workload, and **size up (/23, /22, …) for larger peaks** per the node math above and the workload bands.
- Keep the host and container subnets **equal in size** (Azure).
- Bias the **VNet/VPC up to /16–/20** so multiple non-overlapping workspace subnets (dev/staging/prod) and a private-endpoint subnet fit without renumbering later.
- Reserve a separate **~/27 private-endpoint subnet** at Private-storage-connectivity or higher, kept apart from compute (Azure/GCP).
- Confirm the **current Databricks-reserved CIDR ranges** in the AWS customer-managed VPC docs before finalizing, and avoid overlap with them and with hub/on-prem ranges. (Historically Databricks has reserved internal ranges such as `10.139.0.0/16`; verify the current list rather than assuming.)

## Worked sizing examples: 200 classic nodes

AWS:

```text
200 nodes x 2 IPs + 5 reserved = 405 IPs per workspace subnet.
Recommend /23 per subnet.
AWS requires at least two subnets in different AZs.
A /23 supports approximately 253 nodes.
```

Azure:

```text
200 nodes x 2 IPs + 5 reserved = 405 IPs per delegated subnet.
Recommend equal /23 host and container subnets.
Use a /16–/24 VNet and add a private-endpoint subnet at Private-storage-connectivity or higher.
```

GCP:

```text
For 200 nodes, use at least a /23 primary range (up to approximately 250 nodes).
GCP uses one subnet with one primary range; no secondary ranges or delegation.
```

## AWS requirements

- **Network model:** customer-managed VPC with VPC injection and at least two subnets across AZs.
- **Private connectivity (Private-storage-connectivity or higher):** AWS PrivateLink with workspace and SCC relay interface endpoints. Set no-public-IP/NPIP and disable public access when required.
- **Browser authentication:** no separate endpoint; browser and REST share the workspace endpoint.
- **Private DNS:** Route 53 private hosted zones/records associated with the VPC.
- **Egress:** NAT for standard classic control-plane traffic; for Restricted egress or higher use Transit Gateway plus an inspection VPC or AWS Network Firewall.
- **CMK:** AWS KMS; the cross-account role requires decrypt, data-key generation, and key-description permissions.
- **Deployer IAM:** VPC, subnet, security group, VPC endpoint, Route 53, PassRole, and KMS permissions when in scope.

## Azure requirements

- **Network model:** VNet injection with host and container subnets delegated to `Microsoft.Databricks/workspaces`.
- **Private connectivity (Private-storage-connectivity or higher):** `databricks_ui_api` and `browser_authentication` private endpoints.
- **Browser authentication:** only one browser-authentication endpoint per region per private DNS zone.
- **Private DNS:** `privatelink.azuredatabricks.net`.
- **Public access:** disable Public Network Access when private-only access is required.
- **Egress:** Azure Firewall/NVA in a hub VNet with UDRs for Restricted egress or higher. New private VNets need an explicit outbound method.
- **NSGs:** retain the Microsoft-provided Databricks rules on delegated subnets.
- **CMK:** Key Vault plus an Access Connector managed identity with the required crypto role.
- **Deployer IAM:** VNet, NSG, private endpoint, private DNS, Databricks workspace, and Key Vault write permissions when in scope.

## GCP requirements

- **Network model:** customer-managed VPC injection with one subnet and one primary IP range.
- **Private connectivity (Private-storage-connectivity or higher):** Private Service Connect service attachments, reserved internal addresses, forwarding rules, and private Cloud DNS.
- **Browser authentication:** DNS A record, not a separate endpoint object.
- **Serverless private reach:** GCP serverless can privately reach customer-managed VPC resources via **outbound Private Service Connect (Public Preview)** — expose the target behind an internal load balancer / service attachment and add an NCC private endpoint rule. On-premises is reachable through Google NCC plus Cloud Interconnect/VPN, subject to PSC/NCC propagation caveats. Serverless cannot use PSC to reach Google-managed services (GCS/BigQuery); those use Private Google Access. This is no longer a hard conflict — apply the Preview-explanation rule: state that it is Public Preview, note it must be enabled in the account console and that the Terraform provider does not create the private endpoint rule, explain how it unblocks the customer's serverless use case, and confirm GA/region with the account team. If the customer needs a GA private path today, offer hybrid/classic as the alternative.
- **Egress:** Cloud NAT for stable egress; Cloud NGFW/firewall policy for Restricted egress or higher.
- **CMK:** Cloud KMS; the workspace service account needs encryption/decryption access to the key.
- **Deployer IAM:** VPC, subnet, firewall, address, forwarding-rule, Cloud DNS, service-account-policy, and KMS-policy permissions when in scope.

## DNS is the primary failure source

For private connectivity, the workspace, relay, storage, and browser-auth hostnames must resolve to private endpoint addresses from the correct networks.

Before implementation, confirm:

- named DNS owner
- private-zone creation/delegation rights
- forwarding between on-premises, hub, and spoke resolvers
- no split-horizon records pointing clients to public endpoints
- endpoint records exist before public access is disabled

The `private-networking` skill owns the implementation details and remote-mutation approval gate.
