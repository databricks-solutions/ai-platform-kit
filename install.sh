#!/usr/bin/env bash
# AI Platform Kit installer (macOS / Linux).
#
# Installs the Databricks Platform Kit skills for the coding agent(s) you pick, into
# the current project or globally. Run interactively:
#
#   bash <(curl -sL https://raw.githubusercontent.com/databricks-solutions/ai-platform-kit/main/install.sh)
#
# Or non-interactively (flags are passed straight through to skills-sync.py):
#
#   ./install.sh --agent codex --scope project
#   ./install.sh --agents claude,cursor --scope global
#
# All real logic lives in scripts/skills-sync.py (Python 3, stdlib only). This wrapper
# just finds or fetches the repo, checks for Python, and delegates.
set -euo pipefail

REPO_URL="https://github.com/databricks-solutions/ai-platform-kit"
TARBALL_URL="https://codeload.github.com/databricks-solutions/ai-platform-kit/tar.gz/refs/heads/main"

err() { printf 'error: %s\n' "$*" >&2; exit 1; }

# --- locate python3 -------------------------------------------------------------------
PYTHON=""
for cand in python3 python; do
  if command -v "$cand" >/dev/null 2>&1; then PYTHON="$cand"; break; fi
done
[ -n "$PYTHON" ] || err "Python 3 is required but was not found on PATH."

# --- locate the repo (running from a clone?) or fetch a tarball -----------------------
SCRIPT_SRC="${BASH_SOURCE[0]:-}"
REPO_DIR=""
if [ -n "$SCRIPT_SRC" ] && [ -f "$SCRIPT_SRC" ]; then
  maybe_root="$(cd "$(dirname "$SCRIPT_SRC")" && pwd)"
  if [ -f "$maybe_root/scripts/skills-sync.py" ]; then REPO_DIR="$maybe_root"; fi
fi

CLEANUP_DIR=""
if [ -z "$REPO_DIR" ]; then
  # Piped via curl | bash — download a tarball of main into a temp dir.
  command -v curl >/dev/null 2>&1 || err "curl is required to fetch the kit."
  TMP="$(mktemp -d)"
  CLEANUP_DIR="$TMP"
  printf 'Fetching AI Platform Kit...\n'
  curl -sL "$TARBALL_URL" | tar -xz -C "$TMP"
  REPO_DIR="$(find "$TMP" -maxdepth 1 -type d -name 'ai-platform-kit-*' | head -n1)"
  [ -n "$REPO_DIR" ] || err "could not unpack the kit tarball."
fi
cleanup() { [ -n "$CLEANUP_DIR" ] && rm -rf "$CLEANUP_DIR"; }
trap cleanup EXIT

# --- if invoked via curl|bash with no args, install into the current directory --------
# (skills-sync.py's interactive picker reads stdin; when piped, stdin is the script, so
#  default to installing here and let the user pass flags for other behavior.)
if [ "$#" -eq 0 ] && [ ! -t 0 ]; then
  # Non-interactive stdin (piped). Run the picker against the controlling terminal if
  # available, else fall back to a sensible default.
  if [ -e /dev/tty ]; then
    exec "$PYTHON" "$REPO_DIR/scripts/skills-sync.py" </dev/tty
  fi
fi

exec "$PYTHON" "$REPO_DIR/scripts/skills-sync.py" "$@"
