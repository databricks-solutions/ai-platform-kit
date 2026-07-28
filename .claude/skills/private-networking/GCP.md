# Private Service Connect (PSC) on Databricks GCP

GCP's equivalent of AWS PrivateLink and Azure Private Endpoint. PSC for Databricks on GCP is **supported today** (any older skill text saying "GCP does not have private link yet" is stale). Both back-end (compute → control plane) and front-end (users → workspace UI/API) are supported. Combined = full PSC.

## When to use PSC

| Customer ask | Use |
|---|---|
| "Cluster traffic must not leave Google's backbone" | Back-end PSC |
| "Users / drivers must reach the workspace UI privately" | Front-end PSC |
| "No public endpoints anywhere — compliance mandate" | Full PSC (front + back) + `public_access_enabled = false` |
| "I just need no public IPs on my compute nodes" | BYOVPC + SCC (no_public_ip) — **PSC not required** |

Apply MODERATE pushback when customers ask for PSC without a real driver. PSC adds significant complexity (per-region service-attachment URIs to wire, private DNS zone management, day-2 operational restrictions). BYOVPC + SCC covers most "no public IPs" asks already.

## What PSC actually creates

```
        ┌────────────────────────┐                         ┌────────────────────────┐
        │  Customer VPC          │                         │  Databricks control    │
        │                        │   PSC private link      │  plane VPC (Databricks │
        │  google_compute_       │  ─────────────────────► │  service producer)     │
        │   forwarding_rule      │                         │                        │
        │  + google_compute_     │     accepted by         │  service attachment    │
        │   address (PSC EP)     │     account-level       │  URI (per region)      │
        └──────────┬─────────────┘     mws_vpc_endpoint    └────────────────────────┘
                   │
                   ▼
        ┌────────────────────────┐
        │  Cluster nodes (GKE)   │
        │  in customer subnet    │
        └────────────────────────┘
```

You create **two** Google compute resources per PSC endpoint:
- `google_compute_address` — a regional reserved IP inside your VPC
- `google_compute_forwarding_rule` with `target` set to the Databricks-published service attachment URI

You also register **one** account-level `databricks_mws_vpc_endpoint` per PSC endpoint. The registration name is what `databricks_mws_networks` will reference.

## Back-end PSC (compute → control plane)

Back-end PSC needs **two** endpoints:
- **REST API endpoint** — for Databricks workspace REST API calls from compute (port 443)
- **Relay endpoint** — for the Secure Cluster Connectivity tunnel (the SCC relay)

```hcl
# Reserved IPs in the workspace VPC
resource "google_compute_address" "rest" {
  name         = "${var.prefix}-psc-rest"
  region       = var.region
  subnetwork   = google_compute_subnetwork.workspace.id
  address_type = "INTERNAL"
  project      = var.project
}

resource "google_compute_address" "relay" {
  name         = "${var.prefix}-psc-relay"
  region       = var.region
  subnetwork   = google_compute_subnetwork.workspace.id
  address_type = "INTERNAL"
  project      = var.project
}

# PSC forwarding rules
resource "google_compute_forwarding_rule" "rest" {
  name                  = "${var.prefix}-psc-rest"
  region                = var.region
  network               = google_compute_network.workspace.id
  ip_address            = google_compute_address.rest.id
  target                = var.databricks_rest_psce_service_attachment  # per-region URI from Databricks
  load_balancing_scheme = ""
  project               = var.project
}

resource "google_compute_forwarding_rule" "relay" {
  name                  = "${var.prefix}-psc-relay"
  region                = var.region
  network               = google_compute_network.workspace.id
  ip_address            = google_compute_address.relay.id
  target                = var.databricks_relay_psce_service_attachment
  load_balancing_scheme = ""
  project               = var.project
}

# Register each PSC endpoint with Databricks account
resource "databricks_mws_vpc_endpoint" "rest" {
  provider          = databricks.mws
  account_id        = var.databricks_account_id
  vpc_endpoint_name = "${var.prefix}-rest"
  gcp_vpc_endpoint_info {
    project_id        = var.project
    psc_endpoint_name = google_compute_forwarding_rule.rest.name
    endpoint_region   = var.region
  }
}

resource "databricks_mws_vpc_endpoint" "relay" {
  provider          = databricks.mws
  account_id        = var.databricks_account_id
  vpc_endpoint_name = "${var.prefix}-relay"
  gcp_vpc_endpoint_info {
    project_id        = var.project
    psc_endpoint_name = google_compute_forwarding_rule.relay.name
    endpoint_region   = var.region
  }
}
```

Then wire the endpoints into `databricks_mws_networks`:

```hcl
resource "databricks_mws_networks" "psc" {
  provider     = databricks.mws
  account_id   = var.databricks_account_id
  network_name = "${var.prefix}-network"
  gcp_network_info {
    network_project_id    = var.project
    vpc_id                = google_compute_network.workspace.name
    subnet_id             = google_compute_subnetwork.workspace.name
    subnet_region         = var.region
    pod_ip_range_name     = "pods"
    service_ip_range_name = "services"
  }
  vpc_endpoints {
    dataplane_relay        = databricks_mws_vpc_endpoint.relay.vpc_endpoint_id
    rest_api               = databricks_mws_vpc_endpoint.rest.vpc_endpoint_id
  }
}
```

## Front-end PSC (users / drivers → workspace webapp)

Adds a third endpoint for inbound user traffic to the workspace URL. Same shape, target is the webapp service attachment URI.

```hcl
resource "google_compute_address" "webapp" { ... }
resource "google_compute_forwarding_rule" "webapp" {
  ...
  target = var.databricks_webapp_psce_service_attachment
}
resource "databricks_mws_vpc_endpoint" "webapp" {
  ...
  vpc_endpoint_name = "${var.prefix}-webapp"
}
```

Front-end PSC requires a `databricks_mws_private_access_settings` with `public_access_enabled = false` and the webapp endpoint in `allowed_vpc_endpoint_ids`:

```hcl
resource "databricks_mws_private_access_settings" "pas" {
  provider              = databricks.mws
  account_id            = var.databricks_account_id
  private_access_settings_name = "${var.prefix}-pas"
  region                = var.region
  public_access_enabled = false
  private_access_level  = "ENDPOINT"
  allowed_vpc_endpoint_ids = [databricks_mws_vpc_endpoint.webapp.vpc_endpoint_id]
}
```

**`private_access_level` controls how `allowed_vpc_endpoint_ids` is interpreted:**

| `private_access_level` | `allowed_vpc_endpoint_ids` behavior |
|---|---|
| `ENDPOINT` | List of explicit endpoints allowed. Use this with frontend PSC where you want a specific allowlist. |
| `ACCOUNT` | List **MUST BE EMPTY** (`[]`). Any endpoint in the Databricks account is implicitly trusted. Apply fails with a validation error if a list is set with ACCOUNT mode. |

Pick `ENDPOINT` for principle-of-least-privilege; pick `ACCOUNT` when multiple workspaces in the same account share a common set of endpoints and you want the auto-trust behavior.

## Service attachment URIs

The `target` value on each `google_compute_forwarding_rule` is a **per-region** service attachment URI published by Databricks. Format:
```
projects/<databricks-host-project>/regions/<region>/serviceAttachments/<attachment-name>
```

There is no public registry of these URIs — they are looked up via:
- The Databricks documentation per region (manual)
- The GCP console — "Network services → Private Service Connect → Connected endpoints" — visible after you create a customer endpoint that connects to one
- Databricks support (ES ticket) for the customer's specific region

**The historical `ngrok-psc-endpoint` slot for the REST API attachment is DEPRECATED.** Use `plproxy-psc-endpoint-all-ports` instead. Documentation lookup or ES ticket gets the current canonical name.

## Plan / tier requirement

PSC and customer-managed VPC features require the **ENTERPRISE** plan. PREMIUM workspaces cannot use PSC. Surface this in intake — customers on PREMIUM who ask for PSC need to upgrade first.

## Gotchas

### PSC-backend-only + Unity Catalog + classic compute is structurally broken

If you deploy back-end PSC (compute → control plane private) without front-end PSC (users → webapp private), and try to use **classic** GKE-pod clusters with Unity Catalog, the UC API calls from classic compute return `403 Unauthorized network access to workspace`. The same UC objects work fine from serverless. Marisol reproduced this in R3-2026-05-11 across cluster restarts and PAS-level changes.

Mitigation options:
- **Serverless-only workflows** if PSC-backend is required
- **Add front-end PSC** to make the workspace fully private — UC API then resolves through the PSC routes
- **Use BYOVPC + SCC (no PSC)** if classic + UC is required and "no public IPs on compute" is enough

Document this trade-off with the customer at intake. Don't promise classic + UC + PSC-backend-only without front-end PSC.

### `public_access_enabled = false` at create time blocks day-2 ops from outside the VPC

If you set the PAS `public_access_enabled = false` at workspace creation, every subsequent day-2 operation that doesn't originate inside the VPC (CLI from your laptop, CI/CD pipelines, Terraform applies from a non-VPC runner) gets blocked. Either:
- Run all day-2 ops from inside the VPC (bastion, IAP)
- Add the day-2 origin to `allowed_vpc_endpoint_ids` via a front-end PSC endpoint
- Keep `public_access_enabled = true` initially, flip to `false` after day-2 setup is stable

### PSC workspaces need a private DNS zone

Classic compute resolves the workspace URL by name. If the cluster's GKE pods can't reach Databricks DNS via PSC, classic Path-1 verification (`CREATE TABLE` against a UC table) fails with `403 Unauthorized network access` even though network routes look correct. Fix: create a Cloud DNS private zone scoped to the workspace VPC that maps:
```
<workspace-id>.<region>.gcp.databricks.com → <PSC frontend endpoint IP>
dp-<workspace-id>.<region>.gcp.databricks.com → <PSC frontend endpoint IP>
tunnel.<region>.gcp.databricks.com → <PSC relay endpoint IP>
```

### PSC cannot be retrofitted to an existing workspace

PSC must be set at workspace **creation time** via `databricks_mws_workspaces.private_access_settings_id`. A Databricks-managed-VPC workspace cannot be migrated to PSC. A customer-managed-VPC workspace created without a PAS cannot have one attached after the fact (the PATCH workspace API has tighter constraints than the doc suggests). New workspace + data migration is the only path.

### 2-phase apply required for UC bootstrap behind full PSC + `public_access_enabled=false`

If you set the PAS `public_access_enabled = false` at workspace creation AND start UC bootstrap from outside the VPC (the typical CI/CD pattern from a non-VPC runner), `databricks_metastore_data_access` and related UC bootstrap calls fail with `Unauthorized network access to workspace`. The deployer host can't reach the workspace API to register the data-access credential.

Two-phase pattern:

1. **Phase 1** — create workspace with `public_access_enabled = true`. Apply all UC objects (metastore, data-access, storage credential, external locations, catalog, grants).
2. **Phase 2** — update the PAS to `public_access_enabled = false`. All workspace-internal traffic (clusters → UC, users via PSC frontend) keeps working; external CI/CD now requires PSC-frontend or bastion access.

In Terraform, gate phase 2 behind a variable so the same module supports both states:

```hcl
resource "databricks_mws_private_access_settings" "pas" {
  ...
  public_access_enabled = var.lockdown_phase
}
```

This trade-off is real: you cannot have "no public access at creation" AND "UC bootstrapped from outside the VPC" simultaneously. Either bootstrap from inside the VPC (bastion / IAP) or accept the 2-phase pattern.

## Cross-references

- [`SKILL.md`](SKILL.md) — when to use private networking at all, NCC for serverless egress
- [`../platform-provisioning/gcp-1-auth.md`](../platform-provisioning/gcp-1-auth.md) — the auth chain must work first
- [`../platform-provisioning/gcp-2-deploy.md`](../platform-provisioning/gcp-2-deploy.md) — BYOVPC subnet + secondary ranges
- [`../platform-provisioning/gcp-3-gotchas.md`](../platform-provisioning/gcp-3-gotchas.md) — `databricks_mws_vpc_endpoint` provider bug + CLI-import workaround
- Reference (Databricks Platform SME):
  - https://medium.com/databricks-platform-sme/demystifying-frontend-private-service-connect-psc-architecture-for-databricks-on-google-cloud-5de6fe894313
  - https://medium.com/databricks-platform-sme/demystifying-backend-private-service-connect-psc-architecture-for-databricks-on-google-cloud-14f81a237dd9
- Reference (Databricks docs):
  - https://docs.databricks.com/gcp/en/security/network/classic/private-service-connect
  - https://docs.databricks.com/gcp/en/security/network/front-end/front-end-private-connect
