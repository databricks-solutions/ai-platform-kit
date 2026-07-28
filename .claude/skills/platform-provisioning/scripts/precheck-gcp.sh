#!/usr/bin/env bash
# precheck-gcp.sh — Databricks deploy permission pre-flight for GCP
#
# Mirrors the verify-only behaviour of upstream terraform-checker
# (databricks-solutions/technical-services-solutions, branch
#  feature-terraform-checker-clean, path workspace-setup/terraform-checker).
# Permission lists are derived from config/permissions/gcp.yaml and the
# logic in checkers/gcp.py in that repo (last synced 2025-01).
#
# MODIFIED from that upstream: reimplemented as standalone bash (upstream is
# Python), reduced to verify-only permission pre-flight, and adapted for
# consumption by Claude. Upstream and this file are both under the DB license.
#
# Pure bash + gcloud CLI + jq. No Python, no resource creation.
# Output: one JSON blob to stdout. Intended to be consumed by Claude using
# the rules in gcp-1.5-precheck.md.
#
# Usage:
#   bash precheck-gcp.sh --project PROJECT_ID --region REGION \
#        [--credentials-file PATH]

set -euo pipefail

PROJECT_ID=""
REGION=""
CREDENTIALS_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --project) PROJECT_ID="$2"; shift 2 ;;
    --region) REGION="$2"; shift 2 ;;
    --credentials-file) CREDENTIALS_FILE="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --project PROJECT_ID --region REGION [--credentials-file PATH]"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$PROJECT_ID" || -z "$REGION" ]]; then
  echo "ERROR: --project and --region are required" >&2
  exit 2
fi

# ----- preflight: tools present -----
for tool in gcloud jq curl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "ERROR: $tool not found on PATH" >&2
    exit 3
  fi
done

# Export credentials file if provided (gcloud will pick it up via ADC for
# library calls; gcloud commands themselves use the active account from the
# CLI config, so we also activate the SA key when present).
if [[ -n "$CREDENTIALS_FILE" ]]; then
  if [[ ! -f "$CREDENTIALS_FILE" ]]; then
    echo "ERROR: credentials file not found: $CREDENTIALS_FILE" >&2
    exit 3
  fi
  export GOOGLE_APPLICATION_CREDENTIALS="$CREDENTIALS_FILE"
fi

# ----- 1. identity / project state -----
active_account=$(gcloud auth list --filter=status:ACTIVE \
                   --format="value(account)" 2>/dev/null | head -n1 || true)

if [[ -z "$active_account" ]]; then
  jq -n --arg project "$PROJECT_ID" --arg region "$REGION" '{
    schema_version: "1",
    cloud: "gcp",
    region: $region,
    status: "FAILED",
    failure: "credentials_invalid",
    message: "gcloud auth list shows no ACTIVE account; creds missing or expired"
  }'
  exit 0
fi

if ! project_json=$(gcloud projects describe "$PROJECT_ID" \
                     --format=json 2>/dev/null); then
  jq -n --arg project "$PROJECT_ID" --arg region "$REGION" \
        --arg account "$active_account" '{
    schema_version: "1",
    cloud: "gcp",
    region: $region,
    status: "FAILED",
    failure: "project_inaccessible",
    message: ("gcloud projects describe " + $project +
              " failed; project missing or principal " + $account +
              " lacks resourcemanager.projects.get")
  }'
  exit 0
fi

project_number=$(jq -r '.projectNumber // ""' <<<"$project_json")
project_state=$( jq -r '.lifecycleState // ""' <<<"$project_json")
project_parent=$(jq -r 'if .parent then (.parent.type + ":" + .parent.id) else "" end' <<<"$project_json")

# ----- 2. region availability -----
region_ok="true"
region_msg=""
if ! gcloud compute regions describe "$REGION" --project "$PROJECT_ID" \
       --format=json >/dev/null 2>&1; then
  region_ok="false"
  region_msg="Region $REGION not available in project $PROJECT_ID (or compute.googleapis.com not enabled)"
fi

# ----- 3. required APIs enabled -----
required_apis=(
  compute.googleapis.com
  storage.googleapis.com
  iam.googleapis.com
  cloudresourcemanager.googleapis.com
  cloudkms.googleapis.com
  logging.googleapis.com
  servicenetworking.googleapis.com
)

enabled_apis_raw=$(gcloud services list --enabled --project "$PROJECT_ID" \
                     --format="value(config.name)" 2>/dev/null || echo "")

apis_json="["
first=1
for api in "${required_apis[@]}"; do
  if grep -Fxq "$api" <<<"$enabled_apis_raw"; then
    enabled="true"
  else
    enabled="false"
  fi
  [[ $first -eq 1 ]] && first=0 || apis_json+=","
  apis_json+=$(jq -nc --arg api "$api" --argjson enabled "$enabled" \
                 '{api:$api, enabled:$enabled}')
done
apis_json+="]"

# ----- 4. IAM permission testing -----
# There is no `gcloud projects test-iam-permissions` CLI subcommand. The
# capability exists only as the REST API endpoint
# https://cloudresourcemanager.googleapis.com/v1/projects/{PROJECT}:testIamPermissions
# which echoes back only the permissions the caller actually holds. We call
# it directly with curl + an OAuth access token from gcloud.
GCP_ACCESS_TOKEN=$(gcloud auth print-access-token 2>/dev/null || true)

test_perms() {
  local label="$1"; shift
  local perms=("$@")

  if [[ -z "$GCP_ACCESS_TOKEN" ]]; then
    local r="[]"
    for p in "${perms[@]}"; do
      r=$(jq --arg p "$p" '. + [{permission:$p, granted:null}]' <<<"$r")
    done
    jq -n --arg label "$label" --argjson r "$r" '{
      label:$label, tested:false,
      error:"no access token (gcloud auth print-access-token failed)",
      results:$r
    }'
    return
  fi

  local body
  body=$(printf '%s\n' "${perms[@]}" | jq -R . | jq -s '{permissions: .}')

  local response http_code
  response=$(curl -sS -w '\n%{http_code}' \
        -X POST \
        "https://cloudresourcemanager.googleapis.com/v1/projects/${PROJECT_ID}:testIamPermissions" \
        -H "Authorization: Bearer ${GCP_ACCESS_TOKEN}" \
        -H "Content-Type: application/json" \
        --data "$body" 2>/dev/null || true)
  http_code="${response##*$'\n'}"
  response="${response%$'\n'*}"

  if [[ "$http_code" != "200" ]]; then
    local r="[]"
    for p in "${perms[@]}"; do
      r=$(jq --arg p "$p" '. + [{permission:$p, granted:null}]' <<<"$r")
    done
    jq -n --arg label "$label" --argjson r "$r" \
          --arg code "$http_code" --arg body "$response" '{
      label:$label, tested:false,
      error:("testIamPermissions returned HTTP " + $code),
      raw:$body,
      results:$r
    }'
    return
  fi

  # response.permissions is the subset of inputs that the caller has.
  local granted_arr
  granted_arr=$(jq -c '.permissions // []' <<<"$response")

  local results="[]"
  for p in "${perms[@]}"; do
    if jq -e --arg p "$p" '. | index($p)' <<<"$granted_arr" >/dev/null; then
      g="true"
    else
      g="false"
    fi
    results=$(jq --arg p "$p" --argjson g "$g" \
      '. + [{permission:$p, granted:$g}]' <<<"$results")
  done
  jq -n --arg label "$label" --argjson r "$results" \
    '{label:$label, tested:true, results:$r}'
}

perm_vpc_network=$(test_perms "vpc_network" \
  compute.networks.create \
  compute.networks.delete \
  compute.networks.get \
  compute.networks.updatePolicy)

perm_subnetwork=$(test_perms "subnetwork" \
  compute.subnetworks.create \
  compute.subnetworks.delete \
  compute.subnetworks.get \
  compute.subnetworks.update \
  compute.subnetworks.use \
  compute.subnetworks.setPrivateIpGoogleAccess)

perm_firewall=$(test_perms "firewall" \
  compute.firewalls.create \
  compute.firewalls.delete \
  compute.firewalls.get \
  compute.firewalls.update)

perm_router_nat=$(test_perms "router_nat" \
  compute.routers.create \
  compute.routers.delete \
  compute.routers.get \
  compute.routers.update)

perm_service_account=$(test_perms "service_account" \
  iam.serviceAccounts.create \
  iam.serviceAccounts.delete \
  iam.serviceAccounts.get \
  iam.serviceAccounts.actAs \
  iam.serviceAccountKeys.create \
  iam.serviceAccountKeys.delete)

perm_iam_binding=$(test_perms "iam_binding" \
  resourcemanager.projects.getIamPolicy \
  resourcemanager.projects.setIamPolicy)

perm_storage_bucket=$(test_perms "storage_bucket" \
  storage.buckets.create \
  storage.buckets.delete \
  storage.buckets.get \
  storage.buckets.update \
  storage.buckets.getIamPolicy \
  storage.buckets.setIamPolicy)

perm_kms=$(test_perms "kms" \
  cloudkms.keyRings.create \
  cloudkms.keyRings.get \
  cloudkms.cryptoKeys.create \
  cloudkms.cryptoKeys.get \
  cloudkms.cryptoKeys.update)

# ----- 5. quotas -----
# Global quotas (NETWORKS, SUBNETWORKS, FIREWALLS) live under
# `gcloud compute project-info describe`. CPUS is a *regional* quota and
# is NOT present in the project-info output — it sits under
# `gcloud compute regions describe REGION`. We collect from both.
quotas_json="[]"
if proj_info=$(gcloud compute project-info describe --project "$PROJECT_ID" \
                  --format=json 2>/dev/null); then
  quotas_json=$(jq '[ .quotas[]
                      | select(.metric=="NETWORKS"
                             or .metric=="SUBNETWORKS"
                             or .metric=="FIREWALLS")
                      | {scope:"global", metric: .metric,
                         usage: .usage, limit: .limit} ]' \
                  <<<"$proj_info")
fi
if region_info=$(gcloud compute regions describe "$REGION" \
                   --project "$PROJECT_ID" --format=json 2>/dev/null); then
  region_quotas=$(jq --arg region "$REGION" \
                     '[ .quotas[]
                        | select(.metric=="CPUS" or .metric=="IN_USE_ADDRESSES")
                        | {scope:("region:" + $region), metric: .metric,
                           usage: .usage, limit: .limit} ]' \
                     <<<"$region_info")
  quotas_json=$(jq --argjson r "$region_quotas" '. + $r' <<<"$quotas_json")
fi

# ----- 6. assemble final JSON -----
jq -n \
  --arg schema "1" \
  --arg region "$REGION" \
  --arg project_id "$PROJECT_ID" \
  --arg project_number "$project_number" \
  --arg project_state "$project_state" \
  --arg project_parent "$project_parent" \
  --arg active_account "$active_account" \
  --argjson region_ok  "$region_ok" \
  --arg     region_msg "$region_msg" \
  --argjson apis "$apis_json" \
  --argjson p_vpc        "$perm_vpc_network" \
  --argjson p_subnet     "$perm_subnetwork" \
  --argjson p_firewall   "$perm_firewall" \
  --argjson p_router     "$perm_router_nat" \
  --argjson p_sa         "$perm_service_account" \
  --argjson p_iam        "$perm_iam_binding" \
  --argjson p_storage    "$perm_storage_bucket" \
  --argjson p_kms        "$perm_kms" \
  --argjson quotas       "$quotas_json" \
  '{
    schema_version: $schema,
    cloud: "gcp",
    region: $region,
    status: "OK",
    identity: {
      project_id:     $project_id,
      project_number: $project_number,
      project_state:  $project_state,
      project_parent: $project_parent,
      active_account: $active_account
    },
    region_check: { ok: $region_ok, message: $region_msg },
    required_apis: $apis,
    iam_permissions: {
      vpc_network:     $p_vpc,
      subnetwork:      $p_subnet,
      firewall:        $p_firewall,
      router_nat:      $p_router,
      service_account: $p_sa,
      iam_binding:     $p_iam,
      storage_bucket:  $p_storage,
      kms:             $p_kms
    },
    quotas: $quotas
  }'
