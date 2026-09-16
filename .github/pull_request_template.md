<!-- Thanks for contributing to the Databricks Platform Kit! Keep PRs focused. -->

## What this adds or changes

<!-- One or two lines. If it's a new skill, name it and say what it's for. -->

## Checklist

- [ ] Ran `python3 scripts/skills-sync.py --lint` and it passed (no errors).
- [ ] Ran `python3 scripts/skills-sync.py --generate` and committed the updated `AGENTS.md` / `GEMINI.md`.
- [ ] New/changed skill is listed in the README skills table.
- [ ] Customer-facing skills have a `## How to interact with the customer` section stating a pushback level.
- [ ] Cross-links point at skills that actually exist.
- [ ] Cloud-specific skills include all of `AWS.md`, `AZURE.md`, and `GCP.md`.
- [ ] No credentials, tokens, or `*.tfstate` / `*.tfvars` files are committed.
- [ ] Forked with a `@databricks.com`-verified GitHub account (not a managed/EMU work account).

<!-- CI will re-run the lint, generated-file drift check, and secret scan automatically. -->
