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

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
REFERENCE_URL="https://raw.githubusercontent.com/Albedo-Space-Corp/claude_code/refs/heads/main/settings.json.reference"

# Function to print colored output
print_status() {
    echo -e "${BLUE}==>${NC} $1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

# Function to check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

echo -e "${GREEN}"
echo "╔════════════════════════════════════════════════════════════╗"
echo "║   Claude Code Bedrock Setup Script                        ║"
echo "║   This will install all required tools and configurations ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

# Confirm user wants to proceed
read -p "This script will install curl, Homebrew, AWS CLI, Claude Code, and configure your environment. Continue? (y/n) " -n 1 -r
echo
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    print_error "Setup cancelled by user"
    exit 1
fi

# Prompt for AWS account ID
echo
print_status "AWS Account ID is required for configuration."
print_status "Find it at: https://albedo.awsapps.com/start → Account list"
read -p "Enter your AWS Account ID: " ACCOUNT_ID
if [[ -z "$ACCOUNT_ID" || ! "$ACCOUNT_ID" =~ ^[0-9]+$ ]]; then
    print_error "Invalid account ID. Must be a numeric value."
    exit 1
fi
print_success "Using AWS Account ID: $ACCOUNT_ID"

# Detect OS
OS="$(uname -s)"
case "${OS}" in
    Linux*)     MACHINE=Linux;;
    Darwin*)    MACHINE=Mac;;
    *)          MACHINE="UNKNOWN:${OS}"
esac

# Detect user's login shell (not the script's shell)
# On macOS, default is zsh; on Linux/WSL, default is bash
USER_SHELL="$(basename "$SHELL")"
if [ "$USER_SHELL" = "zsh" ]; then
    SHELL_RC="$HOME/.zshrc"
elif [ "$USER_SHELL" = "bash" ]; then
    SHELL_RC="$HOME/.bashrc"
else
    # Fallback: on macOS default to zshrc, otherwise bashrc
    if [ "$MACHINE" = "Mac" ]; then
        SHELL_RC="$HOME/.zshrc"
    else
        SHELL_RC="$HOME/.bashrc"
    fi
fi
print_status "Detected login shell: $USER_SHELL (configuring $SHELL_RC)"

# Step 1: Update system packages (Linux only)
if [ "$MACHINE" = "Linux" ]; then
    print_status "Updating Ubuntu packages..."
    sudo apt update && sudo apt upgrade -y || print_warning "Package update had issues, continuing..."
    print_success "Ubuntu packages updated"
fi

# Step 2: Install basic tools (Linux only)
if [ "$MACHINE" = "Linux" ]; then
    print_status "Installing basic tools (curl, micro, build-essential, xdg-utils, wslu)..."
    sudo apt install -y curl micro build-essential xdg-utils wslu python3-pip
    print_success "Basic tools installed"
fi

# Step 3: Install Homebrew if not already installed
if command_exists brew; then
    print_warning "Homebrew already installed, skipping..."
else
    print_status "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

    # Add Homebrew to PATH
    print_status "Adding Homebrew to PATH in $SHELL_RC..."
    if [ "$MACHINE" = "Linux" ]; then
        if ! grep -q 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' "$SHELL_RC" 2>/dev/null; then
            echo 'eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"' >> "$SHELL_RC"
        fi
        eval "$(/home/linuxbrew/.linuxbrew/bin/brew shellenv)"
    elif [ "$MACHINE" = "Mac" ]; then
        # macOS Homebrew paths differ by architecture
        if [ -f /opt/homebrew/bin/brew ]; then
            # Apple Silicon
            if ! grep -q 'eval "$(/opt/homebrew/bin/brew shellenv)"' "$SHELL_RC" 2>/dev/null; then
                echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$SHELL_RC"
            fi
            eval "$(/opt/homebrew/bin/brew shellenv)"
        elif [ -f /usr/local/bin/brew ]; then
            # Intel
            if ! grep -q 'eval "$(/usr/local/bin/brew shellenv)"' "$SHELL_RC" 2>/dev/null; then
                echo 'eval "$(/usr/local/bin/brew shellenv)"' >> "$SHELL_RC"
            fi
            eval "$(/usr/local/bin/brew shellenv)"
        fi
    fi
    print_success "Homebrew installed and configured"
fi

# Step 4: Install AWS CLI
if command_exists aws; then
    print_warning "AWS CLI already installed, skipping..."
elif [ "$MACHINE" = "Mac" ]; then
    print_status "Installing AWS CLI via official installer..."
    curl -fsSL "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o /tmp/AWSCLIV2.pkg
    sudo installer -pkg /tmp/AWSCLIV2.pkg -target /
    rm -f /tmp/AWSCLIV2.pkg
    print_success "AWS CLI installed"
else
    print_status "Installing AWS CLI via Homebrew..."
    brew install awscli
    print_success "AWS CLI installed"
fi

# Step 4b: Install jq
if command_exists jq; then
    print_warning "jq already installed, skipping..."
else
    print_status "Installing jq..."
    if command_exists brew && brew install jq; then
        print_success "jq installed via Homebrew"
    elif [ "$MACHINE" = "Mac" ]; then
        print_status "Homebrew install failed, downloading jq binary..."
        mkdir -p "$HOME/.local/bin"
        JQ_ARCH="amd64"
        if [ "$(uname -m)" = "arm64" ]; then JQ_ARCH="arm64"; fi
        curl -fsSL "https://github.com/jqlang/jq/releases/latest/download/jq-macos-${JQ_ARCH}" -o "$HOME/.local/bin/jq"
        chmod +x "$HOME/.local/bin/jq"
        print_success "jq installed via binary download"
    else
        print_error "Failed to install jq"
        exit 1
    fi
fi

# Step 5: Create AWS configuration directory
print_status "Creating AWS configuration directory..."
mkdir -p ~/.aws
print_success "AWS directory created"

# Step 6: Create AWS config file with prod-it01-bedrock profile
print_status "Setting up AWS profile (prod-it01-bedrock)..."

# Check if config file exists
if [ ! -f ~/.aws/config ]; then
    # Create new config file with prod-it01-bedrock profile
    cat > ~/.aws/config << EOF
[profile prod-it01-bedrock]
region = us-west-2
output = json
sso_start_url = https://albedo.awsapps.com/start
sso_region = us-west-2
sso_account_id = $ACCOUNT_ID
sso_role_name = AlbedoBedrockUsers
sso_registration_scopes = sso:account:access
EOF
    print_success "AWS config file created with prod-it01-bedrock profile"
else
    # File exists, check and add missing profile
    if grep -q "\[profile prod-it01-bedrock\]" ~/.aws/config; then
        print_warning "prod-it01-bedrock profile already exists, skipping..."
    else
        cat >> ~/.aws/config << EOF

[profile prod-it01-bedrock]
region = us-west-2
output = json
sso_start_url = https://albedo.awsapps.com/start
sso_region = us-west-2
sso_account_id = $ACCOUNT_ID
sso_role_name = AlbedoBedrockUsers
sso_registration_scopes = sso:account:access
EOF
        print_success "prod-it01-bedrock profile added to config file"
    fi
fi

# Step 7: Setup shell environment
print_status "Setting up shell environment in $SHELL_RC..."

# Check if the configuration already exists
if grep -q "# Disable AWS CLI pager" "$SHELL_RC" 2>/dev/null; then
    print_warning "Shell configuration already exists, skipping..."
else
    cat >> "$SHELL_RC" << 'EOF'

# Disable AWS CLI pager
export AWS_PAGER=""
EOF

    # Add WSL-specific browser config
    if [ "$MACHINE" = "Linux" ] && grep -q microsoft /proc/version 2>/dev/null; then
        cat >> "$SHELL_RC" << 'EOF'

# Enable browser opening from WSL for AWS SSO
export BROWSER=wslview
EOF
    fi
    print_success "Shell configuration added"
fi

# Reload shell configuration
source "$SHELL_RC" 2>/dev/null || true

# Step 8: Install Claude Code
if command_exists claude; then
    print_warning "Claude Code already installed, skipping..."
else
    print_status "Installing Claude Code..."
    curl -fsSL claude.ai/install.sh | bash

    # The Claude installer adds ~/.local/bin to PATH in the running shell's rc file,
    # but since this script runs under bash, it writes to ~/.bashrc. On macOS (zsh),
    # we need to ensure the PATH entry is in the user's actual shell rc file.
    if ! grep -q '\.local/bin' "$SHELL_RC" 2>/dev/null; then
        print_status "Adding Claude Code to PATH in $SHELL_RC..."
        echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$SHELL_RC"
    fi

    # Make claude available in current script session
    export PATH="$HOME/.local/bin:$PATH"
    print_success "Claude Code installed"
fi

# Step 9: Download and setup Claude Code settings.json
print_status "Configuring Claude Code for Bedrock..."
print_status "Downloading latest configuration from GitHub..."

# Download the reference settings
if ! REFERENCE=$(curl -fsSL "$REFERENCE_URL"); then
    print_error "Failed to download settings.json.reference from GitHub"
    print_error "URL: $REFERENCE_URL"
    exit 1
fi

print_success "Downloaded reference configuration"

# Clear stale env vars to avoid profile confusion
unset AWS_PROFILE AWS_DEFAULT_REGION AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

# AWS SSO Login
print_status "Logging in to AWS SSO..."
aws sso login --profile prod-it01-bedrock

# Replace YOUR_ACCOUNT_ID placeholder with actual account ID
REFERENCE=$(echo "$REFERENCE" | sed "s/YOUR_ACCOUNT_ID/$ACCOUNT_ID/g")

# Create .claude directory if it doesn't exist
mkdir -p ~/.claude

# Create or merge settings.json
CLAUDE_SETTINGS="$HOME/.claude/settings.json"

if [ ! -f "$CLAUDE_SETTINGS" ]; then
    print_status "Creating $CLAUDE_SETTINGS..."
    echo "$REFERENCE" > "$CLAUDE_SETTINGS"
    print_success "Settings file created"
else
    print_status "Merging with existing settings..."

    # Create backup
    BACKUP_FILE="$CLAUDE_SETTINGS.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$CLAUDE_SETTINGS" "$BACKUP_FILE"
    print_warning "Backup created: $BACKUP_FILE"

    # Extract values from reference
    REF_ENV=$(echo "$REFERENCE" | jq '.env')
    REF_MODEL=$(echo "$REFERENCE" | jq -r '.model')
    REF_AUTH=$(echo "$REFERENCE" | jq -r '.awsAuthRefresh')

    # Merge: update Bedrock env vars, set model/awsAuthRefresh if missing, preserve everything else
    jq --argjson new_env "$REF_ENV" \
       --arg new_model "$REF_MODEL" \
       --arg new_auth "$REF_AUTH" '
      .model //= $new_model |
      .awsAuthRefresh //= $new_auth |
      .env = (.env // {}) + $new_env
    ' "$CLAUDE_SETTINGS" > /tmp/claude_settings_merged.json

    mv /tmp/claude_settings_merged.json "$CLAUDE_SETTINGS"
    print_success "Settings merged successfully"
fi

# Step 10: Setup S3 plugin marketplace (non-fatal — Bedrock setup is already complete)
print_status "Setting up Albedo plugin marketplace..."

MARKETPLACE_URL="s3://plugin-marketplace-prod-it01-${ACCOUNT_ID}/marketplace"
MARKETPLACE_KEY="albedo-claude-plugin-marketplace"
KNOWN_MARKETPLACES="$HOME/.claude/plugins/known_marketplaces.json"

# Install git-remote-s3
if command_exists git-remote-s3; then
    print_warning "git-remote-s3 already installed, skipping..."
else
    print_status "Installing git-remote-s3..."
    if command_exists uv; then
        uv tool install git-remote-s3 || print_warning "uv tool install failed"
    elif command_exists pipx; then
        pipx install git-remote-s3 || print_warning "pipx install failed"
    elif command_exists brew && brew install pipx 2>/dev/null; then
        pipx install git-remote-s3 || print_warning "pipx install failed"
    else
        print_warning "Could not install git-remote-s3. Install manually: pipx install git-remote-s3"
    fi

    if command_exists git-remote-s3; then
        print_success "git-remote-s3 installed"
    else
        print_warning "git-remote-s3 not found on PATH. Install manually: pipx install git-remote-s3"
    fi
fi

# Validate S3 bucket access
print_status "Validating marketplace access..."
if aws s3 ls "s3://plugin-marketplace-prod-it01-${ACCOUNT_ID}/" --profile prod-it01-bedrock >/dev/null 2>&1; then
    print_success "Marketplace bucket accessible"
else
    print_warning "Could not access marketplace bucket. The marketplace is registered but may not sync until access is granted."
fi

# Register marketplace in known_marketplaces.json
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

# Final steps
echo
echo -e "${GREEN}"
echo "╔════════════════════════════════════════════════════════════╗"
echo "║   Setup Complete!                                          ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo -e "${NC}"

print_success "All tools installed and configured successfully!"
echo
print_status "Next steps:"
echo "  1. Close and reopen your terminal, or run: source $SHELL_RC"
echo "  2. Run: claude"
echo "  3. Run /plugin inside Claude Code to browse the Albedo marketplace"
echo
print_warning "IMPORTANT: You may need to restart your terminal for all changes to take effect"
echo

# Offer to run verification
read -p "Would you like to run verification tests now? (y/n) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo
    print_status "Running verification tests..."

    # Test curl
    if command_exists curl; then
        print_success "curl: OK ($(curl --version | head -n1))"
    else
        print_error "curl: NOT FOUND"
    fi

    # Test Homebrew
    if command_exists brew; then
        print_success "Homebrew: OK ($(brew --version | head -n1))"
    else
        print_error "Homebrew: NOT FOUND"
    fi

    # Test AWS CLI
    if command_exists aws; then
        print_success "AWS CLI: OK ($(aws --version))"
    else
        print_error "AWS CLI: NOT FOUND"
    fi

    # Test Claude Code
    if command_exists claude; then
        print_success "Claude Code: OK (installed)"
    else
        print_error "Claude Code: NOT FOUND - try reopening terminal"
    fi

    # Test jq
    if command_exists jq; then
        print_success "jq: OK ($(jq --version))"
    else
        print_error "jq: NOT FOUND"
    fi

    # Check if AWS config file exists with prod profile
    if [ -f ~/.aws/config ] && grep -q "\[profile prod-it01-bedrock\]" ~/.aws/config; then
        print_success "AWS prod-it01-bedrock profile: OK (configured)"
    else
        print_error "AWS prod-it01-bedrock profile: NOT FOUND"
    fi

    # Check if settings.json exists with Bedrock configuration
    if [ -f ~/.claude/settings.json ] && grep -q "CLAUDE_CODE_USE_BEDROCK" ~/.claude/settings.json; then
        print_success "Claude Code Bedrock configuration: OK"
    else
        print_warning "Claude Code Bedrock configuration: Not verified"
    fi

    # Check git-remote-s3
    if command_exists git-remote-s3; then
        print_success "git-remote-s3: OK"
    else
        print_warning "git-remote-s3: NOT FOUND (needed for plugin marketplace)"
    fi

    # Check marketplace registration
    if [ -f "$HOME/.claude/plugins/known_marketplaces.json" ] && grep -q "albedo-claude-plugin-marketplace" "$HOME/.claude/plugins/known_marketplaces.json"; then
        print_success "Plugin marketplace: registered"
    else
        print_warning "Plugin marketplace: not registered"
    fi
fi

echo
print_success "Setup script completed!"
echo
print_status "You can now use Claude Code with Bedrock by running: claude"
