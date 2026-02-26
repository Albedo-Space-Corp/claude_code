# Claude Code with AWS Bedrock at Albedo

Run [Claude Code](https://claude.ai/claude-code) using AWS Bedrock infrastructure at Albedo (ITAR compliant).

## Quick Start (New Users)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Albedo-Space-Corp/claude_code/refs/heads/main/setup_ccb.sh)
```

This installs:
- Homebrew, AWS CLI, jq
- Claude Code
- AWS SSO profile (prod-it01-bedrock)
- Bedrock configuration in `~/.claude/settings.json`

After installation:
```bash
claude
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
- Sonnet 4.5 (latest available; Sonnet 5 pending release)
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
claude --model sonnet    # Sonnet 4.5 for everything
claude --model haiku     # Haiku 4.5 for everything

# Switch models during session
/model opus
/model sonnet
/model opusplan
```

## Requirements

- macOS or Linux (Ubuntu/WSL)
- AWS SSO access to Albedo's prod-it01 account
- AlbedoBedrockUsers role permissions

## Documentation

See [CLAUDE.md](.claude/CLAUDE.md) for complete documentation including:
- Architecture overview
- AWS profile configuration
- Model activation process
- Troubleshooting guide
- IAM policy reference

## Known Issues

### `/model` Menu Bug with Bedrock

The interactive `/model` menu has a known bug when using Bedrock (see [#18674](https://github.com/anthropics/claude-code/issues/18674), [#17760](https://github.com/anthropics/claude-code/issues/17760), [#10169](https://github.com/anthropics/claude-code/issues/10169))

**What works:**
- Menu: "Default" → Sonnet 4.5 ✓
- Menu: "Opus 4.1" (mislabeled) → Actually Opus 4.6 ✓
- Menu: "Haiku" → Haiku 4.5 ✓
- Typing: `/model opusplan` → OpusPlan ✓

**What's broken:**
- Menu: "Opus 4.6" → ❌ incomplete model ID
- Menu: "Opus (1M context)" → ❌ invalid for Bedrock

**Workaround:** Type the model name instead of using the menu:
```
/model opus
/model sonnet
/model opusplan
```

Or use CLI flags: `claude --model opus`

## Support

For issues or questions, contact #it-help or #ai
