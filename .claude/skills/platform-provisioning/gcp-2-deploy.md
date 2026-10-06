# GCP — Deploy patterns

Workspace creation patterns and the resources you compose. Auth is covered in [`gcp-1-auth.md`](gcp-1-auth.md). Gotchas in [`gcp-3-gotchas.md`](gcp-3-gotchas.md).

## Compute mode: HYBRID vs SERVERLESS

Databricks GCP workspaces have a `compute_mode` attribute that determines whether the workspace supports classic clusters (HYBRID) or only serverless (SERVERLESS). **The skill's older "GCP-managed VPC default" wording implied classic-capable — that is no longer the GCP API default.**

| Mode | What works | What doesn't | When to use |
|---|---|---|---|
| **SERVERLESS** (newer default if `compute_mode` is omitted in some API paths) | Serverless SQL warehouses, serverless job compute, serverless notebooks | Classic clusters (no worker environments) | POCs, customers who only need serverless, regulated serverless-only mandates |
| **HYBRID** | Classic clusters + serverless | — | Production with classic-cluster requirements, custom init scripts, jobs needing specific node types, dbt-on-classic |

Pass `compute_mode` **explicitly** on `databricks_mws_workspaces` (or `--json '{... "compute_mode": "HYBRID" ...}'` on `databricks account workspaces create`). The default differs between API paths and SDK versions; explicit is safe.

```hcl
resource "databricks_mws_workspaces" "this" {
  provider       = databricks.mws
  account_id     = var.databricks_account_id
  workspace_name = "${var.prefix}-ws"
  location       = var.google_region
  cloud_resource_container {
    gcp {
      project_id = var.google_project
    }
  }
  compute_mode = "HYBRID"  # or "SERVERLESS"

  # network_id + private_access_settings_id for BYOVPC + PSC, omit for managed-VPC
  network_id                 = databricks_mws_networks.this.network_id
  private_access_settings_id = databricks_mws_private_access_settings.this.private_access_settings_id

  depends_on = [
    google_compute_subnetwork.workspace,
    databricks_mws_networks.this,
  ]
}
```

**HYBRID is NOT free.** First HYBRID workspace creation in a project triggers lazy creation of the Databricks GCP service agent (`service-<projectnum>@gcp-sa-databricks.iam.gserviceaccount.com`). If your workspace-creator SA lacks `roles/iam.serviceAccountTokenCreator` on that service agent (or org policy blocks it), the workspace stays in `PROVISIONING` with no useful error. The Workspace Creator SA's `iam.roleAdmin` role (from `gcp-1-auth.md`) covers the IAM bootstrap; if you still see provisioning hangs, escalate via a Databricks ES ticket.

## Three deployment patterns

### 1. Managed VPC (simplest — for POCs)

Databricks creates the VPC + subnet for you and launches GCE compute in it. Cannot share VPCs across workspaces. No PSC, no VPC SC, no firewall egress restriction.

```hcl
resource "databricks_mws_workspaces" "managed" {
  provider       = databricks.mws
  account_id     = var.databricks_account_id
  workspace_name = "${var.prefix}-ws"
  location       = var.google_region
  cloud_resource_container {
    gcp { project_id = var.google_project }
  }
  compute_mode = "HYBRID"
  # No network_id → Databricks creates a managed VPC
}
```

### 2. BYO VPC (production default)

You pre-create the VPC + subnet (primary range only — no secondary ranges); Databricks launches GCE compute VMs in your subnet.

```hcl
resource "google_compute_network" "ws" {
  name                    = "${var.prefix}-vpc"
  project                 = var.google_project
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "ws" {
  name          = "${var.prefix}-subnet"
  project       = var.google_project
  region        = var.google_region
  network       = google_compute_network.ws.id
  ip_cidr_range = "10.10.0.0/23"
  private_ip_google_access = true
  # No secondary ranges: GCE-based compute uses the primary range only.
}

# Required: allow all traffic between nodes inside the workspace subnet.
resource "google_compute_firewall" "intra_subnet" {
  name      = "db-${google_compute_subnetwork.ws.name}-ingress"
  project   = var.google_project
  network   = google_compute_network.ws.id
  direction = "INGRESS"
  allow { protocol = "all" }
  source_ranges = [google_compute_subnetwork.ws.ip_cidr_range]
}

resource "databricks_mws_networks" "byovpc" {
  provider     = databricks.mws
  account_id   = var.databricks_account_id
  network_name = "${var.prefix}-network"
  gcp_network_info {
    network_project_id   = var.google_project
    vpc_id               = google_compute_network.ws.name
    subnet_id            = google_compute_subnetwork.ws.name
    subnet_region        = var.google_region
    # pod_ip_range_name / service_ip_range_name are deprecated and no longer
    # supported (GKE-era). Do not set them.
  }
}
```

Pair with Cloud NAT + Cloud Router for outbound (since BYOVPC subnets have no auto-NAT). If the customer needs a static egress IP (e.g., for Delta Sharing partner allowlists), use Cloud NAT in `MANUAL` mode with `google_compute_address` reservations.

**Sizing rules** (each compute node uses **2 IPs** from the primary range; allowed range /29 to /9):

| Subnet | Max nodes |
|---|---|
| /25 | ~60 |
| /24 | ~120 |
| /23 | ~250 (good default) |
| /22 | ~500 |
| /21 | ~1000 |
| /20 | ~2000 |
| /19 | ~4000 |

- Private Google Access **MUST** be enabled on the subnet — without it, compute nodes cannot reach `googleapis.com` and bootstrap fails.
- The `db-<subnet-name>-ingress` intra-subnet firewall rule above is required.
- **Existing GKE-era workspaces:** if their networks still declare pod/service ranges, it is safe to leave the ranges on the subnet, but remove `pod_ip_range_name` / `service_ip_range_name` from new `databricks_mws_networks` configs.

### 3. BYO VPC + PSC (no public endpoints)

Adds Private Service Connect endpoints between your VPC and the Databricks control plane. PSC is the GCP equivalent of AWS PrivateLink and Azure Private Endpoint. See [`../private-networking/GCP.md`](../private-networking/GCP.md) for the full PSC pattern. PSC must be set at workspace creation time — it cannot be retrofitted.

## Resource composition (account-level objects, in order)

```
1. databricks_mws_credentials       (binds the Workspace Creator SA)
2. databricks_mws_storage_configurations  (optional, only if customer brings GCS root bucket)
3. databricks_mws_networks          (BYO VPC + optional PSC endpoints)
4. databricks_mws_private_access_settings  (PSC allowlist; required if any vpc_endpoints registered)
5. databricks_mws_workspaces        (binds it all)
```

After workspace creation, switch to the workspace-level provider for everything inside the workspace (clusters, jobs, secret scopes, IP access lists, UC catalogs, etc.).

## Workspace SA (created by Databricks, customer manages grants)

Databricks auto-creates a workspace service account in your project after workspace creation. You do not control its lifecycle but you grant it access to external GCS buckets, BigQuery datasets, etc. when the cluster needs to read data outside the DBFS root.

Do not read it from `gke_config` — that attribute is deprecated and no longer populated. After the workspace is `RUNNING`, find the Databricks-created service account(s) in the project's IAM page (`gcloud iam service-accounts list --project <project>`) and confirm the email before granting bucket or dataset access.

For Unity Catalog, the storage credential generates a SEPARATE auto-managed SA (different from the workspace SA). Both SAs need bucket-level IAM grants. See [`../unity-catalog-setup/GCP.md`](../unity-catalog-setup/GCP.md).

## Cross-references

- [`gcp-1-auth.md`](gcp-1-auth.md) — must be working before any of this matters
- [`gcp-3-gotchas.md`](gcp-3-gotchas.md) — provider quirks, CMEK timing, `custom_tags` rejection
- [`../private-networking/GCP.md`](../private-networking/GCP.md) — PSC backend + frontend
- [`../unity-catalog-setup/GCP.md`](../unity-catalog-setup/GCP.md) — metastore + catalogs + grants
- [`../deployment-verification/SKILL.md`](../deployment-verification/SKILL.md) — mandatory 3-path verification post-deploy
