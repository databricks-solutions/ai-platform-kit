# Azure Pre-flight Interpretation

## 1. Purpose

This file tells Claude how to interpret the JSON emitted by `scripts/precheck-azure.sh` and turn it into a compatibility matrix the customer can act on. The script does no reasoning — it dumps facts (identity, role assignments, resource provider registration state, quotas, private DNS zones). The rules below map those facts to which Databricks deployment topologies are supported, and which field-repo scenario to recommend.

Azure RBAC has no per-action simulation equivalent to AWS `iam:SimulatePrincipalPolicy`. Capability is **inferred** from built-in role names + scope. Custom roles cannot be analyzed automatically — flag them for human review.

## 2. Role assignment interpretation

The script calls `az role assignment list --assignee <oid> --all --include-groups`, so the emitted `role_assignments[]` array includes both **direct** assignments to the principal and assignments **inherited via Azure AD group membership**. This matters because most enterprises assign roles to groups, not individuals — without `--include-groups`, the array comes back empty and the matrix wrongly concludes "no perms".

Each role assignment has two fields the matrix uses: `role` (the `roleDefinitionName`, e.g. `"Contributor"`) and `scope_level` (`"subscription" | "resource_group" | "management_group" | "resource"`).

**Empty `role_assignments` despite a successful auth probe** is an edge case worth calling out explicitly. It means the script could enumerate `az account show` and resolve the principal object ID, but **no direct or group-inherited RBAC role was found** at any scope. Plausible causes:
- **Azure AD Privileged Identity Management (PIM) / JIT activation** — the principal is eligible for a role but hasn't activated it yet. They need to `az login` again after activating in the Azure portal.
- **Classic subscription co-administrator** — a legacy Azure Service Manager (ASM) role not surfaced in modern RBAC. Treat as Owner-equivalent for matrix purposes if confirmed by the customer.
- **Subscription-management-API access without RBAC** — extremely rare; usually accompanied by other errors.
- **Genuine zero RBAC** — auth works for listing subscriptions but no role grants any deploy capability. Block.

When `role_assignments.length == 0`, do NOT mark every topology BLOCKED automatically. Surface this as `INDETERMINATE` and ask the customer: "I can see your identity but no Azure RBAC role grants at any scope. Are you using PIM, classic admin, or do you need to be granted Contributor?".

| Role | Scope | Can deploy |
|---|---|---|
| `Owner` | subscription, resource_group, management_group | Everything: VNet injection, NAT, Private Link, storage, access connector, **and** UC role assignments |
| `Contributor` | subscription, resource_group, management_group | VNet injection, NAT, Private Link, storage, access connector. **Cannot** create role assignments on storage — UC needs a pairing with `User Access Administrator` |
| `User Access Administrator` | subscription, resource_group, management_group | Role assignments only. Useless alone; pair with `Contributor` for full UC |
| `Network Contributor` | any | VNet/subnet/NSG/PE create only. Insufficient on its own for workspace create |
| `Reader` | any | Nothing — verify-only mode |
| Custom role | any | **Cannot infer.** Surface as `needs_human_review` and list the role name + scope |

**Scope hierarchy.** A role at `management_group` or `subscription` scope covers everything beneath it. A role at `resource_group` scope covers only that RG — fine if the deploy is targeted, blocking if the deploy needs subscription-wide resources (e.g. cross-RG private DNS zones). A role at `resource` scope is too narrow to cover a workspace deploy — treat as not-applicable.

**Aggregation rule.** A principal can hold multiple role assignments. Union them across scopes. Example: `Contributor` at RG `rg-databricks-dev` + `User Access Administrator` at the subscription → behave as if `Owner` at `rg-databricks-dev` for matrix purposes.

## 3. Compatibility matrix

Five topologies. Each row lists the role + RP + quota gates. All gates must pass for a topology to be marked `SUPPORTED`.

| Topology | Roles required | Resource providers | Quota gates |
|---|---|---|---|
| **Standard** (Databricks-managed VNet + storage) | `Owner` or `Contributor` at sub / RG / MG | `Microsoft.Databricks`, `Microsoft.Storage`, `Microsoft.Compute` | VM cores ≥ 32 |
| **VNet injection** | `Owner` or `Contributor` at sub / RG / MG | Standard set + `Microsoft.Network` | + VNets headroom ≥ 1, NSGs headroom ≥ 1 |
| **Unity Catalog** | `Owner` **OR** (`Contributor` + `User Access Administrator`) at sub / RG / MG | VNet-injection set + `Microsoft.ManagedIdentity`, `Microsoft.Authorization` | same as VNet injection |
| **Private Link (classic)** | Same as VNet injection | VNet-injection set + `Microsoft.Network` | + Public IPs headroom ≥ 1 (NAT), Private Endpoints headroom ≥ 3 |
| **Full** (VNet injection + UC + Private Link + CMK) | `Owner` at subscription scope (CMK + KV access policies are easier here) | All of the above + `Microsoft.KeyVault` | All quota gates above |

**Tie-breaker rules:**

- A topology gated on `Owner` is satisfied by `Contributor + User Access Administrator` at the same or broader scope.
- If `Contributor` exists at RG and `User Access Administrator` at subscription, **Unity Catalog** is supported but only within that RG.
- A custom role on any input → mark every topology that depends on that role as `needs_human_review`, not `BLOCKED`.

## 4. Resource provider check

For each entry in `resource_providers[]` where `registered: false`, raise it as a blocker for any topology that requires it (see matrix above). RP registration is fast (`az provider register --namespace <ns>`) and customer-fixable, but deploys fail immediately if missing.

Example JSON shape:

```json
{
  "namespace": "Microsoft.Authorization",
  "state": "NotRegistered",
  "registered": false
}
```

Output as: `Microsoft.Authorization NotRegistered — blocks Unity Catalog`.

If `state: "Unknown"`, the principal likely lacks `Microsoft.Resources/subscriptions/providers/read`. Note this and treat the RP as unknown (not failed).

## 5. Quota interpretation

Each `quotas.*` entry has `name`, `current`, `limit`, `headroom`. Apply these thresholds:

| Quota | Warn when | Why |
|---|---|---|
| `virtual_networks` | headroom < 2 | Need 1 for the workspace, 1 buffer |
| `network_security_groups` | headroom < 4 | Each VNet injection needs ≥ 1 NSG; multi-env deploys consume several |
| `public_ips` | headroom < 2 | NAT gateway consumes 1 |
| `private_endpoints` | headroom < 3 | Classic Private Link needs ~4 PEs (ui_api + browser_auth + blob + dfs) — warn early |
| `vm_cores` (regional) | limit < 32 | Driver + 1 worker on standard SKUs runs ~16 vCPU minimum; UC verification needs headroom |

Treat warnings as **soft signals** — surface to the customer but do not block. Only block if `headroom <= 0` on a quota a topology needs.

## 6. Private DNS zones (Private Link readiness)

The script reports presence (`present_in_subscription: true|false`) of three zones:

- `privatelink.azuredatabricks.net`
- `privatelink.blob.core.windows.net`
- `privatelink.dfs.core.windows.net`

**Interpretation:**

- All three present → strong signal the customer already runs Private Link elsewhere; they likely have a hub-spoke setup. Ask which RG the zones live in and offer to link to existing zones rather than create new.
- Some present, some missing → customer is partway in. Confirm which RG holds the existing zones; the deploy will create missing zones in the workspace RG unless told otherwise.
- None present → first-time Private Link deploy. The Terraform will create them. Confirm the deploying identity has permission to create private DNS zones (covered by `Contributor` or `Network Contributor` at the RG scope).

This is informational, not a blocker. Surface it under a separate "Private DNS zones" line in the output.

## 7. Recommended scenario mapping

Map the matrix result to a field-repo scenario (`azure-vnet-injection`, `azure-vnet-injection-uc`, `azure-privatelink-classic` — see `SKILL.md` Template Index).

| Matrix result | Recommend | Reason |
|---|---|---|
| Only Standard supported (no VNet injection capability) | Push back. Ask the customer to grant `Network Contributor` or `Contributor` at a workspace RG. Databricks-managed VNet is sunsetting in many tenants — avoid it for production | — |
| VNet injection supported, UC **not** supported | `azure-vnet-injection` | Customer lacks `User Access Administrator` — UC role assignments will fail |
| VNet injection supported, UC supported | `azure-vnet-injection-uc` | Default recommendation for production |
| Private Link supported (everything above + PE quota + KV/Net RP) | `azure-privatelink-classic` | Only if the customer explicitly asked for Private Link or compliance implies it |
| `Owner` at subscription + all RPs registered + all quotas green | Offer choice. Default to `azure-vnet-injection-uc` unless customer asked for Private Link or compliance | — |
| Anything `needs_human_review` (custom roles) | Do not auto-recommend. Surface the custom role name and ask the customer or their cloud admin to confirm what it grants | — |

## 8. Output format

Claude shows this to the user after the precheck runs:

```
Pre-flight results (Azure subscription <name>, region <region>):

  Standard         ✓ SUPPORTED   |  ✗ blocked: <reason>
  VNet injection   ✓ SUPPORTED   |  ✗ blocked: <reason>
  Unity Catalog    ✓ SUPPORTED   |  ✗ blocked: <reason>
  Private Link     ✓ SUPPORTED   |  ✗ blocked: <reason>
  Full             ✓ SUPPORTED   |  ✗ blocked: <reason>

Resource providers: <all-registered | list-of-missing-with-namespace>
Quota check:        <green | warnings: vnet headroom=1, public_ips headroom=0>
Private DNS zones:  <existing in subscription | will be created on deploy>

Recommendation: <field-repo scenario> — <one-sentence reason>
[Or: Cannot proceed — needs <specific role / RP / quota raise>]

Proceed with <scenario>, or pause?
```

Keep the block compact. If a topology is `BLOCKED`, the reason should name the missing role / RP / quota explicitly (e.g. `blocked: User Access Administrator not assigned at sub or RG scope`). If `needs_human_review`, say so and name the custom role.

## 9. Caveats

- **No per-action simulation on Azure.** Capability is inferred from role names, not tested. A misconfigured custom role can look like `Contributor` in the name but grant far less — always flag custom roles.
- **Resource-level scopes don't cover broader deploys.** A role at scope `/subscriptions/.../resourceGroups/.../providers/Microsoft.Storage/storageAccounts/foo` does not authorize creating a VNet in the same RG. The matrix treats `scope_level: "resource"` as not-applicable.
- **`Contributor` cannot create role assignments.** UC deploys fail at the storage role assignment step with `AuthorizationFailed` even if every prior step succeeded. Pair with `User Access Administrator` or escalate to `Owner`.
- **Service principal vs user principal differences.** The script resolves both via `az ad signed-in-user show` (user) and `az ad sp show` (SP). A user with broad role assignments may be running Terraform as an SP that has narrower assignments — confirm which principal will run the apply.
- **Quota responses are regional defaults.** Subscription-wide soft caps (e.g. total cores across all regions) may also apply and are not reported by `az network list-usages` / `az vm list-usage`. Treat tight quotas as a hint to file a support request early.
- **Management group scope is rare in practice.** Most customers grant at subscription or RG. If you see MG-scoped roles, confirm the deploy target RG inherits them (it usually does, but custom RBAC denies can override).
- **Region availability.** The script reports `region_check.ok: false` if the region is not enabled on the subscription. This is a hard blocker — no topology is supported until the customer enables the region or picks another.

## 10. Real-world gotchas observed during testing

These were caught by the first real-creds run of `precheck-azure.sh` against a Databricks sandbox subscription. The script has since been patched; documented here so future maintainers know why the code looks the way it does:

a. **`az role assignment list` without `--include-groups` misses the majority of enterprise role assignments.** In the test sub, the user appeared to have zero roles when in fact they had `Contributor` + `User Access Administrator` at subscription scope, both inherited via AAD group membership. **Fix in script:** always pass `--include-groups`. This is the highest-impact bug we found — without it, every enterprise customer would see "no perms" and the matrix would block.

b. **`az account list-locations` does NOT accept `--subscription`.** The flag is silently rejected as "unrecognized arguments" and the command errors out, which the script's `if !` guard interpreted as "region not available". **Fix in script:** call `az account set --subscription "$SUB_ID"` once early, then call `az account list-locations` without the flag.

c. **Azure quota responses come back with numeric values typed as strings, not numbers.** `jq` arithmetic (`.limit - .currentValue`) errors with `string ("1000") and string ("8") cannot be subtracted`. **Fix in script:** `quota_filter` now coerces both fields via `(. // 0 | if type == "string" then tonumber else . end)` before subtraction.

d. **Private DNS zones being present in the subscription is a strong hub-spoke signal.** During testing, all three Private Link DNS zones (`privatelink.azuredatabricks.net`, `privatelink.blob.core.windows.net`, `privatelink.dfs.core.windows.net`) were already present in the sandbox sub. That's almost always because Private Link Databricks has been deployed there before, or the sub is participating in a hub-spoke topology where DNS zones live centrally. The script reports this; the matrix should prompt the customer to confirm whether to link to existing zones rather than create new.
