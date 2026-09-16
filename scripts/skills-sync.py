#!/usr/bin/env python3
"""skills-sync.py — generate agent pointer files and install AIPK skills for any agent.

Single source of truth: the skills under `.claude/skills/<name>/`. This script has
two jobs:

  1. GENERATE (maintainer): regenerate the committed root `AGENTS.md` and `GEMINI.md`
     from the skills so they never drift. Idempotent; `--check` fails on drift.

  2. INSTALL (end user): copy the skills into the layout a chosen agent expects and
     write that agent's pointer/instruction file, into this project or globally.

Design notes:
  - Python 3 stdlib only (no pip installs). Runs on Linux, macOS, Windows.
  - Cross-platform paths via pathlib / Path.home(). Never symlinks (Windows-safe) —
    always copies directories.
  - The skill markdown is never modified. Each agent just gets different packaging.

Usage:
  python3 scripts/skills-sync.py --list
  python3 scripts/skills-sync.py --generate [--check]
  python3 scripts/skills-sync.py --agents claude,codex --scope project
  python3 scripts/skills-sync.py --agent gemini --scope global
  python3 scripts/skills-sync.py --agent codex --into /path/to/other/project

Run with no arguments for interactive mode (the picker the wrappers use).
"""

from __future__ import annotations

import argparse
import re
import shutil
import sys
from pathlib import Path

# --------------------------------------------------------------------------------------
# Repo layout
# --------------------------------------------------------------------------------------

# scripts/skills-sync.py  ->  repo root is one level up.
REPO_ROOT = Path(__file__).resolve().parent.parent
SKILLS_SRC = REPO_ROOT / ".claude" / "skills"

# Files/dirs never copied into an install target (secrets, state, build junk).
EXCLUDE_NAMES = {
    "__pycache__",
    ".pytest_cache",
    ".DS_Store",
    ".terraform",
}
EXCLUDE_SUFFIXES = {".tfstate", ".tfvars", ".pyc"}

REPO_URL = "https://github.com/databricks-solutions/ai-platform-kit"

# --------------------------------------------------------------------------------------
# Agent registry
# --------------------------------------------------------------------------------------
#
# Each agent describes where skills go and which pointer file is written. `skills_dir`
# is relative to the install target; None means "no copy, the pointer file references
# the source skills instead" (Gemini imports, Windsurf rules).

AGENTS: dict[str, dict] = {
    "claude": {
        "label": "Claude Code",
        "skills_dir": ".claude/skills",
        "global_skills_dir": ".claude/skills",  # under Path.home()
        "pointer": "claude",  # settings.json + hook + plugin.json
    },
    "codex": {
        "label": "OpenAI Codex",
        "skills_dir": ".agents/skills",
        "global_skills_dir": ".agents/skills",
        "pointer": "agents_md",
    },
    "cursor": {
        "label": "Cursor",
        "skills_dir": ".cursor/skills",
        "global_skills_dir": ".cursor/skills",
        "pointer": "cursor_mdc",
    },
    "copilot": {
        "label": "GitHub Copilot",
        "skills_dir": ".agents/skills",
        "global_skills_dir": ".agents/skills",
        "pointer": "copilot_md",
    },
    "gemini": {
        "label": "Gemini CLI",
        # Copied so GEMINI.md's @imports resolve in a standalone install.
        "skills_dir": ".agents/skills",
        "global_skills_dir": ".agents/skills",
        "pointer": "gemini_md",
    },
    "windsurf": {
        "label": "Windsurf",
        # Copied so the .windsurf/rules pointer resolves in a standalone install.
        "skills_dir": ".agents/skills",
        "global_skills_dir": ".agents/skills",
        "pointer": "windsurf_rules",
    },
    "opencode": {
        "label": "OpenCode",
        "skills_dir": ".agents/skills",
        "global_skills_dir": ".agents/skills",
        "pointer": "agents_md",
    },
    "kiro": {
        "label": "Kiro",
        "skills_dir": ".kiro/skills",
        "global_skills_dir": ".kiro/skills",
        "pointer": "none",  # native Agent Skills discovery
    },
}

NON_CLAUDE_CRED_NOTE = (
    "> **Credential safety:** Claude Code installs ship a PreToolUse hook that blocks "
    "reads of credential/state files (`.databrickscfg`, `*.tfstate`, cloud creds). "
    "Other agents have no equivalent hook — run them in a gated approval/sandbox mode "
    "so tool calls that touch those files require confirmation."
)


# --------------------------------------------------------------------------------------
# Skill discovery + frontmatter parsing
# --------------------------------------------------------------------------------------


class Skill:
    def __init__(self, directory: Path, name: str, description: str):
        self.directory = directory
        self.dir_name = directory.name
        self.name = name
        self.description = description

    def __repr__(self) -> str:
        return f"Skill({self.dir_name!r}, name={self.name!r})"


def _parse_frontmatter(text: str) -> dict[str, str]:
    """Minimal YAML-frontmatter parser for `key: value` pairs between --- fences.

    Handles quoted values and simple multi-line folding is not needed here — the
    skills use single-line `name:` and `description:` values. Kept dependency-free.
    """
    lines = text.splitlines()
    if not lines or lines[0].strip() != "---":
        return {}
    out: dict[str, str] = {}
    for line in lines[1:]:
        if line.strip() == "---":
            break
        if ":" not in line:
            continue
        key, _, value = line.partition(":")
        key = key.strip()
        value = value.strip()
        if len(value) >= 2 and value[0] in "\"'" and value[-1] == value[0]:
            value = value[1:-1]
        out[key] = value
    return out


def discover_skills(skills_src: Path = SKILLS_SRC) -> list[Skill]:
    if not skills_src.is_dir():
        die(f"skills directory not found: {skills_src}")
    skills: list[Skill] = []
    for child in sorted(skills_src.iterdir()):
        skill_md = child / "SKILL.md"
        if not (child.is_dir() and skill_md.is_file()):
            continue
        fm = _parse_frontmatter(skill_md.read_text(encoding="utf-8"))
        name = fm.get("name", child.name)
        description = fm.get("description", "")
        skills.append(Skill(child, name, description))
    if not skills:
        die(f"no skills found under {skills_src}")
    return skills


# --------------------------------------------------------------------------------------
# Copy helper (cross-platform, exclusions applied)
# --------------------------------------------------------------------------------------


def _ignore(_dir: str, names: list[str]) -> set[str]:
    ignored = set()
    for n in names:
        if n in EXCLUDE_NAMES or any(n.endswith(s) for s in EXCLUDE_SUFFIXES):
            ignored.add(n)
    return ignored


def copy_skill_tree(skills: list[Skill], dest_skills_dir: Path) -> None:
    """Copy each skill directory into dest_skills_dir/<dir_name>, excluding junk."""
    dest_skills_dir.mkdir(parents=True, exist_ok=True)
    for skill in skills:
        target = dest_skills_dir / skill.dir_name
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(skill.directory, target, ignore=_ignore)


# --------------------------------------------------------------------------------------
# Pointer-file renderers
# --------------------------------------------------------------------------------------


def _skill_bullet_lines(skills: list[Skill], skill_path_prefix: str) -> str:
    """Bulleted 'name — description (path)' list for instruction files."""
    lines = []
    for s in skills:
        path = f"{skill_path_prefix}/{s.dir_name}/SKILL.md"
        lines.append(f"- **{s.name}** — {s.description}\n  Read `{path}` when this applies.")
    return "\n".join(lines)


def render_agents_md(skills: list[Skill], skill_path_prefix: str) -> str:
    """Root AGENTS.md — read by Codex, Copilot, Cursor, Gemini, Windsurf, OpenCode."""
    return f"""# AI Platform Kit — agent guide

This repository is a set of **skills** for provisioning and operating Databricks
platform infrastructure (workspaces, Unity Catalog, identity, networking, CI/CD)
across Azure, AWS, and GCP. Each skill is a self-contained markdown file with
instructions the agent follows.

## How to use these skills

The skills live under `{skill_path_prefix}/`. Load only what the task needs: when a
request matches a skill's description below, open that skill's `SKILL.md` and follow
it. Cloud-specific companion files (`AWS.md`, `AZURE.md`, `GCP.md`, and their numbered
topic files) are referenced from within each `SKILL.md` — read them based on the
target cloud to avoid cross-cloud confusion.

## Available skills

{_skill_bullet_lines(skills, skill_path_prefix)}

## Operating notes

- The kit writes Terraform and SDK/CLI calls tailored to the request — there are no
  rigid templates to fill in. Review every `terraform plan` before approving; this
  provisions real, billable cloud infrastructure.
- Verify auth via cloud CLIs (`aws sts get-caller-identity`, `az account show`,
  `gcloud auth list`, `databricks current-user me`) rather than reading credential
  files.

{NON_CLAUDE_CRED_NOTE}

<!-- Generated by scripts/skills-sync.py from {skill_path_prefix}/. Do not hand-edit;
     rerun `python3 scripts/skills-sync.py --generate`. -->
"""


def render_gemini_md(skills: list[Skill], skill_path_prefix: str) -> str:
    """GEMINI.md — Gemini CLI pulls in referenced files via @import syntax."""
    imports = "\n".join(f"@{skill_path_prefix}/{s.dir_name}/SKILL.md" for s in skills)
    listing = _skill_bullet_lines(skills, skill_path_prefix)
    return f"""# AI Platform Kit — Gemini guide

Skills for provisioning and operating Databricks platform infrastructure across
Azure, AWS, and GCP. Load only what the task needs.

## Available skills

{listing}

## Operating notes

- Review every `terraform plan` before approving — this provisions real, billable
  cloud infrastructure.
- Verify auth via cloud CLIs, not by reading credential files.

{NON_CLAUDE_CRED_NOTE}

## Skill imports

{imports}

<!-- Generated by scripts/skills-sync.py from {skill_path_prefix}/. Do not hand-edit;
     rerun `python3 scripts/skills-sync.py --generate`. -->
"""


def render_cursor_mdc(skills: list[Skill], skill_path_prefix: str) -> str:
    """.cursor/rules/*.mdc — Agent Requested rule (description-triggered)."""
    listing = _skill_bullet_lines(skills, skill_path_prefix)
    return f"""---
description: "Databricks platform engineering skills — provision workspaces, Unity Catalog, identity, networking, CI/CD across Azure/AWS/GCP. Use for any Databricks platform/infra request."
alwaysApply: false
---

# AI Platform Kit skills

When a request matches one of the skills below, open that skill's `SKILL.md` and follow
it. Cloud-specific companion files are referenced from within each `SKILL.md`.

{listing}

Review every `terraform plan` before approving. Verify auth via cloud CLIs, not by
reading credential files. No PreToolUse hook runs under Cursor — use a gated approval
mode for tool calls that touch credential/state files.
"""


def render_copilot_md(skills: list[Skill], skill_path_prefix: str) -> str:
    """.github/copilot-instructions.md — repo-wide Copilot instructions."""
    listing = _skill_bullet_lines(skills, skill_path_prefix)
    return f"""# AI Platform Kit — Copilot instructions

This repo provides skills for provisioning and operating Databricks platform
infrastructure across Azure, AWS, and GCP. When a request matches a skill below, open
that skill's `SKILL.md` (under `{skill_path_prefix}/`) and follow it.

{listing}

Review every `terraform plan` before approving — this provisions real, billable cloud
infrastructure. Verify auth via cloud CLIs, not by reading credential files. No
PreToolUse hook runs under Copilot — use a gated approval mode for tool calls that
touch credential/state files.
"""


def render_windsurf_rule(skills: list[Skill], skill_path_prefix: str) -> str:
    """A single .windsurf/rules/*.md file (model_decision trigger, under 12k chars)."""
    listing = _skill_bullet_lines(skills, skill_path_prefix)
    return f"""---
trigger: model_decision
description: "Databricks platform engineering skills — provision workspaces, Unity Catalog, identity, networking, CI/CD across Azure/AWS/GCP."
---

# AI Platform Kit skills

When a request matches one of the skills below, open that skill's `SKILL.md` and follow
it. Cloud-specific companion files are referenced from within each `SKILL.md`.

{listing}

Review every `terraform plan` before approving. Verify auth via cloud CLIs, not by
reading credential files. No PreToolUse hook runs under Windsurf — use a gated
approval mode for tool calls that touch credential/state files.
"""


# --------------------------------------------------------------------------------------
# GENERATE mode
# --------------------------------------------------------------------------------------

GENERATED_FILES = ("AGENTS.md", "GEMINI.md")


def _generated_content(skills: list[Skill]) -> dict[str, str]:
    # Committed pointer files reference the in-repo source location.
    prefix = ".claude/skills"
    return {
        "AGENTS.md": render_agents_md(skills, prefix),
        "GEMINI.md": render_gemini_md(skills, prefix),
    }


def do_generate(check: bool) -> int:
    skills = discover_skills()
    content = _generated_content(skills)
    drift = []
    for fname, text in content.items():
        path = REPO_ROOT / fname
        current = path.read_text(encoding="utf-8") if path.exists() else None
        if current == text:
            continue
        drift.append(fname)
        if not check:
            path.write_text(text, encoding="utf-8")
    if check:
        if drift:
            print(f"drift: {', '.join(drift)} out of date — run --generate", file=sys.stderr)
            return 1
        print("AGENTS.md and GEMINI.md are in sync.")
        return 0
    if drift:
        print(f"regenerated: {', '.join(drift)}")
    else:
        print("already in sync (no changes).")
    return 0


# --------------------------------------------------------------------------------------
# LINT mode
# --------------------------------------------------------------------------------------
#
# Mechanical checks for a skill contribution — the boring stuff a human shouldn't have to
# eyeball on every PR. ERRORS fail (exit 1); warnings are surfaced but don't fail, so the
# current kit (e.g. deployment-verification, which has no customer-interaction section)
# stays green while new contributions still get nudged.

RESERVED_NAME_WORDS = ("claude", "anthropic")
MAX_NAME_LEN = 64
MAX_DESC_LEN = 1024
CLOUD_FILES = ("AWS.md", "AZURE.md", "GCP.md")

_KEBAB_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")
_INTERACT_HEADING_RE = re.compile(r"^##\s+how to interact with the customer\s*$", re.I)
_CROSSLINK_HEADING_RE = re.compile(r"^##\s+cross[- ]?links\s*$", re.I)
_PUSHBACK_RE = re.compile(r"\b(HIGH|MODERATE|LIGHT|MINIMAL)\b")
# Bold, kebab-case, at least one hyphen → looks like a skill reference (not bolded prose).
_BOLD_REF_RE = re.compile(r"\*\*([a-z0-9]+(?:-[a-z0-9]+)+)\*\*")
# Actual secret MATERIAL (not mere mentions of state files, which skills discuss in prose).
_CRED_MATERIAL = (
    ("AWS access key id", re.compile(r"AKIA[0-9A-Z]{16}")),
    ("private key block", re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----")),
    ("Databricks token", re.compile(r"\bdapi[0-9a-f]{32}\b")),
)


def _crosslink_section(text: str) -> str:
    """Return the body under a `## Cross-links` heading (until the next `## ` heading)."""
    out: list[str] = []
    capturing = False
    for line in text.splitlines():
        if line.startswith("## "):
            capturing = bool(_CROSSLINK_HEADING_RE.match(line))
            continue
        if capturing:
            out.append(line)
    return "\n".join(out)


def do_lint(only: str | None) -> int:
    """Validate skills. Returns 1 if any ERROR is found; warnings never fail."""
    skills = discover_skills()
    known = {s.dir_name for s in skills}
    readme = REPO_ROOT / "README.md"
    readme_text = readme.read_text(encoding="utf-8") if readme.is_file() else ""

    total_err = 0
    total_warn = 0
    matched = 0

    for s in skills:
        if only and only not in (s.dir_name, s.name):
            continue
        matched += 1
        errs: list[str] = []
        warns: list[str] = []

        text = (s.directory / "SKILL.md").read_text(encoding="utf-8")
        fm = _parse_frontmatter(text)
        name = fm.get("name", "").strip()
        desc = fm.get("description", "").strip()

        # Frontmatter: name
        if not name:
            errs.append("frontmatter is missing `name`")
        else:
            if not _KEBAB_RE.match(name):
                errs.append(f"name '{name}' is not kebab-case (lowercase letters, digits, hyphens)")
            if len(name) > MAX_NAME_LEN:
                errs.append(f"name is {len(name)} chars (max {MAX_NAME_LEN})")
            for w in RESERVED_NAME_WORDS:
                if w in name.lower():
                    errs.append(f"name contains reserved word '{w}'")
        # Frontmatter: description
        if not desc:
            errs.append("frontmatter is missing `description`")
        elif len(desc) > MAX_DESC_LEN:
            errs.append(f"description is {len(desc)} chars (max {MAX_DESC_LEN})")
        # Directory name
        if not _KEBAB_RE.match(s.dir_name):
            errs.append(f"directory name '{s.dir_name}' is not kebab-case")

        # Customer-interaction / pushback section (warning — not all skills are customer-facing)
        if any(_INTERACT_HEADING_RE.match(ln) for ln in text.splitlines()):
            if not _PUSHBACK_RE.search(text):
                warns.append('has a "How to interact with the customer" section but names no '
                             "pushback level (HIGH/MODERATE/LIGHT/MINIMAL)")
        else:
            warns.append('no "## How to interact with the customer" section '
                         "(customer-facing skills should state a pushback level)")

        # Cross-links resolve to real skills
        for m in _BOLD_REF_RE.finditer(_crosslink_section(text)):
            ref = m.group(1)
            if ref not in known:
                errs.append(f"cross-link **{ref}** points to a skill that doesn't exist (typo?)")

        # Cloud-fan completeness: any of AWS/AZURE/GCP present ⇒ all three present
        present = {n for n in CLOUD_FILES if (s.directory / n).is_file()}
        if present and present != set(CLOUD_FILES):
            missing = sorted(set(CLOUD_FILES) - present)
            errs.append(f"cloud-fanned skill is missing {', '.join(missing)} "
                        f"(has {', '.join(sorted(present))})")

        # Listed in the README skills table
        if readme_text and f"**{s.dir_name}**" not in readme_text:
            errs.append(f"not listed in the README skills table (expected **{s.dir_name}**)")

        # Secret material committed in the skill's markdown
        for md in sorted(s.directory.rglob("*.md")):
            mtext = md.read_text(encoding="utf-8", errors="ignore")
            for label, rx in _CRED_MATERIAL:
                if rx.search(mtext):
                    errs.append(f"possible {label} committed in {md.relative_to(s.directory)}")

        # Report
        if errs:
            print(f"✗ {s.dir_name}")
            for e in errs:
                print(f"    ERROR: {e}")
            for w in warns:
                print(f"    warn:  {w}")
        elif warns:
            print(f"! {s.dir_name}")
            for w in warns:
                print(f"    warn:  {w}")
        else:
            print(f"✓ {s.dir_name}")

        total_err += len(errs)
        total_warn += len(warns)

    if only and matched == 0:
        die(f"no skill named '{only}' found under {SKILLS_SRC}")

    print()
    if total_err:
        print(f"lint: {total_err} error(s), {total_warn} warning(s) — fix the errors above.",
              file=sys.stderr)
        return 1
    print(f"lint: 0 errors, {total_warn} warning(s). OK.")
    return 0


# --------------------------------------------------------------------------------------
# INSTALL mode
# --------------------------------------------------------------------------------------


def _install_claude(skills: list[Skill], target: Path, is_global: bool) -> list[str]:
    written = []
    dest = target / (".claude/skills")
    copy_skill_tree(skills, dest)
    written.append(str(dest))
    # settings.json + hook + plugin.json only for a project install (global is per-user
    # skills dir and does not carry project hooks).
    if not is_global:
        claude_dir = target / ".claude"
        hooks_dir = target / "hooks"
        hooks_dir.mkdir(parents=True, exist_ok=True)
        claude_dir.mkdir(parents=True, exist_ok=True)
        src_hook = REPO_ROOT / "hooks" / "block-cred-reads.py"
        src_settings = REPO_ROOT / ".claude" / "settings.json"
        if src_hook.is_file():
            shutil.copy2(src_hook, hooks_dir / "block-cred-reads.py")
            written.append(str(hooks_dir / "block-cred-reads.py"))
        if src_settings.is_file():
            shutil.copy2(src_settings, claude_dir / "settings.json")
            written.append(str(claude_dir / "settings.json"))
        src_plugin = REPO_ROOT / ".claude-plugin" / "plugin.json"
        if src_plugin.is_file():
            plugin_dir = target / ".claude-plugin"
            plugin_dir.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src_plugin, plugin_dir / "plugin.json")
            written.append(str(plugin_dir / "plugin.json"))
    return written


def _write(path: Path, text: str) -> str:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    return str(path)


def install_agent(agent_key: str, skills: list[Skill], target: Path, is_global: bool) -> list[str]:
    agent = AGENTS[agent_key]
    pointer = agent["pointer"]
    written: list[str] = []

    if agent_key == "claude":
        return _install_claude(skills, target, is_global)

    # Copy skills into the agent's skills dir when it has one.
    skills_dir_rel = agent["global_skills_dir"] if is_global else agent["skills_dir"]
    copied_prefix = None
    if skills_dir_rel:
        dest = target / skills_dir_rel
        copy_skill_tree(skills, dest)
        written.append(str(dest))
        copied_prefix = skills_dir_rel
    else:
        # No copy: pointer references the source skills relative to target.
        copied_prefix = ".claude/skills"

    if pointer == "agents_md":
        written.append(_write(target / "AGENTS.md", render_agents_md(skills, copied_prefix)))
    elif pointer == "gemini_md":
        written.append(_write(target / "GEMINI.md", render_gemini_md(skills, copied_prefix)))
    elif pointer == "cursor_mdc":
        written.append(_write(
            target / ".cursor" / "rules" / "ai-platform-kit.mdc",
            render_cursor_mdc(skills, copied_prefix),
        ))
    elif pointer == "copilot_md":
        written.append(_write(
            target / ".github" / "copilot-instructions.md",
            render_copilot_md(skills, copied_prefix),
        ))
    elif pointer == "windsurf_rules":
        written.append(_write(
            target / ".windsurf" / "rules" / "ai-platform-kit.md",
            render_windsurf_rule(skills, copied_prefix),
        ))
    elif pointer == "none":
        pass  # native Agent Skills discovery (Kiro)

    return written


def do_install(agent_keys: list[str], scope: str, into: Path | None) -> int:
    skills = discover_skills()
    is_global = scope == "global"
    if is_global:
        target = Path.home()
    else:
        target = into.resolve() if into else Path.cwd()
    target.mkdir(parents=True, exist_ok=True)

    print(f"Installing {len(skills)} skills → {target}  (scope: {scope})\n")
    for key in agent_keys:
        written = install_agent(key, skills, target, is_global)
        print(f"  {AGENTS[key]['label']}")
        for w in written:
            rel = _relpath(Path(w), target)
            print(f"    + {rel}")
    print("\nDone. Open the target folder in your agent and go.")
    if any(k != "claude" for k in agent_keys):
        print("\nNote: non-Claude agents have no credential-blocking hook — run them in a "
              "gated approval/sandbox mode.")
    return 0


def _relpath(path: Path, base: Path) -> str:
    try:
        return str(path.relative_to(base))
    except ValueError:
        return str(path)


# --------------------------------------------------------------------------------------
# Interactive picker
# --------------------------------------------------------------------------------------


def _detect_installed(target: Path) -> set[str]:
    """Pre-select agents whose config dirs already exist in the target project."""
    found = set()
    probes = {
        "claude": ".claude",
        "cursor": ".cursor",
        "copilot": ".github",
        "codex": ".agents",
        "windsurf": ".windsurf",
        "kiro": ".kiro",
    }
    for key, rel in probes.items():
        if (target / rel).exists():
            found.add(key)
    return found


def interactive() -> int:
    keys = list(AGENTS.keys())
    preselected = _detect_installed(Path.cwd())
    print("Databricks Platform Kit — installer\n")
    print("Which agent(s)? Enter numbers separated by spaces (e.g. 1 2), or 'a' for all.\n")
    for i, k in enumerate(keys, 1):
        mark = "*" if k in preselected else " "
        print(f"  [{mark}] {i}. {AGENTS[k]['label']}")
    default_hint = (
        " ".join(str(keys.index(k) + 1) for k in keys if k in preselected)
        if preselected else ""
    )
    prompt = f"\nSelection{f' [{default_hint}]' if default_hint else ''}: "
    raw = input(prompt).strip().lower()
    if not raw and default_hint:
        chosen = [k for k in keys if k in preselected]
    elif raw in ("a", "all"):
        chosen = keys
    else:
        chosen = []
        for tok in raw.replace(",", " ").split():
            if tok.isdigit() and 1 <= int(tok) <= len(keys):
                chosen.append(keys[int(tok) - 1])
    chosen = list(dict.fromkeys(chosen))  # dedupe, keep order
    if not chosen:
        print("No agents selected. Nothing to do.")
        return 1

    print("\nInstall where?")
    print("  1. This project (.)   [default]")
    print("  2. Global (all my projects)")
    scope_raw = input("Selection [1]: ").strip()
    scope = "global" if scope_raw == "2" else "project"

    return do_install(chosen, scope, None)


# --------------------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------------------


def die(msg: str) -> "NoReturn":  # type: ignore[valid-type]
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def parse_agent_args(agents: str | None, agent: str | None) -> list[str]:
    raw = []
    if agents:
        raw += agents.split(",")
    if agent:
        raw.append(agent)
    keys = []
    for r in raw:
        r = r.strip().lower()
        if not r:
            continue
        if r == "all":
            return list(AGENTS.keys())
        if r not in AGENTS:
            die(f"unknown agent '{r}'. Valid: {', '.join(AGENTS)}")
        keys.append(r)
    return list(dict.fromkeys(keys))


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(
        description="Generate agent pointer files and install AIPK skills for any agent.",
    )
    p.add_argument("--list", action="store_true", help="list discovered skills and exit")
    p.add_argument("--generate", action="store_true",
                   help="regenerate committed AGENTS.md and GEMINI.md")
    p.add_argument("--check", action="store_true",
                   help="with --generate: fail if generated files are stale")
    p.add_argument("--lint", nargs="?", const="__all__", default=None, metavar="SKILL",
                   help="validate skills (all, or one named skill); non-zero exit on errors")
    p.add_argument("--agents", help="comma-separated agents to install (e.g. claude,codex)")
    p.add_argument("--agent", help="single agent to install")
    p.add_argument("--scope", choices=("project", "global"), default="project",
                   help="install into this project (default) or globally")
    p.add_argument("--into", type=Path, help="project dir to install into (default: cwd)")
    args = p.parse_args(argv)

    if args.list:
        for s in discover_skills():
            print(f"{s.dir_name}\n    name: {s.name}\n    {s.description}\n")
        return 0

    if args.generate:
        return do_generate(check=args.check)

    if args.lint is not None:
        return do_lint(None if args.lint == "__all__" else args.lint)

    agent_keys = parse_agent_args(args.agents, args.agent)
    if agent_keys:
        return do_install(agent_keys, args.scope, args.into)

    # No actionable flags → interactive picker.
    if sys.stdin.isatty():
        return interactive()
    p.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
