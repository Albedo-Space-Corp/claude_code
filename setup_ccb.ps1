#Requires -Version 5.1

<#
.SYNOPSIS
    Claude Code Bedrock Setup Script for Windows
.DESCRIPTION
    Installs Git for Windows, AWS CLI, and Claude Code, then configures
    AWS SSO and Claude Code settings for use with AWS Bedrock.
.NOTES
    Run from a PowerShell prompt (Administrator recommended for winget).
    Usage: powershell -ExecutionPolicy Bypass -File setup_ccb.ps1
#>

$ErrorActionPreference = "Stop"

# Configuration
$ReferenceUrl = "https://raw.githubusercontent.com/Albedo-Space-Corp/claude_code/refs/heads/main/settings.json.reference"

# ── Helper functions ─────────────────────────────────────────────────
function Write-Status  { param([string]$Msg) Write-Host "==> $Msg" -ForegroundColor Blue }
function Write-Ok      { param([string]$Msg) Write-Host "  + $Msg" -ForegroundColor Green }
function Write-Warn    { param([string]$Msg) Write-Host "  ! $Msg" -ForegroundColor Yellow }
function Write-Err     { param([string]$Msg) Write-Host "  x $Msg" -ForegroundColor Red }

function Refresh-Path {
    # Merge registry PATH entries into current process PATH (preserves process-level additions)
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath    = [Environment]::GetEnvironmentVariable("Path", "User")
    $registryPath = "$machinePath;$userPath"
    foreach ($entry in $registryPath.Split(';', [StringSplitOptions]::RemoveEmptyEntries)) {
        if ($env:Path -notlike "*$entry*") {
            $env:Path = "$env:Path;$entry"
        }
    }
}

function Write-Utf8NoBom {
    # PowerShell 5.1's -Encoding UTF8 writes BOM, which can break JSON parsers
    param([string]$Path, [string]$Content)
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

# ── Banner ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "===========================================================" -ForegroundColor Green
Write-Host "  Claude Code Bedrock Setup (Windows Native)"               -ForegroundColor Green
Write-Host "  Installs: Git for Windows, AWS CLI, Claude Code"          -ForegroundColor Green
Write-Host "  Configures: AWS SSO profile, Bedrock settings.json"       -ForegroundColor Green
Write-Host "===========================================================" -ForegroundColor Green
Write-Host ""

$confirm = Read-Host "This will install tools and configure your environment. Continue? (y/n)"
if ($confirm -notin @('y', 'Y')) {
    Write-Err "Setup cancelled."
    exit 1
}

# AWS Account ID — try reading from existing profile first, otherwise prompt
Write-Host ""
$awsConfigProbe = Join-Path $env:USERPROFILE ".aws\config"
$accountId = $null
if (Test-Path $awsConfigProbe) {
    $configContent = Get-Content $awsConfigProbe -Raw -ErrorAction SilentlyContinue
    if ($configContent) {
        # Find the [profile prod-it01-bedrock] block and extract sso_account_id from within it
        $match = [regex]::Match($configContent, '(?ms)^\[profile prod-it01-bedrock\](.*?)(?=^\[|\z)')
        if ($match.Success) {
            $idMatch = [regex]::Match($match.Groups[1].Value, 'sso_account_id\s*=\s*(\d+)')
            if ($idMatch.Success) {
                $accountId = $idMatch.Groups[1].Value
                Write-Ok "Using AWS Account ID from existing profile: $accountId"
            }
        }
    }
}
if (-not $accountId) {
    Write-Status "AWS Account ID is required for configuration."
    Write-Status "Find it at: https://albedo.awsapps.com/start -> Account list"
    $accountId = Read-Host "Enter your AWS Account ID"
    if (-not $accountId -or $accountId -notmatch '^\d+$') {
        Write-Err "Invalid account ID. Must be a numeric value."
        exit 1
    }
    Write-Ok "Using AWS Account ID: $accountId"
}

# ── Check winget ─────────────────────────────────────────────────────
Write-Status "Checking for winget..."
if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Err "winget is not available. Please install App Installer from the Microsoft Store."
    Write-Err "https://aka.ms/getwinget"
    exit 1
}
Write-Ok "winget available"

# ── Step 1: Install Git for Windows ─────────────────────────────────
Write-Status "Checking for Git for Windows..."

if (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Ok "Git already installed ($(git --version))"
} else {
    Write-Status "Installing Git for Windows via winget..."
    # --source winget: skip the msstore source. On fresh/un-updated Windows the
    # bundled winget client has a stale pinned cert chain, so searching msstore
    # fails with 0x8a15005e (-1978335138) and aborts the whole install even though
    # the package lives in the 'winget' source. Scoping the source avoids it.
    winget install Git.Git --source winget --accept-package-agreements --accept-source-agreements --silent
    if ($LASTEXITCODE -ne 0) { Write-Warn "winget returned exit code $LASTEXITCODE (may be non-fatal)" }
    Refresh-Path

    if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
        Write-Err "Git installation failed. Please install manually: https://git-scm.com/downloads/win"
        exit 1
    }
    Write-Ok "Git for Windows installed"
}

# Set CLAUDE_CODE_GIT_BASH_PATH so Claude Code finds bash.exe
$gitBash = "C:\Program Files\Git\bin\bash.exe"
if (Test-Path $gitBash) {
    [Environment]::SetEnvironmentVariable("CLAUDE_CODE_GIT_BASH_PATH", $gitBash, "User")
    $env:CLAUDE_CODE_GIT_BASH_PATH = $gitBash
    Write-Ok "CLAUDE_CODE_GIT_BASH_PATH set to $gitBash"
} else {
    # Try to find bash.exe from git's install location
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    if ($gitCmd) {
        $gitDir = Split-Path (Split-Path $gitCmd.Source)
        $altBash = Join-Path $gitDir "bin\bash.exe"
        if (Test-Path $altBash) {
            [Environment]::SetEnvironmentVariable("CLAUDE_CODE_GIT_BASH_PATH", $altBash, "User")
            $env:CLAUDE_CODE_GIT_BASH_PATH = $altBash
            Write-Ok "CLAUDE_CODE_GIT_BASH_PATH set to $altBash"
        } else {
            Write-Warn "Could not find bash.exe - set CLAUDE_CODE_GIT_BASH_PATH manually"
        }
    }
}

# ── Step 2: Install AWS CLI ─────────────────────────────────────────
Write-Status "Checking for AWS CLI..."

if (Get-Command aws -ErrorAction SilentlyContinue) {
    Write-Ok "AWS CLI already installed ($(aws --version 2>&1))"
} else {
    Write-Status "Installing AWS CLI via winget..."
    # --source winget: see Git install above — avoids the msstore cert-pinning
    # error (0x8a15005e) on fresh Windows that aborts otherwise-valid installs.
    winget install Amazon.AWSCLI --source winget --accept-package-agreements --accept-source-agreements --silent
    if ($LASTEXITCODE -ne 0) { Write-Warn "winget returned exit code $LASTEXITCODE (may be non-fatal)" }
    Refresh-Path

    if (-not (Get-Command aws -ErrorAction SilentlyContinue)) {
        Write-Err "AWS CLI installation failed."
        exit 1
    }
    Write-Ok "AWS CLI installed"
}

# ── Step 3: Install Claude Code ─────────────────────────────────────
Write-Status "Checking for Claude Code..."

# Check PATH first, then known install location
$claudeBin = Join-Path $env:USERPROFILE ".local\bin"
$claudeExe = Join-Path $claudeBin "claude.exe"

if (Get-Command claude -ErrorAction SilentlyContinue) {
    Write-Ok "Claude Code already installed (in PATH)"
} elseif (Test-Path $claudeExe) {
    Write-Ok "Claude Code already installed at $claudeExe"
} else {
    Write-Status "Installing Claude Code (native installer - enables auto-updates)..."
    irm https://claude.ai/install.ps1 | iex
}

# Ensure ~/.local/bin is in the user's persistent PATH
$userPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($userPath -notlike "*$claudeBin*") {
    Write-Status "Adding $claudeBin to user PATH..."
    [Environment]::SetEnvironmentVariable("Path", "$userPath;$claudeBin", "User")
    Write-Ok "Added to persistent PATH"
}
# Also add to current session
if ($env:Path -notlike "*$claudeBin*") {
    $env:Path = "$env:Path;$claudeBin"
}
Refresh-Path

if (Get-Command claude -ErrorAction SilentlyContinue) {
    Write-Ok "Claude Code: ready"
} else {
    Write-Warn "Claude Code: may need terminal restart"
}

# ── Step 4: Configure AWS SSO profile ───────────────────────────────
Write-Status "Configuring AWS SSO profile..."

$awsDir    = Join-Path $env:USERPROFILE ".aws"
$awsConfig = Join-Path $awsDir "config"

if (-not (Test-Path $awsDir)) {
    New-Item -ItemType Directory -Path $awsDir -Force | Out-Null
}

$profileBlock = @"

[profile prod-it01-bedrock]
region = us-west-2
output = json
sso_start_url = https://albedo.awsapps.com/start
sso_region = us-west-2
sso_account_id = $accountId
sso_role_name = AlbedoBedrockUsers
sso_registration_scopes = sso:account:access
"@

if (Test-Path $awsConfig) {
    $content = Get-Content $awsConfig -Raw -ErrorAction SilentlyContinue
    if ($content -and $content.Contains("[profile prod-it01-bedrock]")) {
        Write-Ok "prod-it01-bedrock profile already exists"
    } else {
        Add-Content -Path $awsConfig -Value $profileBlock
        Write-Ok "prod-it01-bedrock profile added to config"
    }
} else {
    Write-Utf8NoBom -Path $awsConfig -Content $profileBlock.TrimStart()
    Write-Ok "AWS config created with prod-it01-bedrock profile"
}

# Disable AWS CLI pager (prevents hanging on long output)
[Environment]::SetEnvironmentVariable("AWS_PAGER", "", "User")
$env:AWS_PAGER = ""
Write-Ok "AWS_PAGER disabled"

# ── Step 5: AWS SSO Login ───────────────────────────────────────────

# Clear stale AWS env vars to avoid profile confusion
Remove-Item Env:AWS_PROFILE           -ErrorAction SilentlyContinue
Remove-Item Env:AWS_DEFAULT_REGION    -ErrorAction SilentlyContinue
Remove-Item Env:AWS_REGION            -ErrorAction SilentlyContinue
Remove-Item Env:AWS_ACCESS_KEY_ID     -ErrorAction SilentlyContinue
Remove-Item Env:AWS_SECRET_ACCESS_KEY -ErrorAction SilentlyContinue
Remove-Item Env:AWS_SESSION_TOKEN     -ErrorAction SilentlyContinue

Write-Status "Logging in to AWS SSO (profile: prod-it01-bedrock)..."
aws sso login --profile prod-it01-bedrock
if ($LASTEXITCODE -ne 0) {
    Write-Err "AWS SSO login failed"
    exit 1
}
Write-Ok "AWS SSO login successful"

# ── Step 6: Configure Claude Code settings.json ─────────────────────
Write-Status "Configuring Claude Code for Bedrock..."

$claudeDir      = Join-Path $env:USERPROFILE ".claude"
$claudeSettings = Join-Path $claudeDir "settings.json"

if (-not (Test-Path $claudeDir)) {
    New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null
}

Write-Status "Downloading latest configuration from GitHub..."
$referenceRaw = (Invoke-WebRequest -Uri $ReferenceUrl -UseBasicParsing).Content
$referenceObj = $referenceRaw | ConvertFrom-Json
Write-Ok "Downloaded reference configuration"

# Pinned model ARN env vars to remove from existing settings (legacy from v5.0.0)
# Claude Code's native /model picker handles model selection now.
$PinnedEnvKeys = @(
    "ANTHROPIC_DEFAULT_OPUS_MODEL",
    "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME",
    "ANTHROPIC_DEFAULT_OPUS_MODEL_DESCRIPTION",
    "ANTHROPIC_DEFAULT_SONNET_MODEL",
    "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME",
    "ANTHROPIC_DEFAULT_SONNET_MODEL_DESCRIPTION",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL_DESCRIPTION"
)

if (Test-Path $claudeSettings) {
    Write-Status "Merging with existing settings..."

    # Backup
    $timestamp  = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupFile = "$claudeSettings.backup.$timestamp"
    Copy-Item $claudeSettings $backupFile
    Write-Warn "Backup created: $backupFile"

    try {
        $existing = Get-Content $claudeSettings -Raw | ConvertFrom-Json
    } catch {
        Write-Err "Existing settings.json is not valid JSON. Check: $claudeSettings"
        Write-Warn "Backup saved to: $backupFile"
        Write-Warn "Overwriting with fresh reference configuration..."
        Write-Utf8NoBom -Path $claudeSettings -Content $referenceRaw
        Write-Ok "Settings file replaced with reference"
        $existing = $null
    }

    if ($existing) {
        if (-not $existing.PSObject.Properties["awsAuthRefresh"]) {
            $existing | Add-Member -NotePropertyName "awsAuthRefresh" -NotePropertyValue $referenceObj.awsAuthRefresh
        }

        # Merge env block: reference values override existing
        if (-not $existing.PSObject.Properties["env"] -or $existing.env -isnot [PSCustomObject]) {
            if ($existing.PSObject.Properties["env"]) {
                $existing.env = $referenceObj.env
            } else {
                $existing | Add-Member -NotePropertyName "env" -NotePropertyValue $referenceObj.env
            }
        } else {
            foreach ($prop in $referenceObj.env.PSObject.Properties) {
                if ($existing.env.PSObject.Properties[$prop.Name]) {
                    $existing.env.($prop.Name) = $prop.Value
                } else {
                    $existing.env | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value
                }
            }

            # Strip any legacy pinned model ARN env vars
            foreach ($key in $PinnedEnvKeys) {
                if ($existing.env.PSObject.Properties[$key]) {
                    $existing.env.PSObject.Properties.Remove($key)
                }
            }
        }

        $merged = $existing | ConvertTo-Json -Depth 10
        Write-Utf8NoBom -Path $claudeSettings -Content $merged
        Write-Ok "Settings merged"
    }
} else {
    Write-Utf8NoBom -Path $claudeSettings -Content $referenceRaw
    Write-Ok "Settings file created"
}

# ── Step 7: Setup S3 plugin marketplace ───────────────────────────────
Write-Status "Setting up Albedo plugin marketplace..."

$MarketplaceUrl = "s3://plugin-marketplace-prod-it01-$accountId/marketplace"
$MarketplaceKey = "albedo-claude-plugin-marketplace"
$KnownMarketplaces = Join-Path $env:USERPROFILE ".claude\plugins\known_marketplaces.json"

# Resolve uv binary — check PATH, then known install locations
function Find-Uv {
    $cmd = Get-Command uv -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    # uv installs to $HOME\.local\bin on Windows by default
    $candidate = Join-Path $env:USERPROFILE ".local\bin\uv.exe"
    if (Test-Path $candidate) { return $candidate }
    # Older uv versions used cargo bin
    $candidate = Join-Path $env:USERPROFILE ".cargo\bin\uv.exe"
    if (Test-Path $candidate) { return $candidate }
    return $null
}

# Ensure uv is available (needed for git-remote-s3)
$uvBin = Find-Uv
if (-not $uvBin) {
    Write-Status "Installing uv (Python package manager)..."
    irm https://astral.sh/uv/install.ps1 | iex
    Refresh-Path
    $uvBin = Find-Uv
    if ($uvBin) {
        Write-Ok "uv installed at $uvBin"
    } else {
        Write-Warn "uv install may have failed. Continuing..."
    }
}

# Install git-remote-s3
if (Get-Command git-remote-s3 -ErrorAction SilentlyContinue) {
    Write-Ok "git-remote-s3 already installed"
} else {
    Write-Status "Installing git-remote-s3..."
    if ($uvBin) {
        & $uvBin tool install git-remote-s3
    } elseif (Get-Command pipx -ErrorAction SilentlyContinue) {
        pipx install git-remote-s3
    } elseif (Get-Command pip -ErrorAction SilentlyContinue) {
        pip install git-remote-s3
    } else {
        Write-Warn "Could not install git-remote-s3. Install manually: uv tool install git-remote-s3"
    }

    Refresh-Path
    if (Get-Command git-remote-s3 -ErrorAction SilentlyContinue) {
        Write-Ok "git-remote-s3 installed"
    } else {
        Write-Warn "git-remote-s3 not found on PATH. You may need to restart your terminal."
    }
}

# Validate S3 bucket access
Write-Status "Validating marketplace access..."
aws s3 ls "s3://plugin-marketplace-prod-it01-$accountId/" --profile prod-it01-bedrock 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Ok "Marketplace bucket accessible"
} else {
    Write-Warn "Could not access marketplace bucket. The marketplace is registered but may not sync until access is granted."
}

# Register marketplace in known_marketplaces.json
$PluginDir = Split-Path $KnownMarketplaces
if (-not (Test-Path $PluginDir)) {
    New-Item -ItemType Directory -Path $PluginDir -Force | Out-Null
}

$InstallLocation = Join-Path $env:USERPROFILE ".claude\plugins\marketplaces\$MarketplaceKey"

$Entry = @{
    source = @{ source = "git"; url = $MarketplaceUrl }
    installLocation = $InstallLocation
    lastUpdated = ((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ"))
}

# Official Claude marketplace — ensure it's always present
$OfficialEntry = @{
    source = @{ source = "github"; repo = "anthropics/claude-plugins-official" }
    installLocation = Join-Path $env:USERPROFILE ".claude\plugins\marketplaces\claude-plugins-official"
    lastUpdated = ((Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ"))
}

if (Test-Path $KnownMarketplaces) {
    try {
        $existing = Get-Content $KnownMarketplaces -Raw | ConvertFrom-Json
        # Build hashtable from PSCustomObject (PS 5.1 compat — no -AsHashtable)
        $Data = @{}
        foreach ($prop in $existing.PSObject.Properties) {
            $Data[$prop.Name] = $prop.Value
        }
    } catch {
        $Data = @{}
    }
} else {
    $Data = @{}
}

if (-not $Data.ContainsKey("claude-plugins-official")) {
    $Data["claude-plugins-official"] = $OfficialEntry
}
$Data[$MarketplaceKey] = $Entry

$jsonStr = $Data | ConvertTo-Json -Depth 4
Write-Utf8NoBom -Path $KnownMarketplaces -Content $jsonStr
Write-Ok "Plugin marketplace registered"

# ── Verification ─────────────────────────────────────────────────────
Write-Host ""
Write-Host "===========================================================" -ForegroundColor Green
Write-Host "  Setup Complete!"                                           -ForegroundColor Green
Write-Host "===========================================================" -ForegroundColor Green
Write-Host ""

Write-Status "Running verification..."

# Git
if (Get-Command git -ErrorAction SilentlyContinue) {
    Write-Ok "Git: $(git --version)"
} else {
    Write-Err "Git: NOT FOUND"
}

# AWS CLI
if (Get-Command aws -ErrorAction SilentlyContinue) {
    Write-Ok "AWS CLI: $(aws --version 2>&1)"
} else {
    Write-Err "AWS CLI: NOT FOUND"
}

# Claude Code
if (Get-Command claude -ErrorAction SilentlyContinue) {
    Write-Ok "Claude Code: installed"
} else {
    Write-Warn "Claude Code: not in PATH yet (reopen terminal)"
}

# CLAUDE_CODE_GIT_BASH_PATH
$persistedGitBash = [Environment]::GetEnvironmentVariable("CLAUDE_CODE_GIT_BASH_PATH", "User")
if ($persistedGitBash -and (Test-Path $persistedGitBash)) {
    Write-Ok "CLAUDE_CODE_GIT_BASH_PATH: $persistedGitBash"
} else {
    Write-Err "CLAUDE_CODE_GIT_BASH_PATH: not set or target missing"
}

# AWS profile
if ((Test-Path $awsConfig) -and (Select-String -Path $awsConfig -Pattern "profile prod-it01-bedrock" -Quiet)) {
    Write-Ok "AWS prod-it01-bedrock profile: configured"
} else {
    Write-Err "AWS prod-it01-bedrock profile: NOT FOUND"
}

# settings.json
if ((Test-Path $claudeSettings) -and (Select-String -Path $claudeSettings -Pattern "CLAUDE_CODE_USE_BEDROCK" -Quiet)) {
    Write-Ok "Claude Code Bedrock settings: configured"
} else {
    Write-Err "Claude Code Bedrock settings: NOT FOUND"
}

# git-remote-s3
if (Get-Command git-remote-s3 -ErrorAction SilentlyContinue) {
    Write-Ok "git-remote-s3: installed"
} else {
    Write-Warn "git-remote-s3: NOT FOUND (needed for plugin marketplace)"
}

# Plugin marketplace
$kmPath = Join-Path $env:USERPROFILE ".claude\plugins\known_marketplaces.json"
if ((Test-Path $kmPath) -and (Select-String -Path $kmPath -Pattern "albedo-claude-plugin-marketplace" -Quiet)) {
    Write-Ok "Plugin marketplace: registered"
} else {
    Write-Warn "Plugin marketplace: not registered"
}

Write-Host ""
Write-Status "Next steps:"
Write-Host "  1. Close and reopen PowerShell"
Write-Host "  2. Run: claude"
Write-Host "  3. Run /plugin inside Claude Code to browse the Albedo marketplace"
Write-Host ""
Write-Warn "You may need to restart your terminal for PATH changes to take effect."
Write-Host ""
