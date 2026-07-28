#!/usr/bin/env bash
# precheck-azure.sh — Databricks deploy permission pre-flight for Azure
#
# Mirrors the verify-only behaviour of upstream terraform-checker
# (databricks-solutions/technical-services-solutions, branch
#  feature-terraform-checker-clean, path workspace-setup/terraform-checker).
# Permission lists are derived from config/permissions/azure.yaml in that repo
# (last synced 2025-01).
#
# MODIFIED from that upstream: reimplemented as standalone bash (upstream is
# Python), reduced to verify-only permission pre-flight, and adapted for
# consumption by Claude. Upstream and this file are both under the DB license.
#
# Azure RBAC has no per-action simulation equivalent to AWS
# iam:SimulatePrincipalPolicy. Instead this script inspects role assignments,
# resource provider registration, and quota state, and lets the matrix rules
# in azure-1.5-precheck.md infer capability.
#
# Pure bash + az CLI + jq. No Python, no resource creation.
# Output: one JSON blob to stdout.
#
# Usage:
#   bash precheck-azure.sh --subscription-id SUB_ID --region REGION \
#        [--resource-group RG_NAME]

set -euo pipefail

SUB_ID=""
REGION=""
RG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription-id) SUB_ID="$2"; shift 2 ;;
    --region|--location) REGION="$2"; shift 2 ;;
    --resource-group) RG="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --subscription-id SUB_ID --region REGION [--resource-group RG]"
      exit 0
      ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$SUB_ID" || -z "$REGION" ]]; then
  echo "ERROR: --subscription-id and --region are required" >&2
  exit 2
fi

for tool in az jq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "ERROR: $tool not found on PATH" >&2; exit 3;
  }
done

# ----- 1. account + identity -----
if ! account_json=$(az account show --subscription "$SUB_ID" --output json 2>/dev/null); then
  jq -n --arg sub "$SUB_ID" --arg region "$REGION" '{
    schema_version: "1",
    cloud: "azure",
    subscription_id: $sub,
    region: $region,
    status: "FAILED",
    failure: "credentials_invalid_or_no_subscription_access",
    message: "az account show failed; not logged in or no access to subscription"
  }'
  exit 0
fi

tenant_id=$(jq -r .tenantId        <<<"$account_json")
sub_name=$( jq -r .name            <<<"$account_json")
sub_state=$(jq -r .state           <<<"$account_json")
user_name=$(jq -r '.user.name'     <<<"$account_json")
user_type=$(jq -r '.user.type'     <<<"$account_json")

# Resolve signed-in principal objectId (best-effort; SPs vs users differ)
principal_oid=""
if [[ "$user_type" == "user" ]]; then
  principal_oid=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)
else
  # service principal — appId is the user.name
  principal_oid=$(az ad sp show --id "$user_name" --query id -o tsv 2>/dev/null || true)
fi

# ----- 2. region availability -----
# Note: `az account list-locations` does NOT accept --subscription; it uses
# the active subscription from `az account set`. We set it explicitly.
az account set --subscription "$SUB_ID" 2>/dev/null || true
region_ok="true"
region_msg=""
if ! az account list-locations --query "[?name=='$REGION']" -o json 2>/dev/null \
     | jq -e 'length>0' >/dev/null; then
  region_ok="false"
  region_msg="Region $REGION not available in this subscription"
fi

# ----- 3. role assignments -----
# Pull all role assignments scoped to subscription or above and any RGs.
# --include-groups is critical: most enterprises assign roles to AAD groups
# rather than individual users; without it, group-inherited roles are invisible
# and the matrix wrongly concludes "no permissions".
# We do not enumerate per-resource scopes (too expensive); the matrix infers
# from built-in role names.
role_assignments_json="[]"
if [[ -n "$principal_oid" ]]; then
  role_assignments_json=$(az role assignment list \
    --assignee "$principal_oid" \
    --subscription "$SUB_ID" \
    --all \
    --include-groups \
    --output json 2>/dev/null || echo "[]")
fi

# Distill role names + scope levels for the matrix
role_summary=$(jq '[ .[] | {
  role: .roleDefinitionName,
  scope: .scope,
  scope_level: (
    if   (.scope | test("^/subscriptions/[^/]+$"))                then "subscription"
    elif (.scope | test("^/subscriptions/[^/]+/resourceGroups/[^/]+$")) then "resource_group"
    elif (.scope | startswith("/providers/Microsoft.Management/managementGroups/")) then "management_group"
    else "resource" end)
} ]' <<<"$role_assignments_json")

# ----- 4. resource provider registration -----
required_rps=(
  Microsoft.Databricks
  Microsoft.Network
  Microsoft.Storage
  Microsoft.Compute
  Microsoft.KeyVault
  Microsoft.ManagedIdentity
  Microsoft.Authorization
)

rps_json="["
first=1
for rp in "${required_rps[@]}"; do
  state=$(az provider show --namespace "$rp" --subscription "$SUB_ID" \
            --query registrationState -o tsv 2>/dev/null || echo "Unknown")
  [[ $first -eq 1 ]] && first=0 || rps_json+=","
  rps_json+=$(jq -nc --arg ns "$rp" --arg state "$state" \
                '{namespace:$ns, state:$state, registered:($state=="Registered")}')
done
rps_json+="]"

# ----- 5. network + compute quotas -----
net_usage=$(az network list-usages --location "$REGION" --subscription "$SUB_ID" \
              --output json 2>/dev/null || echo "[]")
vm_usage=$(az vm list-usage --location "$REGION" --subscription "$SUB_ID" \
              --output json 2>/dev/null || echo "[]")

quota_filter() {
  local data="$1" name_pattern="$2"
  jq --arg p "$name_pattern" \
     '[ .[] | select(.name.value|test($p;"i")) |
        ((.limit        // 0) | (if type=="string" then tonumber else . end)) as $lim |
        ((.currentValue // 0) | (if type=="string" then tonumber else . end)) as $cur |
        { name: .name.localizedValue,
          current: $cur, limit: $lim,
          headroom: ($lim - $cur) } ]' <<<"$data"
}

q_vnet=$(quota_filter "$net_usage" 'VirtualNetwork')
q_nsg=$( quota_filter "$net_usage" 'NetworkSecurityGroup')
q_pip=$( quota_filter "$net_usage" 'PublicIPAddress')
q_pe=$(  quota_filter "$net_usage" 'PrivateEndpoint')
q_cpu=$( quota_filter "$vm_usage"  'cores|virtualMachines')

# ----- 6. private DNS zone scan (Private Link readiness) -----
# Existence of the canonical Private Link DNS zones in the subscription is
# a soft signal — many orgs centralize these in a hub sub. We just report.
pdz_json="[]"
for zone in privatelink.azuredatabricks.net privatelink.blob.core.windows.net privatelink.dfs.core.windows.net; do
  hit=$(az network private-dns zone list --subscription "$SUB_ID" \
         --query "[?name=='$zone']" -o json 2>/dev/null || echo "[]")
  exists=$(jq 'length>0' <<<"$hit")
  pdz_json=$(jq --arg z "$zone" --argjson e "$exists" \
              '. + [{zone:$z, present_in_subscription:$e}]' <<<"$pdz_json")
done

# ----- 7. assemble final JSON -----
jq -n \
  --arg schema "1" \
  --arg region "$REGION" \
  --arg sub_id "$SUB_ID" \
  --arg sub_name "$sub_name" \
  --arg sub_state "$sub_state" \
  --arg tenant_id "$tenant_id" \
  --arg user_name "$user_name" \
  --arg user_type "$user_type" \
  --arg principal_oid "$principal_oid" \
  --argjson region_ok "$region_ok" \
  --arg     region_msg "$region_msg" \
  --argjson roles "$role_summary" \
  --argjson rps   "$rps_json" \
  --argjson q_vnet "$q_vnet" \
  --argjson q_nsg  "$q_nsg" \
  --argjson q_pip  "$q_pip" \
  --argjson q_pe   "$q_pe" \
  --argjson q_cpu  "$q_cpu" \
  --argjson pdz    "$pdz_json" \
  '{
    schema_version: $schema,
    cloud: "azure",
    region: $region,
    status: "OK",
    identity: {
      subscription_id:   $sub_id,
      subscription_name: $sub_name,
      subscription_state: $sub_state,
      tenant_id:         $tenant_id,
      principal_name:    $user_name,
      principal_type:    $user_type,
      principal_object_id: $principal_oid
    },
    region_check: { ok: $region_ok, message: $region_msg },
    role_assignments: $roles,
    resource_providers: $rps,
    quotas: {
      virtual_networks: $q_vnet,
      network_security_groups: $q_nsg,
      public_ips: $q_pip,
      private_endpoints: $q_pe,
      vm_cores: $q_cpu
    },
    private_dns_zones: $pdz
  }'
