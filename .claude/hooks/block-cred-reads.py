#!/usr/bin/env python3
"""AIPK PreToolUse hook: block reads of credential and state files.

Activated by .claude/settings.json when Claude Code runs from this repo.
Receives tool invocation JSON on stdin. Exit 2 = block (with stderr feedback
to Claude). Exit 0 = allow.

Policy: this kit does not read credential files directly. Auth is verified via
cloud CLIs (`aws sts get-caller-identity`, `databricks current-user me`, etc.).
See SECURITY.md.

Note: this hook does NOT restrict how the customer runs Claude Code or
Terraform. Whether to use auto-approve, headless/auto mode, or any other
workflow is the customer's choice and the customer's responsibility. The kit
takes no position on that — see the license and SECURITY.md "Limitations".
"""

import json
import re
import sys

SENSITIVE_PATTERNS = [
    r"\.databrickscfg",
    r"\.aws/credentials",
    r"\.aws/config\b",
    r"\.azure/(msal|access|service_principal|token)",
    r"\.config/gcloud/(credentials|access_tokens|application_default)",
    r"\.tfstate\b",
    r"\.tfvars\b",
]

BLOCK_MESSAGE = """BLOCKED by AIPK security policy: {reason}

This kit does not read credential or state files directly. To verify auth, use
the cloud CLI:

  aws sts get-caller-identity    # AWS
  az account show                # Azure
  gcloud auth list               # GCP
  databricks current-user me     # Databricks

If you need to bypass this for a legitimate reason, edit
.claude/settings.json or remove the hook. See SECURITY.md for the rationale.
"""


def block(reason: str) -> None:
    print(BLOCK_MESSAGE.format(reason=reason), file=sys.stderr)
    sys.exit(2)


def main() -> None:
    try:
        data = json.load(sys.stdin)
    except Exception:
        sys.exit(0)

    tool = data.get("tool_name", "")
    tool_input = data.get("tool_input") or {}

    if tool == "Read":
        target = tool_input.get("file_path", "")
    elif tool == "Bash":
        target = tool_input.get("command", "")
    else:
        sys.exit(0)

    for pattern in SENSITIVE_PATTERNS:
        if re.search(pattern, target):
            block(f"{tool} would touch credential/state file (matched: {pattern})")

    sys.exit(0)


if __name__ == "__main__":
    main()
