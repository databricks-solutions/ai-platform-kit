# AWS Pre-flight Permission Check — Interpretation Rules

## 1. Purpose

This file tells Claude how to interpret the JSON blob emitted by
`scripts/precheck-aws.sh` and turn it into a compatibility matrix the customer
can act on. The script does not decide which topologies are supported — it only
runs `iam:SimulatePrincipalPolicy` against curated action groups and reads
service quotas. Claude reads those results against the rules below and
produces a single recommendation: which field-repo scenario to deploy, or
which permissions to request before proceeding.

The rules here are derived from the upstream
`databricks-solutions/technical-services-solutions` (branch
`feature-terraform-checker-clean`) file
`workspace-setup/terraform-checker/config/permissions/aws.yaml`. The script's
action lists are kept in sync with that yaml.

## 2. Compatibility matrix rules

The JSON's `iam_simulation` object has six groups: `vpc`, `privatelink`,
`s3_root_bucket`, `iam_cross_account`, `kms_cmk`, `unity_catalog`. A group is
**all-allowed** when every entry in `results[].allowed` is `true`. Each
topology is supported iff the listed groups are all-allowed and the listed
critical actions inside them are allowed.

| Topology | Required groups (must be all-allowed) | Critical actions that MUST be allowed |
|---|---|---|
| **Standard** (BYOVPC + workspace) | `vpc`, `s3_root_bucket`, `iam_cross_account` | `ec2:CreateVpc`, `ec2:CreateSubnet`, `ec2:CreateSecurityGroup`, `ec2:CreateNatGateway`, `ec2:AllocateAddress`, `ec2:CreateRouteTable`, `ec2:CreateRoute`, `s3:CreateBucket`, `s3:PutBucketPolicy`, `s3:PutEncryptionConfiguration`, `iam:CreateRole`, `iam:PutRolePolicy`, `iam:PassRole`, `iam:CreateInstanceProfile` |
| **Unity Catalog** | Standard + `unity_catalog` | All Standard actions + `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:ListBucket`, `sts:AssumeRole`, plus `iam:CreateRole` (re-used to create the UC trust-policy role — see caveat 6.b) |
| **PrivateLink** (classic, backend + REST) | Standard + `privatelink` | All Standard actions + `ec2:CreateVpcEndpoint`, `ec2:ModifyVpcEndpoint`, `ec2:DescribeVpcEndpointServices`, `ec2:DescribePrefixLists` |
| **Full** (Standard + UC + PrivateLink + CMK) | Standard + `unity_catalog` + `privatelink` + `kms_cmk` | All of the above + `kms:CreateKey`, `kms:PutKeyPolicy`, `kms:CreateGrant`, `kms:CreateAlias`, `kms:ScheduleKeyDeletion` |

**How to evaluate a group:**

```jsonc
// iam_simulation.vpc looks like:
{
  "label": "vpc",
  "simulated": true,
  "results": [
    { "action": "ec2:CreateVpc",   "decision": "allowed",        "allowed": true  },
    { "action": "ec2:DeleteRoute", "decision": "implicitDeny",   "allowed": false }
  ]
}
```

- If `simulated == false` → see caveat 6.c (treat as INDETERMINATE, not FAIL).
- A group is all-allowed only when every `results[].allowed == true`.
- For each topology, also confirm the critical-action subset is allowed even
  if the group is mostly-allowed. (A group can have a non-critical false and
  still be usable.)

**Region check:** if `region_check.ok == false`, no topology is deployable in
that region regardless of IAM. Surface this first.

**Caller identity sanity:** if the script returned `status == "FAILED"` with
`failure == "credentials_invalid"`, stop and ask the customer to re-auth
(`aws sso login` or refresh keys). Do not show the matrix.

**Simulation principal sanity:** the JSON has `identity.simulation_arn` and
`identity.simulation_arn_source`. STS assumed-role *session* ARNs (the kind
SSO produces, `arn:aws:sts::...:assumed-role/ROLE/SESSION`) are not accepted
by `iam:SimulatePrincipalPolicy` — the script converts them to the
underlying IAM role ARN:

- `simulation_arn_source == "caller_identity_arn"` → the caller is already an
  IAM user / native role; simulation is against the real principal.
- `simulation_arn_source == "resolved_via_get_role"` → the caller was an
  assumed-role session; script called `iam:GetRole` to look up the canonical
  role ARN (with path, e.g. `aws-reserved/sso.amazonaws.com/<region>/...`).
  Trust the simulation results.
- `simulation_arn_source == "constructed_fallback"` → `iam:GetRole` was
  denied; the script built a best-effort role ARN heuristically. Simulation
  results are still informative but may be wrong if the role lives at a
  non-standard path. Add a one-line "results best-effort, GetRole denied"
  note when presenting the matrix.

## 3. Quota interpretation

Walk the `quotas` array and raise warnings:

| Quota `name` | Warn when | Recommended ask |
|---|---|---|
| `VPCs per region` | quota value is null OR (quota value − current AWS VPC count) < 1 | Request +5 |
| `EC2-VPC Elastic IPs` | quota value < 5 | Request 10 |
| `NAT gateways per AZ` | quota value < 2 | Request 5 |
| `Security groups per VPC` | quota value < 50 | Request 100 |

If a quota entry has `error: "unable to read quota …"`, mark it `UNKNOWN`,
not a blocker. The Service Quotas API requires `servicequotas:GetServiceQuota`
which the deployer SP may not have; missing this perm does not block deploy.

Quotas are non-blocking — the customer can still deploy and request raises
later. Surface them as advisory.

## 4. Recommended scenario mapping

After computing the matrix, pick exactly one recommendation:

| Matrix result | Recommend | Why |
|---|---|---|
| Standard ✓, UC ✓, PrivateLink ✗ | `aws/aws-byovpc/` (field repo) | BYOVPC workspace with self-managed UC metastore. Default for production. |
| Standard ✓, PrivateLink ✓ (UC ✓ or ✗) | `aws/aws-byovpc-classic-privatelink/` (field repo) | Classic Private Link covers backend + REST API. Has `standard`, `fully_private`, `custom` modes — pick mode in the next intake round. |
| Standard ✓, UC ✗, PrivateLink ✗ | `aws/aws-byovpc/` (field repo), with UC deferred | Deploy workspace now, add UC later once `unity_catalog` group perms are granted. |
| Standard ✗ | **BLOCK** | Do not proceed. Tell the customer exactly which actions are missing from `vpc` / `s3_root_bucket` / `iam_cross_account` and which IAM-managed policies cover them (e.g. `AmazonVPCFullAccess`, `AmazonS3FullAccess`, `IAMFullAccess` — least-privilege variants exist but are out of scope here). |
| Full ✓ | `aws/aws-byovpc-classic-privatelink/` + add CMK module from SRA `aws/tf/credential.tf` / `kms.tf` | The field repo doesn't ship a CMK-on-AWS scenario — combine field repo PL scenario with the SRA's CMK pattern. |

If `region_check.ok == false`: block with a region-specific message
(e.g. "Databricks does not support `eu-north-1` — pick `eu-west-1`"). See
AWS.md "Supported AWS regions".

## 5. Output format Claude shows to the user

Produce exactly this shape, filled in from the JSON:

```
Pre-flight results (AWS account 123456789012, region us-east-1):

  Standard         ✓ SUPPORTED
  Unity Catalog    ✓ SUPPORTED
  PrivateLink      ✗ MISSING: ec2:CreateVpcEndpoint, ec2:ModifyVpcEndpoint
  Full             ✗ MISSING: ec2:CreateVpcEndpoint, kms:CreateKey, kms:PutKeyPolicy

Quota check:
  VPCs per region        OK (5 / 5 limit, 1 used)
  EC2-VPC Elastic IPs    WARN — limit is 5, recommend raising to 10
  NAT gateways per AZ    OK (5)
  Security groups/VPC    UNKNOWN — could not read quota (perm)

Recommendation: aws-byovpc (BYOVPC + UC metastore).
PrivateLink not available with current perms; deploy Standard + UC now and
request ec2:CreateVpcEndpoint / ec2:ModifyVpcEndpoint to add PL later.

Proceed with aws-byovpc, or pause to request PrivateLink perms first?
```

Rules for filling this in:

- For each topology that is supported, print `✓ SUPPORTED` only.
- For each topology that is **not** supported, print
  `✗ MISSING: <comma-separated action names>`. List the specific actions whose
  `allowed == false`, not the group label. Truncate to the 5 most consequential
  if the list is longer; append `… (N more)`.
- If `simulated == false` for any required group, print
  `? INDETERMINATE — simulation failed (federated/root principal?)` for that
  topology instead of ✗.
- Always print the quota block, even if everything is OK.
- The recommendation paragraph is one or two short sentences, then a single
  proceed/pause question. Do not bury the recommendation under a wall of text.
- If the matrix gives **Standard ✗**, replace the recommendation with:
  `Cannot proceed — needs: <missing actions>. Have the AWS account admin
  attach <suggested managed policy or inline statement> and re-run the
  pre-flight.`

## 6. Caveats

Surface these honestly. They are not optional — IAM simulation is structurally
limited, and the customer needs to know what the green checks do and don't
prove.

a. **Resource-level conditions are invisible to simulation.**
   `iam:SimulatePrincipalPolicy` evaluates actions against `*`-resource ARNs by
   default. A policy that allows `s3:CreateBucket` only on
   `arn:aws:s3:::approved-*` will simulate as `allowed` even though the
   customer's intended bucket name doesn't match. Real allow/deny is only
   confirmed at write time.

b. **Cross-account trust policy correctness for UC is NOT verified.**
   Unity Catalog's storage credential IAM role needs a trust policy that
   trusts the Databricks UC AWS principal (`414351767826`) with an
   `sts:ExternalId` matching the storage credential's auto-generated UUID.
   Simulation only confirms `iam:CreateRole` is allowed — it cannot verify
   the trust JSON shape. The only post-hoc check is
   `databricks_storage_credential.validate()` after the deploy; if that
   fails, see AWS.md "IAM trust policy propagation race vs UC
   external_location".

c. **Federated / root principals may simulate as failures even when
   they work.** If `iam_simulation.<group>.simulated == false`, the
   `simulate-principal-policy` call itself errored. The script now
   pre-resolves SSO assumed-role sessions to their underlying role ARN
   (see "Simulation principal sanity" in §2), so SSO is no longer in this
   bucket. What remains: the account root user, federated identities, and
   roles where `iam:GetRole` was denied AND the fallback-constructed ARN
   doesn't match a real role. Treat affected groups as `INDETERMINATE`,
   not `MISSING`. If the customer is a known account admin and a group
   still won't simulate, the principal type is the most likely reason —
   not missing perms.

d. **The pre-check is `--verify-only` style.** Write-time failures it cannot
   catch include: S3 bucket name collisions across AWS, KMS key alias
   collisions, hitting a quota mid-`terraform apply` because another team
   member is consuming the same quota in parallel, AWS Marketplace
   subscription state for Databricks (which requires
   `AWSMarketplaceManageSubscriptions` — not in the script's action set),
   and Databricks-side limits (e.g. workspaces per account, metastores per
   region).

e. **The script does not check the Databricks account side.** It does not
   verify the account-admin SP or its OAuth secret. Run the AWS.md
   "Pre-flight checks" section (`databricks auth profiles`, env-var hygiene)
   in addition to this script.

f. **The action lists are a point-in-time snapshot.** The upstream yaml
   evolves; if a Databricks release adds new required actions (e.g. for a
   new networking feature), this script will not flag them. Re-sync the
   action lists from the upstream yaml before each major release cycle.

## 7. Real-world gotchas observed during testing

These were caught by the first real-creds run of `precheck-aws.sh`. The
script has since been patched, but they're documented here so future
maintainers know why the code looks the way it does:

a. **STS assumed-role session ARNs are rejected by SimulatePrincipalPolicy.**
   Calling `iam:simulate-principal-policy --policy-source-arn` with
   `arn:aws:sts::ACCT:assumed-role/ROLE/SESSION` returns `InvalidInput:
   Invalid ARN`. AWS expects an IAM user / role / federated-user ARN.
   **Fix in script:** detect `^arn:aws:sts::.*:assumed-role/` and call
   `iam:GetRole` to resolve to the canonical role ARN.

b. **SSO-managed roles live at a non-default path.** Roles created by AWS
   IAM Identity Center sit at
   `arn:aws:iam::ACCT:role/aws-reserved/sso.amazonaws.com/<region>/AWSReservedSSO_<NAME>_<HASH>`.
   The `<region>` segment is present in some tenants and absent in others
   — there is no documented rule. **Fix in script:** always prefer
   `iam:GetRole` (which returns the real path) over heuristic construction.
   The fallback only triggers when `iam:GetRole` is denied.

c. **`aws ec2 describe-regions` needs `--region` (endpoint) even when
   you're querying region availability.** Without `AWS_DEFAULT_REGION` set
   and no `--region` flag, the call fails with "You must specify a region"
   and the script's silent-fallback declared the region unavailable.
   **Fix in script:** pass `--region "$REGION"` to the CLI in addition to
   the `--region-names` filter.

d. **Quota name collisions / sandbox overrides.** During testing, the
   `Security groups per VPC` quota returned `5` in a sandbox account
   (default is 2500). This is likely a sandbox-imposed cap, but it could
   also be a quota-code naming clash. Don't treat low SG-per-VPC numbers
   as a script bug without manually re-running
   `aws service-quotas get-service-quota --service-code vpc --quota-code L-2AFB9258`.
