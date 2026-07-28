# Contributing to the Databricks Platform Kit

This repository is maintained by Databricks Field Engineering. While the repository is
intended to help Databricks Field Engineers and customers provision Databricks
platform infrastructure, **external contributions are not currently accepted**. Feel
free to open an issue with requests or suggestions.

## Development setup

1. Clone the repository:
   ```bash
   git clone https://github.com/databricks-field-eng/ai-platform-kit.git
   cd ai-platform-kit
   ```
2. Open the repo with Claude Code — skills in `.claude/skills/` are auto-discovered. No
   build or install step is required (the kit ships no Python packages).

## Standards

- **Documentation**: Update the relevant `SKILL.md` and the README skills table when adding
  or modifying a skill.
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
