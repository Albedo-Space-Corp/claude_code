#!/usr/bin/env bash
set -euo pipefail

MARKETPLACE_KEY="albedo-claude-plugin-marketplace"
KNOWN_MARKETPLACES="$HOME/.claude/plugins/known_marketplaces.json"

echo "Setting up Albedo plugin marketplace for Claude Code..."

# prod-it01 (commercial) hosts the plugin marketplace, shared across all Albedo users.
ACCOUNT_ID="188343044386"
MARKETPLACE_URL="s3://plugin-marketplace-prod-it01-${ACCOUNT_ID}/marketplace"

# pipx/uv install to ~/.local/bin, which isn't always on PATH in non-login
# shells. Add it now so this script (and the Claude Code launched next) can
# actually find git-remote-s3.
export PATH="$HOME/.local/bin:$PATH"

# Persist the PATH edit to the user's shell rc for future shells.
USER_SHELL="$(basename "${SHELL:-bash}")"
if [ "$USER_SHELL" = "zsh" ]; then
  SHELL_RC="$HOME/.zshrc"
else
  SHELL_RC="$HOME/.bashrc"
fi
if [ -f "$SHELL_RC" ] && ! grep -q '\.local/bin' "$SHELL_RC" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$SHELL_RC"
fi

# Install git-remote-s3
if ! command -v git-remote-s3 &>/dev/null; then
  echo "Installing git-remote-s3..."
  if command -v uv &>/dev/null; then
    uv tool install git-remote-s3
  elif command -v pipx &>/dev/null; then
    pipx install git-remote-s3
    pipx ensurepath >/dev/null 2>&1 || true
  elif [ "$(uname -s)" = "Linux" ] && command -v apt-get &>/dev/null; then
    echo "Installing pipx via apt..."
    sudo apt-get install -y pipx
    pipx install git-remote-s3
    pipx ensurepath >/dev/null 2>&1 || true
  elif command -v brew &>/dev/null; then
    echo "Installing pipx via Homebrew..."
    brew install pipx
    pipx install git-remote-s3
    pipx ensurepath >/dev/null 2>&1 || true
  else
    echo "Error: No supported package manager found (uv, pipx, brew, or apt)." >&2
    echo "Install git-remote-s3 manually: pipx install git-remote-s3" >&2
    exit 1
  fi

  export PATH="$HOME/.local/bin:$PATH"
  if ! command -v git-remote-s3 &>/dev/null; then
    echo "Error: git-remote-s3 was installed but is not on PATH." >&2
    echo "The Albedo plugin marketplace will fail to clone until this is fixed." >&2
    echo "Try:  pipx install git-remote-s3 && pipx ensurepath  (then restart your terminal)" >&2
    exit 1
  fi
  echo "git-remote-s3 installed."
else
  echo "git-remote-s3 already installed."
fi

# Validate AWS credentials and S3 bucket access
echo "Validating marketplace access..."
if aws s3 ls "${MARKETPLACE_URL%/*}/" --profile prod-it01-bedrock >/dev/null 2>&1; then
  echo "Marketplace bucket accessible."
else
  echo "Warning: Could not access marketplace bucket."
  echo "Ensure you have valid AWS credentials: aws sso login --profile prod-it01-bedrock"
  echo "The marketplace will be registered but won't sync until credentials are available."
fi

# Register marketplace in known_marketplaces.json
mkdir -p "$(dirname "$KNOWN_MARKETPLACES")"

python3 -c "
import json, os
from datetime import datetime, timezone

path = '$KNOWN_MARKETPLACES'
data = {}
if os.path.isfile(path):
    with open(path) as f:
        data = json.load(f)

if 'claude-plugins-official' not in data:
    data['claude-plugins-official'] = {
        'source': {'source': 'github', 'repo': 'anthropics/claude-plugins-official'},
        'installLocation': '$HOME/.claude/plugins/marketplaces/claude-plugins-official',
        'lastUpdated': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')
    }

data['$MARKETPLACE_KEY'] = {
    'source': {'source': 'git', 'url': '$MARKETPLACE_URL'},
    'installLocation': '$HOME/.claude/plugins/marketplaces/$MARKETPLACE_KEY',
    'lastUpdated': datetime.now(timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z')
}

with open(path, 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
"

echo ""
echo "Done! The Albedo plugin marketplace is now registered."
echo "Open Claude Code and run /plugin to browse and install plugins."
