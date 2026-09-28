# Question bank, flow, conflicts, and decision record

This file is the authoritative assessment flow. Ask **one question at a time**, and refer to each question by its plain-language topic — never invent a code for it.

Before asking anything, **harvest what the customer already provided** and mark those topics as provisionally answered. Then ask only the open topics — never re-ask a settled question. Maintain a running captured / open / conflicting ledger across phases.

**Accept batched answers.** If the customer volunteers several answers in one message, record all of them; one-question-at-a-time governs how you ask, not how much you accept.

**Explain when the customer is unsure.** Each technical question below carries an *If unsure* gloss — a plain-language explanation, the tradeoff, and the typical choice. Offer it whenever the customer answers "I don't know," asks what a term means, or seems confused. Never record "unknown" without first offering the explanation.

Terraform maturity and disaster recovery are customer-led. By default ask only the two Terraform-baseline questions (using Terraform today, and whether the kit should deploy) and never raise DR. See `terraform-and-dr.md` only after the corresponding trigger.

## Default question bank

### Business context

- **Company or project name:** What is your company or project name?
- **Industry:** What industry best describes your organization? (Financial Services / Healthcare & Life Sciences / Communications, Media & Entertainment, Gaming / Manufacturing / Retail & Consumer Goods / Public Sector / Digital Natives)
- **Subvertical:** Which subvertical applies?
- **Scale:** How many people or teams will use this workspace?
- **Origin:** Is this greenfield, an on-premises migration, or a cloud-platform migration?
- **Existing workspaces:** Do you already have Databricks workspaces deployed? If yes, how are they deployed and managed?
- **Respondent role:** What is your role/title? (Executive/Sponsor / Security or Compliance / Platform or Infrastructure / Data or Platform Engineer / Cloud or Network Architect / Other)
- **Sponsors:** Who are the key leaders or stakeholders sponsoring and approving this initiative?
- **Technical owner:** Will the respondent execute Terraform and own the network build? If not, who is the technical owner?

The respondent role changes explanation depth, not the recommendation. Sponsors and technical owner populate named ownership.

### Cloud platform

- **Cloud provider:** Which cloud provider will host this workspace? (AWS / Azure / GCP / Multiple)
- **Multi-cloud strategy** (when Multiple): Are these independent deployments or a unified multi-cloud strategy?
- **Region:** Which cloud region should host this workspace?
- **Landing zone:** Must the workspace fit into an existing landing zone?

Lock the cloud provider before downstream network/security questions and use only that cloud's vocabulary. Ask the region after the cloud provider (and the multi-cloud strategy question when the answer is Multiple).

### Environment strategy

- **Environments:** Is this a single workspace, or do you need separate environments such as dev, staging, and production?
- **Production vs POC:** Is this a proof-of-concept or evaluation, or a production workspace that must be hardened?

### Terraform baseline

- **Terraform today:** Are you using Terraform to deploy infrastructure today?
- **Deploy with this kit:** After the architecture is approved, do you want this kit to deploy it with Terraform, or do you only need the architecture decision record?

Ask these two one at a time. The deploy-with-this-kit answer controls the implementation handoff: Yes routes the approved record to `platform-provisioning`; No ends the workflow after record approval with no deployment. Do not ask the Terraform-maturity questions unless the customer requests Terraform-specific guidance.

### Compute model

- **Compute model:** Would you like a serverless workspace or a hybrid workspace?
  - Azure: say **serverless or hybrid**.
  - AWS/GCP: say **serverless or classic**, then explain classic is hybrid: classic clusters run in the customer's VPC/VNet and serverless remains available.
  - Serverless means managed compute/networking and no customer VPC/VNet for classic clusters.
  - Hybrid means customer-managed networking plus classic and serverless compute.
- **Stable egress IPs** (serverless): Do you need stable egress IPs to allowlist on downstream firewalls? (Private *reach* to your own resources is the serverless private-reach question below — do not ask it here.)
  - *If unsure:* "Stable egress IPs" means outbound traffic leaves from a fixed set of addresses you can allow-list on other systems' firewalls. Needed when a partner or database restricts access by IP. If nothing downstream filters by IP, you don't need it. Selecting this moves serverless from the baseline to serverless-with-controlled-connectivity (adds an NCC). These are shared CIDR pools / service tags, not a single static IP.
- **Accept customer-managed network** (hybrid/classic): Do you accept managing a customer VPC/VNet?
  - *If unsure:* Hybrid/classic runs compute inside a network you own and operate — more control, but your team maintains the VPC/VNet, subnets, and routing. If you don't want that operational burden, serverless avoids it. Required for hybrid/classic; drives at least a Standard posture.
- **Serverless private reach** (serverless): Must serverless privately reach a resource in your own cloud network or on-premises?
  - *If unsure:* Whether serverless jobs must connect privately (not over the public internet) to a database or service in your own network. If your data sources are all cloud-managed or internet-reachable, the answer is usually No. The status differs by target:
    - **Your cloud VPC/VNet resources:** NCC private endpoints — GA on AWS (PrivateLink+NLB) and Azure (private endpoint rules), Public Preview on GCP (outbound PSC).
    - **On-premises:** Preview — Azure via the Private Network Gateway (ExpressRoute/VPN); GCP via Google NCC + Cloud Interconnect/VPN; AWS via an NLB target that routes onward. Apply the Preview-explanation rule for the on-prem paths.
    Do not treat any of these as a hard blocker. (If on-prem reach is the need, the on-premises-connectivity question captures the requirement — reconcile with it rather than asking twice.)
- **Serverless private-reach target** (when serverless private reach is Yes): What is the exact target domain and internal IP, and is a load balancer (AWS NLB / Azure Standard LB / GCP internal LB or service attachment) already present?
  - *If unsure:* We need the hostname and internal IP of the resource serverless must reach, and whether a load balancer already fronts it (serverless private reach is published through an internal LB / service attachment). If you don't know, your network team will — flag it as a gap rather than guessing.
- **Private front-end on serverless** (serverless and private front-end access is required): Do you need the workspace UI/API reachable privately while staying serverless?
  - *If unsure:* Inbound (front-end) Private Link/PSC keeps the login/API off the public internet, and it is **independent of the compute model — so it works with a serverless-only workspace (GA)**. This lets serverless satisfy the private-front-end requirement without a customer-managed network. Caveats: advanced ingress controls are Beta (context-based ingress policies; private access via a custom "general access" URL), and full "no public access" of the compute-to-control-plane path additionally requires a classic compute-plane Private Link. Front-end privacy for users is GA (Enterprise/Premium plan).
- **Restricted egress on serverless** (serverless and egress policy is Restricted-only): Do you want restricted egress enforced on serverless by domain/FQDN?
  - *If unsure:* Serverless network policies (egress firewall) restrict outbound traffic to an allowlist of domains and storage destinations, with a dry-run mode to audit first. This is **GA** and lets serverless satisfy restricted egress without a customer-managed firewall. Limits: ~100 FQDNs and 100 storage destinations per policy.

For the serverless connectivity questions, prefer the serverless path when it meets the need. Only recommend hybrid/classic when the requirement needs a GA guarantee that serverless cannot yet provide, or when another requirement already forces a customer-managed network. See the serverless connectivity matrix in `networking-by-cloud.md`.

### Network and connectivity

- **Private front-end access:** Must users access the workspace UI and API over a private network only?
  - *If unsure:* This decides whether the workspace login/API is reachable from the public internet or only from your corporate network (VPN/private link). Private-only is more secure but adds DNS and connectivity setup. Most regulated customers require it; most others start public with IP allow-listing. Drives a Fully-private posture.
- **Existing SaaS private connectivity:** Does the organization require VPN/Private Link to other SaaS applications today?
  - *If unsure:* Asking whether you already connect to other SaaS tools over private links rather than the open internet — a sign your network team expects the same here. If they already do this elsewhere, the answer is usually Yes. Drives at least private storage/back-end connectivity.
- **Egress policy:** Does the workspace need outbound internet? (Yes / Restricted-only / No)
  - *If unsure:* Whether workloads can reach the internet for package installs, APIs, and data sources. "Yes" is simplest; "Restricted-only" routes egress through a firewall (Restricted egress); "No" means fully isolated (No-internet isolation). Most production picks Yes or Restricted-only.
- **Isolation mandate:** Is full network isolation mandated (air-gapped, sovereign, or classified)?
  - *If unsure:* "Air-gapped" means no internet path at all; usually driven by a government, defense, or sovereignty mandate. If no regulator or contract requires it, the answer is No. Forces No-internet isolation and overrides other network choices.
- **On-premises connectivity:** Is on-premises connectivity required?
  - *If unsure:* Whether the workspace must reach systems in your own data center (databases, file shares) over VPN or a dedicated link. Yes if data or apps still live on-prem. If Yes, we will also need your on-premises CIDR ranges (see the gated network detail).

### Security posture

- **Private source repos:** Must the workspace reach private source-code repositories?
  - *If unsure:* Whether notebooks/jobs pull code from an internal Git server that isn't on the public internet (e.g. self-hosted GitHub/GitLab). Yes if your repos are behind the firewall. Interacts with the egress policy.
- **Data sensitivity:** What data sensitivity will it process? (Public / Confidential / Regulated / Classified)
  - *If unsure:* Public = open/marketing data; Confidential = internal business data; Regulated = data under a law or contract (PHI, cardholder, PII); Classified = government-classified. Pick the highest class any data in the workspace falls under. This is the biggest posture driver: Public → serverless/Standard baseline, Confidential → Standard, Regulated → Fully private, Classified → No-internet isolation.
- **Customer-managed keys:** Are customer-managed encryption keys required?
  - *If unsure:* By default Databricks encrypts data with keys it manages. Customer-managed keys (CMK) let you own and revoke the key yourself — usually required for sovereignty or strict compliance, at the cost of extra key-management setup. If no policy demands it, default keys are fine. CMK is an add-on layer on top of any posture, not a posture of its own.
- **IP access lists:** Are IP access lists needed in addition to or instead of private connectivity?
  - *If unsure:* IP allow-lists restrict workspace access to known office/VPN IP ranges. They're a lighter-weight control than private networking and often used together with it, or on their own for public workspaces. Most customers want at least this.
- **Log delivery:** Must audit or billable-usage logs be delivered to the customer's SIEM?
  - *If unsure:* Whether your security team needs Databricks audit and cost logs streamed into their monitoring system (Splunk, Sentinel, etc.). Common in regulated orgs; creates a logging workstream but doesn't change the posture.
- **Compliance frameworks:** Which compliance frameworks or residency requirements apply? (HIPAA / PCI-DSS / FedRAMP / SOC 2 / data residency / None)
  - *If unsure:* Name any regulation or contract that governs this data or where it may physically reside. HIPAA (health), PCI-DSS (payment cards), FedRAMP (US gov), SOC 2 (general security attestation), data residency (must stay in a region/country). If none applies, answer None. Should line up with the data sensitivity above.

### Identity

- **SSO/SCIM:** Are SSO/SAML and SCIM provisioning configured today?
  - *If unsure:* SSO/SAML lets users log in with your corporate identity provider (Okta, Entra ID); SCIM auto-syncs users and groups so access is granted and revoked centrally. "Configured today" means already set up for other apps. Most enterprises have this; if not, it becomes a setup task.

SSO/SCIM creates an identity workstream but does not change the posture.

### Gated network detail

When the posture reaches Standard or higher, hybrid/classic is chosen, or an existing landing zone applies, read `networking-by-cloud.md` and ask the gated network-implementation questions. Do not dump them all at once. Skip the compute-subnet-size question for serverless-only. Ask the on-premises-CIDR question only if on-premises connectivity is required. Ask the secondary-region-CIDR question only if DR is already in scope. Ask the dedicated-private-endpoint-subnet question only at Private-storage-connectivity or higher.

### Customer-led Terraform

Only after the customer raises Terraform-specific topics, read `terraform-and-dr.md` and ask:

- **Terraform experience:** Does the organization have experienced Terraform engineers?
- **Remote state and CI/CD:** Is remote state with locking and CI/CD available?
- **Reuse across environments:** Must configuration be reusable across environments or business units?

### Customer-led disaster recovery

Only after the customer raises DR, read `terraform-and-dr.md` and ask:

- **Outage impact:** Would a multi-hour/day regional outage cause unacceptable impact?
- **RTO/RPO documented:** Are business-approved RTO and RPO documented?
- **Cross-region mandate:** Is cross-region recovery contractually or regulatorily required?
- **Near-zero RTO:** Is near-zero RTO required, with dual-run capacity?
- **Second-workspace commitment:** Can the organization fund, operate, and regularly test a second workspace?

## Recommended flow

0. Harvest everything already provided, mark those topics captured, reflect them back for confirmation, and skip them wherever they appear below. Ask only open topics.
1. Collect the business context. Use the respondent role for depth and the sponsors/technical-owner answers for ownership.
2. Collect the cloud provider, the multi-cloud strategy if needed, the region, then the landing zone. Lock cloud vocabulary after the provider is known.
3. Collect the environment strategy (environments, production vs POC).
4. Ask the two Terraform-baseline questions one at a time. Do not initiate the Terraform maturity assessment.
5. Skip DR entirely unless the customer raised it.
6. Ask the compute model. For serverless, ask stable egress IPs, then serverless private reach (and the private-reach target when that is Yes). For hybrid/classic, confirm the customer accepts a customer-managed network. Prefer serverless where it meets the need; GCP private reach is Public Preview, not a hard conflict.
7. Ask the network-and-connectivity and security-posture questions. If serverless is the path, ask about a private front-end on serverless when private front-end access is required, and about restricted egress on serverless when the egress policy is Restricted-only, and confirm whether a serverless connectivity feature satisfies private front-end access, restricted egress, or private resource reach before concluding a customer-managed network is required.
8. Determine the posture using `security-posture.md`.
9. When the posture reaches Standard or higher, hybrid/classic is chosen, or an existing landing zone applies, use `networking-by-cloud.md` for the gated network-implementation questions. Never ask the secondary-region-CIDR question unless DR is already in scope.
10. Ask about SSO/SCIM. If the customer wants this kit to deploy, ask for the resource `<prefix>` if it is still unknown.
11. Run all conflict checks below.
12. Present the Unified Decision Record and obtain corrections or approval.

Customer-led detours:

- If the customer asks about Terraform implementation maturity, insert the Terraform-maturity questions, classify maturity, then return to the default flow.
- If the customer raises DR, insert the DR gate. If it clears, capture the near-zero-RTO, second-workspace, and secondary-region-CIDR answers, then return to the default flow.

## Conflict checks

Treat answers as provisional. Surface a conflict and ask one targeted follow-up.

| Conflict | Clarifying question | Related questions |
| --- | --- | --- |
| Declines serverless and customer-managed networking | A hybrid/classic workspace requires a customer-managed network. Reconsider serverless, or scope VPC/VNet ownership? | Compute model; accept customer-managed network |
| No internet but needs private Git with no private path | Private Link to the Git provider, an internal mirror, or reconsider outbound policy? | Egress policy; private source repos; existing SaaS private connectivity |
| Industry implies a high posture but data is Public | Can you confirm the actual data classification and contractual requirements? | Industry/subvertical; data sensitivity |
| Full isolation but serverless with no NCC | Use serverless+NCC with no external access, or classic with no-internet networking? | Isolation mandate; compute model; stable egress IPs |
| Serverless private reach on GCP | GCP serverless-to-VPC private reach is Public Preview (outbound PSC): confirm GA/region and account-preview enablement, or use hybrid/classic for a GA path today. Not a hard conflict. | Serverless private reach; cloud provider |
| Low Terraform maturity but requests modular multi-environment IaC | Start with a template and grow into modules, or bring support to build modules from day one? | Terraform experience; reuse across environments |
| Compliance framework differs from industry expectation | Is the requirement driven by a contract, subsidiary, or specific data type? | Industry; compliance frameworks |
| DR considered but no approved RTO/RPO | Define business-approved objectives before selecting a strategy. | Outage impact; RTO/RPO documented |
| On-premises required but CIDR unknown | Obtain the range before finalizing CIDR and routing. | On-premises connectivity; on-premises CIDRs |
| Small CIDR conflicts with workload band | Size up now, or confirm the lower long-term capacity ceiling? | Compute subnet size; workload band |
| POC/no-IaC implies Sandbox but a more-private requirement fired | Keep the higher posture and use IaC, or confirm the workload is truly a non-sensitive sandbox? | Production vs POC; Terraform baseline; data sensitivity |
| Hardened production depends on a Preview/Beta serverless feature | Confirm GA and regional availability with the account team; accept the Preview risk, or use the classic/private GA path for that control. | Production vs POC; serverless private reach; private front-end on serverless; restricted egress on serverless |

If the customer disagrees after the recommendation, reopen only the related questions rather than restarting the assessment.

## RACI

R = Responsible, A = Accountable, C = Consulted, I = Informed.

| Activity | Platform Eng. | Security | Cloud/IAM Ops | Sponsor/CDO |
| --- | --- | --- | --- | --- |
| Define posture, CMK, compliance, network controls | C | A/R | C | I |
| Own Terraform modules and repository | R | C | A | I |
| Approve production applies | I | A/R | C | I |
| Manage cloud identity/IAM | C | C | A/R | I |
| Own state backend and secrets vault | I | C | A/R | I |
| Fund and prioritize initiative | C | C | I | A/R |
| Qualify and own DR | C | A/R | C | A |

Replace role labels with the named people captured for sponsors and technical owner.

## Readiness checklist

Before committing to a deployment date, identify gaps in:

- named platform/infrastructure owner
- security representative in review and approval
- executive sponsor
- protected Git repository and mandatory review
- documented production change-management process
- remote state with locking
- CI/CD pipeline
- short-lived/federated pipeline credentials
- secrets vault
- shared/versioned module strategy where required
- approved security posture
- naming, tagging, landing-zone, IPAM, and DNS standards

## Unified Decision Record

Create one record per workspace:

| Field | Entry |
| --- | --- |
| Company / workspace name | |
| Primary contact and role | |
| Sponsors, approver, technical owner | |
| Industry / subvertical | |
| Cloud / region | |
| Multi-cloud strategy (if asked) | |
| Existing landing zone | |
| Environment strategy | |
| Using Terraform today | |
| Terraform deployment requested | |
| Compute: Serverless / Serverless+NCC / Hybrid | |
| Serverless connectivity: private egress, egress firewall, front-end Private Link | |
| Preview/Beta features relied on, and GA/region confirmation status | |
| Data sensitivity | |
| Driving requirements and added CMK layer | |
| Recommended posture (in plain language) | |
| Key rationale with the driving requirements | |
| Network posture | |
| CIDR, subnet plan, workload band/nodes, overlap result | |
| Unity Catalog requirements | |
| Identity / SSO / SCIM requirements | |
| Logging, encryption, compliance, and tags | |
| Confirmed resource `<prefix>` | |
| Outstanding readiness gaps and conflicts | |
| Named owners (RACI) | |
| Approver and date | |

Optional addenda, only when customer-led:

| Field | Entry |
| --- | --- |
| Terraform maturity level | |
| Local or Git-controlled deployment | |
| Template or modularized resource strategy | |
| DR gate: Qualifies / Does not qualify | |
| DR strategy, RTO/RPO, secondary CIDR | |

Ask the customer to correct or explicitly approve the record. Hand it to implementation only when the customer wants this kit to deploy with Terraform.
