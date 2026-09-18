# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

The **Databricks Platform Kit** (AIPK) — a set of agent **skills** for provisioning and operating Databricks platform infrastructure (workspaces, Unity Catalog, identity, networking) across Azure, AWS, and GCP. It is *content*, not a program: the skills are markdown instructions an agent follows, plus one hook and a handful of pre-flight shell scripts. There are no Python packages to install and no MCP server.

There are two distinct audiences for this codebase, and it matters which one you're acting as:

- **Maintainer of the kit** (the usual mode when editing this repo): you edit skill markdown, the hook, the scripts, and regenerate the agent pointer files.
- **A user running the kit** to actually provision infrastructure: the agent *reads* the skills and runs `terraform` / cloud CLIs against real cloud accounts. When someone opens this folder and says "provision a workspace," follow the skills as instructed — see "When acting as the provisioning agent" below.

## Source of truth & the generate step

`.claude/skills/<name>/` is the **single source of truth**. The root `AGENTS.md` and `GEMINI.md` are **generated** from the skills' frontmatter and must never be hand-edited.

After adding, renaming, or removing a skill — or changing any skill's `name`/`description` frontmatter — regenerate the pointer files:

```bash
python3 scripts/skills-sync.py --generate         # rewrite AGENTS.md + GEMINI.md
python3 scripts/skills-sync.py --generate --check  # CI guard: non-zero exit on drift
```

Other useful invocations of the same script (it is stdlib-only, cross-platform, no pip):

```bash
python3 scripts/skills-sync.py --list                              # list discovered skills
python3 scripts/skills-sync.py --agents claude,codex --scope project
python3 scripts/skills-sync.py --agent gemini --scope global
python3 scripts/skills-sync.py --agent codex --into /path/to/proj  # install into another repo
python3 scripts/skills-sync.py                                     # interactive picker
```

There is no build, lint, or test suite. Validation is: run `--generate --check` (drift), and manually confirm skill markdown renders and its frontmatter parses.

## The skills-sync installer (scripts/skills-sync.py)

One script, two jobs — **GENERATE** (maintainer, above) and **INSTALL** (end user). Install copies the skill tree into the layout each agent expects and writes that agent's instruction file. The skill markdown is **never modified** during install; only the packaging differs per agent. Key invariants when editing this script:

- Python 3 **stdlib only** — never add a third-party import.
- **Never symlink** — always copy directories (Windows-safe); use `pathlib` / `Path.home()` for all paths.
- Per-agent targets are defined in the render/install functions (`render_agents_md`, `render_cursor_mdc`, `render_copilot_md`, `render_windsurf_rule`, `_install_claude`, `install_agent`). Adding an agent means adding its renderer + install mapping, not editing skill content.

## Skill architecture (the big picture)

Six skills, each a directory under `.claude/skills/`. Two structural patterns:

- **Cloud-agnostic skills** (`identity-governance`, `workspace-config`, `deployment-verification`) — a single `SKILL.md`.
- **Cloud-fanned skills** (`platform-provisioning`, `unity-catalog-setup`, `private-networking`) — a `SKILL.md` with the shared workflow, plus per-cloud companion files `AZURE.md` / `AWS.md` / `GCP.md`. `platform-provisioning` fans out further into **numbered topic files** per cloud: `{cloud}-1-auth.md`, `{cloud}-1.5-precheck.md`, `{cloud}-2-deploy.md`, `{cloud}-3-gotchas.md`.

**Progressive disclosure is the core design principle.** The agent loads only what a request needs: the matching `SKILL.md` first, then exactly one cloud's companion files based on the target cloud. This deliberately prevents cross-cloud confusion — never write a skill that forces all three clouds into context at once, and keep each cloud's specifics in its own file.

Two conventions run through every skill:

- **`<prefix>` placeholder** — all resource names use `<prefix>` as a stand-in for a customer/project identifier. It is a literal placeholder: `<` and `>` are invalid in bash/SQL/HCL/cloud names and must always be substituted. Never reuse a prefix across deployments in the same cloud account (S3/GCS/Azure storage names are globally unique).
- **Per-skill pushback level** — each `SKILL.md` opens with a "How to interact with the customer" section stating a pushback level (HIGH for provisioning, MODERATE for UC/networking, LIGHT/MINIMAL for identity/config) and hard rules. When editing a skill, preserve and match this calibration; it is intentional.

## Load-bearing rules (do not soften these when editing skills)

- **The Three Paths verification is mandatory and non-negotiable.** `deployment-verification/SKILL.md` requires that after any workspace + UC deploy/modify, the agent runs **all three** compute paths against a UC table (CREATE→INSERT→SELECT→DROP): (1) classic cluster (`data_security_mode = "SINGLE_USER"`), (2) serverless SQL warehouse, (3) serverless notebook job. Serverless-only success does **not** count. `platform-provisioning` and `workspace-config` both point back to this skill; keep those cross-links intact.
- **Identity: account-level SCIM groups only, group-only grants, service principals for all automated jobs.** Workspace-local groups are invisible to Unity Catalog and fail silently. These are hard rules in `identity-governance/SKILL.md`, not suggestions.
- **Network default = VNet/VPC injection + Secure Cluster Connectivity (no public IP).** Do not recommend Private Link unless the customer explicitly asks or names a compliance driver (HIPAA/FedRAMP/PCI-DSS).

## Credential safety model

`.claude/settings.json` registers a PreToolUse hook (`.claude/hooks/block-cred-reads.py`, matcher `Bash|Read`) that **blocks** any tool call touching credential/state files — `.databrickscfg`, `.aws/credentials`, gcloud/azure token files, `*.tfstate`, `*.tfvars` (exit code 2 with feedback to the agent). The kit's policy is to **verify auth via CLI, never by reading credential files**:

```bash
aws sts get-caller-identity    # AWS
az account show                # Azure
gcloud auth list               # GCP
databricks current-user me     # Databricks
```

When editing the hook, keep `SENSITIVE_PATTERNS` in sync with this policy. Non-Claude agents get no equivalent hook — that's why the docs tell users to run them gated/sandboxed.

## When acting as the provisioning agent

If the user opens this repo to actually stand up infrastructure (not to edit the kit):

- **Never auto-select a Databricks CLI profile** — pass `--profile <name>` and let the user choose.
- Always Terraform. **`terraform plan` review is mandatory** before `apply` — this provisions real, billable infrastructure. Treat `terraform destroy`, disabling public access, and deleting a metastore as irreversible: confirm explicitly, stating what will be destroyed.
- The provisioning-agent working flow lives in `platform-provisioning/SKILL.md` (intake → auth check → optional pre-flight `scripts/precheck-{aws,azure,gcp}.sh` → write Terraform → dry run → apply → verify). Follow it rather than improvising.
- Runtime Terraform/deployments are written per-customer and are **git-ignored** (`deployments/`, `*.tfstate`, `*.tfvars`, `.terraform/`). Never commit them, and never commit customer names, account IDs, or credentials — use `<prefix>` and placeholders everywhere.

## Editing conventions

- Skill directory names: lowercase-with-hyphens.
- Update the relevant `SKILL.md` **and** the README skills table together when adding/modifying a skill, then run `--generate`.
- `VERSION` and `.claude-plugin/plugin.json` `version` should stay in lockstep on a release.
