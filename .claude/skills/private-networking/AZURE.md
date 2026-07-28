# Azure Private Networking

## Private Link patterns

### Single workspace private link

The simplest private link deployment: one workspace with VNet injection and two private endpoints.

Components:
- Custom VNet with public and private subnets (delegated to `Microsoft.Databricks/workspaces`)
- NSG with required Databricks rules + Secure Cluster Connectivity enabled
- Two private endpoints: `databricks_ui_api` (workspace API/UI) and `browser_authentication` (SSO callback)
- Private DNS zone `privatelink.azuredatabricks.net` linked to the VNet
- DNS A records for workspace FQDN pointing to the private endpoint IPs

Deploy with `public_network_access_enabled = true` first. Flip to `false` only after the private endpoints and DNS are fully provisioned and tested. If you deploy with public access disabled from the start, Terraform loses API connectivity mid-apply and the deployment fails.

### Hub-spoke (recommended for multi-workspace)

When deploying multiple workspaces with private link in the same region, use the hub-spoke pattern to avoid DNS zone conflicts and reduce private endpoint sprawl.

**Architecture:**
- **Transit VNet (hub):** Hosts a dedicated web auth workspace, the shared private DNS zone, and the single `browser_authentication` private endpoint.
- **Spoke VNets:** Each workspace gets its own VNet with a `databricks_ui_api` private endpoint. Spoke VNets are peered to the transit VNet.

**Why a dedicated web auth workspace?**
The `browser_authentication` private endpoint anchors SSO for all workspaces sharing the same DNS zone. If the workspace that hosts this PE is deleted, SSO breaks for every workspace in the zone. The dedicated web auth workspace exists solely to anchor this PE -- it runs no workloads, costs almost nothing, and must never be deleted.

**Key constraints:**
- Only ONE `browser_authentication` PE is needed per region per private DNS zone.
- Each workspace still needs its own `databricks_ui_api` PE.
- The private DNS zone lives in the transit resource group with VNet links to all spoke VNets.
- Without hub-spoke, the hardcoded DNS zone name `privatelink.azuredatabricks.net` forces each workspace into a separate resource group to avoid zone collisions.

## NCC pattern (serverless to private resources)

Use Network Connectivity Configuration when serverless SQL warehouses or serverless compute need to reach private resources (databases, APIs, storage behind firewalls).

**Architecture:** Serverless compute --> NCC private endpoint --> Private Link Service (PLS) --> Internal Load Balancer (ILB) --> Target resource

### Step-by-step

1. **Create an Internal Load Balancer** (Standard SKU, Internal). Configure a backend pool pointing at your target resource (VM, database, etc.) and a health probe + load balancing rule for the target port.

2. **Create a Private Link Service** on the ILB's frontend IP configuration. The PLS subnet MUST have `disable-private-link-service-network-policies = true` set -- without this, PLS creation fails silently or the PE connection is rejected.

3. **Create an NCC private endpoint rule** with `resource_id` set to the PLS resource ID. This tells Databricks serverless compute where to send traffic.

4. **Approve the private endpoint connection** on the PLS. NCC-created PEs show up as pending connections on the Private Link Service in the Azure portal.

5. **Attach the NCC to the workspace** via the Databricks account API or Terraform.

6. **Create a UC Connection** with the host set to the NCC PE domain. The domain in the NCC PE rule and the UC connection must match character-for-character -- any mismatch causes silent connection failures.

7. **Create a Foreign Catalog** using the connection and run a test query to verify end-to-end connectivity.

### Propagation delay

After attaching an NCC to a workspace or modifying NCC rules, wait approximately 10 minutes for changes to propagate to the serverless control plane. Queries attempted before propagation completes will fail with connection timeouts.

## Azure networking gotchas

- **DNS zone collision (without hub-spoke):** The private DNS zone name `privatelink.azuredatabricks.net` is hardcoded. Multiple workspaces in separate resource groups each create their own zone, which works. But multiple workspaces in the SAME resource group collide on the zone name. Use hub-spoke or separate resource groups.

- **DNS zone VNet link deletion is extremely slow.** Azure DNS zone VNet link deletions take 30-60+ minutes. This is an Azure API limitation. Combined with Azure CLI token expiry (~60 min), long Terraform destroys can fail mid-operation. Re-run `az login` and `terraform destroy` to resume.

- **PLS subnet network policies.** The subnet hosting the Private Link Service MUST have `disable-private-link-service-network-policies = true`. Without it, the PE connection from NCC is rejected with no useful error message.

- **Load balancer health probes.** Health probes originate from IP `168.63.129.16`. The NSG on the target subnet must have an inbound rule allowing traffic from the `AzureLoadBalancer` service tag. Without it, all backend pool members show as unhealthy and traffic blackholes.

- **NCC PE domain must match UC connection host exactly.** The domain string in the NCC private endpoint rule and the `host` field in the Unity Catalog connection must be character-for-character identical. A trailing slash, different casing, or any variation causes the connection to fail silently.

- **NCC limits.** 10 NCCs per region, 30 private endpoint rules per region. Plan accordingly for multi-workspace deployments.

- **Two-phase deploy for private link + UC.** Terraform provider blocks cannot reference resource attributes for the `host` parameter. Deploy workspaces first (Phase 1), then set workspace URLs in tfvars and apply again for catalogs, schemas, and grants (Phase 2).
