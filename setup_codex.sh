#!/usr/bin/env bash
# Codex with Albedo Bedrock, macOS and Ubuntu/WSL. Safe to re-run.
set -euo pipefail

SOURCE_URL="https://raw.githubusercontent.com/Albedo-Space-Corp/claude_code/refs/heads/main"
SETUP_TMP=$(mktemp -d)
trap 'rm -rf "$SETUP_TMP"' EXIT

# sudo closes the descriptor used by bash <(curl ...). Re-exec from a file.
if [[ "${BASH_SOURCE[0]}" == /dev/fd/* || "${BASH_SOURCE[0]}" == /proc/self/fd/* ]]; then
    curl -fsSL "$SOURCE_URL/setup_codex.sh" -o "$SETUP_TMP/setup_codex.sh"
    bash "$SETUP_TMP/setup_codex.sh" "$@"
    exit
fi

echo "Setting up Codex with Albedo Bedrock..."
export PATH="$HOME/.local/bin:$PATH"
export AWS_PAGER=""
case "$(uname -s)" in
    Darwin)
        if ! command -v git >/dev/null 2>&1 || ! git --version >/dev/null 2>&1; then
            echo "Git is required. Run xcode-select --install, then rerun setup." >&2
            exit 1
        fi
        ;;
    Linux)
        if ! command -v apt-get >/dev/null 2>&1; then
            echo "Supported Linux platforms: Ubuntu/WSL (apt-get required)." >&2
            exit 1
        fi
        sudo apt-get update -y
        sudo apt-get install -y curl unzip git xdg-utils
        if grep -qi microsoft /proc/version; then
            sudo apt-get install -y wslu
            export BROWSER=wslview
        fi
        ;;
    *) echo "Supported platforms: macOS and Ubuntu/WSL." >&2; exit 1 ;;
esac

if ! command -v aws >/dev/null 2>&1; then
    if [[ "$(uname -s)" == Darwin ]]; then
        curl -fsSL https://awscli.amazonaws.com/AWSCLIV2.pkg -o "$SETUP_TMP/aws.pkg"
        sudo installer -pkg "$SETUP_TMP/aws.pkg" -target /
    else
        case "$(uname -m)" in
            x86_64) AWS_ARCH=x86_64 ;;
            aarch64|arm64) AWS_ARCH=aarch64 ;;
            *) echo "Unsupported AWS CLI architecture." >&2; exit 1 ;;
        esac
        curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$AWS_ARCH.zip" -o "$SETUP_TMP/aws.zip"
        unzip -q "$SETUP_TMP/aws.zip" -d "$SETUP_TMP"
        sudo "$SETUP_TMP/aws/install"
    fi
fi

if ! command -v uv >/dev/null 2>&1; then
    curl -fsSL https://astral.sh/uv/install.sh -o "$SETUP_TMP/uv.sh"
    sh "$SETUP_TMP/uv.sh"
fi
if ! command -v codex >/dev/null 2>&1; then
    curl -fsSL https://chatgpt.com/codex/install.sh -o "$SETUP_TMP/codex.sh"
    CODEX_NON_INTERACTIVE=1 sh "$SETUP_TMP/codex.sh"
fi
codex --version

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG_HELPER="$SCRIPT_DIR/configure_codex.py"
if [[ ! -f "$CONFIG_HELPER" ]]; then
    CONFIG_HELPER="$SETUP_TMP/configure_codex.py"
    curl -fsSL "$SOURCE_URL/configure_codex.py" -o "$CONFIG_HELPER"
fi
uv run --script "$CONFIG_HELPER"

SHELL_RC="$HOME/.bashrc"
if [[ "${SHELL:-}" == */zsh ]]; then SHELL_RC="$HOME/.zshrc"; fi
# shellcheck disable=SC2016 # Expand in the user's future shell, not during setup.
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
if ! grep -qF "$PATH_LINE" "$SHELL_RC" 2>/dev/null; then
    printf '\n%s\n' "$PATH_LINE" >> "$SHELL_RC"
fi

if ! aws sts get-caller-identity --profile prod-it01-bedrock >/dev/null 2>&1; then
    aws sso login --profile prod-it01-bedrock
fi
echo "Setup complete. Restart Codex or your IDE, then run codex."
echo "Use /status to confirm amazon-bedrock and /model to choose a model."
echo "Use /plugins to browse the Albedo marketplace."
