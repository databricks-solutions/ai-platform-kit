# Contributing to the Databricks Platform Kit

**Any Databricks employee is welcome to contribute** — most often a new skill, or an
improvement to an existing one. This repo is maintained by Databricks Field Engineering,
which reviews and merges contributions. You do **not** need to be on the Field Engineering
team, and you do **not** need to be added to any GitHub org: this is a public repository,
so you contribute the standard open-source way, by fork and pull request.

## Philosophy — what belongs here, and what makes a good skill

Before writing, it helps to know the shape of this kit and the bar for a contribution:

- **This kit is a thin layer.** It ships skills and a little glue — the instructions that
  drive an agent — and nothing else. It orchestrates tools the user installs and
  authenticates separately (the coding agent, Terraform, the cloud and Databricks CLIs) and
  never handles their credentials. New skills stay on that side of the line: guidance, not
  bundled binaries, packages, or an MCP server.
- **Skills are opinionated on purpose.** The kit takes a clear position (self-managed
  metastore, per-environment catalogs, a medallion layout, secure-by-default networking). A
  good skill has a point of view and a sensible default rather than exposing every knob and
  asking the user to decide everything.
- **State a customer-interaction posture.** Customer-facing skills carry a `## How to
  interact with the customer` section that sets a pushback level — how hard the agent should
  push back on a risky or ill-advised request. Decide yours deliberately; it is part of the
  design, not boilerplate.
- **Cloud-agnostic unless it genuinely can't be.** Keep a skill cloud-agnostic (one
  `SKILL.md`) when the guidance is the same everywhere. Only fan out into `AWS.md` /
  `AZURE.md` / `GCP.md` when the clouds truly diverge — and then cover all three.
- **Safe by default.** Never commit credentials, tokens, cloud account IDs, customer names,
  or `*.tfstate` / `*.tfvars`. Use placeholders in every example, prefer read/plan steps
  before mutations, and make destructive actions explicit.
- **Prefer improving an existing skill over adding a new one.** A sharper gotcha or a fixed
  edge case is often worth more than a new top-level skill. Add a new skill when the task is
  a genuinely distinct workflow, not a variation of one already here.
- **Earn the reader's trust with specifics.** The value is in the sharp edges — the auth
  quirk, the ordering constraint, the step that silently fails. Generic guidance the agent
  already knows just adds noise.

## How to contribute (the whole path)

1. **Fork** the repo on GitHub (top-right "Fork"). Use a personal GitHub account with your
   `@databricks.com` email verified — **not** your managed/EMU work account, which cannot
   fork public repos.
2. **Make your change** in your fork. To add a skill, create
   `.claude/skills/<your-skill-name>/SKILL.md` and follow the conventions in
   [`CLAUDE.md`](CLAUDE.md) (frontmatter, the "How to interact with the customer" pushback
   section, cloud-agnostic vs. cloud-fanned layout, `<prefix>` placeholder, cross-links).
3. **Check it locally** (optional but faster than waiting for CI):
   ```bash
   python3 scripts/skills-sync.py --lint       # validate your skill
   python3 scripts/skills-sync.py --generate   # refresh AGENTS.md + GEMINI.md
   ```
4. **Open a pull request** against `main`. A checklist appears automatically — tick it off.
   CI runs the lint, the generated-file drift check, and a secret scan on your PR.
5. **A maintainer reviews and merges.** You cannot merge to `main` yourself; that is the
   only "gate," and it is automatic for a public repo.

Not ready to write code? **Open an issue** with the idea or request instead.

**No CLA or DCO is required for Databricks employees** — your employment agreement covers
it. (External, non-Databricks contributions are not being solicited right now; please open
an issue.)

Want direct push / co-maintainer access instead of forking? Request `databricks-solutions`
org membership via Opal (app `app.github-databricks-solutions`). Most contributors never
need this.

## Development setup

1. Clone the repository:
   ```bash
   git clone https://github.com/databricks-solutions/ai-platform-kit.git
   cd ai-platform-kit
   ```
2. Open the repo with Claude Code — skills in `.claude/skills/` are auto-discovered. No
   build or install step is required (the kit ships no Python packages).

## Standards

- **Documentation**: Update the relevant `SKILL.md` and the README skills table when adding
  or modifying a skill.
- **Lint before you push**: `python3 scripts/skills-sync.py --lint` checks frontmatter,
  kebab-case naming, the pushback section, cross-link targets, cloud-fan completeness, the
  README row, and for stray secrets. CI runs it too, so fixing errors locally is faster.
- **Agent pointer files**: After adding, renaming, or removing a skill, rerun
  `python3 scripts/skills-sync.py --generate` to refresh the committed `AGENTS.md` and
  `GEMINI.md` (they are generated from `.claude/skills/` — do not hand-edit them). CI
  guards this with `--generate --check`.
- **Naming**: Use lowercase with hyphens for directories (e.g. `platform-provisioning`).
- **No credentials**: Never commit credentials, tokens, cloud account IDs, customer names,
  or `*.tfstate` / `*.tfvars` files. Use placeholders in all examples.

## Security

- Report vulnerabilities privately per [SECURITY.md](SECURITY.md) — do not open a public
  issue for security bugs.
- Review changes for potential secret leakage before submitting.

## License

By submitting a contribution, you agree that your contributions will be licensed under the
same terms as the project (see [LICENSE.md](LICENSE.md)).

You certify that:
- You have the right to submit the contribution;
- Your contribution does not include confidential or proprietary information; and
- You grant Databricks the right to use, modify, and distribute your contribution.
