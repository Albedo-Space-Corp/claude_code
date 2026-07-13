#Requires -Version 5.1

<#
.SYNOPSIS
    Reconfigure an existing Claude Code + Bedrock install (Windows), without
    reinstalling the Claude Code binary.
.DESCRIPTION
    Runs the full setup_ccb.ps1 with CCB_SKIP_CLAUDE_INSTALL=1, so it does
    everything setup does — adds both the commercial (prod-it01-bedrock) and
    GovCloud (gc-prod-it01-bedrock) AWS profiles in the modern sso-session
    format, writes ~/.claude/gov.settings.json, installs the claude-gov
    launcher function, merges ~/.claude/settings.json (stripping legacy pinned
    model ARNs and updating awsAuthRefresh), and registers the plugin
    marketplace — but leaves your existing Claude Code binary untouched.

    Safe to re-run; setup_ccb.ps1 is idempotent and backs up files it changes.
.NOTES
    Usage:
      powershell -ExecutionPolicy Bypass -File update_claude_code.ps1
      irm https://raw.githubusercontent.com/Albedo-Space-Corp/claude_code/refs/heads/main/update_claude_code.ps1 | iex

      # Run against a sibling setup_ccb.ps1 instead of downloading (local dev):
      powershell -ExecutionPolicy Bypass -File update_claude_code.ps1 -Local
#>

param(
    [switch]$Local
)

$ErrorActionPreference = "Stop"

$SetupUrl = "https://raw.githubusercontent.com/Albedo-Space-Corp/claude_code/refs/heads/main/setup_ccb.ps1"

Write-Host ""
Write-Host "===========================================================" -ForegroundColor Green
Write-Host "  Claude Code Bedrock - Update / Reconfigure"                -ForegroundColor Green
Write-Host "  Runs full setup (both AWS profiles, gov settings +"        -ForegroundColor Green
Write-Host "  claude-gov launcher, settings.json merge, marketplace)"    -ForegroundColor Green
Write-Host "  but SKIPS installing the Claude Code binary."             -ForegroundColor Green
Write-Host "===========================================================" -ForegroundColor Green
Write-Host ""

$env:CCB_SKIP_CLAUDE_INSTALL = "1"

# Invoke the child setup with the SAME PowerShell runtime that's running this
# script, not a hardcoded "powershell" — otherwise running from pwsh (PS7) on a
# host without Windows PowerShell on PATH would fail before reconfiguring.
$psExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

if ($Local) {
    $localSetup = Join-Path $PSScriptRoot "setup_ccb.ps1"
    if (-not (Test-Path $localSetup)) {
        Write-Host "x -Local given but no setup_ccb.ps1 next to this script ($localSetup)." -ForegroundColor Red
        exit 1
    }
    Write-Host "Running local setup: $localSetup"
    & $psExe -ExecutionPolicy Bypass -File $localSetup
} else {
    $tmp = Join-Path $env:TEMP "setup_ccb_$([System.IO.Path]::GetRandomFileName()).ps1"
    try {
        Invoke-WebRequest -Uri $SetupUrl -OutFile $tmp -UseBasicParsing
        & $psExe -ExecutionPolicy Bypass -File $tmp
    } finally {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
    }
}
