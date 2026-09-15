#Requires -Version 5.1
# Codex with Albedo Bedrock, Windows. Safe to re-run.
$ErrorActionPreference = 'Stop'
$SourceUrl = 'https://raw.githubusercontent.com/Albedo-Space-Corp/claude_code/refs/heads/main'

function Refresh-Path {
    $env:Path = $env:Path + ';' + [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
        [Environment]::GetEnvironmentVariable('Path', 'User') + ';' +
        (Join-Path $env:USERPROFILE '.local\bin')
}
function Check-Exit([string]$Step) {
    if ($LASTEXITCODE -ne 0) { throw "$Step failed (exit $LASTEXITCODE)." }
}

Write-Host 'Setting up Codex with Albedo Bedrock...'
Refresh-Path
$env:AWS_PAGER = ''
foreach ($package in @(@('git', 'Git.Git'), @('aws', 'Amazon.AWSCLI'), @('uv', 'astral-sh.uv'))) {
    if (-not (Get-Command $package[0] -ErrorAction SilentlyContinue)) {
        if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
            throw 'Install App Installer (winget) from the Microsoft Store, then run setup again.'
        }
        winget install --id $package[1] --exact --source winget --accept-package-agreements --accept-source-agreements --silent
        Check-Exit "Installing $($package[1])"
        Refresh-Path
    }
}
if (-not (Get-Command codex -ErrorAction SilentlyContinue)) {
    $PreviousNonInteractive = $env:CODEX_NON_INTERACTIVE
    try {
        $env:CODEX_NON_INTERACTIVE = '1'
        # Keep the official installer's functions and StrictMode in its scope.
        & ([scriptblock]::Create((Invoke-RestMethod https://chatgpt.com/codex/install.ps1)))
    } finally {
        $env:CODEX_NON_INTERACTIVE = $PreviousNonInteractive
    }
    Refresh-Path
}
codex --version
Check-Exit 'Checking Codex'

$LocalBin = Join-Path $env:USERPROFILE '.local\bin'
$UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($LocalBin -notin ($UserPath -split ';')) {
    [Environment]::SetEnvironmentVariable('Path', "$UserPath;$LocalBin", 'User')
}

$TempDir = Join-Path ([IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString())
New-Item -ItemType Directory -Path $TempDir | Out-Null
try {
    $Helper = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'configure_codex.py' } else { '' }
    if (-not $Helper -or -not (Test-Path $Helper)) {
        $Helper = Join-Path $TempDir 'configure_codex.py'
        Invoke-WebRequest "$SourceUrl/configure_codex.py" -OutFile $Helper -UseBasicParsing
    }
    uv run --script $Helper
    Check-Exit 'Configuring AWS and Codex'

    # Windows PowerShell treats native stderr as an error under Stop.
    $ErrorActionPreference = 'Continue'
    aws sts get-caller-identity --profile prod-it01-bedrock 2>&1 | Out-Null
    $SsoOk = $LASTEXITCODE -eq 0
    $ErrorActionPreference = 'Stop'
    if (-not $SsoOk) {
        aws sso login --profile prod-it01-bedrock
        Check-Exit 'AWS SSO login'
    }
} finally {
    Remove-Item $TempDir -Recurse -Force
}
Write-Host 'Setup complete. Restart Codex or your IDE, then run codex.'
Write-Host 'Use /status to confirm amazon-bedrock and /model to choose a model.'
Write-Host 'Use /plugins to browse the Albedo marketplace.'
