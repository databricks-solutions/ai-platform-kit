# AWS Private Networking

## Private Link patterns

### Backend-only private link

Keeps cluster-to-control-plane traffic private while leaving the workspace UI and API publicly accessible. This is the simpler pattern and sufficient for most compliance requirements.

**Components:**
- Two VPC endpoints: REST API and Secure Cluster Connectivity relay. Both use the workspace-specific service names for your region.
- `private_dns_enabled = true` on BOTH VPC endpoints. This is mandatory -- without it, cluster nodes cannot resolve the control plane hostname and workspace creation succeeds but clusters fail to start.
- A single security group shared by the workspace and both VPC endpoints.
- A dedicated Private Link subnet with its own route table (local routes only, no NAT/IGW).

Using separate security groups for the workspace and VPC endpoints causes Unity Catalog queries to hang for 5+ minutes before timing out. Always use a single shared SG.

### Full private link (frontend + backend)

Everything private -- UI, API, and cluster traffic. Requires VPN, DirectConnect, or a bastion host inside the network to access the workspace.

**Architecture:**
- **Transit VPC (hub):** Frontend VPC endpoint (same workspace service name as backend, just in a different VPC), an Internet Gateway for bastion access, and Route 53 private hosted zone.
- **Compute VPCs (spokes):** Backend REST API and relay VPC endpoints, 2 private subnets for Databricks workers, a Private Link subnet, and NAT Gateway for outbound internet.
- **Route 53 private hosted zone** scoped to the workspace FQDN ONLY (e.g., `dbc-xxx.cloud.databricks.com`). NEVER scope the zone to the entire `cloud.databricks.com` domain -- this intercepts OAuth token requests to `accounts.cloud.databricks.com` and breaks authentication completely.
- **Private Access Settings (PAS)** with `public_access_enabled = false`.

**PAS is immutable.** Once created, PAS cannot be modified. To change `public_access_enabled`, create a new PAS and update the workspace to reference it. The workspace re-provisions in 1-2 minutes during the switch.

**Frontend endpoint uses the SAME service name as backend.** The distinction is which VPC it lives in, not a different service.

**Transit VPC needs an IGW** if you need bastion or jump host access from the internet for testing.

**Testing from outside the network:** Temporarily create a new PAS with `public_access_enabled = true`, attach it to the workspace, test, then switch back to the private PAS.

**Unlike Azure, AWS does NOT need a separate web auth workspace.** A single frontend VPC endpoint handles SSO for the workspace.

### Multi-workspace hub-spoke pattern

Scale private link across multiple workspaces:
- 1 transit VPC (hub): frontend VPC endpoint, IGW for bastion access.
- N compute VPCs (spokes): backend REST + relay VPC endpoints, 2 private subnets, PL subnet, NAT Gateway.
- Single security group per compute VPC -- never split SGs across workspace and endpoints.
- Shared IAM cross-account role for Databricks, with separate root S3 buckets per workspace.
- Two-phase deploy: workspaces first (Phase 1), then workspace-level config with URLs in tfvars (Phase 2).

## NCC pattern (serverless to private resources)

Use Network Connectivity Configuration when serverless SQL warehouses need to reach private resources (databases, internal APIs, on-prem systems).

**Architecture:** Serverless compute --> NCC private endpoint --> VPC Endpoint Service --> Network Load Balancer --> Target resource

### Key differences from Azure

- The NCC PE rule uses the `endpoint_service` parameter (the VPC endpoint service name), NOT `resource_id`.
- You must allowlist the Databricks IAM role on the VPC endpoint service: `arn:aws:iam::565502421330:role/private-connectivity-role-{region}` (replace `{region}` with your AWS region).
- NLB target type should be `ip`, not `instance`. IP targets work across availability zones and with containerized workloads.
- The target VM or service needs a separate permissive security group. The workspace security group only allows ports 443, 3306, and 6666 -- it will block traffic to custom ports.

### Step-by-step

1. **Create a Network Load Balancer** (internal, TCP). Configure a target group with IP-type targets pointing at your resource, a health check on the target port, and a listener forwarding to the target group.

2. **Create a VPC Endpoint Service** attached to the NLB.

3. **Allowlist the Databricks IAM role** on the VPC endpoint service. Without this, the NCC PE connection is rejected.

4. **Create an NCC private endpoint rule** with `endpoint_service` set to the VPC endpoint service name (e.g., `com.amazonaws.vpce.us-east-1.vpce-svc-xxx`).

5. **Approve the private endpoint connection** on the VPC endpoint service. NCC-created endpoints appear as pending connections.

6. **Attach the NCC to the workspace(s)** via the Databricks account API or Terraform.

7. **Create a UC Connection and Foreign Catalog.** Set the connection host to the NCC PE domain. Run a test query to verify connectivity end-to-end.

## AWS networking gotchas

- **`private_dns_enabled = true` is mandatory on both VPC endpoints.** Without it, cluster nodes resolve the control plane to public IPs, traffic exits the VPC, and clusters fail to start or experience intermittent connectivity issues.

- **Single security group for workspace + endpoints.** Using separate SGs for the workspace and VPC endpoints causes UC queries to hang for 5+ minutes. This is the most common private link debugging issue on AWS. Always use one shared SG.

- **PL subnet needs its own route table.** The Private Link subnet route table should have local routes only -- no NAT Gateway, no IGW. Adding default routes to this subnet breaks VPC endpoint connectivity.

- **VPC endpoint service names are region-specific.** Each AWS region has different service names for the REST API and relay endpoints. Do NOT hardcode service names. Query them at runtime via the Databricks account API: `GET /api/2.0/accounts/{account_id}/vpc-endpoints` to see existing endpoints, or look up the correct names for your region in the Databricks documentation. Wrong service names cause workspace creation to succeed but clusters to fail silently.

- **PAS is immutable.** You cannot modify a Private Access Settings object after creation. To change `public_access_enabled`, use this pattern: (1) Create a new PAS with the desired setting, (2) Update the workspace to reference the new PAS, (3) Wait 1-2 min for re-provisioning, (4) Delete the old PAS. This is needed when temporarily enabling public access for testing in a full private link deployment.

- **Route 53 zone scope.** The private hosted zone MUST be scoped to the specific workspace FQDN, not the entire `cloud.databricks.com` domain. Overly broad zones break OAuth flows to `accounts.cloud.databricks.com`.

- **NCC limits.** 10 NCCs per region, 30 PE rules per region. Same limits as Azure.

- **IAM propagation delay on cross-account roles.** New or modified IAM roles take 10-30 seconds to propagate. If Terraform fails with "Failed credential validation checks" on first apply, re-run `terraform apply` -- the role will be ready.

- **AWS session token expiry.** STS session tokens from SSO or AssumeRole expire after 1-12 hours. Unlike Azure CLI which can auto-refresh, expired AWS tokens cause immediate failures. Re-export fresh credentials before long Terraform runs.
