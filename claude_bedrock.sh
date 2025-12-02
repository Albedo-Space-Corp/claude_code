#!/usr/bin/env bash
# ============================================================================
# Claude Bedrock Wrapper Script
# ============================================================================
# Version: 2.0.1
# Date:    2025-11-18
# 
# Description:
#   Albedo's wrapper script for running Claude Code with AWS Bedrock. Provides
#   interactive configuration for AWS profiles, model selection, and token
#   limits. Supports both prod-it01-bedrock (SSO) and dev01 (DuploCloud).
#
# Usage:
#   claude_bedrock.sh [--profile PROFILE] [--defaults] [--model-name NAME]
#                     [--max-output-tokens N] [--max-thinking-tokens N]
#
# ============================================================================

set -eo pipefail

# Default to prod profile, but allow override via --profile parameter
PROFILE="prod-it01-bedrock"
REGION="us-west-2"
PROFILE_SET_VIA_PARAM=false

USE_DEFAULTS=${ALBEDO_CLAUDE_USE_DEFAULTS:-false}

claude_args=()
while [ "$1" ]; do
  case "$1" in
    --profile)
      PROFILE="$2"
      PROFILE_SET_VIA_PARAM=true
      shift
      ;;
    --defaults)
      USE_DEFAULTS=true
      ;;
    --model-name)
      MODEL_NAME="$2"
      shift
      ;;
    --max-output-tokens)
      MAX_OUT="$2"
      shift
      ;;
    --max-thinking-tokens)
      MAX_THINK="$2"
      shift
      ;;
    *)
      claude_args+=("$1")
      ;;
  esac
  shift
done

if [ "$USE_DEFAULTS" == true ]; then
  MAX_OUT=4096
  MAX_THINK=1024
  MODEL_SEARCH="sonnet-4-5"
  MODEL_NAME="Claude Sonnet 4.5"
  echo "Using default settings: $MODEL_NAME, $MAX_OUT output tokens, $MAX_THINK thinking tokens"
fi

# Check if claude is installed
if ! command -v claude &> /dev/null; then
  echo "It appears Claude Code is not installed."
  echo ""
  echo "Would you like to install it? (y/n)"
  read -r response
  if [[ "$response" =~ ^[Yy]$ ]]; then
    echo "Installing Claude Code..."
    curl -fsSL claude.ai/install.sh | bash
    echo ""
    echo "Installation complete!"
  else
    echo "Exiting. Claude Code is required to run this script. Either it is not installed or not in your PATH."
    exit 1
  fi
fi

# Check if AWS CLI is installed
if ! command -v aws &> /dev/null; then
  echo "ERROR: AWS CLI is not installed."
  echo "Exiting. AWS CLI is required to run this script. Either it is not installed or not in your PATH."
  exit 1
fi

# Check AWS CLI version (minimum v2.1.0 required for Bedrock)
AWS_VERSION=$(aws --version 2>&1 | cut -d/ -f2 | cut -d' ' -f1)
MIN_VERSION="2.1.0"

version_compare() {
  printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1
}

if [[ "$(version_compare "$AWS_VERSION" "$MIN_VERSION")" != "$MIN_VERSION" ]]; then
  echo "ERROR: AWS CLI version $AWS_VERSION is too old."
  echo "Minimum required version: $MIN_VERSION (for Bedrock support)"
  echo "Current version: $AWS_VERSION"
  echo "Please upgrade AWS CLI to the minimum required version."
  exit 1
fi


echo "=============================================================="
echo " ▄▄· ▄▄▌   ▄▄▄· ▄• ▄▌·▄▄▄▄  ▄▄▄ .     ▄▄·       ·▄▄▄▄  ▄▄▄ . ";
echo "▐█ ▌▪██•  ▐█ ▀█ █▪██▌██▪ ██ ▀▄.▀·    ▐█ ▌▪▪     ██▪ ██ ▀▄.▀· ";
echo "██ ▄▄██▪  ▄█▀▀█ █▌▐█▌▐█· ▐█▌▐▀▀▪▄    ██ ▄▄ ▄█▀▄ ▐█· ▐█▌▐▀▀▪▄ ";
echo "▐███▌▐█▌▐▌▐█ ▪▐▌▐█▄█▌██. ██ ▐█▄▄▌    ▐███▌▐█▌.▐▌██. ██ ▐█▄▄▌ ";
echo "·▀▀▀ .▀▀▀  ▀  ▀  ▀▀▀ ▀▀▀▀▀•  ▀▀▀     ·▀▀▀  ▀█▄▀▪▀▀▀▀▀•  ▀▀▀  ";
echo "▄▄▄   ▄▄▄· ·▄▄▄▄•·▄▄▄▄•    ▄▄▄ .·▄▄▄▄  ▪  ▄▄▄▄▄▪         ▐ ▄ ";
echo "▀▄ █·▐█ ▀█ ▪▀·.█▌▪▀·.█▌    ▀▄.▀·██▪ ██ ██ •██  ██ ▪     •█▌▐█";
echo "▐▀▀▄ ▄█▀▀█ ▄█▀▀▀•▄█▀▀▀•    ▐▀▀▪▄▐█· ▐█▌▐█· ▐█.▪▐█· ▄█▀▄ ▐█▐▐▌";
echo "▐█•█▌▐█ ▪▐▌█▌▪▄█▀█▌▪▄█▀    ▐█▄▄▌██. ██ ▐█▌ ▐█▌·▐█▌▐█▌.▐▌██▐█▌";
echo ".▀  ▀ ▀  ▀ ·▀▀▀ •·▀▀▀ •     ▀▀▀ ▀▀▀▀▀• ▀▀▀ ▀▀▀ ▀▀▀ ▀█▄▀▪▀▀ █▪";
echo "=============================================================="
echo "You are about to use Claude Code with Albedo's AWS Bedrock"
echo "               It is ITAR compliant!"
echo "=============================================================="
echo ""

if [[ "$USE_DEFAULTS" == false && "$PROFILE_SET_VIA_PARAM" == false ]]; then
  # Profile selection menu
  echo "Select AWS Profile:"
  echo "==================="
  echo "1) prod-it01-bedrock (default)"
  echo "2) dev01 (legacy AWS Environment)"
  echo ""
  echo -n "Enter your choice [1-2] (press Enter for default): "
  read -r profile_choice
  
  case "${profile_choice}" in
    2)
      PROFILE="dev01"
      echo "Selected: dev01"
      ;;
    *)
      PROFILE="prod-it01-bedrock"
      echo "Selected: prod-it01-bedrock (default)"
      ;;
  esac
  echo ""
fi

# Validate the selected profile (whether via parameter, menu, or default)
PROFILE_FOUND=false

# Check in ~/.aws/config for [profile PROFILE_NAME]
if [[ -f "$HOME/.aws/config" ]] && grep -q "^\[profile $PROFILE\]" "$HOME/.aws/config"; then
  PROFILE_FOUND=true
fi

# Check in ~/.aws/credentials for [PROFILE_NAME]
if [[ -f "$HOME/.aws/credentials" ]] && grep -q "^\[$PROFILE\]" "$HOME/.aws/credentials"; then
  PROFILE_FOUND=true
fi

if [[ "$PROFILE_FOUND" == false ]]; then
  echo "ERROR: AWS profile '$PROFILE' not found in ~/.aws/config or ~/.aws/credentials"
  echo ""
  echo "Please ensure you have configured the '$PROFILE' profile."
  echo "For prod-it01-bedrock, the profile should exist in ~/.aws/config"
  echo "For dev01, the profile should exist in ~/.aws/credentials"
  echo ""
  echo "Please configure the '$PROFILE' profile in ~/.aws/config or ~/.aws/credentials."
  echo "For more information, please see the 'GSW Development Environment' Notion Page."
  echo "Exiting..."
  exit 1
fi

if [[ "$USE_DEFAULTS" == false ]]; then
  echo "Select the Claude model to use:"
  echo "=================================="
  echo "1) Claude Sonnet 4.5 (default)"
  echo "2) Claude Haiku 4.5"
  echo "3) Opus 4.5"
  echo ""
  echo -n "Enter your choice [1-3] (press Enter for default): "
  read -r model_choice

  # Set search pattern and display name based on selection
  case "${model_choice}" in
    2)
      echo "Selected: Claude Haiku 4.5"
      MODEL_SEARCH="haiku-4-5"  # Haiku 4.5 pattern
      MODEL_NAME="Claude Haiku 4.5"
      ;;
    3)
      echo "Selected: Opus 4.5"
      MODEL_SEARCH="opus-4-5"  # Opus 4.5 pattern
      MODEL_NAME="Opus 4.5"
      ;;
    *)
      echo "Selected: Claude Sonnet 4.5 (default)"
      MODEL_SEARCH="sonnet-4-5"  # Claude Sonnet 4.5 pattern
      MODEL_NAME="Claude Sonnet 4.5"
      ;;
  esac
  echo ""

  echo "Higher value → Claude can return longer, more complete responses (e.g. full code snippets, detailed explanations). This comes at the cost of:"
  echo "  • Higher latency (responses take longer to stream back)."
  echo "  • Higher costs (since Bedrock billing is proportional to input + output tokens)."
  echo "  • Greater risk of hitting AWS Bedrock model limits or timeouts if you set it too high."
  echo ""
  echo "Lower value → Claude's responses are cut off sooner. This improves:"
  echo "  • Response time (faster output)."
  echo "  • Cost control (fewer tokens billed)."
  echo "  But you may get truncated answers, especially for code completions or explanations."
  echo ""
  echo "Configure Maximum Output Tokens:"
  echo "================================="
  echo "1) 4,096 tokens (default)"
  echo "2) 8,192 tokens"
  echo "3) 16,384 tokens"
  echo "4) 32,768 tokens"
  echo ""
  echo -n "Enter your choice [1-4] (press Enter for default): "
  read -r max_out_choice

  # Set MAX_OUT based on selection
  case "${max_out_choice}" in
    2)
      MAX_OUT=8192
      echo "Selected: 8,192 tokens"
      ;;
    3)
      MAX_OUT=16384
      echo "Selected: 16,384 tokens"
      echo "⚠️  WARNING: Higher token limits may result in slower response times and potential timeouts."
      ;;
    4)
      MAX_OUT=32768
      echo "Selected: 32,768 tokens"
      echo "⚠️  WARNING: Higher token limits may result in slower response times and potential timeouts."
      ;;
    *)
      MAX_OUT=4096
      echo "Selected: 4,096 tokens (default)"
      ;;
  esac
  echo ""

  echo "Configure Maximum Thinking Tokens:"
  echo "=================================="
  echo "1) 1,024 tokens (default)"
  echo "2) 2,048 tokens"
  echo "3) 4,096 tokens"
  echo "4) 8,192 tokens"
  echo ""
  echo -n "Enter your choice [1-4] (press Enter for default): "
  read -r max_think_choice

  # Set MAX_THINK based on selection and display selection with warnings
  case "${max_think_choice}" in
    2)
      MAX_THINK=2048
      echo "Selected: 2,048 tokens"
      ;;
    3)
      MAX_THINK=4096
      echo "Selected: 4,096 tokens"
      echo "⚠️  WARNING: Higher token limits may result in slower response times and potential timeouts."
      ;;
    4)
      MAX_THINK=8192
      echo "Selected: 8,192 tokens"
      echo "⚠️  WARNING: Higher token limits may result in slower response times and potential timeouts."
      ;;
    *)
      MAX_THINK=1024
      echo "Selected: 1,024 tokens (default)"
      ;;
  esac

  # Validate that MAX_THINK is not greater than MAX_OUT
  if [[ $MAX_THINK -ge $MAX_OUT ]]; then
    echo "ERROR: Maximum thinking tokens ($MAX_THINK) must be less than maximum output tokens ($MAX_OUT)."
    echo "Setting thinking tokens to a safe default (1,024)."
    MAX_THINK=1024
    echo "Adjusted to: 1,024 tokens"
  fi
fi

# Check if SSO session is valid, if not trigger login
echo "Checking AWS SSO session..."
if ! AWS_PROFILE="$PROFILE" aws sts get-caller-identity &>/dev/null; then
  echo "AWS SSO session expired or not found."
  echo "Opening browser for authentication..."
  echo ""
  # Suppress WSL interop errors but keep the important SSO output
  aws sso login --profile "$PROFILE" 2>&1 | grep -v "WSL Interop\|binfmt_misc\|tcgetpgrp"
  echo ""
  echo "✓ Successfully authenticated"
else
  echo "✓ AWS SSO session is valid"
fi
echo ""

# Find the system-defined inference profile for selected model
MODEL_PROFILE_ARN="$(
  AWS_PROFILE="$PROFILE" AWS_REGION="$REGION" \
  aws bedrock list-inference-profiles --type-equals SYSTEM_DEFINED \
  --query "inferenceProfileSummaries[?contains(inferenceProfileArn,'anthropic') && contains(inferenceProfileArn,'${MODEL_SEARCH}')].inferenceProfileArn | [0]" \
  --output text
)"

if [[ -z "$MODEL_PROFILE_ARN" || "$MODEL_PROFILE_ARN" == "None" ]]; then
  echo "Couldn't find a matching Claude model inference profile in $REGION."
  echo "The selected model may not be available in your region."
  echo "Please check Bedrock console for available models."
  exit 1
fi

SLOW="$MODEL_PROFILE_ARN"                     # <-- use profile ARN, not model ID
FAST="anthropic.claude-3-5-haiku-20241022-v1:0"  # fine to keep a model ID that supports on-demand

echo "AWS SSO profile : $PROFILE"
echo "Region          : $REGION"
echo "Main model      : $MODEL_NAME"
echo "Model ARN       : $SLOW"
echo "Fast model      : Haiku 3.5"
echo "Max output      : $MAX_OUT tokens"
echo "Max thinking    : $MAX_THINK tokens"
echo ""

exec env \
  AWS_PROFILE="$PROFILE" AWS_REGION="$REGION" CLAUDE_CODE_USE_BEDROCK=1 \
  ANTHROPIC_MODEL="$SLOW" ANTHROPIC_SMALL_FAST_MODEL="$FAST" \
  CLAUDE_CODE_MAX_OUTPUT_TOKENS="$MAX_OUT" MAX_THINKING_TOKENS="$MAX_THINK" \
  claude "${claude_args[@]}"
