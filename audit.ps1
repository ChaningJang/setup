#Requires -Version 5.1
#
# Irrational Labs - OFFBOARDING AUDIT (read-only)  [Windows]
# Created: 2026-08-25
# PowerShell port of audit.sh. Same promises, Windows paths.
#
# ============================================================================
#  WHAT THIS SCRIPT DOES
#    It looks at your machine and prints a report of what the Irrational Labs
#    setup script (bootstrap.ps1) may have put there, so a human can decide
#    what should actually be removed. That is all it does.
#
#  WHAT THIS SCRIPT DOES NOT DO - no exceptions
#    * It does not install anything.
#    * It does not uninstall or remove anything.
#    * It does not create, delete, move, or edit a single file or directory.
#      It does not even run New-Item. It writes nothing to disk at all -
#      the report goes to your terminal. If you want it in a file, YOU
#      redirect it:   .\audit.ps1 > $HOME\il-audit.txt
#    * It does not write to the registry. It only reads one value.
#    * It does not change any environment variable that outlives this script.
#    * It does not log in, log out, or touch any credential.
#    * It makes no network requests. Nothing is uploaded anywhere.
#
#  HOW YOU CAN CHECK THAT FOR YOURSELF
#    Every PowerShell command that can write is absent from this file. Search
#    it and see: Set-Content, Add-Content, Out-File, New-Item, Remove-Item,
#    Move-Item, Copy-Item, Rename-Item, Set-ItemProperty, New-ItemProperty,
#    Remove-ItemProperty, Export-*, Tee-Object, .Save(), [IO.File]::Write*,
#    and the > and >> redirection operators. None of them appear below.
#    The only exception is that this script sets two variables INSIDE its own
#    process (GIT_OPTIONAL_LOCKS and GIT_TERMINAL_PROMPT, see below); those
#    vanish the moment it exits and are never persisted to your user account.
#
#  WHAT IT DELIBERATELY NEVER PRINTS
#    * The CONTENTS of any credential, token, API key, .env file, or SSH key.
#      It reports only that such a file EXISTS and where. Never its value.
#    * The contents of your PowerShell profiles, your settings.json, or your
#      repos.
#    * Your email addresses in full (they are masked, e.g. e****@x.com).
#    * Environment variable values, except one harmless setting we need to
#      see (GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND). Everything else: names only.
#    On top of that, every line of output is passed through a scrubber that
#    blanks anything shaped like a secret (GitHub tokens, sk- keys, Slack xox
#    tokens, Google AIza keys, PEM private-key headers, bearer tokens) before
#    it reaches your screen.
#
#  ONE HONEST FOOTNOTE
#    To tell you whether you have unsaved work in an IL repo, it runs git
#    read commands inside repos you already have. Git is invoked with
#    GIT_OPTIONAL_LOCKS=0, which tells git not to take locks or update its
#    index cache, so .git\index is not rewritten. No file in your repos is
#    changed.
#
#  You are meant to read this before running it. Please do.
#  Then send the output back - it is safe to paste.
# ============================================================================

# No 'throw on error' policy: a failed probe should degrade to "UNKNOWN",
# never abort the report.
$ErrorActionPreference = 'SilentlyContinue'

# Process-local only. These die with the script; nothing is persisted.
# GIT_OPTIONAL_LOCKS=0 is the whole point: it stops git rewriting .git\index.
# GIT_TERMINAL_PROMPT=0 means git can never block asking for a password.
$env:GIT_OPTIONAL_LOCKS = '0'
$env:GIT_TERMINAL_PROMPT = '0'

# ---------------------------------------------------------------------------
# Output plumbing
# ---------------------------------------------------------------------------

# Every externally-sourced string goes through here. Patterns match audit.sh's
# screen list, widened to the whole token family rather than just gho_.
function Protect-Secret {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return '' }
    $t = $Text
    $t = [regex]::Replace($t, 'gh[pousr]_[A-Za-z0-9]{6,}',        'gh*_***REDACTED***')
    $t = [regex]::Replace($t, 'github_pat_[A-Za-z0-9_]{6,}',      'github_pat_***REDACTED***')
    $t = [regex]::Replace($t, 'sk-[A-Za-z0-9_\-]{12,}',           'sk-***REDACTED***')
    $t = [regex]::Replace($t, 'xox[abprse]-[A-Za-z0-9\-]{6,}',    'xox*-***REDACTED***')
    $t = [regex]::Replace($t, 'AIza[A-Za-z0-9_\-]{10,}',          'AIza***REDACTED***')
    $t = [regex]::Replace($t, '-----BEGIN[A-Z ]*PRIVATE KEY-----','***PRIVATE KEY HEADER REDACTED***')
    $t = [regex]::Replace($t, '(?i)\bbearer\s+[A-Za-z0-9._\-]{8,}','Bearer ***REDACTED***')
    $t = [regex]::Replace($t, '(?i)\b(ya29|1//)[A-Za-z0-9._\-]{10,}','***OAUTH TOKEN REDACTED***')
    return $t
}

# Write-Output, not Write-Host, so that `.\audit.ps1 > file` actually captures
# the report if the reader chooses to redirect it. The script never redirects.
function Write-Line {
    param([string]$Text = '')
    Write-Output (Protect-Secret $Text)
}

function Write-Header {
    param([string]$Text)
    Write-Line ''
    Write-Line '=============================================================='
    Write-Line $Text
    Write-Line '=============================================================='
}

function Write-Sub {
    param([string]$Text)
    Write-Line ''
    Write-Line "-- $Text"
}

function Write-Item {
    param([string]$Text = '')
    Write-Line "   $Text"
}

$script:NRemove   = 0
$script:NKeep     = 0
$script:NUnknown  = 0
$script:NWorkLoss = 0

function Write-Tag {
    param([string]$Verdict, [string]$Text)
    switch ($Verdict) {
        'REMOVE'  { $script:NRemove  = $script:NRemove  + 1 }
        'KEEP'    { $script:NKeep    = $script:NKeep    + 1 }
        'UNKNOWN' { $script:NUnknown = $script:NUnknown + 1 }
    }
    Write-Line ("   [{0,-7}] {1}" -f $Verdict, $Text)
}

# Mask an email so it is legible but not harvestable: alice@x.com -> a****@x.com
function ConvertTo-MaskedEmail {
    param([string]$Address)
    if ([string]::IsNullOrWhiteSpace($Address)) { return '(none)' }
    if ($Address -notmatch '@') { return '(masked)' }
    $parts = $Address.Split('@')
    $local = $parts[0]
    if ($local.Length -lt 1) { return '(masked)' }
    return ('{0}****@{1}' -f $local.Substring(0,1), $parts[-1])
}

# ---------------------------------------------------------------------------
# Platform guard - refuse to produce a report anywhere but Windows
# ---------------------------------------------------------------------------
# audit.sh banners loudly when it is not on Darwin. This script goes further
# and stops, because every path below is a Windows path: on macOS or Linux the
# report would be uniformly empty and could be misread as "nothing installed".

$onWindows = $true
if (Test-Path 'Variable:\IsWindows') {
    $onWindows = [bool](Get-Variable -Name IsWindows -ValueOnly)
} elseif ($env:OS -ne 'Windows_NT') {
    $onWindows = $false
}

if (-not $onWindows) {
    Write-Line ''
    Write-Line '##############################################################'
    Write-Line '##  STOP - THIS IS THE WINDOWS AUDIT AND YOU ARE NOT ON     ##'
    Write-Line '##  WINDOWS. NO REPORT WAS PRODUCED.                        ##'
    Write-Line '##############################################################'
    Write-Line ''
    Write-Item "Detected platform: $([System.Environment]::OSVersion.VersionString)"
    Write-Item ''
    Write-Item 'Every check in this script looks at a Windows-only location'
    Write-Item '(%LOCALAPPDATA%, %APPDATA%, winget, scoop, the PowerShell'
    Write-Item 'profile, the User environment block). On this machine they'
    Write-Item 'would all come back empty, and an empty report reads exactly'
    Write-Item 'like a clean machine. That would be worse than no report.'
    Write-Item ''
    Write-Item 'On macOS or Linux, run the shell version instead:  bash audit.sh'
    Write-Line ''
    exit 2
}

# ---------------------------------------------------------------------------
# Environment discovery
# ---------------------------------------------------------------------------

$UserHome = $env:USERPROFILE
if ([string]::IsNullOrWhiteSpace($UserHome)) { $UserHome = $HOME }

# Traced to bootstrap.ps1 line 46: Join-Path $env:LOCALAPPDATA "il-setup\receipt.json"
$ReceiptPath = $env:IL_SETUP_RECEIPT
if ([string]::IsNullOrWhiteSpace($ReceiptPath)) {
    $ReceiptPath = Join-Path $env:LOCALAPPDATA 'il-setup\receipt.json'
}

$script:Receipt      = $null
$script:HaveReceipt  = $false
$script:ReceiptTime  = $null
if (Test-Path -LiteralPath $ReceiptPath -PathType Leaf) {
    try {
        $script:Receipt = (Get-Content -LiteralPath $ReceiptPath -Raw) | ConvertFrom-Json
        $script:HaveReceipt = ($null -ne $script:Receipt)
        $script:ReceiptTime = (Get-Item -LiteralPath $ReceiptPath -Force).LastWriteTime
    } catch {
        $script:Receipt = $null
        $script:HaveReceipt = $false
    }
}

function Get-ReceiptField {
    param([string]$Name, $Default = $null)
    if (-not $script:HaveReceipt) { return $Default }
    if ($script:Receipt.PSObject.Properties.Name -contains $Name) {
        $v = $script:Receipt.$Name
        if ($null -eq $v) { return $Default }
        return $v
    }
    return $Default
}

function Test-CommandPresent {
    param([string]$Name)
    return [bool](Get-Command -Name $Name -ErrorAction SilentlyContinue)
}

function Get-CommandPath {
    param([string]$Name)
    $c = Get-Command -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $c) { return '' }
    if ($c.Path) { return $c.Path }
    return $c.Name
}

function Get-FileDateString {
    param([string]$Path)
    try { return (Get-Item -LiteralPath $Path -Force).LastWriteTime.ToString('yyyy-MM-dd') }
    catch { return '?' }
}

function Get-FileTime {
    param([string]$Path)
    try { return (Get-Item -LiteralPath $Path -Force).LastWriteTime }
    catch { return $null }
}

$script:HasGit = Test-CommandPresent 'git'

# All git invocations funnel through here so GIT_OPTIONAL_LOCKS discipline and
# error swallowing are applied in exactly one place.
function Get-GitOutput {
    param([string]$RepoPath, [string[]]$GitArgs)
    # The leading comma matters: PowerShell unrolls a one-element array on
    # return, so without it a single line of git output comes back as a plain
    # string and $o[0] is its first CHARACTER, not the line. That silently made
    # every origin URL read as "h" and every repo look non-IL.
    if (-not $script:HasGit) { return ,@() }
    try {
        $out = & git --no-pager -C $RepoPath @GitArgs 2>$null
        if ($null -eq $out) { return ,@() }
        return ,@($out)
    } catch { return ,@() }
}

# ---- package-manager inventories (read-only, gathered once) ----------------

# winget: deliberately NOT passed --accept-source-agreements, because accepting
# a source agreement PERSISTS that acceptance to winget's own config - a write.
# --disable-interactivity makes winget fail fast instead of hanging on a prompt.
# If it fails we mark things UNKNOWN rather than guessing, and we do NOT retry
# with a bare `winget list`, because that one can block waiting for input.
$script:WingetList = @()
$script:WingetOk = $false
if (Test-CommandPresent 'winget') {
    try {
        $wl = & winget list --disable-interactivity 2>$null
        if ($LASTEXITCODE -eq 0 -and $wl) {
            $script:WingetList = @($wl)
            $script:WingetOk = $true
        }
    } catch { $script:WingetOk = $false }
}

function Test-WingetHasId {
    param([string]$Id)
    if (-not $script:WingetOk) { return $false }
    foreach ($line in $script:WingetList) {
        if ($line -match [regex]::Escape($Id)) { return $true }
    }
    return $false
}

# scoop: read the install root off disk rather than shelling out, so nothing
# can trigger a bucket refresh. Root is $env:SCOOP or the documented default.
$script:ScoopRoot = $env:SCOOP
if ([string]::IsNullOrWhiteSpace($script:ScoopRoot)) {
    $script:ScoopRoot = Join-Path $UserHome 'scoop'
}
$script:ScoopApps = @()
$script:ScoopOk = $false
$scoopAppsDir = Join-Path $script:ScoopRoot 'apps'
if (Test-Path -LiteralPath $scoopAppsDir -PathType Container) {
    try {
        $script:ScoopApps = @(Get-ChildItem -LiteralPath $scoopAppsDir -Directory -ErrorAction SilentlyContinue |
                              ForEach-Object { $_.Name })
        $script:ScoopOk = $true
    } catch { $script:ScoopOk = $false }
}

function Test-ScoopHasApp {
    param([string]$Name)
    if (-not $script:ScoopOk) { return $false }
    return ($script:ScoopApps -contains $Name)
}

function Test-ReceiptClaimsPackage {
    param([string]$Id)
    $f = Get-ReceiptField 'formulae_installed_by_us' @()
    return (@($f) -contains $Id)
}

# Verdict for a shared tool: IL put it here, it predates IL, or we cannot tell.
# Returns a two-element array: verdict, evidence.
function Get-Provenance {
    param([string]$PackageId, [string]$Path, [string]$Manager)

    if (-not $script:HaveReceipt) {
        return @('UNKNOWN', 'no receipt on this machine - cannot attribute')
    }

    if (Test-ReceiptClaimsPackage $PackageId) {
        # A receipt claim is only trustworthy if the package manager still
        # agrees. If the receipt says IL installed it but the manager has no
        # such package, the binary on PATH came from somewhere else and
        # removing it would be wrong.
        if ($Manager -eq 'winget') {
            if (-not $script:WingetOk) {
                return @('UNKNOWN', "receipt says IL setup installed it (winget id $PackageId), but winget could not be queried without an interactive prompt - unverified")
            }
            if (Test-WingetHasId $PackageId) {
                return @('REMOVE', "receipt says IL setup installed it, and winget still lists $PackageId")
            }
            return @('UNKNOWN', "receipt claims IL installed $PackageId but winget does NOT list it - stale receipt; the binary at this path came from somewhere else")
        }
        if ($Manager -eq 'scoop') {
            if (-not $script:ScoopOk) {
                return @('UNKNOWN', "receipt says IL setup installed it (scoop app $PackageId), but no scoop install was found at $($script:ScoopRoot) - unverified")
            }
            if (Test-ScoopHasApp $PackageId) {
                return @('REMOVE', "receipt says IL setup installed it, and scoop still has $PackageId")
            }
            return @('UNKNOWN', "receipt claims IL installed scoop app $PackageId but it is not under $scoopAppsDir - stale receipt")
        }
        return @('REMOVE', 'receipt says IL setup installed it')
    }

    $pt = Get-FileTime $Path
    if ($null -ne $pt -and $null -ne $script:ReceiptTime -and $pt -lt $script:ReceiptTime) {
        return @('KEEP', "predates the IL receipt (installed $(Get-FileDateString $Path)) - yours, not ours")
    }
    return @('KEEP', 'receipt does not claim it - IL setup found it already present')
}

# ---------------------------------------------------------------------------
# Repo discovery (shared by section 2 and section 5)
# ---------------------------------------------------------------------------
# Windows-specific hazard: %USERPROFILE% is littered with junctions
# ("Application Data", "My Documents", "Local Settings") that loop back on
# themselves. Recursing through them never terminates, so reparse points are
# skipped explicitly. OneDrive and AppData are skipped for speed.

$script:SkipTopLevel = @(
    'AppData','Application Data','Local Settings',
    'NetHood','PrintHood','Recent','SendTo','Cookies','Templates',
    'Start Menu','My Documents','My Music','My Pictures','My Videos',
    'node_modules','scoop','.bun','.nuget','.cargo','.vscode',
    '$Recycle.Bin','Searches','Links','Contacts','Favorites'
)

function Get-CandidateRepo {
    $found = New-Object System.Collections.ArrayList

    if (Test-Path -LiteralPath (Join-Path $UserHome '.git') -PathType Container) {
        [void]$found.Add($UserHome)
    }

    $tops = @()
    try {
        $tops = @(Get-ChildItem -LiteralPath $UserHome -Directory -Force -ErrorAction SilentlyContinue |
                  Where-Object {
                      ($script:SkipTopLevel -notcontains $_.Name) -and
                      (-not ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) -and
                      ($_.Name -notlike 'OneDrive*')
                  })
    } catch { $tops = @() }

    foreach ($top in $tops) {
        if (Test-Path -LiteralPath (Join-Path $top.FullName '.git') -PathType Container) {
            [void]$found.Add($top.FullName)
            continue
        }
        $inner = @()
        try {
            # -Depth 2 under a top-level dir mirrors `find -maxdepth 4` in audit.sh.
            $inner = @(Get-ChildItem -LiteralPath $top.FullName -Directory -Force -Recurse -Depth 2 `
                          -Filter '.git' -ErrorAction SilentlyContinue |
                       Where-Object { $_.FullName -notmatch '\\node_modules\\' })
        } catch { $inner = @() }
        foreach ($g in $inner) {
            [void]$found.Add((Split-Path -Parent $g.FullName))
        }
        if ($found.Count -ge 60) { break }
    }

    # Leading comma: keep a single repo as a one-element array (see Get-GitOutput).
    return ,@($found | Select-Object -Unique | Select-Object -First 60)
}

function Get-RepoOrigin {
    param([string]$RepoPath)
    $o = Get-GitOutput $RepoPath @('remote','get-url','origin')
    if ($o.Count -eq 0) { return '' }
    return ($o[0] | Out-String).Trim()
}

function Test-IlOrigin {
    param([string]$Url)
    if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
    return ($Url -match '(?i)irrationallabs')
}

$script:AllRepos = Get-CandidateRepo
$StandardIlRepos = @('irrational_labs_hq','marketing_HQ','IL-experiments')

# ---------------------------------------------------------------------------
# Header
# ---------------------------------------------------------------------------
Write-Line 'IRRATIONAL LABS - OFFBOARDING AUDIT (read-only; nothing was changed)'
Write-Line "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm K')"
Write-Line "Machine:   $([System.Environment]::OSVersion.VersionString) / $env:PROCESSOR_ARCHITECTURE"
Write-Line "Shell:     PowerShell $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))"
Write-Line 'Script:    audit.ps1 (inspect-only)'

# ---------------------------------------------------------------------------
Write-Header '1. THE SETUP RECEIPT  (what the uninstaller depends on)'
if (-not $script:HaveReceipt) {
    Write-Item "NOT FOUND at $ReceiptPath"
    Write-Item ''
    Write-Item '>> This is the important case. Without a receipt the uninstaller cannot'
    Write-Item '>> tell IL-installed tools from your own, and its fallback behaviour is'
    Write-Item '>> to guess. Everything below is therefore marked UNKNOWN rather than'
    Write-Item '>> assumed safe to remove. Do not run the uninstaller on this machine'
    Write-Item '>> until a human has read this report.'
    Write-Item ''
    Write-Item 'Most likely reasons: you never ran the IL bootstrap script; or you ran'
    Write-Item 'it before receipts existed; or bootstrap.ps1 failed before it got as'
    Write-Item 'far as writing one.'
    $script:NUnknown = $script:NUnknown + 1
} else {
    Write-Item "Found:        $ReceiptPath"
    $rsize = 0
    try { $rsize = (Get-Item -LiteralPath $ReceiptPath -Force).Length } catch { $rsize = 0 }
    Write-Item "Written:      $(Get-FileDateString $ReceiptPath)  (size $rsize bytes)"
    Write-Item "Schema:       $(Get-ReceiptField 'schema_version' 'unknown')"
    Write-Item "Bun installed by IL:         $(Get-ReceiptField 'bun_installed_by_us' $false)"
    Write-Item "Claude Code installed by IL: $(Get-ReceiptField 'claude_code_installed_by_us' $false)"
    Write-Item "gws CLI installed by IL:     $(Get-ReceiptField 'gws_cli_installed_by_us' $false)"
    Write-Item "gws env var set by IL:       $(Get-ReceiptField 'gws_env_set_by_us' $false)"
    Write-Item "gh was logged in BEFORE IL:  $(Get-ReceiptField 'gh_was_authenticated_before' $false)"

    $prior = Get-ReceiptField 'git_identity_prior' $null
    $priorName = '(none)'; $priorEmail = ''
    if ($null -ne $prior) {
        if ($prior.name)  { $priorName  = $prior.name }
        if ($prior.email) { $priorEmail = $prior.email }
    }
    Write-Item "Prior git identity:          $priorName <$(ConvertTo-MaskedEmail $priorEmail)>"

    $pkgs = @(Get-ReceiptField 'formulae_installed_by_us' @())
    if ($pkgs.Count -eq 0) { Write-Item 'Packages IL installed:       (none)' }
    else { Write-Item "Packages IL installed:       $($pkgs -join ', ')" }

    $edits = @(Get-ReceiptField 'path_edits' @())
    if ($edits.Count -eq 0) { Write-Item 'Profile files IL edited:     (none)' }
    else { Write-Item "Profile files IL edited:     $($edits -join ', ')" }

    Write-Sub 'Receipt vs. reality - does the receipt still match this machine?'
    $stale = 0
    foreach ($r in @(Get-ReceiptField 'repos_cloned' @())) {
        if (-not $r.path) { continue }
        if (Test-Path -LiteralPath $r.path -PathType Container) {
            Write-Item "OK      repo still present: $($r.path)"
        } else {
            Write-Item "STALE   receipt lists a repo that is GONE: $($r.path)"
            $stale = $stale + 1
        }
    }
    foreach ($p in $pkgs) {
        if (Test-WingetHasId $p) { Write-Item "OK      winget still lists: $p"; continue }
        if (Test-ScoopHasApp $p) { Write-Item "OK      scoop still has:    $p"; continue }
        if (-not $script:WingetOk -and -not $script:ScoopOk) {
            Write-Item "?       cannot verify '$p' - neither winget nor scoop could be queried"
            continue
        }
        Write-Item "STALE   receipt claims IL installed '$p' but no package manager reports it"
        $stale = $stale + 1
    }
    if ($stale -eq 0) {
        Write-Item 'Receipt appears consistent with what is on disk.'
    } else {
        Write-Item ">> $stale stale entr(y/ies). The receipt is out of date; treat its claims with care."
    }
}

# ---------------------------------------------------------------------------
Write-Header '2. IL-SPECIFIC FOOTPRINT  (things that exist because of Irrational Labs)'

Write-Sub 'IL repositories'
# Traced to bootstrap.ps1 line 697: $target = "$HOME\$($entry.dir)"
foreach ($d in $StandardIlRepos) {
    $t = Join-Path $UserHome $d
    if (Test-Path -LiteralPath (Join-Path $t '.git') -PathType Container) {
        Write-Tag 'REMOVE' "IL repo: $t"
        Write-Item "          origin: $(Get-RepoOrigin $t)"
        Write-Item "          cloned/modified: $(Get-FileDateString $t)"
    } elseif (Test-Path -LiteralPath $t) {
        Write-Tag 'UNKNOWN' "$t exists but is not a git repo - do NOT let anything delete this"
    }
}

Write-Sub 'Any other repo on this machine pointing at the IL GitHub org'
$otherIl = 0
foreach ($r in $script:AllRepos) {
    $leaf = Split-Path -Leaf $r
    if ($StandardIlRepos -contains $leaf) { continue }
    $u = Get-RepoOrigin $r
    if (-not (Test-IlOrigin $u)) { continue }
    Write-Tag 'REMOVE' "IL-org repo not in the standard list: $r"
    Write-Item "          origin: $u"
    $otherIl = $otherIl + 1
}
if ($otherIl -eq 0) { Write-Item 'None beyond the standard list above.' }
Write-Item "(Scanned $($script:AllRepos.Count) git repo(s) under $UserHome, four levels deep.)"

Write-Sub 'gws (Google Workspace CLI) - IL Google access'
# Traced to bootstrap.ps1 line 543: npm install -g '@googleworkspace/cli'
if (Test-CommandPresent 'gws') {
    Write-Tag 'REMOVE' "gws CLI installed at $(Get-CommandPath 'gws')"
} else {
    Write-Item 'gws CLI: not installed.'
}

# bootstrap.ps1 never sets GOOGLE_WORKSPACE_CLI_CONFIG_DIR, so the config
# location on Windows is not traceable to a line in it. We probe the plausible
# spots and report only what actually exists; if nothing is found we say
# UNKNOWN rather than assert a path we cannot back up.
$gwsCandidates = @()
if ($env:GOOGLE_WORKSPACE_CLI_CONFIG_DIR) { $gwsCandidates += $env:GOOGLE_WORKSPACE_CLI_CONFIG_DIR }
$gwsCandidates += (Join-Path $env:APPDATA 'gws')
$gwsCandidates += (Join-Path $env:LOCALAPPDATA 'gws')
$gwsCandidates += (Join-Path $UserHome '.config\gws')
$gwsFound = 0
foreach ($g in $gwsCandidates) {
    if ([string]::IsNullOrWhiteSpace($g)) { continue }
    if (-not (Test-Path -LiteralPath $g -PathType Container)) { continue }
    $gwsFound = $gwsFound + 1
    Write-Tag 'REMOVE' "gws config directory exists: $g  (modified $(Get-FileDateString $g))"
    $cred = Join-Path $g 'credentials.enc'
    if (Test-Path -LiteralPath $cred -PathType Leaf) {
        $csz = 0
        try { $csz = (Get-Item -LiteralPath $cred -Force).Length } catch { $csz = 0 }
        Write-Item "          credentials.enc EXISTS ($csz bytes)."
        Write-Item '          >> This is a live Google login. Contents NOT shown and never will be.'
        Write-Item '          >> Offboarding must revoke this.'
    } else {
        Write-Item '          no credentials.enc - not currently signed in.'
    }
}
if ($gwsFound -eq 0) {
    if (Test-CommandPresent 'gws') {
        Write-Tag 'UNKNOWN' 'gws CLI is installed but no config dir was found in any probed location'
        Write-Item '          probed: %APPDATA%\gws, %LOCALAPPDATA%\gws, ~\.config\gws'
        Write-Item '          bootstrap.ps1 never pins GOOGLE_WORKSPACE_CLI_CONFIG_DIR, so the'
        Write-Item '          real path on Windows cannot be derived from it. A human should'
        Write-Item '          check where this install keeps its credentials before removal.'
    } else {
        Write-Item 'No gws config directory in any probed location.'
    }
}

# Traced to bootstrap.ps1 line 456: SetEnvironmentVariable(..., "User")
Write-Sub 'gws keyring guard (a PERSISTENT user environment variable)'
$kbUser = [Environment]::GetEnvironmentVariable('GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND','User')
$kbProc = $env:GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND
if ($kbUser) {
    Write-Tag 'REMOVE' "User env var GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND is set to '$kbUser'"
    Write-Item '          >> This is Windows-only: on macOS the same setting lives in a'
    Write-Item '          >> shell file. Here it is in your account environment block and'
    Write-Item '          >> survives every reboot until it is explicitly cleared.'
} else {
    Write-Item 'Not set for your user account.'
}
Write-Item "In this process: $(if ($kbProc) { $kbProc } else { '(not set)' })"

# Traced to bootstrap.ps1 lines 415-422: bun bin added to the User PATH
Write-Sub 'Bun global bin on your persistent user PATH'
$bunBin = Join-Path $UserHome '.bun\bin'
$userPath = [Environment]::GetEnvironmentVariable('Path','User')
if ($userPath -and $userPath -like "*$bunBin*") {
    Write-Tag 'REMOVE' "Your User PATH contains $bunBin (added by IL setup)"
    Write-Item '          >> Removing this entry is safe only if nothing else you use'
    Write-Item '          >> lives in ~\.bun\bin. Claude Code may - see section 4.'
} elseif (Test-Path -LiteralPath $bunBin -PathType Container) {
    Write-Item "$bunBin exists but is not on your persistent User PATH."
} else {
    Write-Item 'No bun global bin directory.'
}
if (Test-Path -LiteralPath $bunBin -PathType Container) {
    $bnames = @(Get-ChildItem -LiteralPath $bunBin -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    Write-Item "          contents (names only, $($bnames.Count) item(s)): $($bnames -join ', ')"
}

# Traced to bootstrap.ps1 lines 465-490: $claudeDir = "$HOME\.claude"
Write-Sub 'IL Claude Code plugin registration (~\.claude\settings.json)'
$settingsPath = Join-Path $UserHome '.claude\settings.json'
if (Test-Path -LiteralPath $settingsPath -PathType Leaf) {
    Write-Item "settings.json present ($(Get-FileDateString $settingsPath)). Checking only for IL keys; nothing else is read out."
    $settings = $null
    try { $settings = (Get-Content -LiteralPath $settingsPath -Raw) | ConvertFrom-Json } catch { $settings = $null }
    if ($null -eq $settings) {
        Write-Tag 'UNKNOWN' 'settings.json exists but could not be parsed as JSON - cannot inspect keys safely'
    } else {
        $mk = $settings.extraKnownMarketplaces
        if ($null -ne $mk -and ($mk.PSObject.Properties.Name -contains 'irrational-labs-plugins')) {
            Write-Tag 'REMOVE' 'IL key present in settings.json: extraKnownMarketplaces["irrational-labs-plugins"]'
        }
        $ep = $settings.enabledPlugins
        if ($null -ne $ep) {
            foreach ($p in @('gws@irrational-labs-plugins','il-slides@irrational-labs-plugins','key-behavior@irrational-labs-plugins')) {
                if ($ep.PSObject.Properties.Name -contains $p) {
                    Write-Tag 'REMOVE' "IL key present in settings.json: enabledPlugins[`"$p`"]"
                }
            }
        }
        $ev = $settings.env
        if ($null -ne $ev -and ($ev.PSObject.Properties.Name -contains 'GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND')) {
            Write-Tag 'REMOVE' 'IL key present in settings.json: env.GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND'
        }
        Write-Item "Total top-level keys in settings.json: $(@($settings.PSObject.Properties.Name).Count) (names not printed)"
    }
} else {
    Write-Item 'No ~\.claude\settings.json.'
}

# Traced to bootstrap.ps1 lines 121-128 (Add-IlPathBlock) and 417
# ($PROFILE.CurrentUserAllHosts). The OneDrive-redirected Documents folder is
# checked too, because Documents is commonly redirected on managed Windows and
# $PROFILE then points somewhere other than %USERPROFILE%\Documents.
Write-Sub 'il-setup blocks written into your PowerShell profiles'
$profilePaths = New-Object System.Collections.ArrayList
if ($null -ne $PROFILE) {
    foreach ($n in @('CurrentUserAllHosts','CurrentUserCurrentHost','AllUsersAllHosts','AllUsersCurrentHost')) {
        $v = $PROFILE.$n
        if ($v) { [void]$profilePaths.Add($v) }
    }
}
foreach ($docRoot in @((Join-Path $UserHome 'Documents'), $env:OneDrive)) {
    if ([string]::IsNullOrWhiteSpace($docRoot)) { continue }
    foreach ($sub in @('WindowsPowerShell','PowerShell','Documents\WindowsPowerShell','Documents\PowerShell')) {
        foreach ($f in @('profile.ps1','Microsoft.PowerShell_profile.ps1')) {
            [void]$profilePaths.Add((Join-Path $docRoot (Join-Path $sub $f)))
        }
    }
}
$profileHits = 0
foreach ($p in @($profilePaths | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
    $marks = @(Select-String -LiteralPath $p -SimpleMatch '# >>> il-setup >>>' -ErrorAction SilentlyContinue)
    if ($marks.Count -gt 0) {
        Write-Tag 'REMOVE' "$p contains $($marks.Count) il-setup block(s)"
        foreach ($m in $marks) { Write-Item "             marker at line $($m.LineNumber)" }
        $total = @(Get-Content -LiteralPath $p -ErrorAction SilentlyContinue).Count
        Write-Item "          (the file has $total lines total; its contents are not printed)"
        $profileHits = $profileHits + 1
    }
}
if ($profileHits -eq 0) { Write-Item 'No il-setup blocks found in any PowerShell profile.' }

# Traced to bootstrap.ps1 lines 267 and 277 - settings bootstrap.ps1 changed
# that the uninstaller does not reverse.
Write-Sub 'Long-path settings that bootstrap.ps1 changes'
$lp = (Get-GitOutput $UserHome @('config','--global','core.longpaths'))
$lpVal = ''
if ($lp.Count -gt 0) { $lpVal = ($lp[0] | Out-String).Trim() }
if ($lpVal -eq 'true') {
    Write-Tag 'UNKNOWN' 'git core.longpaths=true is set globally - bootstrap.ps1 sets this'
    Write-Item '          >> Harmless to leave. It is listed only so the report is complete;'
    Write-Item '          >> reverting it can break other deep-path repos you keep.'
} else {
    Write-Item "git core.longpaths: $(if ($lpVal) { $lpVal } else { '(unset)' })"
}
$lpReg = $null
try {
    $lpReg = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' `
                -Name 'LongPathsEnabled' -ErrorAction SilentlyContinue).LongPathsEnabled
} catch { $lpReg = $null }
Write-Item "HKLM LongPathsEnabled (read only, never written here): $(if ($null -ne $lpReg) { $lpReg } else { '(unset)' })"
Write-Item '          >> Machine-wide OS setting. Leave it. It affects every app, not IL.'

# Read off disk, NOT via `gh auth status`: running gh at all writes
# ~\.local\state\gh\device-id on first use (caught by CI). gh keeps its login
# in hosts.yml under $env:GH_CONFIG_DIR or %APPDATA%\GitHub CLI. Only the
# github.com user handle is printed; the token line is never read out (and the
# scrubber would blank it anyway).
Write-Sub 'GitHub CLI login (read from hosts.yml, gh is not run)'
$ghConfigDir = $env:GH_CONFIG_DIR
if ([string]::IsNullOrWhiteSpace($ghConfigDir)) { $ghConfigDir = Join-Path $env:APPDATA 'GitHub CLI' }
$ghHosts = Join-Path $ghConfigDir 'hosts.yml'
if (Test-CommandPresent 'gh') {
    $ghUser = ''
    $ghLoggedIn = $false
    if (Test-Path -LiteralPath $ghHosts -PathType Leaf) {
        $inGithub = $false
        foreach ($l in @(Get-Content -LiteralPath $ghHosts -ErrorAction SilentlyContinue)) {
            if ($l -match '^github\.com:') { $inGithub = $true; $ghLoggedIn = $true; continue }
            if ($l -match '^\S') { $inGithub = $false; continue }
            if ($inGithub -and $l -match '^\s+user:\s*(\S+)') { $ghUser = $Matches[1] }
        }
    }
    if ($ghLoggedIn) {
        Write-Item "gh: github.com entry present in $ghHosts$(if ($ghUser) { " (user $ghUser)" })"
        $ghBefore = Get-ReceiptField 'gh_was_authenticated_before' $null
        if ($ghBefore -eq $true) {
            Write-Tag 'KEEP' 'You were already signed into GitHub before IL setup - this login is YOURS'
        } elseif ($script:HaveReceipt) {
            Write-Tag 'REMOVE' 'GitHub login was established by IL setup'
        } else {
            Write-Tag 'UNKNOWN' 'GitHub login present, no receipt - cannot tell if IL created it. Default: KEEP.'
        }
        Write-Item '          >> Either way, the durable offboarding step is removing you from'
        Write-Item '          >> the IrrationalLabs-team GitHub org, which is done server-side.'
    } else {
        Write-Item "gh installed but no github.com login in $ghHosts."
    }
} else {
    Write-Item 'gh not installed.'
}

Write-Sub 'Global git identity (what your commits are signed with right now)'
$gn = Get-GitOutput $UserHome @('config','--global','user.name')
$ge = Get-GitOutput $UserHome @('config','--global','user.email')
$gnv = '(unset)'; $gev = ''
if ($gn.Count -gt 0) { $gnv = ($gn[0] | Out-String).Trim() }
if ($ge.Count -gt 0) { $gev = ($ge[0] | Out-String).Trim() }
Write-Item "name:  $gnv"
Write-Item "email: $(ConvertTo-MaskedEmail $gev)"
if ($script:HaveReceipt) {
    $prior = Get-ReceiptField 'git_identity_prior' $null
    $pn = '(none)'; $pe = ''
    if ($null -ne $prior) {
        if ($prior.name)  { $pn = $prior.name }
        if ($prior.email) { $pe = $prior.email }
    }
    Write-Item "receipt says it was, before IL setup: $pn <$(ConvertTo-MaskedEmail $pe)>"
} else {
    Write-Tag 'UNKNOWN' 'no receipt - if IL setup overwrote your git identity, we cannot restore it automatically'
}

# The Windows analogue of launch agents / cron. bootstrap.ps1 creates NO
# scheduled task, so anything matching here was set up by hand and is UNKNOWN,
# not a removal candidate.
Write-Sub 'Scheduled tasks and startup items referencing IL or gws'
$taskHits = 0
$taskTotal = 0
try {
    $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue)
    $taskTotal = $tasks.Count
    foreach ($t in $tasks) {
        if ($t.TaskName -match '(?i)gws|irrational|il-setup') {
            Write-Tag 'UNKNOWN' "scheduled task: $($t.TaskName)  (path $($t.TaskPath))"
            Write-Item '          >> bootstrap.ps1 does not create scheduled tasks, so this was'
            Write-Item '          >> made by hand. A human must decide.'
            $taskHits = $taskHits + 1
        }
    }
} catch { $taskTotal = -1 }
if ($taskTotal -lt 0) {
    Write-Item 'Could not enumerate scheduled tasks on this machine.'
} elseif ($taskHits -eq 0) {
    Write-Item "No IL/gws scheduled tasks. ($taskTotal other tasks present; names not printed.)"
}
$startupDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
if (Test-Path -LiteralPath $startupDir -PathType Container) {
    $su = @(Get-ChildItem -LiteralPath $startupDir -File -ErrorAction SilentlyContinue)
    $suHits = @($su | Where-Object { $_.Name -match '(?i)gws|irrational|il-setup' })
    if ($suHits.Count -gt 0) {
        foreach ($s in $suHits) { Write-Tag 'UNKNOWN' "startup item: $($s.Name)" }
    } else {
        Write-Item "No IL/gws startup items. ($($su.Count) other startup item(s); names not printed.)"
    }
}

# Read off disk, NOT via `npm ls -g`: running npm at all writes files under the
# user's npm cache (_logs\*.log and _update-notifier-last-checked) - proven
# empirically. Traced to bootstrap.ps1 line 543: npm install -g with the default
# prefix, which on Windows is %APPDATA%\npm.
Write-Sub 'Globally installed npm packages (names only, read from %APPDATA%\npm)'
$npmGlobal = Join-Path $env:APPDATA 'npm\node_modules'
if (Test-Path -LiteralPath $npmGlobal -PathType Container) {
    $npmNames = New-Object System.Collections.ArrayList
    foreach ($d in @(Get-ChildItem -LiteralPath $npmGlobal -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($d.Name -like '@*') {
            foreach ($sd in @(Get-ChildItem -LiteralPath $d.FullName -Directory -ErrorAction SilentlyContinue)) {
                [void]$npmNames.Add("$($d.Name)/$($sd.Name)")
            }
        } elseif ($d.Name -ne '.bin') {
            [void]$npmNames.Add($d.Name)
        }
    }
    if ($npmNames.Count -eq 0) { Write-Item '(none)' }
    else { foreach ($n in ($npmNames | Select-Object -First 30)) { Write-Item $n } }
} elseif (Test-CommandPresent 'npm') {
    Write-Item "npm is installed but $npmGlobal does not exist - global prefix is not the default; not probed further."
} else {
    Write-Item 'npm not installed.'
}

# ---------------------------------------------------------------------------
Write-Header '3. SHARED DEVELOPER TOOLS  (IL setup can install these - but may not have)'
Write-Item 'For each: did IL put it here, or was it already yours? Evidence shown.'
Write-Item 'When we cannot tell, it says UNKNOWN. We do not guess.'
Write-Line ''

# Every entry below is traced to a specific bootstrap.ps1 line.
#   command | package id in the receipt | manager | bootstrap.ps1 line
$ToolMap = @(
    @{ Cmd='git';      Id='Git.Git';                        Mgr='winget'; Line=202 },
    @{ Cmd='git-lfs';  Id='GitHub.GitLFS';                  Mgr='winget'; Line=210 },
    @{ Cmd='gh';       Id='GitHub.cli';                     Mgr='winget'; Line=218 },
    @{ Cmd='node';     Id='OpenJS.NodeJS';                  Mgr='winget'; Line=235 },
    @{ Cmd='gswin64c'; Id='ArtifexSoftware.GhostScript';    Mgr='winget'; Line=649 },
    @{ Cmd='jq';       Id='jq';                             Mgr='scoop';  Line=226 },
    @{ Cmd='rg';       Id='ripgrep';                        Mgr='scoop';  Line=630 },
    @{ Cmd='fd';       Id='fd';                             Mgr='scoop';  Line=630 },
    @{ Cmd='bat';      Id='bat';                            Mgr='scoop';  Line=630 },
    @{ Cmd='fzf';      Id='fzf';                            Mgr='scoop';  Line=630 },
    @{ Cmd='delta';    Id='delta';                          Mgr='scoop';  Line=630 },
    @{ Cmd='ffmpeg';   Id='ffmpeg';                         Mgr='scoop';  Line=644 },
    @{ Cmd='exiftool'; Id='exiftool';                       Mgr='scoop';  Line=644 },
    @{ Cmd='yt-dlp';   Id='yt-dlp';                         Mgr='scoop';  Line=644 },
    @{ Cmd='pandoc';   Id='pandoc';                         Mgr='scoop';  Line=644 },
    @{ Cmd='magick';   Id='imagemagick';                    Mgr='scoop';  Line=644 },
    @{ Cmd='yq';       Id='yq';                             Mgr='scoop';  Line=644 },
    @{ Cmd='mlr';      Id='miller';                         Mgr='scoop';  Line=644 },
    @{ Cmd='sd';       Id='sd';                             Mgr='scoop';  Line=644 },
    @{ Cmd='gawk';     Id='gawk';                           Mgr='scoop';  Line=644 },
    @{ Cmd='eza';      Id='eza';                            Mgr='scoop';  Line=644 }
)

foreach ($t in $ToolMap) {
    if (-not (Test-CommandPresent $t.Cmd)) { continue }
    $pth = Get-CommandPath $t.Cmd
    $pr = Get-Provenance $t.Id $pth $t.Mgr
    Write-Tag $pr[0] "$($t.Cmd)  ($pth)"
    Write-Item "          $($pr[1])"
    Write-Item "          [bootstrap.ps1 line $($t.Line) installs this as $($t.Mgr) '$($t.Id)']"
}

Write-Sub 'Package managers'
if (Test-CommandPresent 'winget') {
    Write-Tag 'KEEP' "winget at $(Get-CommandPath 'winget') - ships with Windows; IL setup only used it"
    if (-not $script:WingetOk) {
        Write-Item '          >> NOTE: `winget list` could not be read non-interactively on this'
        Write-Item '          >> machine, so every winget provenance verdict above is UNKNOWN.'
    }
} else {
    Write-Item 'winget not available.'
}
# Traced to bootstrap.ps1 lines 169-185: bootstrap.ps1 installs Scoop if absent.
if ((Test-CommandPresent 'scoop') -or $script:ScoopOk) {
    Write-Tag 'UNKNOWN' "Scoop at $($script:ScoopRoot) - bootstrap.ps1 installs it when it is missing"
    Write-Item '          >> Removing Scoop removes EVERY scoop package on this machine,'
    Write-Item '          >> including ones that have nothing to do with IL. Human call.'
    Write-Item "          >> Installed scoop apps: $($script:ScoopApps.Count)."
    Write-Item '          >> The receipt does not record whether IL installed Scoop itself,'
    Write-Item '          >> only individual packages - so this cannot be attributed.'
} else {
    Write-Item 'Scoop not installed.'
}

Write-Sub 'Bun'
# Traced to bootstrap.ps1 lines 243-255.
if (Test-CommandPresent 'bun') {
    $bunByIl = Get-ReceiptField 'bun_installed_by_us' $false
    if ($bunByIl -eq $true) {
        Write-Tag 'REMOVE' "Bun (~\.bun) - receipt says IL setup installed it"
        Write-Item '          >> But see section 4: Claude Code may live in ~\.bun\bin.'
        Write-Item '          >> Removing Bun would take Claude Code with it. Human call.'
    } elseif ($script:HaveReceipt) {
        Write-Tag 'KEEP' "Bun at $(Get-CommandPath 'bun') - predates IL setup"
    } else {
        Write-Tag 'UNKNOWN' 'Bun present, no receipt - default KEEP'
    }
} else {
    Write-Item 'Bun not installed.'
}

# ---------------------------------------------------------------------------
Write-Header '4. KEEP  (yours - offboarding should not touch these)'
if (Test-CommandPresent 'claude') {
    $claudePath = Get-CommandPath 'claude'
    $claudeByIl = Get-ReceiptField 'claude_code_installed_by_us' $false
    if ($claudeByIl -eq $true) {
        Write-Tag 'KEEP' "Claude Code at $claudePath - receipt says IL installed it, but the standing instruction is KEEP."
    } else {
        Write-Tag 'KEEP' "Claude Code at $claudePath - yours, predates IL setup"
    }
    $cdir = Join-Path $UserHome '.claude'
    if (Test-Path -LiteralPath $cdir -PathType Container) {
        Write-Item "          ~\.claude config dir: present ($(Get-FileDateString $cdir)) - never removed"
    } else {
        Write-Item '          ~\.claude config dir: absent'
    }
    if ($claudePath -like "*$bunBin*") {
        Write-Item '          >> WARNING: this binary lives under ~\.bun\bin. Anything that'
        Write-Item '          >> removes Bun removes Claude Code too. See section 3.'
    }
} else {
    Write-Item 'Claude Code not installed.'
}
if (Test-CommandPresent 'gh') {
    Write-Tag 'KEEP' 'GitHub CLI binary - general-purpose tool, keep regardless of org access'
}
if (Test-CommandPresent 'winget') {
    Write-Tag 'KEEP' 'winget - Windows package manager, never an offboarding target'
}
$sshDir = Join-Path $UserHome '.ssh'
if (Test-Path -LiteralPath $sshDir -PathType Container) {
    $pubs = @(Get-ChildItem -LiteralPath $sshDir -Filter '*.pub' -File -ErrorAction SilentlyContinue)
    Write-Tag 'KEEP' "SSH keys: $($pubs.Count) public key(s) in ~\.ssh - personal, contents NEVER read"
}
$gitcfg = Join-Path $UserHome '.gitconfig'
if (Test-Path -LiteralPath $gitcfg -PathType Leaf) {
    Write-Tag 'KEEP' '~\.gitconfig - personal git config, only the IL-set identity should change'
}
$nonIl = 0
foreach ($r in $script:AllRepos) {
    if (Test-IlOrigin (Get-RepoOrigin $r)) { continue }
    $nonIl = $nonIl + 1
}
Write-Tag 'KEEP' "$nonIl non-IL git repo(s) under $UserHome - not an offboarding target, paths not printed"
Write-Item ''
Write-Item 'Also keep by default: every non-IL repo, every non-IL winget/scoop'
Write-Item 'package, your PowerShell profile, your editor, your dotfiles, and'
Write-Item 'anything not listed in section 2 above.'

# ---------------------------------------------------------------------------
Write-Header '5. !! UNSAVED WORK  - the only thing here that cannot be undone !!'
Write-Item 'Uninstalling deletes IL repo directories outright. Anything not committed'
Write-Item 'AND pushed is gone permanently. This is the section to read first.'
Write-Line ''
$anyRisk = 0
$totalUnpushed = 0
$totalUncommitted = 0
$ilRepoCount = 0
foreach ($r in $script:AllRepos) {
    $u = Get-RepoOrigin $r
    if (-not (Test-IlOrigin $u)) { continue }
    $ilRepoCount = $ilRepoCount + 1

    $status    = Get-GitOutput $r @('status','--porcelain')
    $dirty     = $status.Count
    $untracked = @($status | Where-Object { ($_ | Out-String).Trim().StartsWith('??') }).Count
    $unpushed  = (Get-GitOutput $r @('log','--branches','--not','--remotes','--oneline')).Count
    $stashes   = (Get-GitOutput $r @('stash','list')).Count

    if ($dirty -gt 0 -or $unpushed -gt 0 -or $stashes -gt 0) {
        $anyRisk = $anyRisk + 1
        $script:NWorkLoss = $script:NWorkLoss + 1
        $totalUnpushed = $totalUnpushed + $unpushed
        $totalUncommitted = $totalUncommitted + $dirty
        Write-Line "   *** WORK AT RISK: $r"
        Write-Item "       uncommitted changes: $dirty  (of which untracked: $untracked)"
        Write-Item "       commits not pushed:  $unpushed"
        Write-Item "       stashes:             $stashes"
        Write-Item '       (filenames are not listed - they can reveal client names)'
    } else {
        Write-Item "clean, everything pushed: $r"
    }
}
Write-Line ''
if ($ilRepoCount -eq 0) {
    Write-Item 'No IL repos found on this machine, so there is nothing here to lose.'
} elseif ($anyRisk -eq 0) {
    Write-Item "No unsaved work found in any of the $ilRepoCount IL repo(s). Good."
} else {
    Write-Item "*** $anyRisk of $ilRepoCount IL repo(s) have work at risk."
    Write-Item "***   total commits not pushed: $totalUnpushed"
    Write-Item "***   total uncommitted changes: $totalUncommitted"
    Write-Item '>> Push or back up the above BEFORE anyone runs an uninstaller.'
}

# ---------------------------------------------------------------------------
Write-Header '6. SUMMARY'
Write-Line ("   CANDIDATE FOR REMOVAL  : {0}" -f $script:NRemove)
Write-Line ("   KEEP                   : {0}" -f $script:NKeep)
Write-Line ("   UNKNOWN (ask a human)  : {0}" -f $script:NUnknown)
Write-Line ("   REPOS WITH WORK AT RISK: {0}" -f $script:NWorkLoss)
Write-Line ''
Write-Item 'Nothing on this machine was changed by running this. Send this output back'
Write-Item 'to Chaning; the actual removal list will be decided by a human from it.'
Write-Line ''
