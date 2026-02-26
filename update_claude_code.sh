#!/usr/bin/env bash
set -eo pipefail

# Configuration
AWS_CONFIG_FILE="$HOME/.aws/config"
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
REFERENCE_URL="${SETTINGS_REFERENCE_URL:-https://raw.githubusercontent.com/Albedo-Space-Corp/claude_code/refs/heads/main/settings.json.reference}"

echo "=============================================================="
echo "Claude Code Bedrock Configuration Updater"
echo "=============================================================="
echo ""

# Check for jq
echo "Step 1: Checking dependencies"
echo "=============================="
echo ""

if ! command -v jq &> /dev/null; then
    echo "⚠️  jq is required but not installed."
    echo ""

    # Check if brew is available
    if command -v brew &> /dev/null; then
        echo "Installing jq via Homebrew..."
        brew install jq
        echo "✓ jq installed"
    else
        echo "❌ Error: jq is not installed and Homebrew is not available."
        echo "Please install jq manually:"
        echo "  macOS:  brew install jq"
        echo "  Linux:  sudo apt-get install jq  (Debian/Ubuntu)"
        echo "          sudo yum install jq      (RedHat/CentOS)"
        exit 1
    fi
else
    echo "✓ jq is installed"
fi
echo ""

# Ensure ~/.aws/config exists
if [[ ! -f "$AWS_CONFIG_FILE" ]]; then
    echo "Creating $AWS_CONFIG_FILE..."
    mkdir -p "$(dirname "$AWS_CONFIG_FILE")"
    touch "$AWS_CONFIG_FILE"
fi

echo "Step 2: Checking AWS Profiles"
echo "=============================="
echo ""

# Check for prod-it01-bedrock profile
if [[ -f "$AWS_CONFIG_FILE" ]] && grep -q "^\[profile prod-it01-bedrock\]" "$AWS_CONFIG_FILE"; then
    echo "✓ prod-it01-bedrock profile found"
else
    echo "Adding prod-it01-bedrock profile..."
    echo ""
    echo "AWS Account ID is required. Find it at: https://albedo.awsapps.com/start"
    read -p "Enter your AWS Account ID: " SETUP_ACCOUNT_ID
    if [[ -z "$SETUP_ACCOUNT_ID" || ! "$SETUP_ACCOUNT_ID" =~ ^[0-9]+$ ]]; then
        echo "❌ Invalid account ID. Must be a numeric value."
        exit 1
    fi
    cat >> "$AWS_CONFIG_FILE" << EOF

[profile prod-it01-bedrock]
region = us-west-2
output = json
sso_start_url = https://albedo.awsapps.com/start
sso_region = us-west-2
sso_account_id = $SETUP_ACCOUNT_ID
sso_role_name = AlbedoBedrockUsers
sso_registration_scopes = sso:account:access
EOF
    echo "✓ Added"
fi
echo ""

echo "Step 3: Updating Claude Code settings"
echo "======================================"
echo ""

echo "Downloading latest Bedrock configuration from GitHub..."

# Download the reference settings
if ! REFERENCE=$(curl -fsSL "$REFERENCE_URL"); then
    echo "❌ Failed to download settings.json.reference from GitHub"
    echo "URL: $REFERENCE_URL"
    exit 1
fi

echo "✓ Downloaded reference configuration"
echo ""

# Read account ID from existing AWS config profile
echo "Reading AWS account ID from profile..."
ACCOUNT_ID=$(grep -A 10 "\[profile prod-it01-bedrock\]" "$AWS_CONFIG_FILE" | grep "sso_account_id" | awk -F'= ' '{print $2}' | tr -d '[:space:]')
if [[ -z "$ACCOUNT_ID" || ! "$ACCOUNT_ID" =~ ^[0-9]+$ ]]; then
    echo "⚠️  Could not read account ID from profile. Please enter it manually."
    echo "Find it at: https://albedo.awsapps.com/start"
    read -p "Enter your AWS Account ID: " ACCOUNT_ID
    if [[ -z "$ACCOUNT_ID" || ! "$ACCOUNT_ID" =~ ^[0-9]+$ ]]; then
        echo "❌ Invalid account ID."
        exit 1
    fi
fi
echo "✓ AWS Account ID: $ACCOUNT_ID"
echo ""

# Clear stale env vars and login
unset AWS_PROFILE AWS_DEFAULT_REGION AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
echo "Logging in to AWS SSO..."
aws sso login --profile prod-it01-bedrock
echo ""

# Replace YOUR_ACCOUNT_ID placeholder with actual account ID
REFERENCE=$(echo "$REFERENCE" | sed "s/YOUR_ACCOUNT_ID/$ACCOUNT_ID/g")

# Create .claude directory if it doesn't exist
mkdir -p "$HOME/.claude"

# Merge or create settings.json
if [[ ! -f "$CLAUDE_SETTINGS" ]]; then
    echo "Creating new $CLAUDE_SETTINGS..."
    echo "$REFERENCE" > "$CLAUDE_SETTINGS"
    echo "✓ Settings file created"
else
    echo "Merging with existing settings..."

    # Create backup
    BACKUP_FILE="$CLAUDE_SETTINGS.backup.$(date +%Y%m%d_%H%M%S)"
    cp "$CLAUDE_SETTINGS" "$BACKUP_FILE"
    echo "  Backup created: $BACKUP_FILE"

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
    echo "✓ Settings merged successfully"
fi
echo ""

echo "=============================================================="
echo "✓ Update Complete!"
echo "=============================================================="
echo ""
echo "Configuration updated in: $CLAUDE_SETTINGS"
echo ""

# Extract model ARNs from reference for display (after account ID substitution)
OPUS_ARN=$(echo "$REFERENCE" | jq -r '.env.ANTHROPIC_DEFAULT_OPUS_MODEL // "not set"')
SONNET_ARN=$(echo "$REFERENCE" | jq -r '.env.ANTHROPIC_DEFAULT_SONNET_MODEL // "not set"')
HAIKU_ARN=$(echo "$REFERENCE" | jq -r '.env.ANTHROPIC_DEFAULT_HAIKU_MODEL // "not set"')

# Extract just the model name portion from the ARN for readable display
opus_name=$(echo "$OPUS_ARN" | grep -oP 'us\.anthropic\.\K[^"]+' || echo "$OPUS_ARN")
sonnet_name=$(echo "$SONNET_ARN" | grep -oP 'us\.anthropic\.\K[^"]+' || echo "$SONNET_ARN")
haiku_name=$(echo "$HAIKU_ARN" | grep -oP 'us\.anthropic\.\K[^"]+' || echo "$HAIKU_ARN")

echo "What changed:"
echo "  • Model ARNs updated to latest versions:"
echo "      Opus:   $opus_name"
echo "      Sonnet: $sonnet_name"
echo "      Haiku:  $haiku_name"
echo "  • Automatic AWS SSO credential refresh configured"
echo "  • All existing settings preserved (hooks, plugins, etc.)"
echo ""
echo "Usage:"
echo "  Just run: claude"
echo ""
echo "  Or specify a model:"
echo "    claude --model opus      # Use Opus"
echo "    claude --model sonnet    # Use Sonnet"
echo "    # Default is 'opusplan' - auto-switches between models"
echo ""
echo "  Change models in-session:"
echo "    /model opus"
echo "    /model sonnet"
echo "    /model opusplan"
echo ""
echo "Note: claude_bedrock.sh wrapper still works if you prefer it!"
echo ""
