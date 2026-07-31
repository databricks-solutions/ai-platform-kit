# Databricks Platform Kit

**AI-powered Databricks platform engineering.** Provision workspaces, configure Unity Catalog, set up networking, manage groups and permissions — all through natural language with Claude.

> Sibling to the [Databricks AI Dev Kit](https://github.com/databricks-solutions/ai-dev-kit): where that kit gives coding agents Databricks-specific skills for *building on* the platform, this kit focuses on *standing up* the platform itself — workspaces, Unity Catalog, identity, and networking across Azure, AWS, and GCP.

## What it does

Tell Claude what you need, and it handles the rest:

- **Workspace provisioning** — VNet/VPC injection, Secure Cluster Connectivity across Azure, AWS, GCP
- **Unity Catalog** — opinionated setup: self-managed metastore, per-env catalogs, external locations, medallion schemas, Lakehouse Federation
- **Identity & governance** — account-level SCIM groups, tiered RBAC, service principals for jobs
- **Workspace config** — SQL warehouses, cluster policies, secret scopes, IP access lists
- **Private networking** — private link (AWS), Private Endpoints (Azure), Private Service Connect (GCP), hub-spoke, NCC for serverless connectivity (when you need it)
- **Built-in verification** — a 3-path test (classic cluster + serverless SQL warehouse + serverless notebook job) designed to catch common configuration failures after a deploy (it does not guarantee correctness or fitness for any particular use)

Claude writes the Terraform and SDK calls from scratch based on your specific requirements — no rigid templates to fill in.

## Architecture

```
.claude/skills/                      # 6 focused skills
  platform-provisioning/             #   Workspace creation + deploy
    SKILL.md                         #     Shared workflow + interaction guidance
    AZURE.md / AWS.md / GCP.md       #     Cloud-entry navigation files
    {azure,aws,gcp}-1-auth.md        #     Auth setup per cloud
    {azure,aws,gcp}-2-deploy.md      #     Deploy patterns per cloud
    {azure,aws,gcp}-3-gotchas.md     #     Sharp edges per cloud
  unity-catalog-setup/               #   Metastore, catalogs, governance
    SKILL.md + AZURE.md / AWS.md / GCP.md
  identity-governance/               #   Groups, users, SPs, RBAC
    SKILL.md                         #     Cloud-agnostic
  workspace-config/                  #   SQL warehouses, policies, secrets
    SKILL.md                         #     Cloud-agnostic
  private-networking/                #   Private link, hub-spoke, NCC, PSC
    SKILL.md + AZURE.md / AWS.md / GCP.md
  deployment-verification/           #   3-path verification (mandatory after deploy)
    SKILL.md                         #     Cloud-agnostic
```

The agent uses `az login` / `aws configure` / `gcloud auth login` + `terraform` via shell. No third-party Python packages, no MCP server — just skills (the installer is a single stdlib-only Python script).

## What this repo ships (and what it doesn't)

This kit is a thin layer. It's worth being precise about what it is, because that's also what the [LICENSE](LICENSE.md) covers:

**Shipped by this repo (covered by the license):**
- The skill files (`.claude/skills/**`) — the instructions that drive the agent.
- One PreToolUse hook (`.claude/hooks/block-cred-reads.py`) and three pre-flight scripts (`.claude/skills/platform-provisioning/scripts/precheck-*.sh`).

**Brought by the user (not shipped here, each under its own terms):**
- **A coding agent** — Claude Code, OpenAI Codex, Cursor, GitHub Copilot, Gemini CLI, Windsurf, OpenCode, or Kiro — that reads the skills and executes commands (their respective vendors).
- **Terraform** and the **AWS / Azure / gcloud / Databricks CLIs** — the tools that actually provision infrastructure (their respective vendors).
- The user's own cloud credentials, accounts, and the choice of how to run the agent (interactive vs. auto mode, etc.).

In other words: the kit is the skills and a little glue. It orchestrates tools the user installs and authenticates separately, using credentials the kit never sees. The license and [SECURITY.md](SECURITY.md) scope Databricks' responsibility to this repo's own contents — not to the agent, the cloud tools, or how the user chooses to operate them.

## Quick start

**Claude Code** — clone, `cd` in, run:

```bash
git clone https://github.com/databricks-solutions/ai-platform-kit.git
cd ai-platform-kit
claude
```

Claude Code auto-discovers the skills in `.claude/skills/`. No install step needed.

## Use with your agent

Prefer a different agent, or want the skills in your own project? The installer copies
the skills into the layout your agent expects and writes its instruction file. Pick your
platform:

**macOS / Linux**
```bash
bash <(curl -sL https://raw.githubusercontent.com/databricks-solutions/ai-platform-kit/main/install.sh)
```

**Windows (PowerShell)**
```powershell
irm https://raw.githubusercontent.com/databricks-solutions/ai-platform-kit/main/install.ps1 | iex
```

You'll be asked **which agent(s)** and **where** (this project, or globally for all your
projects) — that's it. Supported agents and what lands where:

| Agent | Where skills go | Instruction file written |
|-------|-----------------|--------------------------|
| Claude Code | `.claude/skills/` | `.claude/settings.json` + cred-block hook |
| OpenAI Codex | `.agents/skills/` | `AGENTS.md` |
| Cursor | `.cursor/skills/` | `.cursor/rules/databricks-platform-kit.mdc` |
| GitHub Copilot | `.agents/skills/` | `.github/copilot-instructions.md` |
| Gemini CLI | (referenced in place) | `GEMINI.md` |
| Windsurf | (referenced in place) | `.windsurf/rules/databricks-platform-kit.md` |
| OpenCode | `.agents/skills/` | `AGENTS.md` |
| Kiro | `.kiro/skills/` | native (Agent Skills) |

Already cloned the repo? A root `AGENTS.md` and `GEMINI.md` are committed, so Codex,
Cursor, Copilot, Gemini, Windsurf, and OpenCode work on clone with no install step. You
can also run the installer directly without the wrapper:

```bash
python3 scripts/skills-sync.py --agent codex --scope project
```

> **Credential safety on non-Claude agents:** the Claude Code install ships a PreToolUse
> hook that blocks reads of credential/state files. Other agents have no equivalent hook —
> run them in a **gated approval/sandbox mode** so tool calls that touch those files require
> confirmation.

### Prerequisites

- **A coding agent** — Claude Code, Codex, Cursor, Copilot, Gemini CLI, Windsurf, OpenCode, or Kiro
- **Python 3** — for the installer (`python3` on PATH; already present with the Databricks/cloud CLIs)
- **Terraform** >= 1.9.0: `brew install terraform`
- **Cloud CLI**: `az login` (Azure), `aws configure` (AWS), or `gcloud auth login` (GCP) — depending on which cloud you'll deploy to
- **Databricks CLI** >= 0.296.0: `brew install databricks` (older versions can serve stale tokens and break auth debugging)
- **Databricks account ID** — from the accounts console for your cloud:
  - AWS: `accounts.cloud.databricks.com`
  - Azure: `accounts.azuredatabricks.net`
  - GCP: `accounts.gcp.databricks.com`

## Usage

Just tell Claude what you want:

> "Set up 3 Databricks workspaces (dev/stg/prod) on Azure with Unity Catalog and proper groups"

Claude will:
1. Ask the right questions (cloud, region, environment strategy, naming, networking, compliance)
2. Check your auth and gather inputs in one batch
3. Write Terraform tailored to your request
4. Deploy end-to-end with real `terraform apply`
5. Run the 3-path verification against a UC table before declaring done

## Skills

| Skill | What it does | When it loads |
|-------|-------------|---------------|
| **platform-provisioning** | Create workspaces, deploy infrastructure | "create a workspace", "provision", "deploy" |
| **unity-catalog-setup** | Metastore, catalogs, schemas, grants, Lakehouse Federation | "Unity Catalog", "metastore", "catalog" |
| **identity-governance** | Groups, users, SPs, RBAC | "groups", "permissions", "service principal" |
| **workspace-config** | SQL warehouses, policies, secrets, tokens | "SQL warehouse", "cluster policy", "secret" |
| **private-networking** | Private link, hub-spoke, NCC, GCP PSC | "private link", "PSC", "hub-spoke", "NCC" |
| **deployment-verification** | 3-path verification (classic + sqlwh + notebook), mandatory after any deploy | Loaded whenever a workspace + UC has been freshly deployed or modified |

Each skill loads independently — Claude only reads what's relevant to your request. Cloud-specific files (`AZURE.md`, `AWS.md`, `GCP.md` and their numbered topic siblings) are loaded based on your target cloud to prevent cross-cloud confusion.

## Supported clouds

| Cloud | Workspaces | Unity Catalog | Private Link / PSC | Multi-env | Lakehouse Federation |
|-------|-----------|---------------|--------------------|-----------|----------------------|
| Azure | Yes | Yes | Yes (Private Endpoints) | Yes | Yes (Synapse, SQL DB, Postgres) |
| AWS   | Yes | Yes | Yes (AWS PrivateLink) | Yes | Yes (RDS, Redshift, Snowflake) |
| GCP   | Yes | Yes | Yes (PSC backend + frontend) | Yes | Yes (CloudSQL Postgres) |

> **Disclaimer:** This is a Databricks Solutions project. It is **not** an officially supported Databricks product and comes with no warranty or SLA. It provisions real, billable cloud infrastructure on your accounts — review every `terraform plan` before approving. Use is subject to the [LICENSE](LICENSE.md). See [SECURITY.md](SECURITY.md) for the security model and its limitations.

## Support

Databricks support does not cover this project. For questions or bugs, open a
[GitHub issue](https://github.com/databricks-solutions/ai-platform-kit/issues) and the
team will help on a best-effort basis. For security issues, follow the private
disclosure process in [SECURITY.md](SECURITY.md) instead of opening a public issue.

## License

&copy; 2026 Databricks, Inc. All rights reserved.

The source in this project is provided subject to the Databricks License. See
[LICENSE.md](LICENSE.md) for the full text and [NOTICE.md](NOTICE.md) for attributions.
