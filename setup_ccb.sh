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
print_status "Configuring AWS profile (prod-it01-bedrock)..."
mkdir -p ~/.aws

PROFILE_BLOCK="[profile prod-it01-bedrock]
region = us-west-2
output = json
sso_start_url = https://albedo.awsapps.com/start
sso_region = us-west-2
sso_account_id = $ACCOUNT_ID
sso_role_name = AlbedoBedrockUsers
sso_registration_scopes = sso:account:access"

if [ ! -f ~/.aws/config ]; then
    echo "$PROFILE_BLOCK" > ~/.aws/config
    print_success "AWS config created with prod-it01-bedrock profile"
elif grep -q "\[profile prod-it01-bedrock\]" ~/.aws/config; then
    print_success "prod-it01-bedrock profile already exists"
else
    printf "\n%s\n" "$PROFILE_BLOCK" >> ~/.aws/config
    print_success "prod-it01-bedrock profile added to existing config"
fi

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

source "$SHELL_RC" 2>/dev/null || true

# ── Step 5: Claude Code ───────────────────────────────────────────────────
if command_exists claude; then
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

        # Merge reference env + awsAuthRefresh, and strip any pinned model ARNs
        # from older versions so Claude Code's native /model picker takes over.
        jq --argjson new_env "$REF_ENV" \
           --arg new_auth "$REF_AUTH" '
          .awsAuthRefresh //= $new_auth |
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
if command_exists git-remote-s3; then
    print_success "git-remote-s3 already installed"
else
    print_status "Installing git-remote-s3..."
    if command_exists uv; then
        uv tool install git-remote-s3 2>/dev/null || print_warning "uv tool install failed"
    elif command_exists pipx; then
        pipx install git-remote-s3 2>/dev/null || print_warning "pipx install failed"
    elif [ "$MACHINE" = "Linux" ]; then
        (sudo apt-get install -y pipx >> /dev/null 2>&1 && pipx install git-remote-s3 2>/dev/null) || print_warning "Could not install git-remote-s3 — install manually: pipx install git-remote-s3"
    elif command_exists brew; then
        (brew install pipx 2>/dev/null && pipx install git-remote-s3 2>/dev/null) || print_warning "Could not install git-remote-s3 — install manually: pipx install git-remote-s3"
    else
        print_warning "Could not install git-remote-s3 — install manually: pipx install git-remote-s3"
    fi

    if command_exists git-remote-s3; then
        print_success "git-remote-s3 installed"
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
echo "║   Setup Complete!                                          ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo -e "${NC}"
print_success "All tools installed and configured"
echo
print_status "Next steps:"
echo "  1. Open a new terminal (or run: source $SHELL_RC)"
echo "  2. Run: claude"
echo "  3. Run /plugin inside Claude Code to browse the Albedo marketplace"
echo
