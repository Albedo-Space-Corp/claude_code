#Requires -Version 5.1

<#
.SYNOPSIS
    Albedo plugin marketplace setup for Claude Code (Windows).
.DESCRIPTION
    For machines that already have Claude Code and the Bedrock AWS profiles
    configured. setup_ccb.ps1 does this same work as its step 7; this script
    exists so an existing install can pick up the marketplace on its own.

    The marketplace is a CodeCommit repository cloned over HTTPS, authorized by
    the caller's own AlbedoBedrockUsers role through the AWS CLI git credential
    helper. Nothing long-lived is stored on this machine.

    Safe to re-run.
.NOTES
    Usage:
      powershell -ExecutionPolicy Bypass -File setup-marketplace.ps1
      irm https://raw.githubusercontent.com/Albedo-Space-Corp/claude_code/refs/heads/main/setup-marketplace.ps1 | iex
#>

$ErrorActionPreference = "Stop"

function Invoke-Native {
    # Every native command whose streams are redirected goes through here, and
    # returns its exit code plus output rather than throwing.
    #
    # Under the script-level $ErrorActionPreference = "Stop", Windows PowerShell 5.1
    # turns a redirected native stderr write into a terminating NativeCommandError.
    # Both redirection forms do it: `2>$null` and `2>&1`. Only a bare, unredirected
    # call is safe, because its stderr goes straight to the console without becoming
    # an ErrorRecord. That is backwards from the intuition the redirections were
    # written with, and it means each one fired on exactly the failure path it was
    # added to detect: an absent credential helper, a config section that is not
    # there yet, an unreachable marketplace, a lapsed SSO session. Relaxing the
    # preference to this function's scope is what keeps those recoverable.
    #
    # PowerShell 7 does not behave this way ($PSNativeCommandUseErrorActionPreference
    # defaults to false), so CI on the pwsh image cannot catch a regression here by
    # running the code. tests/test_setup_ccb.ps1 checks the shape statically.
    #
    # The argument list is one explicit array rather than remaining arguments:
    # ValueFromRemainingArguments silently drops the first bare token, so
    # `Invoke-Native git config --global ...` would hand git `--global ...` and earn
    # a usage error.
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string[]]$Arguments,
        [string]$StandardInput,
        # Keep stderr in the returned output, for callers that report the message.
        [switch]$CaptureStderr
    )
    $ErrorActionPreference = "Continue"
    if ($CaptureStderr) {
        $Output = @(& $Command @Arguments 2>&1 | ForEach-Object { "$_" })
    } elseif ($PSBoundParameters.ContainsKey("StandardInput")) {
        $Output = @($StandardInput | & $Command @Arguments 2>$null)
    } else {
        $Output = @(& $Command @Arguments 2>$null)
    }
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $Output }
}

function Expand-GitQuotedPath {
    # git C-style quotes a config origin path when it holds a character that needs
    # escaping. On Windows every backslash qualifies, so a quoted path is the norm
    # whenever GIT_CONFIG_GLOBAL is set, and a non-ASCII character arrives as one
    # \nnn octal escape per UTF-8 byte (Jose with an acute e becomes Jos\303\251).
    # Decoding to bytes and reading them back as UTF-8 recovers the original name.
    #
    # Stripping backslashes with a regex is not enough: that turns \303\251 into the
    # literal characters 303251, and the credential section then lands in a path git
    # never reads, leaving the marketplace unauthenticated.
    #
    # Asking git to print the path unescaped instead (GIT_EDITOR=echo git config
    # --global --edit) is worse here rather than better: that emits raw UTF-8, which
    # Windows PowerShell 5.1 decodes with the console code page and mangles. The
    # escaped form is pure ASCII and survives any code page.
    param([Parameter(Mandatory = $true)][string]$Quoted)
    if ($Quoted.Length -lt 2 -or -not ($Quoted.StartsWith('"') -and $Quoted.EndsWith('"'))) {
        return $Quoted
    }
    $Body = $Quoted.Substring(1, $Quoted.Length - 2)
    $Bytes = New-Object System.Collections.Generic.List[byte]
    $Simple = @{ 'a' = 7; 'b' = 8; 'f' = 12; 'n' = 10; 'r' = 13; 't' = 9; 'v' = 11; '\' = 92; '"' = 34 }
    $i = 0
    while ($i -lt $Body.Length) {
        if ($Body[$i] -ne '\') {
            $Bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes([string]$Body[$i]))
            $i++
            continue
        }
        $i++
        if ($i -ge $Body.Length) { break }
        $Next = [string]$Body[$i]
        if ($Simple.ContainsKey($Next)) {
            $Bytes.Add([byte]$Simple[$Next])
            $i++
        } elseif ($Next -match '^[0-7]$') {
            $Octal = ""
            while ($i -lt $Body.Length -and $Octal.Length -lt 3 -and [string]$Body[$i] -match '^[0-7]$') {
                $Octal += $Body[$i]
                $i++
            }
            $Bytes.Add([Convert]::ToByte($Octal, 8))
        } else {
            $Bytes.AddRange([System.Text.Encoding]::UTF8.GetBytes($Next))
            $i++
        }
    }
    return [System.Text.Encoding]::UTF8.GetString($Bytes.ToArray())
}

function Invoke-GitNonInteractive {
    # Runs git with every credential prompt disabled, then restores the caller's
    # environment.
    #
    # The AWS credential helper prints its own diagnostic and returns nothing when
    # it cannot mint a password (no SSO session, wrong profile, aws not on PATH,
    # missing codecommit:GitPull), and git's response to an empty credential is to
    # ask the user for one. That turns a diagnosable failure into "Username for
    # 'https://git-codecommit.us-west-2.amazonaws.com'" and a hung installer.
    #
    # All three suppressors are needed: GIT_TERMINAL_PROMPT stops the terminal
    # prompt, GIT_ASKPASS pre-empts a configured core.askPass that could open a GUI
    # dialog, and GCM_INTERACTIVE stops Git Credential Manager doing the same.
    param([Parameter(Mandatory = $true)][string[]]$Arguments)
    $Saved = @{}
    foreach ($Name in "GIT_TERMINAL_PROMPT", "GIT_ASKPASS", "GCM_INTERACTIVE") {
        $Saved[$Name] = [Environment]::GetEnvironmentVariable($Name)
    }
    try {
        $env:GIT_TERMINAL_PROMPT = "0"
        $env:GIT_ASKPASS = "echo"
        $env:GCM_INTERACTIVE = "never"
        return Invoke-Native git $Arguments -CaptureStderr
    } finally {
        foreach ($Name in $Saved.Keys) {
            if ($null -eq $Saved[$Name]) {
                Remove-Item "Env:\$Name" -ErrorAction SilentlyContinue
            } else {
                Set-Item "Env:\$Name" -Value $Saved[$Name]
            }
        }
    }
}

# ── Configuration ────────────────────────────────────────────────────
$MarketplaceKey = "albedo-claude-plugin-marketplace"
$OfficialKey    = "claude-plugins-official"
$AwsProfile     = if ($env:ALBEDO_AWS_PROFILE) { $env:ALBEDO_AWS_PROFILE } else { "prod-it01-bedrock" }
$CodeCommitHost = "https://git-codecommit.us-west-2.amazonaws.com"
$MarketplaceRepo = "albedo-plugins"
# The trailing .git is mandatory: without it Claude Code classifies the URL as a
# direct marketplace.json download, sends no credentials, and fails with an
# opaque HTTP 401.
$RepoUrl = "$CodeCommitHost/v1/repos/$MarketplaceRepo.git"

$ClaudeDir         = if ($env:CLAUDE_CONFIG_DIR) { $env:CLAUDE_CONFIG_DIR } else { Join-Path $env:USERPROFILE ".claude" }
$PluginsDir        = Join-Path $ClaudeDir "plugins"
$KnownMarketplaces = Join-Path $PluginsDir "known_marketplaces.json"
$SettingsFile      = Join-Path $ClaudeDir "settings.json"
$MarketplaceClone  = Join-Path $PluginsDir "marketplaces\$MarketplaceKey"
$BackupStamp       = (Get-Date).ToString("yyyyMMdd_HHmmss")
$NowStamp          = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")

Write-Host "Setting up the Albedo plugin marketplace for Claude Code..."

# Reads a PSCustomObject (as produced by ConvertFrom-Json) into a hashtable.
# PowerShell 5.1 has no -AsHashtable switch for ConvertFrom-Json, so we walk
# the properties ourselves.
function ConvertTo-Hashtable {
    param($InputObject)
    $ht = @{}
    if ($InputObject) {
        foreach ($prop in $InputObject.PSObject.Properties) {
            $ht[$prop.Name] = $prop.Value
        }
    }
    return $ht
}

# ---------------------------------------------------------------------------
# 1. Prerequisites
# ---------------------------------------------------------------------------
foreach ($tool in @("git", "aws")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Error "$tool is not installed or not on PATH. Run the full setup first: setup_ccb.ps1"
        exit 1
    }
}

Write-Host "Checking AWS SSO session for profile '$AwsProfile'..."
$Caller = Invoke-Native aws @("sts", "get-caller-identity", "--profile", $AwsProfile) -CaptureStderr
$SsoOk = ($Caller.ExitCode -eq 0)
if (-not $SsoOk) {
    Write-Host "Warning: no active AWS SSO session for profile '$AwsProfile'." -ForegroundColor Yellow
    Write-Host "  Run: aws sso login --profile $AwsProfile" -ForegroundColor Yellow
    Write-Host "  Continuing; the check at the end will fail until you log in." -ForegroundColor Yellow
} else {
    Write-Host "AWS SSO session is active."
}

# ---------------------------------------------------------------------------
# 2. Clear any cached credential for this host
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Clearing any cached credential for $CodeCommitHost..."

# Git Credential Manager may hold a SigV4 password minted by the AWS helper on
# an earlier run. That password expires in about 15 minutes, but GCM does not
# know that and will hand out the stale value again, producing intermittent 403s
# that logging in again never fixes. `erase` speaks the standard git-credential
# protocol, so it works whatever store GCM is backed by, and is a harmless no-op
# when nothing was cached. GCM is invoked directly rather than through git's
# helper selection, so this works regardless of the config written below.
#
# Both binary names are tried: Git for Windows renamed
# git-credential-manager-core to git-credential-manager in 2022, so on any
# current Git the second name is absent and git reports it as an unknown
# command. That is expected, which is why these go through Invoke-Git.
$CodeCommitHostname = ([Uri]$CodeCommitHost).Host
# The trailing blank line terminates the git credential request; without it a
# helper can block waiting for more input.
$EraseRequest = "protocol=https`nhost=$CodeCommitHostname`n`n"
foreach ($gcm in @("credential-manager", "credential-manager-core")) {
    $null = Invoke-Native -Command git -StandardInput $EraseRequest -Arguments @($gcm, "erase")
}
Write-Host "Done."

# ---------------------------------------------------------------------------
# 3. Git credential helper, scoped to this repository only
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Configuring git credentials for the marketplace repository..."

# Git for Windows registers Git Credential Manager as an UNSCOPED
# credential.helper, and unscoped helpers are consulted before scoped ones, so a
# bare AWS helper for this repo would never run. Per git's own documentation,
# configuring a helper as the empty string resets the helper list up to that
# point, so an empty entry followed by the AWS helper makes the AWS helper
# authoritative here.
#
# The section is keyed on the full repository URL rather than the host, with
# UseHttpPath=true so git sends the path for matching. A host-only section would
# own every CodeCommit repo under this host: another repo needing a different AWS
# profile would have nowhere for that profile to live, and re-running this script
# would silently discard whatever it had configured. GitHub, GitLab, and any
# other CodeCommit remote keep using GCM.
#
# The profile is pinned rather than inherited from the environment because
# claude-gov runs with AWS_PROFILE set to the GovCloud profile, which cannot read
# this commercial repository.
#
# Idempotency means clearing any prior version of the section first.
# --remove-section fails when the section does not exist yet, which is the normal
# first-run case, so its stderr is discarded.
$null = Invoke-Native git @("config", "--global", "--remove-section", "credential.$RepoUrl")

# PowerShell cannot reliably pass an empty-string argument to a native
# executable: it is silently dropped from the child process command line, a
# long-standing engine limitation. That rules out `git config --add ... ""` for
# the empty helper entry, so the section is appended to the gitconfig file
# directly, which is also easy to verify byte for byte.
#
# Ask git which file it treats as the global config rather than assuming
# ~/.gitconfig: git prefers $GIT_CONFIG_GLOBAL and falls back to an XDG location
# when one already exists. Writing a throwaway key is the only reliable way to
# make git name the file, because --show-origin reports nothing when the config
# is empty.
$null = Invoke-Native git @("config", "--global", "--add", "albedo.configprobe", "1")
$ProbeOrigin = (Invoke-Native git @("config", "--global", "--list", "--show-origin", "--name-only")).Output |
    Where-Object { $_ -match "albedo\.configprobe" } | Select-Object -First 1
$null = Invoke-Native git @("config", "--global", "--unset", "albedo.configprobe")
# The line is `file:<path>`, a TAB, then the key name. Split on that tab rather
# than matching up to the first whitespace: a Windows profile path routinely
# contains spaces (C:\Users\John Doe\.gitconfig), and matching to whitespace
# truncates it, which would append the helper to the wrong file and leave git
# without any credential configuration for the marketplace.
$OriginPath = $null
if ($ProbeOrigin) {
    $OriginField = ($ProbeOrigin -split "`t", 2)[0]
    if ($OriginField.StartsWith("file:")) {
        $OriginPath = Expand-GitQuotedPath $OriginField.Substring(5)
    }
}
if ($OriginPath) {
    $GitConfigPath = $OriginPath
} else {
    $GitConfigPath = if ($env:GIT_CONFIG_GLOBAL) { $env:GIT_CONFIG_GLOBAL } else { Join-Path $env:USERPROFILE ".gitconfig" }
}

$AwsHelperCommand  = '!aws --profile ' + $AwsProfile + ' codecommit credential-helper $@'
$CredentialSection = "`r`n[credential `"$RepoUrl`"]`r`n`thelper = `r`n`thelper = $AwsHelperCommand`r`n`tUseHttpPath = true`r`n"
[System.IO.File]::AppendAllText($GitConfigPath, $CredentialSection, [System.Text.UTF8Encoding]::new($false))

$ConfiguredHelpers = (Invoke-Native git @("config", "--global", "--get-all", "credential.$RepoUrl.helper")).Output
if ($ConfiguredHelpers.Count -ne 2 -or $ConfiguredHelpers[0] -ne "") {
    Write-Error "Expected an empty helper followed by the AWS helper for $RepoUrl, got: $ConfiguredHelpers. Check $GitConfigPath manually."
    exit 1
}
Write-Host "Git credential helper configured for $MarketplaceRepo."

# ---------------------------------------------------------------------------
# 4. Register the marketplace
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Updating $KnownMarketplaces..."

if (-not (Test-Path $PluginsDir)) {
    New-Item -ItemType Directory -Path $PluginsDir -Force | Out-Null
}

$Data = @{}
if (Test-Path $KnownMarketplaces) {
    Copy-Item $KnownMarketplaces "$KnownMarketplaces.backup.$BackupStamp" -Force
    try {
        $Data = ConvertTo-Hashtable (Get-Content $KnownMarketplaces -Raw | ConvertFrom-Json)
    } catch {
        Write-Host "Warning: $KnownMarketplaces was not valid JSON; rebuilding it. Original backed up to $KnownMarketplaces.backup.$BackupStamp" -ForegroundColor Yellow
        $Data = @{}
    }
}

# Merged rather than replaced so a hand-set installLocation, and any field Claude
# Code itself added, survive.
$InstallLocation = $MarketplaceClone
if ($Data.ContainsKey($MarketplaceKey) -and $Data[$MarketplaceKey].installLocation) {
    $InstallLocation = $Data[$MarketplaceKey].installLocation
}

$Data[$MarketplaceKey] = @{
    source          = @{ source = "git"; url = $RepoUrl }
    installLocation = $InstallLocation
    lastUpdated     = $NowStamp
}

# The official Anthropic marketplace should always be present alongside ours.
if (-not $Data.ContainsKey($OfficialKey)) {
    $Data[$OfficialKey] = @{
        source          = @{ source = "github"; repo = "anthropics/claude-plugins-official" }
        installLocation = Join-Path $PluginsDir "marketplaces\$OfficialKey"
        lastUpdated     = $NowStamp
    }
}

$JsonOut = $Data | ConvertTo-Json -Depth 6
[System.IO.File]::WriteAllText($KnownMarketplaces, $JsonOut, [System.Text.UTF8Encoding]::new($false))
Write-Host "Marketplace registered at $RepoUrl."

# ---------------------------------------------------------------------------
# 5. Reconcile settings.json
# ---------------------------------------------------------------------------
# A marketplace may also be declared in settings.json. When that declaration and
# the registration above disagree, Claude Code refuses the marketplace outright:
# "its network source differs from the one declared for it in settings".
if (Test-Path $SettingsFile) {
    $Settings = Get-Content $SettingsFile -Raw | ConvertFrom-Json
    $ExtraEntry = $Settings.extraKnownMarketplaces.$MarketplaceKey
    $NeedsFix = $ExtraEntry -and -not ($ExtraEntry.source.source -eq "git" -and $ExtraEntry.source.url -eq $RepoUrl)

    if ($NeedsFix) {
        Copy-Item $SettingsFile "$SettingsFile.backup.$BackupStamp" -Force

        $SettingsData = ConvertTo-Hashtable $Settings
        $ExtraMarketplaces = ConvertTo-Hashtable $Settings.extraKnownMarketplaces
        $EntryData = ConvertTo-Hashtable $ExtraMarketplaces[$MarketplaceKey]
        $EntryData["source"] = @{ source = "git"; url = $RepoUrl }
        $ExtraMarketplaces[$MarketplaceKey] = $EntryData
        $SettingsData["extraKnownMarketplaces"] = $ExtraMarketplaces

        # Depth is at the maximum: ConvertTo-Json silently replaces anything
        # deeper with a flattened string, which would corrupt nested hook or
        # mcpServers configuration.
        $SettingsJsonOut = $SettingsData | ConvertTo-Json -Depth 100
        [System.IO.File]::WriteAllText($SettingsFile, $SettingsJsonOut, [System.Text.UTF8Encoding]::new($false))
        Write-Host "settings.json marketplace declaration updated to match."
    }
}

# ---------------------------------------------------------------------------
# 6. Verify, then retire the old clone
# ---------------------------------------------------------------------------
# Verification has to come first. An existing checkout is a working marketplace
# even when its remote is unreachable: Claude Code reads plugins from the working
# tree and needs the remote only to update. Discarding it before the replacement
# is proven would turn "stale but usable" into "no marketplace at all" for anyone
# whose SSO session has lapsed.
Write-Host ""
Write-Host "Verifying access to the marketplace repository..."
$LsRemote = Invoke-GitNonInteractive @("ls-remote", $RepoUrl)
if ($LsRemote.ExitCode -eq 0) {
    # A checkout whose origin is any other URL cannot pull from the marketplace.
    # The replacement is known good now, so drop it and let Claude Code clone
    # fresh on launch.
    if (Test-Path $MarketplaceClone) {
        $OldOrigin = (Invoke-Native git @("-C", $MarketplaceClone, "remote", "get-url", "origin")).Output | Select-Object -First 1
        if ($OldOrigin -ne $RepoUrl) {
            Write-Host ""
            Write-Host "Removing a stale marketplace clone (origin was $OldOrigin)..."
            Remove-Item $MarketplaceClone -Recurse -Force
        }
    }
    Write-Host ""
    Write-Host "Done. The Albedo plugin marketplace is registered and reachable." -ForegroundColor Green
    Write-Host "Restart Claude Code and run /plugin to browse and install plugins."
} else {
    $ErrorText = ($LsRemote.Output | Out-String).Trim()
    Write-Host "Failed to reach the marketplace repository." -ForegroundColor Red
    # A 403 means the helper produced a password and CodeCommit refused it.
    # "Could not read Username" means it produced nothing, which logging in does
    # not fix if the cause is a missing profile or an aws that is not on PATH.
    if ($ErrorText -match "403") {
        Write-Host "  403: credentials were rejected." -ForegroundColor Yellow
        # SigV4 rejects a request signed outside a 15-minute window, and CodeCommit
        # reports that as a bare 403 with nothing about time. The credential helper
        # cannot catch it either: it signs locally and never calls AWS, so it hands
        # git a password that is already invalid. Asking STS makes AWS state the skew.
        $SkewErr = (Invoke-Native aws @("sts", "get-caller-identity", "--profile", $AwsProfile) -CaptureStderr).Output -join " "
        # Only the time-specific messages mean a skew. A bare SignatureDoesNotMatch
        # also covers wrong credentials.
        if ($SkewErr -match "Signature not yet current|Signature expired|RequestTimeTooSkewed") {
            Write-Host "  This machine's clock is too far from AWS for request signing to work." -ForegroundColor Yellow
            Write-Host "  Fix the clock, then re-run this script: net start w32time; w32tm /resync /force" -ForegroundColor Yellow
            Write-Host "  AWS said: $SkewErr" -ForegroundColor Yellow
        } elseif (-not $SsoOk) {
            Write-Host "  Run: aws sso login --profile $AwsProfile, then re-run this script." -ForegroundColor Yellow
        } else {
            Write-Host "  Your role may lack codecommit:GitPull or kms:Decrypt. Ask in #it-help with this message." -ForegroundColor Yellow
        }
    } elseif ($ErrorText -match "could not read Username|terminal prompts disabled") {
        Write-Host "  The AWS credential helper returned no credentials." -ForegroundColor Yellow
        Write-Host "  Check that profile $AwsProfile exists and that aws is on PATH." -ForegroundColor Yellow
    } elseif ($ErrorText -match "(?i)repository.*not found") {
        Write-Host "  Repository not found. Expected: $RepoUrl" -ForegroundColor Yellow
    }
    # Always show git's own message, whichever branch ran. Replacing it with fixed
    # advice hid the real cause.
    Write-Host "  git reported: $ErrorText" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  Any marketplace already on this machine was left untouched, so /plugin keeps" -ForegroundColor Yellow
    Write-Host "  working from its last sync. Re-run this script once the above is fixed." -ForegroundColor Yellow
    exit 1
}
