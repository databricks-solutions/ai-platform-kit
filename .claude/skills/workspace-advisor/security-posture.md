# Security posture

Load this file for the posture-determination logic, the plain-language posture ladder, industry ranges, or the entry lens.

Recommend the **least private posture that satisfies the customer's actual regulatory, data-sensitivity, and risk requirements.** More private is not automatically better; each added control carries cost, build complexity, and operational overhead. Express the recommendation in plain language — the controls the posture includes — not a code the reader has to decode.

## How to determine the posture

**The recommended posture is the most private baseline any requirement demands, plus every added control any requirement triggers, plus customer-managed keys when required.** Work through the drivers below, take the most private one, and layer on the others.

Postures are **cumulative**: a more private posture includes every control below it. A single strong requirement therefore pulls in all the lower controls — for example, restricted-only egress brings private front-end access and private storage and back-end paths with it, even if those were not separately requested. When one requirement drives the posture well above the others, say so in the decision record rationale so the customer understands the added scope and cost, and confirm that driving requirement is real rather than assumed.

Drivers, from the answers gathered in `question-bank.md`:

- **Data sensitivity:**
  - Public → serverless or Standard baseline is sufficient.
  - Confidential → at least **Standard** (customer-managed network with Secure Cluster Connectivity).
  - Regulated → at least **Fully private** (private front-end).
  - Classified → **No-internet isolation**.
- **Private front-end access required** (users reach the UI/API over a private network only) → **Fully private** (private front-end).
- **Existing SaaS private-connectivity pattern** (org already requires VPN/Private Link to other SaaS) → at least **private storage/back-end connectivity**.
- **Egress policy:**
  - Restricted-only (firewalled outbound) → **Restricted egress**.
  - No outbound internet → **No-internet isolation**.
  - Yes (open outbound) → no floor.
- **Network isolation mandate** (air-gapped, sovereign, or classified) → **No-internet isolation**. Overrides the egress answer and applies regardless of other answers; it is the mandate/attestation layer on top of the same no-internet control.
- **Customer-managed network** (the customer chose hybrid/classic compute) → at least **Standard**. Hybrid/classic requires a customer-managed VPC/VNet and IaC, so it can never be a Sandbox — this blocks the Sandbox rule even for a POC.
- **Customer-managed keys (CMK):** an **add-on layer applied to any posture**, not a posture of its own. Record it as an added encryption control and note it in the decision record (for example, "Fully private + CMK").
- **Sandbox (no IaC):** recommend only after working through the drivers above, and only when **all** of these hold:
  - it is a POC/evaluation, not production;
  - the customer is not using Terraform today and does not want this kit to deploy with Terraform;
  - compute is serverless (a customer-managed network cannot be a Sandbox);
  - no more-private driver fired — no private front-end, no existing-SaaS-private-connectivity requirement, no restricted/no-internet egress, no isolation mandate, and data is not Confidential/Regulated/Classified.
  - The Public data-sensitivity level does not by itself block Sandbox when the conditions above hold. If any more-private driver fired, keep the higher posture and treat IaC as required.

**Compute model is the implementation, not the posture.** Set the posture from the requirements above, then choose the compute model that meets it. Serverless is the preferred implementation whenever it can meet the required posture, because it is faster to launch and lower to operate. Serverless can satisfy several private-connectivity controls **without a customer-managed network**:

- **private front-end access** via inbound (front-end) Private Link — GA and compute-agnostic, so it works with serverless-only workspaces;
- **private egress to your own cloud resources** via NCC private endpoints — GA on AWS/Azure, Public Preview on GCP;
- **restricted/firewalled egress** via serverless network policies — GA.

State the Preview/Beta caveat where one applies (GCP private egress, on-premises gateways, and advanced ingress controls are Preview/Beta; full "no public access" of the compute path also needs a classic compute-plane Private Link). Move to hybrid/classic only when the posture needs a GA guarantee serverless cannot yet provide, when compute must run in the customer tenant, or when strict residency or air-gap isolation requires it. The customer-managed-compute controls in the ladder below (Secure Cluster Connectivity / no-public-IP and the back-end compute-to-control-plane path) do not apply to serverless, where Databricks manages the compute plane.

Do not let a directional industry range override explicit data classification, contractual obligations, or security policy.

## Worked examples

Regulated data, private front end, and CMK:

```text
Recommended posture: Fully private (private front-end) + customer-managed keys
Driving requirements:
  - Data sensitivity: Regulated → Fully private
  - Private front-end access required → Fully private
Added layer: customer-managed keys (CMK required).
```

Network isolation mandate with CMK:

```text
Recommended posture: No-internet isolation + customer-managed keys
Driving requirements:
  - Data sensitivity: Confidential → Standard
  - Network isolation mandate (air-gapped/sovereign) → No-internet isolation
Added layer: customer-managed keys (CMK required).
```

Serverless requested and a regulated-data requirement fired:

```text
Recommended posture: Fully private (private front-end)
Driving requirements:
  - Data sensitivity: Regulated → Fully private
Implementation: serverless can meet this posture — inbound/front-end Private
Link (GA, compute-agnostic) for private UI/API, plus NCC private endpoints
(GA on AWS/Azure) for private egress. Note that advanced ingress controls
(context-based ingress, custom-URL access) are Beta, and full "no public access"
of the compute path also needs a classic compute-plane Private Link. Confirm
regional availability with the account team.
```

POC with no Terraform and no more-private requirement:

```text
Recommended posture: Sandbox (no IaC)
Driving requirements:
  - POC + not using Terraform + kit will not deploy with Terraform + serverless
    + no more-private driver fired → Sandbox
Customer-managed keys, if required, are recorded as an encryption control; the
posture stays Sandbox.
```

Hybrid/classic POC — the customer-managed network blocks Sandbox:

```text
Recommended posture: Standard (customer-managed network)
Driving requirements:
  - Data sensitivity: Public → serverless/Standard baseline
  - Customer-managed network (hybrid/classic) → Standard
Sandbox does not apply: hybrid/classic requires a customer-managed network and IaC.
```

No outbound internet without a formal isolation mandate:

```text
Recommended posture: No-internet isolation
Driving requirements:
  - Data sensitivity: Confidential → Standard
  - Egress policy: No outbound internet → No-internet isolation
No isolation mandate was asserted, but "no outbound internet" reaches the same
no-internet control.
```

## Posture ladder

Least to most private. Each rung adds its control on top of the ones above it.

| Posture | Architecture | Added control | Typical use |
| --- | --- | --- | --- |
| Sandbox (no IaC) | Manual / UI or managed locked network | No IaC | POC, sandbox, no Terraform capability |
| Serverless baseline | Serverless | Managed compute-plane networking | Fast time-to-value, non-sensitive data |
| Serverless + controlled connectivity | Serverless + NCC | Stable egress or private connectivity | Serverless needing controlled connectivity |
| Standard | Customer-managed network | Secure Cluster Connectivity / no public IP | Standard enterprise production |
| Private storage connectivity | Standard + private storage | No public storage exposure | Sensitive data at rest |
| Private backend | + back-end private connectivity | Private compute-to-control-plane path | Regulated workloads |
| Fully private (private front-end) | + front-end private connectivity | Private workspace UI/API | No-public-ingress environments |
| Restricted egress | Fully private + egress firewall | Restricted outbound access | Controlled production egress |
| No-internet isolation | Fully private + no internet | Full isolation | Classified/sovereign workloads |

**Customer-managed keys (CMK)** layer on top of any posture above — record them as an added control (for example, "Restricted egress + CMK" or "No-internet isolation + CMK"), not as a separate rung.

The **Architecture** column describes the classic / customer-managed *reference* implementation of each posture. The posture is the security outcome; classic and serverless are two implementations of it. Serverless meets several of these postures by other means without a customer-managed network — inbound (front-end) Private Link for the front-end control (Fully private), NCC private endpoints for private storage/resource connectivity (Private storage connectivity), and serverless network policies for restricted egress (Restricted egress). The Standard / Private-storage / Private-backend rungs that describe the customer *compute plane* (Secure Cluster Connectivity / no-public-IP, the back-end compute-to-control-plane path) do not apply to serverless, where Databricks manages the compute plane. Postures that require compute in the customer tenant, or full air-gap / no-internet isolation, remain classic/isolated — serverless does not meet those.

## Industry alignment

Directional only:

| Industry | Typical posture range | Notes |
| --- | --- | --- |
| Financial Services | Fully private → No-internet isolation, usually with CMK | PCI-DSS/SOX; private connectivity and CMK are common |
| Healthcare / Life Sciences | Fully private and up, often with CMK | PHI commonly drives private connectivity and CMK |
| Public Sector | Restricted egress → No-internet isolation, with CMK | FedRAMP, sovereign, and isolation mandates |
| Manufacturing & Energy | Standard → Restricted egress | OT/IT separation and controlled egress |
| Retail & Consumer Goods | Serverless + controlled connectivity → Private storage | PCI subsets; otherwise velocity and baseline controls |
| Media / Communications / Games | Serverless baseline → Standard | Elasticity and time-to-value |
| Digital Natives | Sandbox → Standard | Cloud-native; posture follows data sensitivity |

## Entry lens

- **Serverless → serverless baseline, higher postures via NCC:** fastest to launch and no infrastructure to manage. With NCC private endpoints, serverless network policies, and inbound (front-end) Private Link (GA and compute-agnostic), it can meet many private-connectivity and restricted-egress requirements without a customer-managed network — prefer it when it meets the posture, and see the serverless connectivity matrix in `networking-by-cloud.md`. It may still not satisfy compute-in-tenant or strict-residency requirements.
- **Customer-managed network + Secure Cluster Connectivity → Standard:** common first-production landing point; retains a path to private connectivity and controlled egress.
- **Customer-managed network + private connectivity → Private storage / Private backend / Fully private:** higher control with greater deployment and operating complexity.
- **CMK additions:** layer onto any posture; record the added control without changing the posture name.
- **Managed locked network → Sandbox:** only for POC/sandbox with no Terraform and no more-private requirement. Cannot be retrofitted to customer-managed networking without redeploying.
