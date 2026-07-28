# Security

How the Databricks Platform Kit handles credentials, what it does and does not do with them, and how to report a vulnerability.

## TL;DR

These are the kit's design goals and the controls that support them. They are best-effort safeguards built on Claude Code skills plus one PreToolUse hook — not guarantees. Because the kit is driven by an LLM and runs on the customer's machine, the customer remains responsible for reviewing what it does. See "Limitations" below.

- **The kit is designed not to read or store credentials.** It calls cloud CLIs (`aws`, `az`, `gcloud`, `databricks`, `terraform`) that already hold the customer's credentials, and works from their stdout/stderr.
- **Auth is verified via status commands** rather than by reading credential files. A built-in Claude Code hook blocks common attempts to read the listed credential and state files (see coverage and limitations below).
- **The skills are written to run `terraform plan` before `terraform apply` and to ask for review before destructive operations.** This is guidance the skills follow by default, not a hard restriction. The kit does **not** control how the customer runs Claude Code or Terraform: using auto-approve, headless/auto mode, or any other workflow is the customer's choice and the customer's responsibility. The customer should review plans before approving anything that matters.
- **All AI tool calls are auditable** in the local Claude Code transcript. All cloud-side actions are logged in the customer's own audit trail (CloudTrail, Activity Log, Cloud Audit Logs, Databricks audit log).

## Threat model

| Threat | Mitigation |
|---|---|
| Kit reads credentials from disk | Skills are written to never read `~/.databrickscfg`, `~/.aws/credentials`, etc. A PreToolUse hook blocks it at the harness layer (`.claude/hooks/block-cred-reads.py`). |
| Skill prints a secret as part of "verification" | Skills standardize on status commands (`aws sts get-caller-identity`, `databricks current-user me`) that never echo secrets. |
| Skill executes a destructive command without confirmation | Skills default to running `terraform plan` before `terraform apply` and to asking for review first. This is default guidance, not a hard block — the customer decides whether to run auto-approve / auto mode, and is responsible for that choice. |
| Long-lived credentials leak into transcripts | Recommended auth methods are short-lived (SSO, U2M, ADC, OIDC). Tokens expire in minutes-to-hours. |
| Terraform state contains secrets in plaintext | Skills recommend remote state with KMS/CMEK encryption (S3 + KMS, AzureRM, GCS + CMEK). Local state is gitignored. The hook also blocks reads of `*.tfstate` and `*.tfvars`. |
| Credential file path leaks via `cat`/`echo` | The PreToolUse hook (`block-cred-reads.py`) inspects every Bash command and Read invocation and blocks direct references to the listed credential and state file paths. It does not cover credentials held in environment variables, and a determined user can obfuscate a path to evade the regex — see Limitations. |
| Cross-cloud cred contamination | Skills route by cloud (`AWS.md`, `AZURE.md`, `GCP.md`); each cloud's CLI manages its own cred store. |

## How authentication works

The kit relies entirely on credentials the customer's developers already have on their machine. The kit never collects, stores, or transmits credentials.

| Cloud / system | Auth method (preferred) | Where the secret lives | What Claude sees |
|---|---|---|---|
| AWS | `aws sso login` (SSO) → STS short-lived | `~/.aws/sso/cache/` (hour-bound) | `aws sts get-caller-identity` output (no secret) |
| Azure | `az login` (device code) → MSAL cache | `~/.azure/msal_token_cache.json` (refreshing) | `az account show` output (no secret) |
| GCP | `gcloud auth application-default login` | `~/.config/gcloud/application_default_credentials.json` | `gcloud auth list` output (no secret) |
| Databricks | U2M (browser PKCE) or OIDC/WIF federation | `~/.databrickscfg` profile (browser-cached) | `databricks current-user me` output (no secret) |
| Terraform | Provider blocks reference profile names; inherit cloud-CLI creds | Same files above | Plan/apply output |

**Service-account / M2M environments**: the kit supports M2M OAuth and workload identity federation. The skills are unchanged — only the customer's `~/.databrickscfg` profile differs.

## What ships in the kit to protect credentials

### 1. Skill discipline (`.claude/skills/`)

Every skill is written to delegate auth to the cloud CLI. Skills never run `cat`, `head`, `tail`, `grep`, etc. against `~/.databrickscfg`, `~/.aws/credentials`, `~/.azure/`, `~/.config/gcloud/`, or any `*.tfstate` / `*.tfvars` file.

Auth verification is standardized:

```bash
aws sts get-caller-identity     # AWS
az account show                 # Azure
gcloud auth list                # GCP
databricks current-user me      # Databricks
databricks auth profiles        # Databricks: list profiles, no secret values
```

### 2. PreToolUse hook (`.claude/hooks/block-cred-reads.py`)

Activated automatically by `.claude/settings.json` when Claude Code runs from this repository. Before every `Bash` or `Read` tool call, the hook inspects the input and blocks if it references:

- `.databrickscfg`
- `.aws/credentials`, `.aws/config`
- `.azure/msal_*`, `.azure/access*`, `.azure/service_principal*`, `.azure/token*`
- `.config/gcloud/credentials*`, `.config/gcloud/access_tokens*`, `.config/gcloud/application_default*`
- `*.tfstate*`
- `*.tfvars*`

Blocked calls return an explanation to the model so Claude can self-correct.

The hook only restricts credential/state file reads. It does **not** restrict how the customer runs Claude Code or Terraform — auto-approve, headless/auto mode, and similar workflows are intentionally left to the customer.

The hook is open source (~70 lines of Python 3, no third-party dependencies) and located at `.claude/hooks/block-cred-reads.py`. The customer's security team can review, modify, or replace it. Note its limits (see "Limitations"): the credential patterns are regex-based and can be evaded by a determined user or disabled by the customer.

### 3. Project-local activation (no global side effects)

The hook is enabled by `.claude/settings.json` in this repository — **not** by modifying the customer's global `~/.claude/settings.json`. When the customer is working inside the kit, defenses are on. When they are not, their normal Claude Code is unchanged. Uninstall = `rm -rf` the kit folder.

## Terraform discipline

Skills enforce the following Terraform conventions:

- **Plan before apply.** Every skill walks the customer through `terraform plan` and shows the diff before running `terraform apply`. The customer must approve.
- **No `-auto-approve`.** It is never used.
- **Sensitive outputs marked.** Outputs containing tokens are declared `sensitive = true`.
- **Remote state recommended.** Skills recommend S3 + KMS, AzureRM, or GCS + CMEK. Local state is gitignored (`.terraform/`, `*.tfstate*`).
- **Plan output review.** When plan output contains sensitive values, the skill summarizes rather than streams the full plan back through the model.

## Limitations

What the kit explicitly **does not** protect against:

- **Best-effort, not guaranteed.** The credential and plan-review safeguards are implemented as LLM skill instructions plus one regex hook. Because an LLM is probabilistic, it can deviate (bug, model error, ambiguous instruction, or prompt injection). Treat the safeguards as defense-in-depth, not guarantees, and review what the agent does.
- **How you run Claude Code is your choice and your responsibility.** The kit does not restrict auto-approve, headless/auto mode, `--dangerously-skip-permissions`, or any other workflow. It runs on your machine, with your credentials, under your control. If you choose a mode that applies changes without review, the consequences are yours — the kit takes no position on and accepts no responsibility for how it is operated.
- **Hook coverage gaps.** The credential-read hook matches the listed file paths only. It does **not** cover credentials held in environment variables (relevant to M2M/CI setups), and a determined user can obfuscate a path to evade the regex.
- **Customer-controlled bypass.** A customer can edit `.claude/settings.json` to disable the hook, or invoke Claude Code outside the kit folder. The kit cannot prevent this — by design, it is the customer's machine.
- **Cloud provider compromise.** The kit's blast radius equals the cloud provider's blast radius for the customer's existing CLI session.
- **Cost / financial exposure.** The kit provisions billable cloud infrastructure. A loop, misconfiguration, or unattended run can incur cloud charges. All cloud charges are the customer's responsibility; review the `terraform plan` and any cost estimate before approving.
- **Model-level prompt injection from external content.** The kit is an actuating agent that runs `terraform apply` and cloud CLI commands, and its skills instruct it to clone and read external repos as templates. If any consumed content (a repo, ticket, README, or module comment) carries injected instructions, it could steer the agent toward unintended actions. The customer is responsible for the trustworthiness of any repos, templates, or content the tool is directed to consume. Skills should not include `WebFetch` against untrusted hosts.
- **Network-level attacks.** TLS to the cloud provider and to Anthropic is the customer's TLS, not the kit's.

## Prerequisites for the security hook

- **Python 3** (any 3.x) — pre-installed on macOS and most Linux distros.
- **Claude Code** — version supporting `PreToolUse` hooks.

The hook has no third-party Python dependencies.

## Reporting a vulnerability

If you find a security issue in the kit (skill, hook, or repo), please report it privately:

- Email `bugbounty@databricks.com` (preferred), or
- Open a [GitHub Security Advisory](https://github.com/databricks-field-eng/ai-platform-kit/security/advisories/new). Do not open a public issue for security bugs.

Please include: a description of the vulnerability, steps to reproduce, the affected file/skill, and any suggested mitigation.

## Audit trail

Two independent logs cover every action the kit takes:

- **Local Claude Code transcript.** Every tool call, every Bash command, every file read or write is recorded by Claude Code. The customer can ship this to a SIEM if desired.
- **Cloud-side audit logs.** Every action against AWS / Azure / GCP / Databricks generates a record in CloudTrail / Activity Log / Cloud Audit Logs / Databricks audit log — under the customer's own account, not Anthropic's.

If something goes wrong, the customer has full forensic visibility from both sides.
