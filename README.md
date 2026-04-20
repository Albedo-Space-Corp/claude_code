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

## Migrate Existing Setup (v5.0.0 → v5.2.0)

If you ran setup before ~April 2026, you likely have pinned model ARN env vars in your `~/.claude/settings.json`. These limit the `/model` picker to just Opus/Sonnet/Haiku at whatever versions were pinned. Run:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Albedo-Space-Corp/claude_code/refs/heads/main/update_claude_code.sh)
```

This removes the pinned ARNs so Claude Code's native `/model` picker shows the full Bedrock model list (including 1M context variants). Your hooks, plugins, and other settings are preserved.

**Note:** The `claude_bedrock.sh` wrapper still works if you prefer it.

## What's New in v5.2.0

**Native model picker:** Removed pinned model ARNs. Claude Code's built-in `/model` picker now controls model selection, exposing all available Bedrock models (including 1M context variants).

**Why this is better:**
- New models (e.g., Opus 4.8) appear automatically when Claude Code updates — no more `update_claude_code.sh` runs for model changes
- 1M context variants are now selectable via the picker
- Smaller `settings.json` — no account ID substitution, no model ARNs to maintain

## Usage

```bash
# Launch with default model (opusplan - auto-switching)
claude

# Resume Conversations
claude --resume

# Launch with specific model
claude --model opus      # Opus 4.7 for everything
claude --model sonnet    # Sonnet 4.6 for everything
claude --model haiku     # Haiku 4.5 for everything

# Switch models during session
/model opus
/model sonnet
/model opusplan
```

### Windows

Download and run the setup script:
```powershell
Invoke-WebRequest https://raw.githubusercontent.com/Albedo-Space-Corp/claude_code/refs/heads/main/setup_ccb.ps1 -OutFile "$HOME\Downloads\setup_ccb.ps1"
powershell -ExecutionPolicy Bypass -File "$HOME\Downloads\setup_ccb.ps1"
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
