# GCP Platform Provisioning

Cloud-specific guidance for provisioning Databricks workspaces on GCP. This file is split into three focused topic files — read the one that matches what you're doing.

## When to read which

| Topic | Read | Triggers |
|---|---|---|
| Authentication | [`gcp-1-auth.md`](gcp-1-auth.md) | Setting up Terraform; "Failed to get oauth access token"; deciding between `google-id` / `google-credentials` / SP / U2M |
| Deploy patterns | [`gcp-2-deploy.md`](gcp-2-deploy.md) | Workspace creation; HYBRID vs SERVERLESS; managed VPC vs BYOVPC; resource composition |
| Gotchas | [`gcp-3-gotchas.md`](gcp-3-gotchas.md) | Apply failures; CMEK timing; `custom_tags` errors; orphan metastores; tier availability |

## At a glance

- **Auth: `google_service_account` + `auth_type = "google-id"` is the only TF-supported pattern that works for `databricks_mws_workspaces`.** AWS-style M2M client_id/secret does NOT work on GCP; U2M cached tokens don't work either. See [`gcp-1-auth.md`](gcp-1-auth.md).
- **Workspace Creator SA needs 5 project roles:** editor + serviceAccountAdmin + projectIamAdmin + iam.roleAdmin + compute.networkAdmin. Plus `account_admin` on the Databricks account (register the SA email as an account user via SCIM, not as a service principal).
- **GCE-based compute (not GKE).** Classic compute runs as Google Compute Engine VMs in the customer project. BYOVPC needs only a primary subnet range (2 IPs per node; /29 to /9) — **no pod/service secondary ranges**. The provider marks `pod_ip_range_name`, `service_ip_range_name`, and `gke_config` as deprecated and no longer supported; omit them. Private Google Access MUST be enabled.
- **PSC is GA** (since November 2025) — front-end and back-end, self-service. See [`../private-networking/GCP.md`](../private-networking/GCP.md). PSC must be set at workspace creation; cannot be retrofitted.
- **HYBRID vs SERVERLESS compute_mode is explicit.** SERVERLESS workspaces have no worker environments and cannot run classic clusters — pass `compute_mode = "HYBRID"` explicitly if customer needs classic.

## Required APIs on the workspace project

```
compute.googleapis.com
container.googleapis.com
iam.googleapis.com
iamcredentials.googleapis.com
cloudresourcemanager.googleapis.com
servicenetworking.googleapis.com
storage.googleapis.com
cloudkms.googleapis.com         # if CMEK
```

## GCP Template Patterns

| Pattern | When to Use |
|---|---|
| Managed VPC + SERVERLESS | POC, sandbox, customer wants the simplest possible path |
| BYO VPC + HYBRID | Production default — full control over networking, classic compute available |
| BYO VPC + PSC + HYBRID | Production with compliance requiring no public endpoints |
| BYO VPC + PSC + CMEK + Shared VPC | Regulated workloads (HIPAA / PCI / FedRAMP) — see [`gcp-3-gotchas.md`](gcp-3-gotchas.md) for CMEK timing |

## Reference repos

Fetch from these at runtime for GCP Terraform patterns, in this order:

1. **`https://github.com/databricks-solutions/technical-services-solutions`** (path `workspace-setup/terraform-examples/gcp/`) — **START HERE.** Self-contained, deploy-as-is scenarios curated by Databricks Shared Technical Services. Covers `gcp-byovpc-standalone` (custom VPC + subnet + Cloud Router + Cloud NAT + SA impersonation) and `gcp-byovpc-shared-vpc` (shared-VPC host/service project topology). Actively maintained.
2. **`https://github.com/databricks/terraform-databricks-sra`** — GCP section for enterprise hardening (CMEK, log delivery, exfil protection). Use when the field repo doesn't cover the security requirement.
3. **`https://github.com/databricks/terraform-databricks-examples`** — broader GCP examples catalog. **Updates more slowly — verify provider versions and commit log before relying on it.** Note: check examples for GKE-era fields (`pod_ip_range_name`, `service_ip_range_name`, `gke_config`) and drop them; add the `db-<subnet>-ingress` firewall rule if missing.

Provider + product docs:

- `https://github.com/databricks/terraform-provider-databricks/blob/main/docs/guides/gcp-workspace.md`
- `https://github.com/databricks/terraform-provider-databricks/blob/main/docs/guides/gcp-private-service-connect-workspace.md`
- `https://docs.databricks.com/gcp/en/dev-tools/auth/google-id-auth`
- `https://docs.databricks.com/gcp/en/admin/cloud-configurations/gcp/permissions`
