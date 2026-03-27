# Claude Code with AWS Bedrock at Albedo

Run [Claude Code](https://claude.ai/claude-code) using AWS Bedrock infrastructure at Albedo (ITAR compliant).

## Quick Start (New Users)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Albedo-Space-Corp/claude_code/refs/heads/main/setup_ccb.sh)
```

This installs:
- AWS CLI, jq, Claude Code
- AWS SSO profile (prod-it01-bedrock)
- Bedrock configuration in `~/.claude/settings.json`
- S3 plugin marketplace (git-remote-s3 + marketplace registration)

After installation:
```bash
claude                # Launch Claude Code
/plugin               # Browse the Albedo plugin marketplace
```

## Update to v5.0.0 (Existing Users)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Albedo-Space-Corp/claude_code/refs/heads/main/update_claude_code.sh)
```

This updates your `~/.claude/settings.json` with the latest model ARNs while preserving your hooks and plugins.

**Note:** The `claude_bedrock.sh` wrapper still works if you prefer it.

## What's New in v5.0.0

**Performance:** Eliminates ~2-3 second Bedrock query overhead on every launch by using hardcoded inference profile ARNs.

**Stability:** Pins model versions

**Current Models:**
- Opus 4.6
- Sonnet 4.6
- Haiku 4.5

**Migration:** Configuration moved from wrapper script to `settings.json`. Just run `update_claude_code.sh` to migrate.

## Usage

```bash
# Launch with default model (opusplan - auto-switching)
claude

# Resume Conversations
claude --resume

# Launch with specific model
claude --model opus      # Opus 4.6 for everything
claude --model sonnet    # Sonnet 4.6 for everything
claude --model haiku     # Haiku 4.5 for everything

# Switch models during session
/model opus
/model sonnet
/model opusplan
```

### Windows

```powershell
powershell -ExecutionPolicy Bypass -File setup_ccb.ps1
```

## Requirements

- macOS, Linux (Ubuntu/WSL), or Windows 10/11
- AWS SSO access to Albedo's prod-it01 account
- AlbedoBedrockUsers role permissions

## Plugin Marketplace (Existing Users)

Already have Claude Code set up? Add the Albedo plugin marketplace:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Albedo-Space-Corp/claude_code/refs/heads/main/setup-s3-marketplace.sh)
```

**Windows:**
```powershell
irm https://raw.githubusercontent.com/Albedo-Space-Corp/claude_code/refs/heads/main/setup-s3-marketplace.ps1 | iex
```

Then open Claude Code and run `/plugin` → **Update marketplace** to sync plugins.

## Documentation

See [CLAUDE.md](.claude/CLAUDE.md) for complete documentation including:
- Architecture overview
- AWS profile configuration
- Model activation process
- Troubleshooting guide
- IAM policy reference

## Support

For issues or questions, contact #it-help or #ai
