# GCP Pre-flight Permission Check — Interpretation Rules

## 1. Purpose

This file tells Claude how to interpret the JSON blob emitted by
`scripts/precheck-gcp.sh` and turn it into a compatibility matrix the customer
can act on. The script does not decide which topologies are supported — it
calls `gcloud projects test-iam-permissions` against curated permission groups,
checks which required Google APIs are enabled on the project, and reads a
handful of Compute quotas. Claude reads those results against the rules below
and produces a single recommendation: which field-repo scenario to deploy, or
which permissions / APIs to request before proceeding.

The rules here are derived from the upstream
`databricks-solutions/technical-services-solutions` (branch
`feature-terraform-checker-clean`) file
`workspace-setup/terraform-checker/config/permissions/gcp.yaml`. The script's
permission lists are kept in sync with that yaml.

## 2. Required APIs (blocker check)

Before evaluating IAM, walk `required_apis[]`. Any entry with
`enabled: false` is a hard blocker for the topology that needs it, but APIs
are fast and free to enable — flag them, but don't make it sound scary.

| API | Needed for | If disabled |
|---|---|---|
| `compute.googleapis.com` | Every topology — VPC / subnet / firewall / router | Blocks all topologies |
| `storage.googleapis.com` | Standard (root bucket) + UC | Blocks Standard, UC |
| `iam.googleapis.com` | Service accounts + IAM bindings | Blocks all topologies |
| `cloudresourcemanager.googleapis.com` | Project IAM policy reads/writes | Blocks all topologies |
| `cloudkms.googleapis.com` | CMEK only | Blocks Full (CMEK) only |
| `logging.googleapis.com` | Workspace log delivery | Blocks all topologies |
| `servicenetworking.googleapis.com` | Private services access (UC, PSC) | Blocks UC, Full |

**Remediation Claude should suggest:** one line per disabled API —

> `gcloud services enable <api> --project <project_id>`

Surface API enablement at the top of the output (before the matrix), since a
missing API can present as "all perms denied" downstream and is much cheaper
to fix.

## 3. Compatibility matrix rules

The JSON's `iam_permissions` object has eight groups: `vpc_network`,
`subnetwork`, `firewall`, `router_nat`, `service_account`, `iam_binding`,
`storage_bucket`, `kms`. A group is **all-granted** when every entry in
`results[].granted` is `true`. Each topology is supported iff the listed
groups are all-granted AND the required APIs are enabled.

GCP has three meaningful deployment shapes (simpler than AWS/Azure):

| Topology | Required groups (must be all-granted) | Required APIs |
|---|---|---|
| **Standard** (BYOVPC + workspace) | `vpc_network`, `subnetwork`, `firewall`, `router_nat`, `service_account`, `iam_binding` | `compute`, `iam`, `cloudresourcemanager`, `logging`, `servicenetworking` |
| **Unity Catalog** | Standard + `storage_bucket` | Standard APIs + `storage` |
| **Full (CMEK)** | Standard + `storage_bucket` + `kms` | Standard APIs + `storage` + `cloudkms` |

**How to evaluate a group:**

```jsonc
// iam_permissions.vpc_network looks like:
{
  "label": "vpc_network",
  "tested": true,
  "results": [
    { "permission": "compute.networks.create",       "granted": true  },
    { "permission": "compute.networks.delete",       "granted": true  },
    { "permission": "compute.networks.get",          "granted": true  },
    { "permission": "compute.networks.updatePolicy", "granted": false }
  ]
}
```

- If `tested == false` → see caveat 7.b (treat as INDETERMINATE, not FAIL).
- A group is all-granted only when every `results[].granted == true`.
- When a topology fails, list the specific permissions whose `granted == false`
  in the output — not just the group label.

**Permission → topology mapping (for "what does this denied perm block?"):**

| Group | Permissions | Blocks if missing |
|---|---|---|
| `vpc_network` | `compute.networks.{create,delete,get,updatePolicy}` | Standard, UC, Full |
| `subnetwork` | `compute.subnetworks.{create,delete,get,update,use,setPrivateIpGoogleAccess}` | Standard, UC, Full |
| `firewall` | `compute.firewalls.{create,delete,get,update}` | Standard, UC, Full |
| `router_nat` | `compute.routers.{create,delete,get,update}` | Standard, UC, Full |
| `service_account` | `iam.serviceAccounts.{create,delete,get,actAs}`, `iam.serviceAccountKeys.{create,delete}` | Standard, UC, Full |
| `iam_binding` | `resourcemanager.projects.{getIamPolicy,setIamPolicy}` | Standard, UC, Full |
| `storage_bucket` | `storage.buckets.{create,delete,get,update,getIamPolicy,setIamPolicy}` | UC, Full |
| `kms` | `cloudkms.keyRings.{create,get}`, `cloudkms.cryptoKeys.{create,get,update}` | Full only |

**Region check:** if `region_check.ok == false`, no topology is deployable in
that region in this project (typical cause: region exists but
`compute.googleapis.com` is disabled, OR the region name is mistyped).
Surface this first, before the matrix.

**Caller identity sanity:** if the script returned `status == "FAILED"` with
`failure == "credentials_invalid"`, stop and tell the customer to run
`gcloud auth login` (or `gcloud auth application-default login` for ADC). Do
not show the matrix. Same for `failure == "project_inaccessible"` — that
means the principal can't even read the project; nothing else will work.

## 4. Quota interpretation

Walk the `quotas` array and raise warnings. All four are project-wide global
Compute quotas:

| Quota `metric` | Warn when | Why |
|---|---|---|
| `NETWORKS` | `(limit − usage) < 1` | Need 1 free for the Databricks VPC |
| `SUBNETWORKS` | `(limit − usage) < 2` | Need primary + pod/services secondaries; subnets count toward the per-network limit |
| `FIREWALLS` | `(limit − usage) < 5` | Databricks creates several ingress/egress rules per workspace |
| `CPUS` | `limit < 24` | Default driver + a few workers chew through vCPUs immediately |

If the `quotas` array is empty, the script could not read project quotas
(typically because `compute.googleapis.com` is disabled, which is already a
blocker from §2). Mark quota check as `UNKNOWN`, not a failure.

Quotas are advisory — the customer can still deploy and request raises
later via `gcloud compute project-info` or the Cloud Console. Note that
**regional** quotas (per-region CPUS, IN_USE_ADDRESSES, etc.) are not in
this snapshot; the script only reads project-wide global quotas. The first
real deploy will surface regional limits if they bite.

## 5. Recommended scenario mapping

After computing the matrix, pick exactly one recommendation:

| Matrix result | Recommend | Why |
|---|---|---|
| Standard ✓, single project, no host/service mention | `gcp/gcp-byovpc-standalone/` (field repo) | Custom VPC + Cloud Router + Cloud NAT + SA impersonation in one project. Default for production. |
| Standard ✓, customer mentions Shared VPC / host project / service project / org-level networking | `gcp/gcp-byovpc-shared-vpc/` (field repo) | Workspace lives in a service project, networking in a host project. See caveat 7.c. |
| Standard ✓, UC ✓ | Same scenario as above, extend with UC metastore + storage credential | Both field-repo scenarios can be extended to add UC. See caveat 7.d on bucket-level perms. |
| Standard ✓, UC ✗ | Standalone or Shared-VPC scenario, with UC deferred | Deploy workspace now, add UC later once `storage_bucket` group is granted. |
| Standard ✗ | **BLOCK** | Do not proceed. Tell the customer exactly which permissions are missing and which predefined GCP role usually covers them (e.g. `roles/compute.networkAdmin` covers `vpc_network`/`subnetwork`/`firewall`/`router_nat`; `roles/iam.serviceAccountAdmin` + `roles/resourcemanager.projectIamAdmin` cover `service_account`/`iam_binding`). |
| Required APIs not all enabled | **BLOCK** until enabled | List the `gcloud services enable` commands. Cheap fix — most accounts have permission to enable APIs even when they can't yet create resources. |
| Full (CMEK) ✓ | Standalone or Shared-VPC scenario + add CMEK from `terraform-databricks-sra` | The field repo doesn't ship a CMEK-on-GCP scenario — combine the field repo with the SRA's GCP CMEK pattern. |

If `region_check.ok == false`: block with a region-specific message. Common
causes: region typo (e.g. `us-east-1` instead of `us-east1` — note GCP omits
the dash), or `compute.googleapis.com` not enabled in the project. See
GCP.md for supported regions.

## 6. Output format Claude shows to the user

Produce exactly this shape, filled in from the JSON:

```
Pre-flight results (GCP project my-databricks-prod, region us-central1):

  Standard       ✓ SUPPORTED
  Unity Catalog  ✓ SUPPORTED
  Full (CMEK)    ✗ MISSING: cloudkms.keyRings.create, cloudkms.cryptoKeys.create, cloudkms.cryptoKeys.update

API enablement:
  compute, storage, iam, cloudresourcemanager, logging, servicenetworking  ENABLED
  cloudkms                                                                 DISABLED

Quota check:
  NETWORKS     OK   (5 / 5 limit, 0 used)
  SUBNETWORKS  OK   (275 / 275 limit, 3 used)
  FIREWALLS    WARN — limit is 100, only 2 headroom; recommend raising to 200
  CPUS         OK   (limit 72)

Recommendation: gcp-byovpc-standalone (BYOVPC + UC metastore).
CMEK not available — cloudkms API is disabled and KMS perms are missing.
Enable with: gcloud services enable cloudkms.googleapis.com --project my-databricks-prod,
then request the KMS perms above to add CMEK later.

Proceed with gcp-byovpc-standalone, or pause to enable CMEK first?
```

Rules for filling this in:

- For each topology that is supported, print `✓ SUPPORTED` only.
- For each topology that is **not** supported, print
  `✗ MISSING: <comma-separated permission names>`. List the specific
  permissions whose `granted == false`, not the group label. Truncate to the
  5 most consequential if the list is longer; append `… (N more)`.
- If `tested == false` for any required group, print
  `? INDETERMINATE — test-iam-permissions failed for this principal` for that
  topology instead of `✗`.
- The API enablement block is one line of comma-separated enabled APIs +
  one line per disabled API. If everything is enabled, collapse to a single
  `all required APIs enabled` line.
- Always print the quota block. If `quotas` is empty, print
  `UNKNOWN — could not read project quotas (compute API disabled?)`.
- The recommendation paragraph is one or two short sentences, then a single
  proceed/pause question. Do not bury the recommendation under a wall of text.
- If the matrix gives **Standard ✗**, replace the recommendation with:
  `Cannot proceed — needs: <missing permissions or APIs>. Have the project
  IAM admin grant <suggested predefined role(s)> on project <id> and re-run
  the pre-flight.`
- If a Shared-VPC topology is suspected (customer mentioned host project,
  service project, org-level networking, or VPCs they don't control),
  append a one-line note: `Shared VPC suspected — also run this pre-check
  in the host project; see caveat 7.c.`

## 7. Caveats

Surface these honestly. They matter — `test-iam-permissions` is project-scoped
and the customer needs to know what the green checks do and don't prove.

a. **Project-level only.** `gcloud projects test-iam-permissions` tests
   permissions at the project resource. Bucket-level
   (`storage.objects.*` on a specific bucket), key-ring-level
   (`cloudkms.cryptoKeyEncrypterDecrypter` on a specific key), and
   service-account-level (`iam.serviceAccounts.actAs` on a specific SA — the
   project-level grant works, but customers often bind it narrowly) checks
   are NOT performed. UC storage credentials, CMEK key access by the
   Databricks robot SA, and SA impersonation chains can still fail post-deploy
   even when this pre-check is green. The only post-hoc check for UC is
   `databricks_storage_credential.validate()`.

b. **`tested == false` is not the same as a denied permission.** Some
   principals (notably service accounts missing
   `resourcemanager.projects.testIamPermissions` on the project, and certain
   organization-level grants) can't run `test-iam-permissions` at all.
   When `tested == false`, the script writes `granted: false` for every
   permission in that group as a placeholder — treat the group as
   `INDETERMINATE`, not `MISSING`. Re-run the script as the actual deployer
   principal, not from an admin context.

c. **Shared VPC requires a second pre-check.** This script tests permissions
   only in the project passed via `--project`. Shared-VPC deployments split
   resources across two projects: the workspace + GKE + SA live in the
   **service project**, the VPC + subnets + firewalls + router live in the
   **host project**. Running this script against the service project will
   show `vpc_network`, `subnetwork`, `firewall`, `router_nat` as missing —
   that's expected and correct. Re-run the script against the host project
   to verify the network-admin perms there. The `gcp-byovpc-shared-vpc` field
   repo scenario expects both project-side checks to pass.

d. **GCP UC needs more than the bucket-create perms tested here.** The
   `storage_bucket` group confirms the deployer can create the GCS bucket
   that backs the UC metastore root. UC's runtime access uses a *different*
   GCP service account (the Databricks-managed UC SA) that must be granted
   `storage.objectAdmin` (or finer) on that bucket, plus
   `iam.serviceAccounts.actAs` on the workspace SA. Those grants are made
   *after* bucket/SA creation, so this pre-check cannot verify them — but
   it can confirm the deployer has the IAM perms needed to make those
   grants (`iam_binding` group covers `setIamPolicy`).

e. **Custom IAM roles are fine.** This script tests effective permissions,
   not role names. A custom role that grants the listed permissions will
   pass; a predefined role like `roles/owner` will also pass. We don't
   inspect role definitions — only what the principal can actually do.

f. **API enablement is point-in-time.** `required_apis[].enabled == true`
   means the API is on right now. It does NOT mean the principal has
   permission to *use* that API — that's what the IAM group checks are for.
   Conversely, a disabled API with all IAM perms granted will still fail
   at deploy time; enable the API first.

g. **The script does not check the Databricks account side.** It does not
   verify the Databricks account admin user, the account ID, or
   `accounts.gcp.databricks.com` reachability. Run the GCP.md
   "Authentication" section in addition to this script.

h. **The permission lists are a point-in-time snapshot.** The upstream yaml
   evolves; if a Databricks release adds new required permissions (e.g. for
   a new GCP networking feature like Private Service Connect for serverless),
   this script will not flag them. Re-sync the permission lists from the
   upstream yaml before each major release cycle.

## 8. Real-world gotchas observed during testing

These were caught by the first real-creds run of `precheck-gcp.sh` against
the `gcp-sandbox-field-eng` project. The script has since been patched;
documented here so future maintainers know why the code looks the way it
does:

a. **`gcloud projects test-iam-permissions` is not a real gcloud subcommand.**
   The capability exists only as the REST API endpoint
   `projects:testIamPermissions` on `cloudresourcemanager.googleapis.com`.
   `gcloud projects test-iam-permissions PROJECT --permissions=...` returns
   `ERROR: Invalid choice: 'test-iam-permissions'`. The first version of
   the script invoked this fake subcommand and silently fell back to
   `tested: false / denied: N` for every group — making it look like every
   GCP customer had zero permissions. **Fix in script:** call the REST
   endpoint directly via `curl` with the OAuth bearer token from
   `gcloud auth print-access-token`. Added `curl` as a required tool
   alongside `gcloud` and `jq`.

b. **`CPUS` is a regional quota, not a global one.** `gcloud compute
   project-info describe` returns `NETWORKS`, `SUBNETWORKS`, `FIREWALLS` but
   does **not** include `CPUS`. CPUS lives under
   `gcloud compute regions describe REGION`. **Fix in script:** query both
   endpoints and tag each quota with a `scope` field (`"global"` or
   `"region:<region>"`). Same approach picks up `IN_USE_ADDRESSES`, which
   is regional and matters for NAT gateway sizing.

c. **`storage_bucket` perms can split unexpectedly under composite roles.**
   The test sandbox principal showed `storage.buckets.create` and `.delete`
   as granted but `.get`, `.update`, `.getIamPolicy`, `.setIamPolicy` as
   denied — an unusual combination implying a custom role or org constraint
   that allows lifecycle but not management. The matrix rules correctly
   blocked Unity Catalog (which needs `setIamPolicy` to grant the UC SA
   bucket access). Don't treat this as a script bug: it's
   `testIamPermissions` reporting honestly at *project* scope, and the user
   may have additional perms granted at *bucket* scope that aren't visible
   here. If the matrix blocks UC over storage perms and the customer
   insists they can deploy UC, ask which storage-admin role they have at
   what scope before debugging the script.
