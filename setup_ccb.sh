#!/bin/bash

# Claude Code Bedrock Setup Script
# This script automates the installation of all tools needed for Claude Code with AWS Bedrock
#
# REQUIREMENTS:
#   - Run this AFTER installing WSL Ubuntu (or on macOS)
#   - Your user must have sudo privileges (the script will prompt for password when needed)
#   - Do NOT run this script with sudo - run it as your normal user
#
# USAGE:
#   bash setup_ccb.sh
#   bash <(curl -fsSL https://raw.githubusercontent.com/Albedo-Space-Corp/claude_code/refs/heads/main/setup_ccb.sh)

set -e  # Exit on any error

# If running from process substitution (bash <(curl ...)), re-download to a
# temp file and re-exec. sudo closes non-standard file descriptors on Linux,
# which kills the fd bash is reading the script from.
if [[ "${BASH_SOURCE[0]}" == /dev/fd/* ]] || [[ "${BASH_SOURCE[0]}" == /proc/self/fd/* ]]; then
    _tmpfile=$(mktemp /tmp/setup_ccb.XXXXXX.sh)
    curl -fsSL "https://raw.githubusercontent.com/Albedo-Space-Corp/claude_code/refs/heads/main/setup_ccb.sh" -o "$_tmpfile"
    bash "$_tmpfile" "$@"
    _exit=$?
    rm -f "$_tmpfile"
    exit $_exit
fi

# ── Configuration ───────────────────────────────────────────────────────────
ACCOUNT_ID="188343044386"  # prod-it01 (commercial) — hosts Bedrock + plugin marketplace
GC_ACCOUNT_ID="479469912381"  # gc-prod-it01 (GovCloud) — hosts GovCloud Bedrock
REFERENCE_URL="https://raw.githubusercontent.com/Albedo-Space-Corp/claude_code/refs/heads/main/settings.json.reference"
# ────────────────────────────────────────────────────────────────────────────

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_status() { echo -e "${BLUE}==>${NC} $1"; }
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_warning() { echo -e "${YELLOW}⚠${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
command_exists() { command -v "$1" >/dev/null 2>&1; }

# Detect OS
OS="$(uname -s)"
case "${OS}" in
    Linux*)  MACHINE=Linux ;;
    Darwin*) MACHINE=Mac ;;
    *)       print_error "Unsupported OS: ${OS}"; exit 1 ;;
esac

# Detect user's login shell
USER_SHELL="$(basename "$SHELL")"
if [ "$USER_SHELL" = "zsh" ]; then
    SHELL_RC="$HOME/.zshrc"
elif [ "$USER_SHELL" = "bash" ]; then
    SHELL_RC="$HOME/.bashrc"
elif [ "$MACHINE" = "Mac" ]; then
    SHELL_RC="$HOME/.zshrc"
else
    SHELL_RC="$HOME/.bashrc"
fi

echo -e "${GREEN}"
echo "╔════════════════════════════════════════════════════════════╗"
echo "║   Claude Code Bedrock Setup Script                        ║"
echo "║   Installing tools and configuring environment            ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
print_status "OS: $MACHINE | Shell: $USER_SHELL ($SHELL_RC)"

# ── Step 1: System packages ────────────────────────────────────────────────
if [ "$MACHINE" = "Linux" ]; then
    print_status "Updating system packages..."
    sudo apt-get update -y >> /dev/null 2>&1 || print_warning "apt update had issues, continuing..."

    print_status "Installing basic tools (curl, unzip, jq, xdg-utils, build-essential)..."
    sudo apt-get install -y curl unzip jq build-essential xdg-utils python3-pip >> /dev/null 2>&1 || print_warning "Some packages failed, continuing..."

    # WSL-specific packages
    if grep -q microsoft /proc/version 2>/dev/null; then
        sudo apt-get install -y wslu >> /dev/null 2>&1 || print_warning "wslu install failed, continuing..."
    fi

    print_success "System packages installed"

elif [ "$MACHINE" = "Mac" ]; then
    # macOS: Homebrew for packages not available natively
    if ! command_exists brew; then
        print_status "Installing Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

        if [ -f /opt/homebrew/bin/brew ]; then
            if ! grep -q 'eval "$(/opt/homebrew/bin/brew shellenv)"' "$SHELL_RC" 2>/dev/null; then
                echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$SHELL_RC"
            fi
            eval "$(/opt/homebrew/bin/brew shellenv)"
        elif [ -f /usr/local/bin/brew ]; then
            if ! grep -q 'eval "$(/usr/local/bin/brew shellenv)"' "$SHELL_RC" 2>/dev/null; then
                echo 'eval "$(/usr/local/bin/brew shellenv)"' >> "$SHELL_RC"
            fi
            eval "$(/usr/local/bin/brew shellenv)"
        fi
        print_success "Homebrew installed"
    fi

    if ! command_exists jq; then
        print_status "Installing jq..."
        if command_exists brew; then
            brew install jq
        else
            mkdir -p "$HOME/.local/bin"
            JQ_ARCH="amd64"
            if [ "$(uname -m)" = "arm64" ]; then JQ_ARCH="arm64"; fi
            curl -fsSL "https://github.com/jqlang/jq/releases/latest/download/jq-macos-${JQ_ARCH}" -o "$HOME/.local/bin/jq"
            chmod +x "$HOME/.local/bin/jq"
        fi
        print_success "jq installed"
    fi
fi

# ── Step 2: AWS CLI ────────────────────────────────────────────────────────
if command_exists aws; then
    print_success "AWS CLI already installed ($(aws --version 2>&1 | head -1))"
elif [ "$MACHINE" = "Mac" ]; then
    print_status "Installing AWS CLI via official macOS installer..."
    curl -fsSL "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o /tmp/AWSCLIV2.pkg
    sudo installer -pkg /tmp/AWSCLIV2.pkg -target /
    rm -f /tmp/AWSCLIV2.pkg
    print_success "AWS CLI installed"
else
    print_status "Installing AWS CLI v2..."
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
    (cd /tmp && unzip -qo awscliv2.zip)
    sudo /tmp/aws/install --update 2>/dev/null || sudo /tmp/aws/install
    rm -rf /tmp/aws /tmp/awscliv2.zip
    print_success "AWS CLI v2 installed"
fi

# ── Step 3: AWS profile ───────────────────────────────────────────────────
# We use the MODERN sso-session format (CLI v2.9+), NOT the legacy inline
# format. The sso-session block holds an OIDC refresh token, which lets the
# AWS CLI / Claude Code silently re-mint the access token in the background
# (up to the IIC "background session" window, currently 7 days) instead of
# stalling on an interactive browser login mid-session. The profile references
# the session via `sso_session =`; Claude only knows the profile name, follows
# that pointer, and gets silent refresh for free. The legacy inline format
# (sso_start_url etc. directly in the profile) has NO refresh token, so it
# forces interactive re-auth the moment the ~8h access token expires.
print_status "Configuring AWS profile (prod-it01-bedrock, sso-session format)..."
mkdir -p ~/.aws

# Canonical target: one sso-session block + a profile that references it.
CANONICAL_BLOCK="[sso-session albedo-commercial]
sso_start_url = https://albedo.awsapps.com/start
sso_region = us-west-2
sso_registration_scopes = sso:account:access

[profile prod-it01-bedrock]
sso_session = albedo-commercial
sso_account_id = $ACCOUNT_ID
sso_role_name = AlbedoBedrockUsers
region = us-west-2
output = json

[sso-session albedo-gc]
sso_start_url = https://start.us-gov-home.awsapps.com/directory/albedo-gc
sso_region = us-gov-west-1
sso_registration_scopes = sso:account:access

[profile gc-prod-it01-bedrock]
sso_session = albedo-gc
sso_account_id = $GC_ACCOUNT_ID
sso_role_name = AlbedoBedrockUsers
region = us-gov-west-1
output = json"

if [ ! -f ~/.aws/config ]; then
    printf '%s\n' "$CANONICAL_BLOCK" > ~/.aws/config
    print_success "AWS config created (sso-session + prod-it01-bedrock profile)"
else
    # Idempotent migration: strip any existing albedo-commercial session and
    # prod-it01-bedrock profile (legacy OR modern), then prepend the canonical
    # blocks. Everything else in the file (other profiles, comments) is
    # preserved verbatim. Back up first.
    BACKUP=~/.aws/config.bak.$(date +%Y%m%d_%H%M%S)
    cp ~/.aws/config "$BACKUP"

    REMAINDER=$(awk '
        /^\[/ {
            if ($0 ~ /^\[(profile[[:space:]]+(prod-it01-bedrock|gc-prod-it01-bedrock)|sso-session[[:space:]]+(albedo-commercial|albedo-gc))\][[:space:]]*$/) { skip=1; next }
            skip=0
        }
        !skip
    ' ~/.aws/config)

    {
        printf '%s\n\n' "$CANONICAL_BLOCK"
        printf '%s\n' "$REMAINDER"
    } | cat -s > ~/.aws/config.new
    mv ~/.aws/config.new ~/.aws/config

    if grep -q "\[profile prod-it01-bedrock\]" "$BACKUP" 2>/dev/null; then
        print_success "prod-it01-bedrock migrated to sso-session format (backup: $BACKUP)"
        print_warning "Next 'aws sso login' re-registers the client (one browser prompt); after that, silent refresh."
    else
        print_success "sso-session + prod-it01-bedrock profile added (backup: $BACKUP)"
    fi
fi

# Clear cached role credentials so the next login mints fresh creds under the
# new session format. A stale ~/.aws/cli/cache entry would otherwise keep the
# old short-lived creds alive until they expire on their original schedule.
rm -f ~/.aws/cli/cache/*.json 2>/dev/null || true

# ── Step 4: Shell environment ──────────────────────────────────────────────
print_status "Configuring shell environment..."
if ! grep -q "# Disable AWS CLI pager" "$SHELL_RC" 2>/dev/null; then
    cat >> "$SHELL_RC" << 'EOF'

# Disable AWS CLI pager
export AWS_PAGER=""
EOF

    if [ "$MACHINE" = "Linux" ] && grep -q microsoft /proc/version 2>/dev/null; then
        cat >> "$SHELL_RC" << 'EOF'

# Enable browser opening from WSL for AWS SSO
export BROWSER=wslview
EOF
    fi
    print_success "Shell configuration added"
else
    print_success "Shell configuration already present"
fi

# GovCloud launcher. Partition MUST be selected via a --settings file, not shell
# env: settings.json's env block overrides shell env vars, so an
# `AWS_REGION=us-gov-west-1 claude` alias is silently defeated by the commercial
# region in settings.json (gov model ID then hits the commercial endpoint -> 400
# invalid model). A --settings file instead LAYERS on top of the base
# settings.json (hooks/plugins/statusline inherited) and its env block wins.
#
# gov.settings.json pins the gov profile/region and the us-gov. model IDs (the
# /model picker resolves aliases to us.anthropic.* regardless of region). Model
# is set via ANTHROPIC_DEFAULT_OPUS_MODEL + "model":"opus" so the alias resolves
# through the pin (a raw gov model string in the "model" field is ignored across
# files). No Haiku var: no usable Haiku in gov, unset => background tasks run on
# the primary model.
mkdir -p ~/.claude
cat > ~/.claude/gov.settings.json << 'EOF'
{
  "awsAuthRefresh": "aws sso login --profile gc-prod-it01-bedrock",
  "env": {
    "CLAUDE_CODE_USE_BEDROCK": "1",
    "AWS_PROFILE": "gc-prod-it01-bedrock",
    "AWS_REGION": "us-gov-west-1",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "us-gov.anthropic.claude-opus-4-8",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "us-gov.anthropic.claude-sonnet-4-5-20250929-v1:0"
  },
  "model": "opus"
}
EOF
print_success "GovCloud settings written (~/.claude/gov.settings.json)"

# claude-gov launcher (bare `claude` stays commercial via the base settings.json).
if ! grep -q "# Claude Code GovCloud launcher" "$SHELL_RC" 2>/dev/null; then
    cat >> "$SHELL_RC" << 'EOF'

# Claude Code GovCloud launcher
alias claude-gov='claude --settings ~/.claude/gov.settings.json'
EOF
    print_success "claude-gov launcher added to $SHELL_RC"
    print_warning "Open a NEW terminal (or run: source \"$SHELL_RC\") before 'claude-gov' works"
else
    print_success "claude-gov launcher already present"
fi

source "$SHELL_RC" 2>/dev/null || true

# ── Step 5: Claude Code ───────────────────────────────────────────────────
# CCB_SKIP_CLAUDE_INSTALL=1 skips the binary install (used by
# update_claude_code.sh, which reconfigures existing installs without
# reinstalling Claude Code). PATH is still ensured so later steps find claude.
if [ "${CCB_SKIP_CLAUDE_INSTALL:-0}" = "1" ]; then
    export PATH="$HOME/.local/bin:$PATH"
    print_status "Skipping Claude Code install (update mode)"
elif command_exists claude; then
    print_success "Claude Code already installed"
else
    print_status "Installing Claude Code..."
    curl -fsSL https://claude.ai/install.sh | bash

    if ! grep -q '\.local/bin' "$SHELL_RC" 2>/dev/null; then
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$SHELL_RC"
    fi
    export PATH="$HOME/.local/bin:$PATH"
    print_success "Claude Code installed"
fi

# ── Step 6: Claude Code Bedrock settings ──────────────────────────────────
print_status "Configuring Claude Code for Bedrock..."

if ! REFERENCE=$(curl -fsSL "$REFERENCE_URL"); then
    print_warning "Failed to download settings.json.reference — skipping Bedrock config"
else
    mkdir -p ~/.claude
    CLAUDE_SETTINGS="$HOME/.claude/settings.json"

    if [ ! -f "$CLAUDE_SETTINGS" ]; then
        echo "$REFERENCE" > "$CLAUDE_SETTINGS"
        print_success "Claude Code settings created"
    else
        BACKUP_FILE="$CLAUDE_SETTINGS.backup.$(date +%Y%m%d_%H%M%S)"
        cp "$CLAUDE_SETTINGS" "$BACKUP_FILE"
        print_warning "Existing settings backed up to $BACKUP_FILE"

        REF_ENV=$(echo "$REFERENCE" | jq '.env')
        REF_AUTH=$(echo "$REFERENCE" | jq -r '.awsAuthRefresh')

        # awsAuthRefresh is force-updated (not set-if-absent) so existing installs
        # pick up the profile-following form. Warn if we're replacing a different
        # value — a user with a custom auth wrapper should know it changed.
        OLD_AUTH=$(jq -r '.awsAuthRefresh // empty' "$CLAUDE_SETTINGS" 2>/dev/null)
        if [ -n "$OLD_AUTH" ] && [ "$OLD_AUTH" != "$REF_AUTH" ]; then
            print_warning "awsAuthRefresh updated to '$REF_AUTH' (was: '$OLD_AUTH'); backup at $BACKUP_FILE"
        fi

        # Merge reference env + awsAuthRefresh, and strip any pinned model ARNs
        # from older versions so Claude Code's native /model picker takes over.
        jq --argjson new_env "$REF_ENV" \
           --arg new_auth "$REF_AUTH" '
          .awsAuthRefresh = $new_auth |
          .env = (.env // {}) + $new_env |
          del(.env.ANTHROPIC_DEFAULT_OPUS_MODEL,
              .env.ANTHROPIC_DEFAULT_OPUS_MODEL_NAME,
              .env.ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION,
              .env.ANTHROPIC_DEFAULT_SONNET_MODEL,
              .env.ANTHROPIC_DEFAULT_SONNET_MODEL_NAME,
              .env.ANTHROPIC_DEFAULT_SONNET_MODEL_DESCRIPTION,
              .env.ANTHROPIC_DEFAULT_HAIKU_MODEL,
              .env.ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME,
              .env.ANTHROPIC_DEFAULT_HAIKU_MODEL_DESCRIPTION)
        ' "$CLAUDE_SETTINGS" > /tmp/claude_settings_merged.json

        mv /tmp/claude_settings_merged.json "$CLAUDE_SETTINGS"
        print_success "Claude Code settings merged"
    fi
fi

# ── Step 7: Plugin marketplace ────────────────────────────────────────────
print_status "Setting up Albedo plugin marketplace..."

MARKETPLACE_URL="s3://plugin-marketplace-prod-it01-${ACCOUNT_ID}/marketplace"
MARKETPLACE_KEY="albedo-claude-plugin-marketplace"
KNOWN_MARKETPLACES="$HOME/.claude/plugins/known_marketplaces.json"

# Install git-remote-s3
# pipx/uv install to ~/.local/bin, which isn't always on PATH in non-login
# shells. Add it now so this script (and the Claude Code launched next) can
# actually find git-remote-s3. Also persist the PATH edit for future shells.
export PATH="$HOME/.local/bin:$PATH"
if [ -f "$SHELL_RC" ] && ! grep -q '\.local/bin' "$SHELL_RC" 2>/dev/null; then
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$SHELL_RC"
fi

if command_exists git-remote-s3; then
    print_success "git-remote-s3 already installed"
else
    print_status "Installing git-remote-s3..."
    if command_exists uv; then
        uv tool install git-remote-s3 || print_warning "uv tool install failed"
    elif command_exists pipx; then
        pipx install git-remote-s3 || print_warning "pipx install failed"
        pipx ensurepath >/dev/null 2>&1 || true
    elif [ "$MACHINE" = "Linux" ]; then
        if sudo apt-get install -y pipx >> /dev/null 2>&1; then
            pipx install git-remote-s3 || print_warning "pipx install failed"
            pipx ensurepath >/dev/null 2>&1 || true
        else
            print_warning "Could not install pipx via apt — install manually: sudo apt install pipx && pipx install git-remote-s3"
        fi
    elif command_exists brew; then
        if brew install pipx; then
            pipx install git-remote-s3 || print_warning "pipx install failed"
            pipx ensurepath >/dev/null 2>&1 || true
        else
            print_warning "Could not install pipx via brew — install manually: brew install pipx && pipx install git-remote-s3"
        fi
    else
        print_warning "No package manager available (uv, pipx, brew, apt) — install manually: pipx install git-remote-s3"
    fi

    # Re-check PATH in case pipx just dropped the binary in ~/.local/bin
    export PATH="$HOME/.local/bin:$PATH"
    if command_exists git-remote-s3; then
        print_success "git-remote-s3 installed"
    else
        print_error "git-remote-s3 not found on PATH after install."
        print_error "The Albedo plugin marketplace will fail to clone until this is fixed."
        print_error "Try:  pipx install git-remote-s3 && pipx ensurepath  (then restart your terminal)"
    fi
fi

# Register marketplace
mkdir -p "$HOME/.claude/plugins"
OFFICIAL_KEY="claude-plugins-official"
OFFICIAL_LOC="$HOME/.claude/plugins/marketplaces/$OFFICIAL_KEY"
NOW=$(date -u +"%Y-%m-%dT%H:%M:%S.000Z")

if [ -f "$KNOWN_MARKETPLACES" ]; then
    jq --arg key "$MARKETPLACE_KEY" \
       --arg url "$MARKETPLACE_URL" \
       --arg loc "$HOME/.claude/plugins/marketplaces/$MARKETPLACE_KEY" \
       --arg okey "$OFFICIAL_KEY" \
       --arg oloc "$OFFICIAL_LOC" \
       --arg now "$NOW" \
       '.[$key] = {source: {source: "git", url: $url}, installLocation: $loc, lastUpdated: $now} | if has($okey) then . else .[$okey] = {source: {source: "github", repo: "anthropics/claude-plugins-official"}, installLocation: $oloc, lastUpdated: $now} end' \
       "$KNOWN_MARKETPLACES" > /tmp/known_marketplaces_tmp.json
    mv /tmp/known_marketplaces_tmp.json "$KNOWN_MARKETPLACES"
else
    jq -n --arg key "$MARKETPLACE_KEY" \
          --arg url "$MARKETPLACE_URL" \
          --arg loc "$HOME/.claude/plugins/marketplaces/$MARKETPLACE_KEY" \
          --arg okey "$OFFICIAL_KEY" \
          --arg oloc "$OFFICIAL_LOC" \
          --arg now "$NOW" \
          '{($okey): {source: {source: "github", repo: "anthropics/claude-plugins-official"}, installLocation: $oloc, lastUpdated: $now}, ($key): {source: {source: "git", url: $url}, installLocation: $loc, lastUpdated: $now}}' \
          > "$KNOWN_MARKETPLACES"
fi
print_success "Plugin marketplace registered"

# ── Done ──────────────────────────────────────────────────────────────────
echo
echo -e "${GREEN}"
echo "╔════════════════════════════════════════════════════════════╗"
if [ "${CCB_SKIP_CLAUDE_INSTALL:-0}" = "1" ]; then
    echo "║   Reconfigure Complete!                                    ║"
else
    echo "║   Setup Complete!                                          ║"
fi
echo "╚════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
if [ "${CCB_SKIP_CLAUDE_INSTALL:-0}" = "1" ]; then
    print_success "Configuration updated (Claude Code binary left as-is)"
else
    print_success "All tools installed and configured"
fi
echo
print_status "Next steps:"
echo "  1. Open a NEW terminal (or run: source \"$SHELL_RC\") — required for the claude-gov alias"
echo "  2. Run: claude          (commercial Bedrock)"
echo "  3. Run: claude-gov      (GovCloud Bedrock — needs the new terminal from step 1)"
echo "  4. Run /plugin inside Claude Code to browse the Albedo marketplace"
echo
