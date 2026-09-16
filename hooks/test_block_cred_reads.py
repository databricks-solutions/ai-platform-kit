#!/usr/bin/env python3
"""Fixture test for the credential-safety PreToolUse hook.

Proves that, in the installed layout (hook resolved next to this file, exactly
as `${CLAUDE_PLUGIN_ROOT}/hooks/block-cred-reads.py` resolves on a plugin
install), a credential/state-file access is blocked (exit 2) while benign
access is allowed (exit 0). Stdlib only — no third-party deps.

Run: python3 hooks/test_block_cred_reads.py
"""

import json
import subprocess
import sys
import unittest
from pathlib import Path

HOOK = Path(__file__).resolve().parent / "block-cred-reads.py"


def run_hook(payload: dict) -> int:
    """Invoke the hook exactly as Claude Code would: JSON event on stdin."""
    proc = subprocess.run(
        [sys.executable, str(HOOK)],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
    )
    return proc.returncode


class TestBlockCredReads(unittest.TestCase):
    def test_hook_file_exists(self):
        self.assertTrue(HOOK.is_file(), f"hook not found at {HOOK}")

    def test_read_databrickscfg_blocked(self):
        rc = run_hook({"tool_name": "Read", "tool_input": {"file_path": "/Users/x/.databrickscfg"}})
        self.assertEqual(rc, 2, "reading .databrickscfg must be blocked")

    def test_read_aws_credentials_blocked(self):
        rc = run_hook({"tool_name": "Read", "tool_input": {"file_path": "~/.aws/credentials"}})
        self.assertEqual(rc, 2, "reading .aws/credentials must be blocked")

    def test_bash_cat_tfstate_blocked(self):
        rc = run_hook({"tool_name": "Bash", "tool_input": {"command": "cat infra/terraform.tfstate"}})
        self.assertEqual(rc, 2, "a Bash command touching *.tfstate must be blocked")

    def test_bash_cat_tfvars_blocked(self):
        rc = run_hook({"tool_name": "Bash", "tool_input": {"command": "cat prod.tfvars"}})
        self.assertEqual(rc, 2, "a Bash command touching *.tfvars must be blocked")

    def test_benign_read_allowed(self):
        rc = run_hook({"tool_name": "Read", "tool_input": {"file_path": "/repo/README.md"}})
        self.assertEqual(rc, 0, "reading a normal file must be allowed")

    def test_benign_bash_allowed(self):
        rc = run_hook({"tool_name": "Bash", "tool_input": {"command": "terraform plan"}})
        self.assertEqual(rc, 0, "a normal Bash command must be allowed")

    def test_other_tool_allowed(self):
        rc = run_hook({"tool_name": "Glob", "tool_input": {"pattern": "**/*.tf"}})
        self.assertEqual(rc, 0, "non-Read/Bash tools must pass through")

    def test_malformed_input_allowed(self):
        proc = subprocess.run(
            [sys.executable, str(HOOK)], input="not json", text=True, capture_output=True
        )
        self.assertEqual(proc.returncode, 0, "malformed input must not block")


if __name__ == "__main__":
    unittest.main(verbosity=2)
