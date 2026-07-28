#!/usr/bin/env bash
# precheck-aws.sh — Databricks deploy permission pre-flight for AWS
#
# Mirrors the verify-only behaviour of upstream terraform-checker
# (databricks-solutions/technical-services-solutions, branch
#  feature-terraform-checker-clean, path workspace-setup/terraform-checker).
# Permission lists are derived from config/permissions/aws.yaml in that repo
# (last synced 2025-01).
#
# MODIFIED from that upstream: reimplemented as standalone bash (upstream is
# Python), reduced to verify-only permission pre-flight, and adapted for
# consumption by Claude. Upstream and this file are both under the DB license.
#
# Pure bash + aws CLI + jq. No Python, no resource creation.
# Output: one JSON blob to stdout. Intended to be consumed by Claude using
# the rules in aws-1.5-precheck.md.
#
# Usage:
#   bash precheck-aws.sh --region us-east-1 [--profile NAME]

set -euo pipefail

REGION=""
PROFILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --region) REGION="$2"; shift 2 ;;
    --profile) PROFILE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --region REGION [--profile NAME]"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$REGION" ]]; then
  echo "ERROR: --region is required" >&2
  exit 2
fi

AWS=(aws)
[[ -n "$PROFILE" ]] && AWS+=(--profile "$PROFILE")

# ----- preflight: tools present -----
for tool in aws jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: $tool not found on PATH" >&2
    exit 3
  fi
done

# ----- 1. caller identity -----
if ! caller_json=$("${AWS[@]}" sts get-caller-identity --output json 2>/dev/null); then
  jq -n --arg region "$REGION" '{
    schema_version: "1",
    cloud: "aws",
    region: $region,
    status: "FAILED",
    failure: "credentials_invalid",
    message: "aws sts get-caller-identity failed; creds missing or expired"
  }'
  exit 0
fi

account_id=$(jq -r .Account <<<"$caller_json")
caller_arn=$(jq -r .Arn   <<<"$caller_json")
caller_uid=$(jq -r .UserId <<<"$caller_json")

# ----- 1b. resolve principal ARN for simulate-principal-policy -----
# AWS's SimulatePrincipalPolicy requires an IAM-User / IAM-Role / federated-user
# ARN. An STS assumed-role *session* ARN
# (arn:aws:sts::ACCOUNT:assumed-role/ROLE_NAME/SESSION_NAME) is rejected with
# InvalidInput. Convert it to the underlying role ARN.
sim_arn="$caller_arn"
sim_arn_source="caller_identity_arn"
if [[ "$caller_arn" =~ ^arn:aws:sts::([0-9]+):assumed-role/([^/]+)/(.+)$ ]]; then
  role_name="${BASH_REMATCH[2]}"
  # iam:GetRole gives the canonical ARN (with /path/ for SSO-managed roles)
  if role_arn=$("${AWS[@]}" iam get-role --role-name "$role_name" \
                  --query 'Role.Arn' --output text 2>/dev/null); then
    sim_arn="$role_arn"
    sim_arn_source="resolved_via_get_role"
  else
    # Fallback: best-effort construction. Works for normal roles; SSO-managed
    # roles need the /aws-reserved/sso.amazonaws.com/ path, which we add
    # heuristically when the role name starts with AWSReservedSSO_.
    if [[ "$role_name" == AWSReservedSSO_* ]]; then
      sim_arn="arn:aws:iam::${account_id}:role/aws-reserved/sso.amazonaws.com/${role_name}"
    else
      sim_arn="arn:aws:iam::${account_id}:role/${role_name}"
    fi
    sim_arn_source="constructed_fallback"
  fi
fi

# ----- 2. region availability -----
# describe-regions needs --region (endpoint), separate from --region-names (filter).
region_ok="true"
region_msg=""
if ! "${AWS[@]}" ec2 describe-regions --region "$REGION" \
       --region-names "$REGION" --output json >/dev/null 2>&1; then
  region_ok="false"
  region_msg="Region $REGION not enabled or not visible to this principal"
fi

# ----- 3. IAM permission simulation -----
# Grouped by resource category for matrix interpretation.
# simulate-principal-policy accepts up to 50 actions per call.

simulate() {
  local label="$1"; shift
  local actions=("$@")
  local out
  if ! out=$("${AWS[@]}" iam simulate-principal-policy \
        --policy-source-arn "$sim_arn" \
        --action-names "${actions[@]}" \
        --output json 2>&1); then
    # simulate can fail entirely for federated/root principals — record gracefully
    jq -n --arg label "$label" --arg err "$out" '{
      label: $label, simulated: false, error: $err, results: []
    }'
    return
  fi
  jq --arg label "$label" '{
    label: $label,
    simulated: true,
    results: [ .EvaluationResults[] |
      { action: .EvalActionName,
        decision: .EvalDecision,
        allowed: (.EvalDecision == "allowed") } ]
  }' <<<"$out"
}

sim_vpc=$(simulate "vpc" \
  ec2:CreateVpc ec2:DeleteVpc ec2:DescribeVpcs ec2:ModifyVpcAttribute \
  ec2:CreateSubnet ec2:DeleteSubnet ec2:ModifySubnetAttribute ec2:DescribeSubnets \
  ec2:CreateSecurityGroup ec2:DeleteSecurityGroup \
  ec2:AuthorizeSecurityGroupIngress ec2:AuthorizeSecurityGroupEgress \
  ec2:RevokeSecurityGroupIngress ec2:RevokeSecurityGroupEgress \
  ec2:CreateInternetGateway ec2:AttachInternetGateway ec2:DeleteInternetGateway \
  ec2:CreateNatGateway ec2:DeleteNatGateway ec2:AllocateAddress ec2:ReleaseAddress \
  ec2:CreateRouteTable ec2:CreateRoute ec2:DeleteRoute ec2:AssociateRouteTable \
  ec2:CreateTags ec2:DescribeAvailabilityZones)

sim_privatelink=$(simulate "privatelink" \
  ec2:CreateVpcEndpoint ec2:DeleteVpcEndpoints ec2:ModifyVpcEndpoint \
  ec2:DescribeVpcEndpoints ec2:DescribeVpcEndpointServices ec2:DescribePrefixLists)

sim_s3=$(simulate "s3_root_bucket" \
  s3:CreateBucket s3:DeleteBucket s3:ListAllMyBuckets \
  s3:GetBucketPolicy s3:PutBucketPolicy s3:DeleteBucketPolicy \
  s3:PutBucketVersioning s3:PutEncryptionConfiguration \
  s3:PutBucketPublicAccessBlock s3:PutBucketTagging)

sim_iam=$(simulate "iam_cross_account_role" \
  iam:CreateRole iam:DeleteRole iam:GetRole \
  iam:PutRolePolicy iam:DeleteRolePolicy iam:GetRolePolicy \
  iam:AttachRolePolicy iam:DetachRolePolicy iam:UpdateAssumeRolePolicy \
  iam:CreateInstanceProfile iam:DeleteInstanceProfile iam:AddRoleToInstanceProfile \
  iam:PassRole iam:CreatePolicy iam:DeletePolicy iam:SimulatePrincipalPolicy)

sim_kms=$(simulate "kms_cmk" \
  kms:CreateKey kms:DescribeKey kms:ScheduleKeyDeletion \
  kms:CreateAlias kms:UpdateAlias kms:DeleteAlias \
  kms:GetKeyPolicy kms:PutKeyPolicy \
  kms:CreateGrant kms:RevokeGrant kms:TagResource)

sim_uc_storage=$(simulate "unity_catalog_storage" \
  s3:GetObject s3:PutObject s3:DeleteObject \
  s3:ListBucket s3:GetBucketLocation \
  sts:AssumeRole)

# ----- 4. service quotas -----
quota() {
  local code="$1" qcode="$2" name="$3"
  local out
  if out=$("${AWS[@]}" service-quotas get-service-quota \
        --service-code "$code" --quota-code "$qcode" \
        --region "$REGION" --output json 2>/dev/null); then
    jq --arg name "$name" '{name: $name,
       value: .Quota.Value, adjustable: .Quota.Adjustable}' <<<"$out"
  else
    jq -n --arg name "$name" '{name: $name, value: null,
       error: "unable to read quota (perm or region issue)"}'
  fi
}

q_vpcs=$(quota vpc L-F678F1CE         "VPCs per region")
q_eips=$(quota ec2 L-0263D0A3         "EC2-VPC Elastic IPs")
q_nats=$(quota vpc L-FE5A380F         "NAT gateways per AZ")
q_sgs=$(quota  vpc L-2AFB9258         "Security groups per VPC")

# ----- 5. assemble final JSON -----
jq -n \
  --arg schema "1" \
  --arg region "$REGION" \
  --arg account_id "$account_id" \
  --arg caller_arn "$caller_arn" \
  --arg caller_uid "$caller_uid" \
  --arg sim_arn "$sim_arn" \
  --arg sim_arn_source "$sim_arn_source" \
  --argjson region_ok  "$region_ok" \
  --arg     region_msg "$region_msg" \
  --argjson vpc        "$sim_vpc" \
  --argjson privatelink "$sim_privatelink" \
  --argjson s3         "$sim_s3" \
  --argjson iam        "$sim_iam" \
  --argjson kms        "$sim_kms" \
  --argjson uc_storage "$sim_uc_storage" \
  --argjson q_vpcs "$q_vpcs" \
  --argjson q_eips "$q_eips" \
  --argjson q_nats "$q_nats" \
  --argjson q_sgs  "$q_sgs" \
  '{
    schema_version: $schema,
    cloud: "aws",
    region: $region,
    status: "OK",
    identity: {
      account_id:           $account_id,
      arn:                  $caller_arn,
      user_id:              $caller_uid,
      simulation_arn:       $sim_arn,
      simulation_arn_source: $sim_arn_source
    },
    region_check: { ok: $region_ok, message: $region_msg },
    iam_simulation: {
      vpc:               $vpc,
      privatelink:       $privatelink,
      s3_root_bucket:    $s3,
      iam_cross_account: $iam,
      kms_cmk:           $kms,
      unity_catalog:     $uc_storage
    },
    quotas: [$q_vpcs, $q_eips, $q_nats, $q_sgs]
  }'
