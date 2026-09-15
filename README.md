# Claude Code and Codex with AWS Bedrock at Albedo

Run [Claude Code](https://claude.ai/claude-code) using AWS Bedrock infrastructure at Albedo (ITAR compliant).

## Codex setup

**macOS or Ubuntu/WSL:**
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Albedo-Space-Corp/claude_code/refs/heads/main/setup_codex.sh)
```

**Windows (PowerShell):**
```powershell
irm https://raw.githubusercontent.com/Albedo-Space-Corp/claude_code/refs/heads/main/setup_codex.ps1 | iex
```

Setup installs missing tools (AWS CLI, Codex, and uv for the configuration helper),
configures the same `prod-it01-bedrock` SSO profile as Claude, and registers the
Albedo plugin marketplace. Windows and Ubuntu also install Git when needed;
macOS requires Git (install Apple's Command Line Tools if prompted).
The setup baseline is Codex CLI 0.154.0+ and AWS CLI 2.9.0+; older installations
must be updated before configuration is changed.

Restart Codex or your IDE after setup. Run `codex`, confirm `amazon-bedrock` in
`/status`, and choose an available `openai.gpt-*` model with `/model`.
Browse the Albedo marketplace with `/plugins`.

The native provider uses commercial Bedrock in `us-west-2` and your
`AlbedoBedrockUsers` role. No OpenAI API key or ChatGPT sign-in is needed.
This installer configures commercial Bedrock only. Fast Mode is unavailable on
the current Bedrock connection.
See [OpenAI's Bedrock guide](https://learn.chatgpt.com/docs/amazon-bedrock)
for supported features.

`codex-gov` is a planned extension pending GPT model and Codex connection support
in GovCloud. It can use a separate Codex configuration profile selecting
`gc-prod-it01-bedrock` and `us-gov-west-1`, while retaining the commercial default
and shared setup helper. Setup preserves any existing GovCloud AWS profile;
it does not install an inactive GovCloud launcher.

Re-run the same installer to update configuration. Existing Codex installs are
kept; use `codex update` to update the CLI. Changed configuration files are backed
up beside the originals. Both configuration files are staged before replacement;
if replacement fails, setup restores the original files. If restoration also fails,
the error identifies the backup for manual recovery. Other AWS profiles, Codex instructions, permissions,
MCP servers, and enabled plugins are preserved. Setup replaces the Bedrock provider
and Albedo marketplace entries, turns Fast Mode off, and clears incompatible
ChatGPT model selections. Existing `openai.*` model selections are kept.
`AWS_CONFIG_FILE` and `CODEX_HOME` are honored when set.

If SSO expires, run `aws sso login --profile prod-it01-bedrock`.
If Codex still uses an API key, remove `AWS_BEARER_TOKEN_BEDROCK` from its
environment (including `~/.codex/.env`) and restart it. An explicitly selected
Codex configuration profile can override the defaults written by setup.

## Quick Start (New Users)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Albedo-Space-Corp/claude_code/refs/heads/main/setup_ccb.sh)
```

This installs:
- AWS CLI, jq, Claude Code
- AWS SSO profiles for commercial (`prod-it01-bedrock`) and GovCloud (`gc-prod-it01-bedrock`)
- Bedrock configuration in `~/.claude/settings.json`, plus a `claude-gov` launcher
- Albedo plugin marketplace, authenticated with your Bedrock SSO role

After installation:
```bash
claude                # Launch Claude Code
/plugin               # Browse the Albedo plugin marketplace
```

## Update an Existing Setup

Run this if you set up before ~September 2026, or any time you want to pull the latest
configuration. It reconfigures everything without reinstalling Claude Code itself:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Albedo-Space-Corp/claude_code/refs/heads/main/update_claude_code.sh)
```

It adds both AWS SSO profiles (migrating older ones to the format that refreshes
credentials silently), installs the GovCloud settings and `claude-gov` launcher, strips
any pinned model ARNs so the `/model` picker shows the full Bedrock catalog, and registers
the plugin marketplace. Your hooks, plugins, and other settings are preserved, and it's
safe to re-run.

**Windows:**
```powershell
irm https://raw.githubusercontent.com/Albedo-Space-Corp/claude_code/refs/heads/main/update_claude_code.ps1 | iex
```

**Note:** The `claude_bedrock.sh` wrapper still works if you prefer it.

## What's New

**v5.4.0, marketplace over CodeCommit.** The Albedo plugin marketplace is now an AWS
CodeCommit repository, cloned over HTTPS with your existing `prod-it01-bedrock` SSO role.
Nothing extra to install, no second account, no credential to keep. Model selection and
Bedrock authentication are untouched. If `/plugin` stopped showing Albedo plugins, run the
update script above or the [marketplace setup](#plugin-marketplace-existing-users).

**v5.3.0, GovCloud support.** Setup now adds a GovCloud profile, writes
`~/.claude/gov.settings.json`, and installs a `claude-gov` launcher. Bare `claude` still
runs against commercial Bedrock. See [Commercial vs GovCloud](#commercial-vs-govcloud).

**v5.2.0, native model picker.** Pinned model ARNs are gone; Claude Code's built-in
`/model` picker controls model selection. New models appear automatically when Claude Code
updates, 1M-context variants are selectable, and `settings.json` no longer carries any
model ARNs to maintain.

## Usage

```bash
# Launch Claude Code (uses the model from your last session)
claude

# Resume a conversation
claude --resume

# Launch with a specific model
claude --model opus
claude --model sonnet
claude --model haiku

# Switch models during a session. The picker lists everything available,
# including 1M-context variants
/model
```

### Commercial vs GovCloud

Bare `claude` runs against **commercial** Bedrock (`prod-it01-bedrock`, `us-west-2`). To run
against **GovCloud** Bedrock, setup installs a `claude-gov` launcher:

```bash
claude          # Commercial Bedrock (default)
claude-gov      # GovCloud Bedrock (gc-prod-it01-bedrock, us-gov-west-1)
```

`claude-gov` is `claude --settings ~/.claude/gov.settings.json`, a small settings file that
layers over your normal config (hooks, plugins, and statusline all carry over) and switches
the AWS profile, region, and models to GovCloud. It composes with flags: `claude-gov --resume`.

GovCloud has a smaller catalog (Opus 5 and Sonnet 5); the gov settings file pins the correct
`us-gov.` inference profiles for you, because Claude Code's `/model` picker resolves its gov
aliases to older models and never to the 1M-context variants. Background tasks run on your
primary model (there is no Haiku tier in GovCloud yet).

> GovCloud access requires the `AlbedoBedrockUsers` role in the GovCloud account, which
> your SSO login grants. If `claude-gov` fails at login, ask in #it-help.

### Windows

Download and run the setup script:
```powershell
Invoke-WebRequest https://raw.githubusercontent.com/Albedo-Space-Corp/claude_code/refs/heads/main/setup_ccb.ps1 -OutFile "$HOME\Downloads\setup_ccb.ps1"
powershell -ExecutionPolicy Bypass -File "$HOME\Downloads\setup_ccb.ps1"
```

## Requirements

- macOS, Linux (Ubuntu/WSL), or Windows 10/11
- AWS SSO access to Albedo's prod-it01 account (plus gc-prod-it01 for GovCloud)
- AlbedoBedrockUsers role permissions

## Plugin Marketplace (Existing Users)

Already have Claude Code set up? Add the Albedo plugin marketplace:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Albedo-Space-Corp/claude_code/refs/heads/main/setup-marketplace.sh)
```

**Windows:**
```powershell
irm https://raw.githubusercontent.com/Albedo-Space-Corp/claude_code/refs/heads/main/setup-marketplace.ps1 | iex
```

Then open Claude Code and run `/plugin` → **Update marketplace** to sync plugins.

## Documentation

Full internal documentation lives in the GitLab source repo (`devops/leverages/claude_bedrock`)
and covers the architecture, AWS profile configuration, the model activation process,
troubleshooting, and the IAM policy reference. Ask in #it-help if you need access.

## Support

For issues or questions, contact #it-help or #ai
