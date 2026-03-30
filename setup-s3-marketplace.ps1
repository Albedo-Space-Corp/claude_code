$ErrorActionPreference = "Stop"

$MarketplaceKey = "albedo-claude-plugin-marketplace"
$KnownMarketplaces = Join-Path $env:USERPROFILE ".claude\plugins\known_marketplaces.json"

Write-Host "Setting up Albedo plugin marketplace for Claude Code..."

# Get account ID from AWS config or prompt
$awsConfig = Join-Path $env:USERPROFILE ".aws\config"
$accountId = $null
if (Test-Path $awsConfig) {
    $content = Get-Content $awsConfig -Raw
    if ($content -match "(?s)\[profile prod-it01-bedrock\].*?sso_account_id\s*=\s*(\d+)") {
        $accountId = $Matches[1]
    }
}
if (-not $accountId) {
    Write-Host "AWS Account ID not found in ~/.aws/config."
    Write-Host "Find it at: https://albedo.awsapps.com/start -> Account list"
    $accountId = Read-Host "Enter your AWS Account ID"
    if (-not $accountId -or $accountId -notmatch '^\d+$') {
        Write-Error "Invalid account ID."
        exit 1
    }
}

$MarketplaceUrl = "s3://plugin-marketplace-prod-it01-$accountId/marketplace"

# Resolve uv binary — check PATH, then known install locations
function Find-Uv {
    $cmd = Get-Command uv -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidate = Join-Path $env:USERPROFILE ".local\bin\uv.exe"
    if (Test-Path $candidate) { return $candidate }
    $candidate = Join-Path $env:USERPROFILE ".cargo\bin\uv.exe"
    if (Test-Path $candidate) { return $candidate }
    return $null
}

# Refresh PATH from registry
function Refresh-Path {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath    = [Environment]::GetEnvironmentVariable("Path", "User")
    foreach ($entry in "$machinePath;$userPath".Split(';', [StringSplitOptions]::RemoveEmptyEntries)) {
        if ($env:Path -notlike "*$entry*") { $env:Path = "$env:Path;$entry" }
    }
}

# Ensure uv is available (needed for git-remote-s3)
$uvBin = Find-Uv
if (-not $uvBin) {
    Write-Host "Installing uv (Python package manager)..."
    irm https://astral.sh/uv/install.ps1 | iex
    Refresh-Path
    $uvBin = Find-Uv
    if ($uvBin) { Write-Host "uv installed at $uvBin" }
}

# Install git-remote-s3
if (-not (Get-Command git-remote-s3 -ErrorAction SilentlyContinue)) {
    Write-Host "Installing git-remote-s3..."
    if ($uvBin) {
        & $uvBin tool install git-remote-s3
    } elseif (Get-Command pipx -ErrorAction SilentlyContinue) {
        pipx install git-remote-s3
    } elseif (Get-Command pip -ErrorAction SilentlyContinue) {
        pip install git-remote-s3
    } else {
        Write-Error "Could not install git-remote-s3. Install manually: uv tool install git-remote-s3"
        exit 1
    }
} else {
    Write-Host "git-remote-s3 already installed."
}

# Validate AWS credentials and S3 bucket access
Write-Host "Validating marketplace access..."
$bucketUrl = $MarketplaceUrl.Substring(0, $MarketplaceUrl.LastIndexOf('/') + 1)
aws s3 ls $bucketUrl --profile prod-it01-bedrock 2>&1 | Out-Null
if ($LASTEXITCODE -eq 0) {
    Write-Host "Marketplace bucket accessible."
} else {
    Write-Host "Warning: Could not access marketplace bucket." -ForegroundColor Yellow
    Write-Host "Ensure you have valid AWS credentials: aws sso login --profile prod-it01-bedrock" -ForegroundColor Yellow
    Write-Host "The marketplace will be registered but won't sync until credentials are available." -ForegroundColor Yellow
}

# Register marketplace in known_marketplaces.json
$PluginDir = Split-Path $KnownMarketplaces
if (-not (Test-Path $PluginDir)) {
    New-Item -ItemType Directory -Path $PluginDir -Force | Out-Null
}

$Entry = @{
    source = @{ source = "git"; url = $MarketplaceUrl }
    installLocation = Join-Path $env:USERPROFILE ".claude\plugins\marketplaces\$MarketplaceKey"
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
[System.IO.File]::WriteAllText($KnownMarketplaces, $jsonStr, [System.Text.UTF8Encoding]::new($false))

Write-Host ""
Write-Host "Done! The Albedo plugin marketplace is now registered."
Write-Host "Open Claude Code and run /plugin to browse and install plugins."
