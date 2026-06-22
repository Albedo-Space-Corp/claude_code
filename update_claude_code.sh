#!/usr/bin/env bash
# One-time migration for existing Claude Code + Bedrock users.
#
# Removes the pinned model ARN env vars that earlier versions of this repo
# installed (ANTHROPIC_DEFAULT_OPUS_MODEL, etc.) so Claude Code's native
# /model picker takes over and the full Bedrock model list is available.
#
# Safe to re-run. Creates a timestamped backup before modifying.
#
# Usage:
#   bash update_claude_code.sh
#   bash <(curl -fsSL https://raw.githubusercontent.com/Albedo-Space-Corp/claude_code/refs/heads/main/update_claude_code.sh)

set -eo pipefail

CLAUDE_SETTINGS="$HOME/.claude/settings.json"
AWS_CONFIG="$HOME/.aws/config"

# ── Best-effort: migrate a legacy inline prod-it01-bedrock profile to the
# modern sso-session format. The canonical migration lives in setup_ccb.sh;
# this is a convenience so a stray `update` run also fixes auth. Skips quietly
# if the profile is missing or already modern.
migrate_aws_config() {
    [[ -f "$AWS_CONFIG" ]] || return 0
    grep -q "^\[profile prod-it01-bedrock\]" "$AWS_CONFIG" || return 0
    # Already modern? (profile references an sso-session) → nothing to do.
    if awk '/^\[profile prod-it01-bedrock\]/{f=1;next} /^\[/{f=0} f && /^[[:space:]]*sso_session[[:space:]]*=/{found=1} END{exit !found}' "$AWS_CONFIG"; then
        echo "✓ AWS profile already on sso-session format."
        return 0
    fi
    local acct
    acct=$(awk '/^\[profile prod-it01-bedrock\]/{f=1;next} /^\[/{f=0} f && /^[[:space:]]*sso_account_id[[:space:]]*=/{print $3; exit}' "$AWS_CONFIG")
    acct="${acct:-188343044386}"
    local block="[sso-session albedo-commercial]
sso_start_url = https://albedo.awsapps.com/start
sso_region = us-west-2
sso_registration_scopes = sso:account:access

[profile prod-it01-bedrock]
sso_session = albedo-commercial
sso_account_id = $acct
sso_role_name = AlbedoBedrockUsers
region = us-west-2
output = json"
    local bak="$AWS_CONFIG.bak.$(date +%Y%m%d_%H%M%S)"
    cp "$AWS_CONFIG" "$bak"
    local rem
    rem=$(awk '/^\[/ { if ($0 ~ /^\[(profile[[:space:]]+prod-it01-bedrock|sso-session[[:space:]]+albedo-commercial)\][[:space:]]*$/) { skip=1; next } skip=0 } !skip' "$AWS_CONFIG")
    { printf '%s\n\n' "$block"; printf '%s\n' "$rem"; } | cat -s > "$AWS_CONFIG.new"
    mv "$AWS_CONFIG.new" "$AWS_CONFIG"
    rm -f "$HOME"/.aws/cli/cache/*.json 2>/dev/null || true
    echo "✓ Migrated prod-it01-bedrock to sso-session format (backup: $bak)"
    echo "  Next 'aws sso login' = one browser prompt, then silent refresh for ~7 days."
}
migrate_aws_config

echo "=============================================================="
echo "Claude Code Bedrock Migration"
echo "  Removes pinned model ARNs so the native /model picker takes"
echo "  over. All other settings (hooks, plugins, etc.) are preserved."
echo "=============================================================="
echo ""

if ! command -v jq &> /dev/null; then
    echo "jq is required. Install with:"
    echo "  macOS:  brew install jq"
    echo "  Linux:  sudo apt-get install jq"
    exit 1
fi

if [[ ! -f "$CLAUDE_SETTINGS" ]]; then
    echo "No $CLAUDE_SETTINGS found."
    echo "Run setup_ccb.sh first to create a baseline configuration."
    exit 1
fi

# Check if any of the pinned keys are actually present
HAS_PINS=$(jq '
    (.env.ANTHROPIC_DEFAULT_OPUS_MODEL // empty),
    (.env.ANTHROPIC_DEFAULT_SONNET_MODEL // empty),
    (.env.ANTHROPIC_DEFAULT_HAIKU_MODEL // empty)
' "$CLAUDE_SETTINGS")

if [[ -z "$HAS_PINS" ]]; then
    echo "✓ No pinned model ARNs found. Nothing to migrate."
    exit 0
fi

BACKUP_FILE="$CLAUDE_SETTINGS.backup.$(date +%Y%m%d_%H%M%S)"
cp "$CLAUDE_SETTINGS" "$BACKUP_FILE"
echo "✓ Backup: $BACKUP_FILE"

jq 'del(.env.ANTHROPIC_DEFAULT_OPUS_MODEL,
        .env.ANTHROPIC_DEFAULT_OPUS_MODEL_NAME,
        .env.ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION,
        .env.ANTHROPIC_DEFAULT_SONNET_MODEL,
        .env.ANTHROPIC_DEFAULT_SONNET_MODEL_NAME,
        .env.ANTHROPIC_DEFAULT_SONNET_MODEL_DESCRIPTION,
        .env.ANTHROPIC_DEFAULT_HAIKU_MODEL,
        .env.ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME,
        .env.ANTHROPIC_DEFAULT_HAIKU_MODEL_DESCRIPTION)
' "$CLAUDE_SETTINGS" > /tmp/claude_settings_migrated.json
mv /tmp/claude_settings_migrated.json "$CLAUDE_SETTINGS"

echo "✓ Pinned model ARNs removed"
echo ""
echo "Restart Claude Code and run /model to see the full Bedrock model list."
echo "Current session will keep its existing model until you restart."
