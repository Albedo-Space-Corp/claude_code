#!/usr/bin/env bash
# Reconfigure an EXISTING Claude Code + Bedrock install to the latest setup,
# WITHOUT reinstalling the Claude Code binary.
#
# This runs the full setup_ccb.sh with CCB_SKIP_CLAUDE_INSTALL=1, so it does
# everything setup does — migrates ~/.aws/config to the modern sso-session
# format, adds BOTH the commercial (prod-it01-bedrock) and GovCloud
# (gc-prod-it01-bedrock) profiles, writes ~/.claude/gov.settings.json, installs
# the claude-gov launcher, merges ~/.claude/settings.json (stripping any legacy
# pinned model ARNs and updating awsAuthRefresh), and registers the plugin
# marketplace — but leaves your existing `claude` binary untouched.
#
# Safe to re-run; setup_ccb.sh is idempotent and backs up files it changes.
#
# Usage:
#   bash update_claude_code.sh
#   bash <(curl -fsSL https://raw.githubusercontent.com/Albedo-Space-Corp/claude_code/refs/heads/main/update_claude_code.sh)
#
#   # Run against a sibling setup_ccb.sh instead of curling (for local dev):
#   bash update_claude_code.sh --local

set -eo pipefail

SETUP_URL="https://raw.githubusercontent.com/Albedo-Space-Corp/claude_code/refs/heads/main/setup_ccb.sh"

echo "=============================================================="
echo "Claude Code Bedrock — Update / Reconfigure"
echo "  Runs the full setup (both AWS profiles, gov settings +"
echo "  claude-gov launcher, settings.json merge, marketplace)"
echo "  but SKIPS installing the Claude Code binary."
echo "=============================================================="
echo ""

export CCB_SKIP_CLAUDE_INSTALL=1

if [ "${1:-}" = "--local" ]; then
    # Run the setup script sitting next to this one (development / testing).
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    LOCAL_SETUP="$SCRIPT_DIR/setup_ccb.sh"
    if [ ! -f "$LOCAL_SETUP" ]; then
        echo "✗ --local given but no setup_ccb.sh next to this script ($LOCAL_SETUP)." >&2
        exit 1
    fi
    echo "Running local setup: $LOCAL_SETUP"
    bash "$LOCAL_SETUP"
else
    # Fetch the canonical setup script and run it. A temp file (not a pipe) so
    # setup's own process-substitution re-exec / sudo handling behaves.
    _tmp=$(mktemp /tmp/setup_ccb.XXXXXX.sh)
    trap 'rm -f "$_tmp"' EXIT
    if ! curl -fsSL "$SETUP_URL" -o "$_tmp"; then
        echo "✗ Failed to download setup script from $SETUP_URL" >&2
        exit 1
    fi
    bash "$_tmp"
fi
