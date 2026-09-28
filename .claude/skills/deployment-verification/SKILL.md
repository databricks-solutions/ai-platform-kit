---
name: databricks-deployment-verification
description: "MANDATORY post-deployment verification. After any workspace + Unity Catalog deployment, you MUST run all THREE compute paths against a UC table — classic cluster, serverless SQL warehouse, serverless notebook job. Skipping any of the three is incomplete work. Use whenever a workspace + UC has been freshly deployed or modified."
---

# Deployment Verification — THE THREE PATHS RULE

> **STOP. Before declaring any workspace "deployed" or "verified", you MUST run all three of:**
>
> 1. **Classic cluster** with UC (`data_security_mode = "SINGLE_USER"`)
> 2. **Serverless SQL warehouse** (PRO)
> 3. **Serverless notebook job** (ephemeral job compute)
>
> Each must read AND write a UC table end-to-end (CREATE → INSERT → SELECT → DROP).
>
> One success on serverless does NOT count as verified. Classic must work too — that's where most real-world skill bugs live (cluster policies, init scripts, custom AMIs, SCC/PrivateLink port story, JVM warmup interactions with private storage, `data_security_mode` enforcement). If you only test serverless you're testing the easy path.

## How to interact with the customer

**Pushback level: HIGH for skipping verification and for the remote mutations verification creates.**

- Verification is mandatory: never declare a deployment "done" or "verified" without running all three paths. Resist "it took too long", "we're serverless-first", or "it's just a POC" — none is a valid reason to skip (see "When to skip" for the narrow, logged exceptions).
- The verification resources are real remote mutations. Present one batched plan and get explicit approval before creating them (see the approval gate below); never skip that gate, and never create extra resources on retry without re-approval.
- Report results faithfully — per path PASS / FAIL / SKIPPED-WITH-REASON, with the reason recorded. A partial or half-run verification is incomplete work, not a pass.
- When a path fails on a customer-account constraint (quota, capacity, missing approval), stop and tell the customer what is blocking and where to fix it, rather than silently skipping.

## Approval gate for the verification resources

Verification is **mandatory** (never skip it), but the verification itself creates real remote resources — a classic cluster, a PRO SQL warehouse, a notebook, and a job. Those are mutations, so before creating them present ONE plan and get explicit approval:

1. **Target** -- the workspace and the `--profile` (or host) you will verify against.
2. **Change set** -- the exact verify-* resources you will create (cluster, warehouse, notebook, job) and the UC table you will CREATE/INSERT/SELECT/DROP. Batched: one approval for the whole verification run, not one prompt per resource.
3. **Wait for explicit approval**, then create **only** those resources.
4. **Retry / recovery** uses the same gate — never create extra resources without re-approval.
5. **Cleanup** (below) destroys only the verify-* resources this run created, and reports what it removed.

"Mandatory" means you must not declare a deployment done without running verification — it does not mean skipping this approval. It is the default for interactive use; auto-approve / headless mode is the customer's choice and responsibility (see SECURITY.md).

## Why this is its own skill

Deployment verification is the most-skipped step in every platform stress test. Agents reach for the cheapest path (serverless SQL) because it's the fastest and the cluster cold-start warning in `workspace-config` discourages classic. Result: skill gaps that only surface on classic clusters never get caught until a real customer hits them in prod. **This skill exists to make verification impossible to forget and impossible to half-do.**

## The Three Paths

### Path 1 — Classic cluster (UC-enabled)

The most informative test. Surfaces:
- Cluster policy correctness (`data_security_mode`, `single_user_name`, allowed instance types)
- IAM role / managed identity propagation to the cluster
- UC metastore + external location + storage credential resolution from worker nodes
- Init scripts and custom AMIs (if used by persona)
- SCC relay + private networking (workers reach control plane on TCP 443)
- Workspace-level secret scopes if used in Spark conf
- DBFS root encryption (CMK on managed disks for HIGH personas)

**Minimum cluster spec:**

```hcl
data "databricks_node_type" "verify" {
  # DO NOT use the bare "smallest" preset — on AWS it picks m5d.large (2 vCPU / 8GB),
  # which fails Spark driver startup with DriverStartupTimeout 300s on a fresh
  # workspace (JVM warmup needs more cores). Pin a real floor:
  min_cores      = 8
  min_memory_gb  = 32
  local_disk     = true
  category       = "General Purpose"
}

resource "databricks_cluster" "verify_classic" {
  cluster_name            = "verify-classic-${var.workspace_name}"
  spark_version           = data.databricks_spark_version.lts.id  # latest LTS
  node_type_id            = data.databricks_node_type.verify.id
  num_workers             = 1   # NOT autoscaled — keep deterministic
  autotermination_minutes = 0   # CRITICAL: 0 = no auto-terminate during JVM warmup
                                # If you set 30, on a fresh workspace the cluster can
                                # reach RUNNING but stay in "Starting Spark" past the
                                # 30-min window → terminates before any job attaches →
                                # infinite restart loop. Set 0 for verify clusters and
                                # destroy them explicitly at end (cleanup section).
  data_security_mode      = "SINGLE_USER"   # required for UC table reads
  single_user_name        = var.verifier_principal  # for an SP, this is the SP's
                                                    # application_id (UUID) — NOT the
                                                    # numeric SP id. For a user, the
                                                    # email. For a group, the group name.

  # AWS only — required when local_disk = false OR when the chosen instance type
  # doesn't have NVMe instance store (most non-d-series). Without this, cluster
  # creation fails with "Cluster requires at least one EBS volume".
  aws_attributes {
    ebs_volume_count = 1
    ebs_volume_size  = 100
    ebs_volume_type  = "GENERAL_PURPOSE_SSD"
  }

  # Tag so it can be identified + cleaned up
  custom_tags = {
    purpose = "deployment-verification"
    persona = var.persona_name
  }
}
```

**Why the explicit `min_cores`/`min_memory_gb` floor:** the bare `data "databricks_node_type" "smallest"` selector picks the cheapest UC-eligible node, which on AWS is m5d.large (2 vCPU / 8 GB). On a fresh workspace, the Spark driver JVM warmup + UC metadata cache + storage credential resolution doesn't finish in the API's 300s `DriverStartupTimeout` window with only 2 cores — even m5d.xlarge (4 vCPU / 16 GB) has been observed to time out. m5.2xlarge (8 vCPU / 32 GB) is the lowest size that reliably starts cold. Pinning `min_cores = 8` + `min_memory_gb = 32` lets the data source pick a regional equivalent on Azure/GCP without hardcoding instance types. Use the same floor on Azure (selects `Standard_D8s_v5` or similar) and GCP (`n2-standard-8`).

**Expected timing:** 5–10 min cold-start on a fresh workspace at the recommended size, 10–15 min on the smaller-than-recommended sizes that often time out anyway. The skill warning about classic cold-start is REAL but it's not an excuse to skip the test — it's a reason to start the cluster early in your deploy and verify near the end.

**SQL test (run via `databricks api post /api/2.0/sql/statements` against the cluster, OR notebook task on the cluster):**

```sql
-- Replace catalog/schema with the catalog you just deployed
CREATE TABLE <catalog>.<schema>.verify_classic (id INT, msg STRING);
INSERT INTO <catalog>.<schema>.verify_classic VALUES (1, 'classic verified');
SELECT * FROM <catalog>.<schema>.verify_classic;
DROP TABLE <catalog>.<schema>.verify_classic;
```

**Pass criteria:** all four statements succeed. SELECT must return exactly the row inserted. If any fails: do NOT mark verified. Diagnose, fix, retry.

**Hard-failure modes to watch for:**

| Symptom | Likely root cause |
|---|---|
| Cluster stuck in "Pending" >20 min | IAM role propagation, instance profile attached but not yet readable |
| Cluster started but SQL fails with "credential not found" | UC IAM policy missing `s3:ListBucketMultipartUploads` family (AWS) or DES managed identity not granted Get/UnwrapKey on Key Vault (Azure CMK) |
| `data_security_mode=SINGLE_USER` rejected | Cluster policy is too restrictive; relax `data_security_mode` constraint |
| Cluster started but timed out fetching control-plane | SCC over PrivateLink misconfigured (AWS) or NSG/firewall rules wrong (Azure) — see private-networking skill |
| AWS only: workers can't reach S3 | Missing `s3:GetBucketTagging` or `s3:GetBucketAcl` on the UC IAM policy (often missing from older skill examples) |
| Azure only: spark fails reading UC managed table | DES (Disk Encryption Set) managed identity missing Key Vault access policy |

### Path 2 — Serverless SQL warehouse (PRO)

Fastest verification. Tests UC + serverless + storage credential resolution from the serverless plane (different from classic — different network egress, different identity).

**Minimum warehouse spec:**

```hcl
resource "databricks_sql_endpoint" "verify_serverless" {
  name                      = "verify-serverless"
  cluster_size              = "2X-Small"   # smallest serverless size
  enable_serverless_compute = true
  warehouse_type            = "PRO"        # PRO required for UC-aware features
  auto_stop_mins            = 10
  min_num_clusters          = 1            # REQUIRED — SDK warehouses.create()
  max_num_clusters          = 1            # rejects with "0 is not a valid value
                                           # for max_num_clusters" if either is
                                           # omitted. Both must be >= 1.
  tags { custom_tags { key = "purpose" value = "deployment-verification" } }
}
```

The `databricks_sql_endpoint` resource defaults `min_num_clusters` and `max_num_clusters` to 0 if not set, but the underlying `warehouses.create()` SDK call rejects 0. Always set both explicitly to 1 (or higher if you actually want autoscaling). Symptom of omitting: `INVALID_PARAMETER_VALUE: 0 is not a valid value for max_num_clusters`.

**Pass criteria:** same four-statement CRUD as Path 1 succeeds. **CRITICAL:** the Statement Execution API (`/api/2.0/sql/statements`) does NOT accept multi-statement bodies — it returns `PARSE_SYNTAX_ERROR: Syntax error at or near 'CREATE': extra input 'CREATE'`. You MUST split into 4 separate calls:

```bash
WS_PROFILE=<workspace-profile>
WAREHOUSE_ID=<id>
TABLE="<catalog>.<schema>.verify_serverless"

for STMT in \
  "CREATE TABLE $TABLE (id INT, msg STRING)" \
  "INSERT INTO $TABLE VALUES (2, 'serverless verified')" \
  "SELECT * FROM $TABLE" \
  "DROP TABLE $TABLE" ; do
  databricks api post /api/2.0/sql/statements \
    --profile "$WS_PROFILE" \
    --json "{\"warehouse_id\": \"$WAREHOUSE_ID\", \"statement\": $(jq -Rs . <<< "$STMT"), \"wait_timeout\": \"30s\"}" \
    || { echo "FAIL on: $STMT"; exit 1; }
done
```

The third call (SELECT) must return one row containing `[2, "serverless verified"]`.

**Hard-failure modes:**

| Symptom | Likely root cause |
|---|---|
| Warehouse fails to start | Serverless not enabled on the workspace OR region doesn't support serverless |
| SQL fails with storage error | Storage account firewall (Azure) blocking serverless egress — needs trusted-services exception OR private endpoint to managed storage |
| Warehouse PROVISIONING but never STARTING | Account-level entitlement for serverless missing |

### Path 3 — Serverless notebook job (ephemeral job compute)

Tests the **third** compute plane: serverless job compute. This is structurally different from both Path 1 (classic) and Path 2 (serverless SQL) because:
- Different identity context (job runs as the runner / SP, not as cluster owner)
- Different egress (different network path than serverless SQL warehouse)
- Tests notebook → UC table flow (different code path than SQL warehouse → UC table)

**Minimum job spec — MUST be a Python notebook with `dbutils.notebook.exit(...)`.** SQL notebooks don't surface SELECT results through the run-output API, so the verifier can't programmatically confirm the row was returned.

```hcl
resource "databricks_notebook" "verify_notebook" {
  path     = "/Shared/verify_notebook"
  language = "PYTHON"
  content_base64 = base64encode(<<-EOT
    # Databricks notebook source
    catalog, schema = "<catalog>", "<schema>"
    table = f"{catalog}.{schema}.verify_notebook"
    spark.sql(f"CREATE TABLE {table} (id INT, msg STRING)")
    spark.sql(f"INSERT INTO {table} VALUES (3, 'notebook verified')")
    rows = [r.asDict() for r in spark.sql(f"SELECT * FROM {table}").collect()]
    spark.sql(f"DROP TABLE {table}")
    dbutils.notebook.exit(str(rows))   # surfaces in run-output as notebook_output.result
  EOT
  )
}

resource "databricks_job" "verify_notebook" {
  name = "verify-notebook"
  task {
    task_key = "verify"
    notebook_task { notebook_path = databricks_notebook.verify_notebook.path }
    # No cluster spec — uses serverless job compute by default
  }
}
```

Then trigger and wait. **CRITICAL:** when you submit a job via `runs/submit` or trigger one via `run-now`, the API returns the OUTER run id, but `runs/get-output` errors with `"Retrieving the output of runs with multiple tasks is not supported"` if you query the outer id directly — even when there's only one task. You must extract the task-level run id first:

```bash
WS_PROFILE=<workspace-profile>
JOB_ID=<job-id>

# 1. Trigger
RUN_ID=$(databricks jobs run-now --job-id "$JOB_ID" --profile "$WS_PROFILE" | jq -r '.run_id')

# 2. Wait for SUCCESS (poll runs/get every 10s until life_cycle_state == TERMINATED)
while :; do
  STATUS=$(databricks api get /api/2.1/jobs/runs/get --profile "$WS_PROFILE" --json "{\"run_id\": $RUN_ID}")
  LCS=$(echo "$STATUS" | jq -r '.state.life_cycle_state')
  RES=$(echo "$STATUS" | jq -r '.state.result_state')
  [ "$LCS" = "TERMINATED" ] && break
  sleep 10
done
[ "$RES" = "SUCCESS" ] || { echo "FAIL: $RES"; exit 1; }

# 3. Extract task-level run id (NOT the outer RUN_ID)
TASK_RUN_ID=$(echo "$STATUS" | jq -r '.tasks[0].run_id')

# 4. Get notebook output via the TASK run id
OUT=$(databricks api get /api/2.1/jobs/runs/get-output --profile "$WS_PROFILE" \
        --json "{\"run_id\": $TASK_RUN_ID}" | jq -r '.notebook_output.result')

# OUT should equal the str(rows) from dbutils.notebook.exit, e.g. "[{'id': 3, 'msg': 'notebook verified'}]"
echo "$OUT" | grep -q "notebook verified" || { echo "FAIL: output didn't match"; exit 1; }
```

**Pass criteria:** outer run state = TERMINATED/SUCCESS AND `notebook_output.result` from the task-level run id contains `notebook verified`.

**Hard-failure modes:**

| Symptom | Likely root cause |
|---|---|
| Job stuck in `PENDING_QUEUE` | Serverless compute capacity issue or workspace-level serverless not enabled |
| Job FAILED with permission error on UC | The job runs as the workspace creator (you) — but the catalog/schema may have been granted only to a group. Either run as SP that's in the group OR grant the runner directly. |
| Notebook fails on `CREATE TABLE` | Same UC IAM/identity issue as Path 1 — surface here means it's a write-path issue not a compute-path issue |

## The Verification Workflow (mandatory)

Run these phases at the END of every workspace + UC deployment, in this order:

```
1. Verify all three paths PASS         → workspace is verified
2. If any path FAILS                   → diagnose, fix, RE-RUN ALL THREE
3. Save verification artifacts         → see "What to save" below
4. Update transcript with PASS/FAIL    → per path
```

**What to save (in the deployment dir):**

- `verification.tf` — the three resources defined above (cluster, warehouse, notebook+job)
- `verification.log` — output of each SQL statement, exit codes, durations
- `verification.json` — structured pass/fail per path:
  ```json
  {
    "classic":    {"status": "PASS|FAIL", "duration_s": 720, "cluster_id": "0503-...", "error": null},
    "serverless": {"status": "PASS|FAIL", "duration_s": 8,   "warehouse_id": "...",    "error": null},
    "notebook":   {"status": "PASS|FAIL", "duration_s": 45,  "job_id": "...", "run_id": "...", "error": null}
  }
  ```

## When to skip (NARROW exceptions)

You may skip a path ONLY if:

- **Skip classic** — only when one of:
  - Customer **explicitly** requires no classic compute (regulated workloads, serverless-only mandate)
  - The workspace was created with `compute_mode = "SERVERLESS"` (GCP only) — these workspaces have no worker environments and classic clusters cannot run, period. `databricks clusters create` returns `Current organization X does not have any associated worker environments`. This is structural, not a skip-for-convenience.
  - **GCP-specific:** PSC-backend-only workspace + UC — classic GKE pods cannot reach the UC API through PSC-backend-only routing (`403 Unauthorized network access to workspace`). If the customer truly needs classic + UC + PSC, they need PSC frontend too. Log this as `SKIPPED-WITH-REASON` and recommend adding frontend PSC or switching to serverless workflows.
  Log the reason in `verification.json` with `"status": "SKIPPED-WITH-REASON"`. Do NOT skip classic just because cold-start is slow.
- **Skip serverless** — only when the customer explicitly forbids serverless (regulated FSI / banking with no serverless approval) AND the workspace genuinely does not have serverless enabled. Log the reason.
- **Skip notebook job** — only when serverless job compute is not available in the region. (Rare today.) Log the reason.

**Default: run all three.** "Took too long" / "use case is serverless-first" / "POC scope" are NOT valid reasons. The point of verification is to find configuration gaps, not to validate the customer's preferred path.

## Optional 4th path: external-table read

For customers whose primary value is **reading data they already have** (existing S3/ADLS/GCS bucket with curated data; UC managed catalog is for the new analytics workload), add an external-table read path. This verifies that the read-only external location resolves AND that the auto-generated storage credential SA actually has the IAM grants you set.

```sql
CREATE TABLE IF NOT EXISTS <catalog>.<schema>.verify_external_read
USING TEXT
LOCATION 'gs://<customer-existing-bucket>/<path-with-data>/';
SELECT count(*) FROM <catalog>.<schema>.verify_external_read;
DROP TABLE <catalog>.<schema>.verify_external_read;
```

Mark this as `path: "external_read"` in `verification.json`. PASS = the COUNT returned (even if 0; bucket may be empty for new customers). FAIL = permission denied or location not found — verify the storage credential SA has BOTH `roles/storage.objectViewer` AND `roles/storage.legacyBucketReader` on the bucket (objectViewer alone is not enough; see `unity-catalog-setup/GCP.md`).

### What to do when verification surfaces a cloud-account problem (not a deploy bug)

If a verification path FAILS due to a customer-account constraint — service quota exhausted, regional capacity unavailable for the chosen node type, missing org-policy approval, etc. — do NOT mark it SKIPPED-WITH-REASON and move on. Treat it the same as any quota error during deploy:

1. Stop verification.
2. Identify the constraint precisely (which AWS/Azure quota, which org policy, which approval is missing).
3. Tell the customer: what's blocking, where to fix it (Service Quotas page, IT ticket, etc.), and that verification will resume once cleared.
4. Re-run all three paths once the customer has cleared it.

The verify cluster hanging in `Starting Spark` for 30+ minutes is almost always either a customer EC2/VM capacity issue OR the JVM-warmup-vs-autotermination race (see `platform-provisioning/AWS.md` and `AZURE.md`). Diagnose which before declaring verification "blocked".

## Recovering when TF state is partial (verify resources created but not in state)

If a `terraform apply` is interrupted mid-create — Ctrl-C, OAuth token expired, network blip — the verify cluster (or warehouse, or job) may exist in the workspace but not in Terraform state. Re-running `terraform apply` then fails with:

```
Error: cannot create cluster: Cluster <name> already exists
```

(or the storage equivalent for warehouse/job: `name already in use`). **Never delete the workspace-side resource and let TF recreate** — you'll lose any manual fixes and may not have permission to delete it as the deployer SP. Two clean recovery paths:

1. **Import the existing resource into state** (preferred):
   ```bash
   # Cluster
   CID=$(databricks clusters list --filter "name=verify-classic-${WS}" --output json | jq -r '.[0].cluster_id')
   terraform import databricks_cluster.verify_classic "$CID"

   # SQL warehouse
   WID=$(databricks warehouses list --output json | jq -r '.[] | select(.name=="verify-serverless") | .id')
   terraform import databricks_sql_endpoint.verify_serverless "$WID"

   # Job
   JID=$(databricks jobs list --output json | jq -r '.[] | select(.settings.name=="verify-notebook") | .job_id')
   terraform import databricks_job.verify_notebook "$JID"
   ```
   Then re-run `terraform plan` — it should report no changes if the workspace-side resource matches your HCL. If it shows drift, decide per-attribute whether to update state or update the workspace.

2. **Delete via API + re-apply** (when you can't import — e.g. workspace lacks the resource type's import support):
   ```bash
   databricks clusters delete --cluster-id "$CID"
   ```
   Then `terraform apply` recreates from your HCL. Only safe when you're sure no other consumer depends on the resource (typically true for verify resources, since they're tagged `purpose=deployment-verification`).

**Diagnostic tip:** before either path, run `terraform state list | grep verify` to confirm the resource is genuinely missing from state vs just hidden in a module. Modules show as `module.foo.databricks_cluster.verify_classic`, not `databricks_cluster.verify_classic`.

## Cleanup

After PASS, clean up **only the verify-* resources this run created** (never anything else), and report to the customer exactly what you removed:

```bash
# Drop verify objects (idempotent — they were already DROPped per-path, but kill the resources)
terraform destroy -target=databricks_cluster.verify_classic
terraform destroy -target=databricks_sql_endpoint.verify_serverless
terraform destroy -target=databricks_job.verify_notebook
terraform destroy -target=databricks_notebook.verify_notebook
```

Or leave them in place if the customer wants the warehouses/clusters for ongoing work — but tag them clearly with `purpose=deployment-verification` so they can be found. Never delete pre-existing resources you did not create in this run to "make room" or reset state; if something is in the way, report it and ask.

## How this skill is referenced from other skills

- `platform-provisioning/SKILL.md` — references this as the mandatory final step after workspace deployment.
- `workspace-config/SKILL.md` — references this when deploying or modifying SQL warehouses, cluster policies, or job compute.
- Stress-test spawn prompts — reference this skill explicitly. If a stress-test agent reports "verified" without all three paths, the run is incomplete.
