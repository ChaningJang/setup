# =============================================================================
# Irrational Labs HQ - Bootstrap Script (Windows)
# =============================================================================
# One-command setup for new team members on Windows.
#
# Usage (from PowerShell, a normal window, not "Run as administrator"):
#   irm https://raw.githubusercontent.com/ChaningJang/setup/test-flight/bootstrap.ps1 | iex
#
# This script is idempotent — safe to re-run to fix problems. On a machine that
# is already set up it only adds what's missing: nothing installed is replaced,
# ~/.claude/settings.json is backed up before any edit and left alone if it
# doesn't parse, and everything it does change goes in the receipt so
# uninstall.ps1 can undo exactly that.
# =============================================================================

param(
    [string]$Repos = "",       # comma-separated repo keys
    [switch]$BaseOnly
)

# No script-wide $ErrorActionPreference = "Stop": under `irm | iex` it would
# change the caller's own PowerShell session, and on Windows PowerShell 5.1 it
# turns any native tool writing to a redirected stderr (gh, npm, git) into a
# terminating error. Main sets "Continue" for its own scope instead.

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
# Test flight: this branch fetches its own files. Switch to main with the
# November merge (same as bootstrap.sh).
$SETUP_RAW_BASE = if ($env:SETUP_RAW_BASE) { $env:SETUP_RAW_BASE } else { "https://raw.githubusercontent.com/ChaningJang/setup/test-flight" }
# IL's bb plugin catalog and the IL Setup plugin in it (private repos), as in bootstrap.sh.
$BB_MARKETPLACE_SOURCE = "git:https://github.com/IrrationalLabs-team/bb-marketplace@main"
$BB_PLUGIN_ENTRY       = "il@il-plugins"
$BB_RELEASES           = "https://github.com/get-bb/bb/releases/latest/download"
$BB_CLI_RELATIVE       = "resources\app.asar.unpacked\node_modules\bb-app\host-daemon\dist\bb.cmd"
$LFS_MIN_SIZE   = 1000
$EMBEDDED_REPOS_JSON = '{"repos":[{"key":"hq","name":"Irrational Labs HQ","slug":"IrrationalLabs-team/irrational_labs_hq","dir":"irrational_labs_hq","setup":"hq","default":true,"description":"Main workspace"}]}'

$script:ReposJson    = $null
$script:SelectedKeys = @()
$script:Warnings     = @()

# ---- Receipt state -----------------------------------------------------------
$script:ILFormulae   = @()        # winget/scoop ids we installed
$script:ILPathFiles  = @()        # profile files we edited
$script:ILRepos      = @()        # @{ path=...; created_dir=$true/$false }
$script:ILBrew       = $false     # n/a on Windows; kept for schema parity
$script:ILBun        = $false
$script:ILClaude     = $false
$script:ILGws        = $false
$script:ILGwsEnv     = $false     # we set the keyring-backend user env var
$script:ILSettings   = $false     # we wrote IL keys into ~/.claude/settings.json
$script:ILClaudeMethod = ""      # "native" = Anthropic's installer (~\.local\bin\claude.exe)
$script:ILSettingsAdded = @()     # settings.json keys this run added (uninstall removes only these)
$script:ILUserPath   = @()        # dirs we appended to the User PATH
$script:ILBb         = $false     # we installed the bb app
$script:ILBbShim     = ""         # the bb.cmd we put on PATH
$script:HasScoop     = $false
$script:ILPriorGitName  = ""
$script:ILPriorGitEmail = ""
$script:ILGhBefore      = $null

function Get-ReceiptPath {
    if ($env:IL_SETUP_RECEIPT) { return $env:IL_SETUP_RECEIPT }
    return (Join-Path $env:LOCALAPPDATA "il-setup\receipt.json")
}

function Capture-PriorState {
    $path = Get-ReceiptPath
    $existing = $null
    if (Test-Path $path) { try { $existing = Get-Content -Raw $path | ConvertFrom-Json } catch { $existing = $null } }
    if ($existing -and ($existing.PSObject.Properties.Name -contains "git_identity_prior")) {
        $script:ILPriorGitName  = $existing.git_identity_prior.name
        $script:ILPriorGitEmail = $existing.git_identity_prior.email
    } else {
        $script:ILPriorGitName  = (git config --global user.name) 2>$null
        $script:ILPriorGitEmail = (git config --global user.email) 2>$null
        if (-not $script:ILPriorGitName)  { $script:ILPriorGitName  = "" }
        if (-not $script:ILPriorGitEmail) { $script:ILPriorGitEmail = "" }
    }
    if ($existing -and ($existing.PSObject.Properties.Name -contains "gh_was_authenticated_before")) {
        $script:ILGhBefore = $existing.gh_was_authenticated_before
    } else {
        gh auth status *> $null
        $script:ILGhBefore = ($LASTEXITCODE -eq 0)
    }
}

function Write-Receipt {
    $path = Get-ReceiptPath
    $dir = Split-Path $path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $existing = [PSCustomObject]@{}
    if (Test-Path $path) { try { $existing = Get-Content -Raw $path | ConvertFrom-Json } catch { $existing = [PSCustomObject]@{} } }

    function _arr($o,$n) { if ($o.PSObject.Properties.Name -contains $n -and $o.$n) { return @($o.$n) } else { return @() } }
    function _bool($o,$n) { if ($o.PSObject.Properties.Name -contains $n) { return [bool]$o.$n } else { return $false } }

    $formulae = (@(_arr $existing 'formulae_installed_by_us') + $script:ILFormulae) | Sort-Object -Unique
    $paths    = (@(_arr $existing 'path_edits') + $script:ILPathFiles) | Sort-Object -Unique

    $repos = @()
    $seen = @{}
    foreach ($r in @(_arr $existing 'repos_cloned')) { if ($r.path -and -not $seen.ContainsKey($r.path)) { $repos += $r; $seen[$r.path]=$true } }
    foreach ($r in $script:ILRepos) { if ($r.path -and -not $seen.ContainsKey($r.path)) { $repos += $r; $seen[$r.path]=$true } }

    # Start from everything already there, so fields the IL Setup bb plugin
    # wrote survive a re-run of this script.
    $receipt = [ordered]@{}
    foreach ($prop in $existing.PSObject.Properties) { $receipt[$prop.Name] = $prop.Value }
    $receipt.schema_version              = 1
    $receipt.formulae_installed_by_us    = @($formulae)
    $receipt.path_edits                  = @($paths)
    $receipt.repos_cloned                = @($repos)
    $receipt.brew_installed_by_us        = ((_bool $existing 'brew_installed_by_us') -or $script:ILBrew)
    $receipt.bun_installed_by_us         = ((_bool $existing 'bun_installed_by_us') -or $script:ILBun)
    $receipt.claude_code_installed_by_us = ((_bool $existing 'claude_code_installed_by_us') -or $script:ILClaude)
    $receipt.gws_cli_installed_by_us     = ((_bool $existing 'gws_cli_installed_by_us') -or $script:ILGws)
    $receipt.gws_env_set_by_us           = ((_bool $existing 'gws_env_set_by_us') -or $script:ILGwsEnv)
    $receipt.bb_app_installed_by_us      = ((_bool $existing 'bb_app_installed_by_us') -or $script:ILBb)
    if ($script:ILClaudeMethod) { $receipt.claude_code_install_method = $script:ILClaudeMethod }
    if ($script:ILBbShim) { $receipt.bb_cli_shim = $script:ILBbShim }
    $receipt.user_path_added       = @((@(_arr $existing 'user_path_added') + $script:ILUserPath) | Sort-Object -Unique)
    $receipt.claude_settings_added = @((@(_arr $existing 'claude_settings_added') + $script:ILSettingsAdded) | Sort-Object -Unique)
    if ($script:ILSettings) {
        $receipt.claude_settings = [ordered]@{ marketplace = "irrational-labs-plugins";
            plugins = @("gws@irrational-labs-plugins","il-slides@irrational-labs-plugins","key-behavior@irrational-labs-plugins") }
    } elseif ($existing.PSObject.Properties.Name -contains 'claude_settings') {
        $receipt.claude_settings = $existing.claude_settings
    }
    if ($existing.PSObject.Properties.Name -contains 'git_identity_prior') {
        $receipt.git_identity_prior = $existing.git_identity_prior
    } else {
        $receipt.git_identity_prior = [ordered]@{ name = $script:ILPriorGitName; email = $script:ILPriorGitEmail }
    }
    if ($existing.PSObject.Properties.Name -contains 'gh_was_authenticated_before') {
        $receipt.gh_was_authenticated_before = $existing.gh_was_authenticated_before
    } else {
        $receipt.gh_was_authenticated_before = [bool]$script:ILGhBefore
    }

    $json = [PSCustomObject]$receipt | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Add-IlPathBlock([string]$ProfilePath, [string]$Line) {
    if (-not (Test-Path $ProfilePath)) {
        New-Item -ItemType Directory -Path (Split-Path $ProfilePath) -Force | Out-Null
        New-Item -ItemType File -Path $ProfilePath -Force | Out-Null
    }
    if (Select-String -Path $ProfilePath -SimpleMatch "# >>> il-setup >>>" -Quiet) { return }
    Add-Content -Path $ProfilePath -Value "`n# >>> il-setup >>>`n$Line`n# <<< il-setup <<<"
    $script:ILPathFiles += $ProfilePath
}

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

function Print-Step($msg)    { Write-Host "`n▶ $msg" -ForegroundColor Blue }
function Print-Success($msg) { Write-Host "✓ $msg" -ForegroundColor Green }
function Print-Warning($msg) { Write-Host "⚠ $msg" -ForegroundColor Yellow }
function Print-Error($msg)   { Write-Host "✗ $msg" -ForegroundColor Red }
function Print-Info($msg)    { Write-Host "  $msg" }

function Test-CommandExists($cmd) {
    return [bool](Get-Command $cmd -ErrorAction SilentlyContinue)
}

function Refresh-Path {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"
}

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Append a directory to the User PATH, once. Goes through the registry so
# entries like %USERPROFILE%\... stay unexpanded and the value keeps its
# REG_EXPAND_SZ type ([Environment]::SetEnvironmentVariable would flatten both).
function Add-UserPathEntry([string]$Dir) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $true)
    $raw = [string]$key.GetValue("Path", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $parts = @($raw -split ";" | Where-Object { $_ })
    $expanded = @($parts | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_).TrimEnd("\") })
    if ($expanded -contains $Dir.TrimEnd("\")) { $key.Close(); return }
    $key.SetValue("Path", (($parts + $Dir) -join ";"), [Microsoft.Win32.RegistryValueKind]::ExpandString)
    $key.Close()
    # Setting any user variable through .NET broadcasts the change, so new
    # windows pick up the PATH without signing out.
    [Environment]::SetEnvironmentVariable("IL_SETUP_PATH_REFRESH", "1", "User")
    [Environment]::SetEnvironmentVariable("IL_SETUP_PATH_REFRESH", $null, "User")
    $script:ILUserPath += $Dir
    if (-not (($env:Path -split ";") -contains $Dir)) { $env:Path = "$env:Path;$Dir" }
    Print-Success "Added $Dir to your PATH"
}

# ~/.claude/settings.json is the person's own file. Parse it or leave it
# alone; back it up (once a day) before the first change; write only when the
# edit changed something. $Edit gets the parsed object and returns $true if it
# changed it.
function Edit-ClaudeSettings([scriptblock]$Edit) {
    $claudeDir = Join-Path $HOME ".claude"
    $path = Join-Path $claudeDir "settings.json"
    $settings = [PSCustomObject]@{}
    if (Test-Path $path) {
        $text = [System.IO.File]::ReadAllText($path)
        if ($text.Trim()) {
            try { $settings = $text | ConvertFrom-Json -ErrorAction Stop } catch { $settings = $null }
            if ($settings -isnot [System.Management.Automation.PSCustomObject]) {
                Print-Warning "$path isn't valid JSON, so I left it alone"
                $script:Warnings += "~\.claude\settings.json isn't valid JSON, so IL settings weren't added. Fix it, then re-run setup."
                return $false
            }
        }
    }
    $changed = [bool](& $Edit $settings)
    if (-not $changed) { return $true }
    if (-not (Test-Path $claudeDir)) { New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null }
    $backup = "$path.il-bak-$(Get-Date -Format yyyy-MM-dd)"
    if ((Test-Path $path) -and -not (Test-Path $backup)) { Copy-Item $path $backup }
    # BOM-free UTF-8 — Set-Content -Encoding UTF8 emits a BOM on PS 5.1, which
    # breaks JSON parsers reading settings.json.
    $json = $settings | ConvertTo-Json -Depth 32
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
    $script:ILSettings = $true
    return $true
}

function Set-JsonProp($obj, [string]$name, $value) {
    if ($obj.PSObject.Properties.Name -contains $name) { $obj.$name = $value }
    else { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value }
}

# -----------------------------------------------------------------------------
# Setup Steps
# -----------------------------------------------------------------------------

function Ensure-Winget {
    Print-Step "Checking winget..."

    if (Test-CommandExists "winget") {
        Print-Success "winget already available"
    } else {
        Print-Error "winget is not available"
        Print-Info "winget comes pre-installed on Windows 10 (1809+) and Windows 11."
        Print-Info "If missing, install 'App Installer' from the Microsoft Store:"
        Print-Info "  https://aka.ms/getwinget"
        throw "winget is required to continue"
    }
}

# Scoop only supplies the optional shell helpers and HQ media tools, so it
# never stops setup. Its installer refuses to run as Administrator.
function Ensure-Scoop {
    Print-Step "Checking Scoop..."

    if (Test-CommandExists "scoop") {
        Print-Success "Scoop already installed"
    } elseif (Test-IsAdmin) {
        Print-Warning "Skipping Scoop: it won't install from an Administrator window"
        $script:Warnings += "Shell helpers (ripgrep, fd, bat, fzf, delta) skipped: re-run setup from a normal PowerShell window to get them"
        return
    } else {
        Print-Info "Installing Scoop..."
        try {
            if ((Get-ExecutionPolicy -Scope CurrentUser) -in @("Undefined", "Restricted")) {
                Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
            }
            Invoke-RestMethod -Uri https://get.scoop.sh -ErrorAction Stop | Invoke-Expression
        } catch { Print-Warning "Scoop installer failed: $($_.Exception.Message)" }
        Refresh-Path
        if (Test-CommandExists "scoop") {
            Print-Success "Scoop installed"
        } else {
            Print-Warning "Scoop isn't available; skipping the optional shell helpers"
            $script:Warnings += "Scoop didn't install, so the optional shell helpers were skipped"
            return
        }
    }
    $script:HasScoop = $true

    # Add extras bucket for some tools
    $buckets = scoop bucket list 2>$null | Select-String "extras"
    if (-not $buckets) {
        scoop bucket add extras 2>$null
    }
    $buckets = scoop bucket list 2>$null | Select-String "main"
    if (-not $buckets) {
        scoop bucket add main 2>$null
    }
}

function Ensure-EarlyTools {
    Print-Step "Installing core tools (git, git-lfs, gh, jq, node, bun)..."

    if (-not (Test-CommandExists "git")) {
        winget install --id Git.Git --accept-source-agreements --accept-package-agreements -e
        Refresh-Path
        if (Test-CommandExists "git") { $script:ILFormulae += "Git.Git" }
    }
    if (Test-CommandExists "git") { Print-Success "git $(git --version)" }
    else { Print-Error "Git installation failed"; throw "Git is required" }

    if (-not (Test-CommandExists "git-lfs")) {
        winget install --id GitHub.GitLFS --accept-source-agreements --accept-package-agreements -e
        Refresh-Path
        if (Test-CommandExists "git-lfs") { $script:ILFormulae += "GitHub.GitLFS" }
    }
    git lfs install 2>$null | Out-Null
    Print-Success "git-lfs ready"

    if (-not (Test-CommandExists "gh")) {
        winget install --id GitHub.cli --accept-source-agreements --accept-package-agreements -e
        Refresh-Path
        if (Test-CommandExists "gh") { $script:ILFormulae += "GitHub.cli" }
    }
    if (Test-CommandExists "gh") { Print-Success "gh installed" }
    else { Print-Warning "gh may need a terminal restart" }

    if (-not (Test-CommandExists "jq")) {
        winget install --id jqlang.jq --accept-source-agreements --accept-package-agreements -e
        Refresh-Path
        if (Test-CommandExists "jq") { $script:ILFormulae += "jqlang.jq" }
    }
    if (Test-CommandExists "jq") { Print-Success "jq ready" } else { Print-Warning "jq may need a terminal restart" }

    # Node gives us npm, needed to install global CLI tools like the gws
    # (Google Workspace) CLI in Ensure-GwsCli.
    if (-not (Test-CommandExists "npm")) {
        winget install --id OpenJS.NodeJS --accept-source-agreements --accept-package-agreements -e
        Refresh-Path
        if (Test-CommandExists "npm") { $script:ILFormulae += "OpenJS.NodeJS" }
    }
    if (Test-CommandExists "npm") { Print-Success "node $(node --version) / npm $(npm --version)" }
    else { Print-Warning "Node may need a terminal restart" }

    if (Test-CommandExists "bun") {
        Print-Success "bun $(bun --version)"
    } else {
        Print-Info "Installing Bun..."
        powershell -NoProfile -ExecutionPolicy Bypass -Command "irm bun.sh/install.ps1 | iex"
        Refresh-Path
        $bunPath = "$HOME\.bun\bin"
        if (Test-Path $bunPath) { $env:Path = "$bunPath;$env:Path" }
        if (Test-CommandExists "bun") {
            Print-Success "bun $(bun --version)"
            $script:ILBun = $true
        }
        else {
            Print-Warning "Bun didn't install; only IL HQ's own scripts need it"
            $script:Warnings += "Bun didn't install. Only needed for IL HQ: re-run setup, or see https://bun.sh"
        }
    }
}

function Ensure-LongPaths {
    Print-Step "Enabling long-path support..."

    # Git for Windows honors core.longpaths=true by switching to the
    # extended-length (\\?\) path API, so clone/checkout of deeply nested repos
    # succeeds past the legacy 260-character MAX_PATH limit. HQ has paths well
    # over that — without this, the checkout aborts partway and the clone looks
    # like an access/permissions failure when it is really a path-length one.
    # Must run AFTER git is installed and BEFORE any repo is cloned.
    git config --global core.longpaths true 2>$null
    Print-Success "Git long-path support enabled (core.longpaths=true)"

    # Best-effort: flip the OS-wide flag so non-Git tools (node/bun reading deep
    # paths, Explorer, etc.) also cope. Needs admin — skip quietly if we can't
    # write HKLM; Git's own long-path support is enough for the clone itself.
    try {
        $fs  = "HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem"
        $cur = (Get-ItemProperty -Path $fs -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled
        if ($cur -ne 1) {
            Set-ItemProperty -Path $fs -Name LongPathsEnabled -Value 1 -Type DWord -ErrorAction Stop
            Print-Success "Enabled OS-wide long paths (LongPathsEnabled=1)"
        } else {
            Print-Success "OS-wide long paths already enabled"
        }
    } catch {
        Print-Info "Couldn't set OS-wide long paths (needs admin) — Git long paths cover the clone"
        $script:Warnings += "OS-wide long paths not enabled (needs admin). If a tool later complains about long file names, open PowerShell as Administrator and run: Set-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' LongPathsEnabled 1"
    }
}

function Ensure-GitHubAuth {
    Print-Step "Checking GitHub authentication..."

    if (-not (Test-CommandExists "gh")) {
        Print-Error "GitHub CLI not found — skipping auth"
        return
    }

    $authStatus = gh auth status 2>&1
    if ($LASTEXITCODE -eq 0) {
        $user = ($authStatus | Select-String "Logged in to github.com account (\S+)").Matches.Groups[1].Value
        Print-Success "Already authenticated with GitHub as $user"
    } else {
        Print-Info "Opening browser to authenticate with GitHub..."
        Print-Info "Please click 'Authorize' when prompted in your browser."
        Write-Host ""

        gh auth login --web --git-protocol https

        $authCheck = gh auth status 2>&1
        if ($LASTEXITCODE -eq 0) {
            Print-Success "GitHub authentication successful"
        } else {
            Print-Error "GitHub authentication failed"
            Print-Info "Please try running: gh auth login"
            throw "GitHub authentication is required"
        }
    }
}

function Ensure-GitIdentity {
    Print-Step "Setting up Git commit identity..."

    $currentName = (git config --global user.name 2>$null)
    $currentEmail = (git config --global user.email 2>$null)

    # Skip if already set to something sensible.
    # The "*.local" pattern is the OS default — replace it.
    if ($currentName -and $currentEmail -and -not ($currentEmail -like "*.local")) {
        Print-Success "Git identity already set ($currentName <$currentEmail>)"
        return
    }

    if ($currentEmail -like "*.local") {
        Print-Info "Existing email '$currentEmail' is an OS default — replacing with your GitHub identity"
    }

    $ghUserJson = gh api user 2>$null
    # gh prints the error body on stdout too, so check the exit code, not just output.
    if ($LASTEXITCODE -ne 0 -or -not $ghUserJson) {
        Print-Warning "Could not determine Git identity from GitHub — skipping"
        return
    }

    $ghUser = ($ghUserJson -join "`n") | ConvertFrom-Json
    if (-not $ghUser.login) {
        Print-Warning "Could not determine Git identity from GitHub — skipping"
        return
    }
    $ghName  = if ($ghUser.name) { $ghUser.name } else { $ghUser.login }
    $ghEmail = $ghUser.email

    # If the user keeps their email private, GitHub returns null.
    # Fall back to the privacy-preserving noreply address.
    if (-not $ghEmail) {
        $ghEmail = "$($ghUser.id)+$($ghUser.login)@users.noreply.github.com"
        Print-Info "Your GitHub email is private — using $ghEmail"
    }

    if (-not $ghName -or -not $ghEmail) {
        Print-Warning "Could not determine Git identity from GitHub — skipping"
        return
    }

    git config --global user.name $ghName
    git config --global user.email $ghEmail
    Print-Success "Git identity set to $ghName <$ghEmail>"
}

function Repair-LfsIfNeeded($dir) {
    $testFile = "$dir\templates\powerpoint\irrational_labs_powerpoint_template_3.pptx"
    $needs = $true
    if (Test-Path $testFile) { if ((Get-Item $testFile).Length -ge $LFS_MIN_SIZE) { $needs = $false } }
    if ($needs) {
        Print-Info "Downloading LFS files..."
        Set-Location $dir; git lfs install --local; git lfs pull
        Print-Success "LFS files downloaded"
    } else { Print-Success "LFS files verified" }
}

function Install-PrecommitHook($dir) {
    Set-Location $dir
    if (-not (Test-Path ".git\hooks")) { New-Item -ItemType Directory -Path ".git\hooks" -Force | Out-Null }
    $hook = @'
#!/bin/sh
PROJECT_ROOT=$(git rev-parse --show-toplevel)
if ! bun run "$PROJECT_ROOT/scripts/validate_filenames.ts" --staged --quiet; then
    printf "\nCommit rejected: filenames contain Windows-incompatible characters.\n\n"
    exit 1
fi
exit 0
'@
    Set-Content -Path ".git\hooks\pre-commit" -Value $hook -NoNewline
    Print-Success "Pre-commit hook installed"
}

function Load-HqSecrets($dir) {
    Set-Location $dir
    if (Test-Path ".env") {
        Print-Info ".env already exists"
    } else {
        Print-Info "Fetching secrets from Infisical..."
        try { bun run scripts/load_infisical_env.ts; Print-Success "Secrets loaded to .env" }
        catch { $script:Warnings += "HQ: could not load Infisical secrets — ask an admin"; Print-Warning "Could not load secrets" }
    }
}

function Ensure-ClaudeCode {
    Print-Step "Checking Claude Code..."

    if (Test-CommandExists "claude") {
        Print-Success "Claude Code already installed"
    } else {
        # Anthropic's native installer (user-level, no admin), same as the Mac
        # script and the IL Setup panel. It puts claude.exe in ~\.local\bin.
        Print-Info "Installing Claude Code..."
        powershell -NoProfile -ExecutionPolicy Bypass -Command "irm https://claude.ai/install.ps1 | iex"
        Add-UserPathEntry (Join-Path $HOME ".local\bin")
        Refresh-Path
        if (Test-CommandExists "claude") { $script:ILClaude = $true; $script:ILClaudeMethod = "native" }
    }

    Refresh-Path
    if (Test-CommandExists "claude") {
        Print-Success "Claude Code ready"
    } else {
        Print-Warning "claude installed but not yet on PATH — open a new terminal"
        $script:Warnings += "Claude Code installed but not yet on PATH — open a new terminal to use it"
    }
}

# -----------------------------------------------------------------------------
# gws (Google Workspace) — the whole stack, installed rather than assumed
# -----------------------------------------------------------------------------
# Mirrors ensure_gws_keyring_env / ensure_il_claude_plugins / ensure_gws_cli in
# bootstrap.sh. A working gws needs the npm CLI, the IL `gws` Claude Code plugin
# (which supplies /gws:setup, the skill, and the guard hook), AND
# GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file. Leaving the plugin to the claude.ai
# org's "Installed by default" push did not reach fresh machines, so it is
# registered explicitly here.

function Ensure-GwsKeyringEnv {
    Print-Step "Installing the gws keyring guard..."

    # CRITICAL. gws's default keyring backend silently DELETES its stored
    # credentials; without this variable a working login evaporates later with
    # no error. Set it as a persistent USER env var so it applies to every
    # process the user starts, not just this shell.
    $existing = [Environment]::GetEnvironmentVariable("GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND", "User")
    if ($existing -eq "file") {
        Print-Info "Keyring guard already set for your user account"
    } else {
        [Environment]::SetEnvironmentVariable("GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND", "file", "User")
        $script:ILGwsEnv = $true
        Print-Success "GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file set for your user account"
    }
    # Apply to the current process too, so any gws call later in this run is
    # already on the safe backend.
    $env:GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND = "file"

    # Belt and braces: also set it for Claude Code sessions directly.
    $ok = Edit-ClaudeSettings {
        param($settings)
        if (-not ($settings.PSObject.Properties.Name -contains "env")) { Set-JsonProp $settings "env" ([PSCustomObject]@{}) }
        $had = $settings.env.PSObject.Properties.Name -contains "GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND"
        if ($had -and $settings.env.GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND -eq "file") { return $false }
        Set-JsonProp $settings.env "GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND" "file"
        if (-not $had) { $script:ILSettingsAdded += "env.GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND" }
        return $true
    }
    if ($ok) { Print-Success "Keyring guard set for Claude Code sessions too" }
}

function Ensure-IlClaudePlugins {
    Print-Step "Registering the Irrational Labs Claude Code plugins..."

    $ok = Edit-ClaudeSettings {
        param($settings)
        $changed = $false
        # Marketplace registration is always (re)set.
        $marketplace = [PSCustomObject]@{
            source = [PSCustomObject]@{
                source = "github"
                repo   = "IrrationalLabs-team/knowledge-work-plugins"
            }
        }
        if (-not ($settings.PSObject.Properties.Name -contains "extraKnownMarketplaces")) {
            Set-JsonProp $settings "extraKnownMarketplaces" ([PSCustomObject]@{})
        }
        $markets = $settings.extraKnownMarketplaces
        if (-not ($markets.PSObject.Properties.Name -contains "irrational-labs-plugins")) {
            Set-JsonProp $markets "irrational-labs-plugins" $marketplace
            $script:ILSettingsAdded += "extraKnownMarketplaces.irrational-labs-plugins"
            $changed = $true
        } elseif (($markets."irrational-labs-plugins" | ConvertTo-Json -Depth 5 -Compress) -ne ($marketplace | ConvertTo-Json -Depth 5 -Compress)) {
            Set-JsonProp $markets "irrational-labs-plugins" $marketplace
            $changed = $true
        }

        # Default-on plugins — only set when the key is absent, so an explicit
        # disable survives a re-run.
        if (-not ($settings.PSObject.Properties.Name -contains "enabledPlugins")) {
            Set-JsonProp $settings "enabledPlugins" ([PSCustomObject]@{})
        }
        foreach ($p in @("gws@irrational-labs-plugins","il-slides@irrational-labs-plugins","key-behavior@irrational-labs-plugins")) {
            if (-not ($settings.enabledPlugins.PSObject.Properties.Name -contains $p)) {
                Set-JsonProp $settings.enabledPlugins $p $true
                $script:ILSettingsAdded += "enabledPlugins.$p"
                $changed = $true
            }
        }
        return $changed
    }
    if (-not $ok) { return }
    Print-Success "IL plugin marketplace registered"
    Print-Info "Default-on: gws, il-slides, key-behavior"
    Print-Info "Available on demand: pipedrive, figma-port, my-chief-of-staff, il-qol"
}

function Ensure-GwsCli {
    Print-Step "Setting up the gws (Google Workspace) CLI..."

    # The npm CLI the gws plugin drives.
    if (Test-CommandExists "gws") {
        Print-Success "gws CLI already installed"
    } elseif (Test-CommandExists "npm") {
        Print-Info "Installing gws (Google Workspace) CLI..."
        npm install -g '@googleworkspace/cli' 2>$null
        Refresh-Path
        if (Test-CommandExists "gws") { Print-Success "gws CLI installed"; $script:ILGws = $true }
        else { Print-Warning "gws CLI install failed - run: npm install -g @googleworkspace/cli" }
    } else {
        Print-Warning "npm not available - skipping gws CLI install"
    }
    Print-Info "Next: restart Claude Code, then run /gws:setup and sign in with @irrationallabs.com"
}

# -----------------------------------------------------------------------------
# bb, plus the IL Setup plugin inside it
# -----------------------------------------------------------------------------
# Same as ensure_bb in bootstrap.sh: official bb from its GitHub releases
# (checksum-verified), then the IL plugin through bb's own CLI, so bb's
# auto-updates keep working and the plugin keeps its own update channel.
# Windows bb (0.45+) is alpha and installs per user, no admin.

function Get-BbInstallDir {
    foreach ($root in @("HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
                        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall")) {
        $hit = Get-ChildItem $root -ErrorAction SilentlyContinue |
            ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } |
            Where-Object { $_.DisplayName -match '^bb( |$)' -and $_.InstallLocation -and (Test-Path (Join-Path $_.InstallLocation "bb.exe")) } |
            Select-Object -First 1
        if ($hit) { return $hit.InstallLocation.TrimEnd("\") }
    }
    $default = Join-Path $env:LOCALAPPDATA "Programs\bb"
    if (Test-Path (Join-Path $default "bb.exe")) { return $default }
    return $null
}

function Install-Bb {
    $ProgressPreference = "SilentlyContinue"   # PS 5.1's progress bar makes big downloads crawl
    $tmp = Join-Path $env:TEMP ("il-bb-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "$BB_RELEASES/latest.yml" -OutFile "$tmp\latest.yml" -ErrorAction Stop
        } catch {
            Print-Warning "Couldn't reach bb's download page; skipping bb"
            $script:Warnings += "bb not installed: download failed. Re-run this command to retry."
            return $false
        }
        $manifest = Get-Content "$tmp\latest.yml"
        $file = ($manifest | Select-String '^path:\s*(\S+)' | Select-Object -First 1).Matches.Groups[1].Value
        $want = ($manifest | Select-String '^sha512:\s*(\S+)' | Select-Object -First 1).Matches.Groups[1].Value
        if (-not $file -or -not $want) {
            Print-Warning "bb's release manifest looked wrong; skipping bb"
            $script:Warnings += "bb not installed: unexpected release manifest. Tell Chaning."
            return $false
        }
        Print-Info "Downloading bb (about 180 MB)..."
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "$BB_RELEASES/$file" -OutFile "$tmp\$file" -ErrorAction Stop
        } catch {
            Print-Warning "bb download failed; skipping"
            $script:Warnings += "bb not installed: download failed. Re-run this command to retry."
            return $false
        }
        $hex = (Get-FileHash -Algorithm SHA512 "$tmp\$file").Hash
        $bytes = New-Object byte[] ($hex.Length / 2)
        for ($i = 0; $i -lt $bytes.Length; $i++) { $bytes[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16) }
        if ([Convert]::ToBase64String($bytes) -ne $want) {
            Print-Error "The bb download didn't match its published checksum; not installing it"
            $script:Warnings += "bb not installed: checksum mismatch. Re-run this command; if it repeats, tell Chaning."
            return $false
        }
        Print-Info "Installing bb..."
        Start-Process -FilePath "$tmp\$file" -ArgumentList "/S" -Wait
        return $true
    } finally {
        Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
    }
}

function Ensure-Bb {
    Print-Step "Setting up bb..."

    $dir = Get-BbInstallDir
    if ($dir) {
        Print-Success "bb already installed"
    } else {
        if (-not (Install-Bb)) { return }
        $dir = Get-BbInstallDir
        if (-not $dir) {
            Print-Warning "bb's installer finished but bb isn't where expected; skipping the IL plugin"
            $script:Warnings += "bb install couldn't be confirmed. Re-run this command; if it repeats, tell Chaning."
            return
        }
        $script:ILBb = $true
        Print-Success "bb installed"
    }

    # bb's command ships inside the app as bb.cmd, which runs on Node.
    $cli = Join-Path $dir $BB_CLI_RELATIVE
    if (-not (Test-Path $cli)) {
        Print-Warning "This bb has no command-line tool where expected; skipping the IL plugin"
        $script:Warnings += "IL Setup not added to bb: bb's command wasn't found. Tell Chaning which bb version you have."
        return
    }
    if (-not (Test-CommandExists "node")) {
        Print-Warning "bb's command needs Node, which isn't on PATH yet; skipping the IL plugin"
        $script:Warnings += "IL Setup not added to bb: open a new PowerShell window and re-run this command"
        return
    }

    # Make `bb` a command in new terminals: the IL Setup skill tells people and
    # agents to run `bb il ...`. Never over an existing bb command.
    $shimDir = Join-Path $HOME ".local\bin"
    $shim = Join-Path $shimDir "bb.cmd"
    if (-not (Test-CommandExists "bb") -and -not (Test-Path $shim)) {
        New-Item -ItemType Directory -Path $shimDir -Force | Out-Null
        $default = Join-Path $env:LOCALAPPDATA "Programs\bb"
        $target = if ($dir -ieq $default) { "%LOCALAPPDATA%\Programs\bb\$BB_CLI_RELATIVE" } else { $cli }
        [System.IO.File]::WriteAllText($shim, "@echo off`r`n`"$target`" %*`r`n", [System.Text.Encoding]::Default)
        $script:ILBbShim = $shim
        Add-UserPathEntry $shimDir
        Print-Success "bb command available in new PowerShell windows"
    }

    Print-Info "Opening bb..."
    if (-not (Get-Process -Name "bb" -ErrorAction SilentlyContinue)) { Start-Process (Join-Path $dir "bb.exe") }
    # Wait for bb's server, not just the app: `plugin list` needs it (see bootstrap.sh).
    $ready = $false
    for ($i = 0; $i -lt 90; $i++) {
        & $cli plugin list *> $null
        if ($LASTEXITCODE -eq 0) { $ready = $true; break }
        Start-Sleep -Seconds 2
    }
    if (-not $ready) {
        Print-Warning "bb didn't finish starting, so the IL Setup plugin wasn't added"
        $script:Warnings += "IL Setup not added to bb: open bb, then re-run this command"
        return
    }

    if (@(& $cli plugin list 2>$null) -match '^il@') {
        Print-Success "IL Setup plugin already in bb"
        return
    }
    Print-Info "Adding IL's plugin catalog and the IL Setup plugin to bb..."
    $log = Join-Path $env:TEMP "il-bb-plugin-install.log"
    if (-not (@(& $cli marketplace list 2>$null) -match 'il-plugins')) {
        & $cli marketplace add $BB_MARKETPLACE_SOURCE *> $log
    }
    & $cli plugin install $BB_PLUGIN_ENTRY --yes *>> $log
    if ($LASTEXITCODE -eq 0) {
        Print-Success "IL Setup added to bb (left sidebar)"
    } else {
        Print-Warning "Couldn't add the IL Setup plugin (details: $log)"
        $script:Warnings += "IL Setup not added to bb: re-run this command, or send Chaning $log"
    }
}


function Load-Manifest {
    Print-Step "Loading repo list..."
    $fetched = $null
    try { $fetched = Invoke-RestMethod -Uri "$SETUP_RAW_BASE/repos.json" -ErrorAction Stop } catch { $fetched = $null }
    if ($fetched -and $fetched.repos) {
        $script:ReposJson = $fetched
        Print-Success "Repo list loaded"
    } else {
        $script:ReposJson = ($EMBEDDED_REPOS_JSON | ConvertFrom-Json)
        Print-Warning "Couldn't fetch repo list — using built-in default (HQ only)"
    }
}

function Get-RepoEntry($key) {
    return $script:ReposJson.repos | Where-Object { $_.key -eq $key } | Select-Object -First 1
}

function Select-Repos {
    $script:SelectedKeys = @()

    if ($BaseOnly) {
        Print-Info "Base-only mode — no repositories will be cloned"
        return
    }

    if ($Repos) {
        foreach ($k in ($Repos -split ",")) {
            $k = $k.Trim()
            if (-not $k) { continue }
            if (Get-RepoEntry $k) { $script:SelectedKeys += $k }
            else { Print-Warning "Unknown repo key '$k' — skipping" }
        }
        return
    }

    Print-Step "Checking which repos you can access..."
    $accessible = @()
    foreach ($r in $script:ReposJson.repos) {
        gh repo view $r.slug *> $null
        if ($LASTEXITCODE -eq 0) { $accessible += $r }
    }
    if ($accessible.Count -eq 0) {
        Print-Warning "Couldn't verify repo access — showing the full list"
        $accessible = $script:ReposJson.repos
    }

    Write-Host ""
    Write-Host "Which repositories do you want to clone?"
    for ($i = 0; $i -lt $accessible.Count; $i++) {
        $n = $i + 1
        Write-Host ("  {0}) {1} — {2}" -f $n, $accessible[$i].name, $accessible[$i].description)
    }
    Write-Host "  0) None (base tools only)"
    Write-Host ""
    $answer = Read-Host "Enter numbers separated by spaces or commas (default: 1)"
    if (-not $answer) { $answer = "1" }
    $answer = $answer -replace ",", " "

    foreach ($tok in ($answer -split "\s+")) {
        if (-not $tok) { continue }
        if ($tok -eq "0") { $script:SelectedKeys = @(); return }
        if ($tok -match '^\d+$') {
            $idx = [int]$tok - 1
            if ($idx -ge 0 -and $idx -lt $accessible.Count) {
                $script:SelectedKeys += $accessible[$idx].key
            } else {
                Print-Warning "Ignoring out-of-range choice: $tok"
            }
        }
    }
}

function Install-ShellHelpers {
    Print-Step "Installing shell helpers..."
    $helpers = @{ "ripgrep" = "rg"; "fd" = "fd"; "bat" = "bat"; "fzf" = "fzf"; "delta" = "delta" }
    if (-not $script:HasScoop) { Print-Info "No Scoop — skipping"; return }
    foreach ($h in $helpers.GetEnumerator()) {
        if (-not (Test-CommandExists $h.Value)) {
            scoop install $h.Key 2>$null
        }
    }
    Refresh-Path
    Print-Success "Shell helpers installed"
}

function Install-HqExtras {
    Print-Step "Installing HQ media/doc tools..."
    $scoopTools = @{
        "ffmpeg"="ffmpeg"; "exiftool"="exiftool"; "yt-dlp"="yt-dlp"; "pandoc"="pandoc";
        "imagemagick"="magick"; "yq"="yq"; "miller"="mlr"; "sd"="sd"; "gawk"="gawk"; "eza"="eza"
    }
    foreach ($t in $scoopTools.GetEnumerator()) {
        if (-not (Test-CommandExists $t.Value)) { scoop install $t.Key 2>$null }
    }
    Refresh-Path
    if (-not (Test-CommandExists "marp")) { bun install -g @marp-team/marp-cli 2>$null }
    if (-not (Test-CommandExists "gswin64c") -and -not (Test-CommandExists "gs")) {
        winget install --id ArtifexSoftware.GhostScript --accept-source-agreements --accept-package-agreements -e 2>$null
        Refresh-Path
    }
    Print-Success "HQ tools installed"
}

function Setup-Hq($dir) {
    Print-Step "Running HQ setup..."
    Install-HqExtras
    Repair-LfsIfNeeded $dir
    Set-Location $dir
    bun install
    if ($LASTEXITCODE -ne 0) { $script:Warnings += "HQ: bun install failed" }
    Install-PrecommitHook $dir
    Load-HqSecrets $dir
    Print-Success "HQ setup complete"
}

function Setup-Generic($dir) {
    $base = Split-Path $dir -Leaf
    Print-Step "Running generic setup for $base..."
    Set-Location $dir
    if (Test-Path "package.json") {
        Print-Info "Found package.json — running bun install"
        try { bun install } catch { $script:Warnings += "${base}: bun install failed" }
    }
    if ((Test-Path ".gitattributes") -and (Select-String -Path ".gitattributes" -Pattern "filter=lfs" -Quiet)) {
        Print-Info "Repo uses Git LFS — pulling LFS files"
        git lfs install --local 2>$null | Out-Null
        git lfs pull
        if ($LASTEXITCODE -ne 0) { $script:Warnings += "${base}: git lfs pull failed" }
    }
    if (-not (Test-Path ".env")) {
        $example = $null
        if (Test-Path ".env.example") { $example = ".env.example" }
        elseif (Test-Path ".env.sample") { $example = ".env.sample" }
        if ($example) {
            Copy-Item $example ".env"
            Print-Info "Created .env from $example — fill in secrets before use"
            $script:Warnings += "${base}: created .env from $example — needs your secrets"
        }
    }
    Print-Success "$base ready — check its README for any extra setup"
}

function Clone-AndSetupRepo($key) {
    $entry = Get-RepoEntry $key
    if (-not $entry) { Print-Warning "Unknown repo key '$key' — skipping"; return }
    $target = "$HOME\$($entry.dir)"
    Print-Step "Setting up $($entry.slug)..."

    if (Test-Path "$target\.git") {
        Print-Info "Already cloned — pulling latest"
        Set-Location $target; git pull --ff-only 2>$null
    } else {
        $createdDir = -not (Test-Path (Split-Path $target))
        gh repo clone $entry.slug $target
        if ($LASTEXITCODE -ne 0) {
            $script:Warnings += "Could not clone $($entry.slug) — check your GitHub access, or a long-path/filename error (see the git output above)"
            Print-Error "Failed to clone $($entry.slug) (continuing)"
            Print-Info "If git reported 'Filename too long', long-path support may not have applied — open a new terminal and re-run this script."
            return
        }
        $script:ILRepos += [PSCustomObject]@{ path = $target; created_dir = $createdDir }
        Print-Success "Cloned $($entry.slug)"
    }

    switch ($entry.setup) {
        "hq"      { Setup-Hq $target }
        "generic" { Setup-Generic $target }
        default   { Setup-Generic $target }
    }
}

function Verify-Setup {
    Print-Step "Verifying setup..."
    $allGood = $true
    $criticalCmds = @("git", "git-lfs", "gh", "node")
    foreach ($cmd in $criticalCmds) {
        if (Test-CommandExists $cmd) { Print-Success $cmd }
        else { Print-Error "$cmd not found"; $allGood = $false }
    }
    foreach ($cmd in @("jq", "bun", "scoop")) {
        if (Test-CommandExists $cmd) { Print-Success $cmd } else { Print-Warning "$cmd not in PATH (optional)" }
    }
    if (Test-CommandExists "claude") { Print-Success "claude" } else { Print-Warning "claude not in PATH (may need terminal restart)" }
    return $allGood
}

function Print-Completion {
    Write-Host ""
    Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "  Setup Complete!" -ForegroundColor Green
    Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Green

    if ($script:Warnings.Count -gt 0) {
        Write-Host ""
        Write-Host "Heads up — a few things need attention:" -ForegroundColor Yellow
        foreach ($w in $script:Warnings) { Write-Host "  • $w" -ForegroundColor Yellow }
    }

    Write-Host ""
    Write-Host "Next steps:"
    if (Get-BbInstallDir) {
        Write-Host "  1. Go to bb (it's open). Click IL Setup in the left sidebar."
        Write-Host "     It checks this PC and signs you in to GitHub, Claude, and Google."
        Write-Host "  2. Open a new PowerShell window to pick up PATH changes"
    } else {
        Write-Host "  1. Open a new terminal window (to pick up PATH changes)"
        Write-Host "  2. cd into a cloned repo and run:  claude"
        Write-Host "  3. Ask Claude: 'Give me a tour of this project'"
    }
    Write-Host ""
    Write-Host "If you run into issues:"
    Write-Host "  • Re-run this script to repair problems"
    Write-Host "  • Ask Chaning or Kristen for help"
    Write-Host ""
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

function Main {
    $ErrorActionPreference = "Continue"   # this scope only; see the note at the top
    Write-Host ""
    Write-Host "Irrational Labs — Setup (Windows)" -ForegroundColor White
    Write-Host "This will install your dev tools, then ask which repos to clone."
    Write-Host ""

    Ensure-Winget
    Ensure-Scoop
    Ensure-EarlyTools          # step 3
    Ensure-LongPaths           # Windows MAX_PATH fix — must precede any clone
    Capture-PriorState         # record pre-setup git identity + gh auth state
    Ensure-GitHubAuth          # step 4
    Ensure-GitIdentity
    Ensure-ClaudeCode          # step 5 (moved up; hardened in Task 8)
    Ensure-GwsKeyringEnv       # MUST precede any gws call — see the function comment
    Ensure-IlClaudePlugins
    Ensure-GwsCli              # step 5
    Load-Manifest              # step 6
    Select-Repos
    Install-ShellHelpers       # step 7

    if ($script:SelectedKeys.Count -gt 0) {
        foreach ($k in $script:SelectedKeys) {
            try { Clone-AndSetupRepo $k }
            catch { $script:Warnings += "${k}: setup hit an error — $($_.Exception.Message)" }
        }
    } else {
        Print-Info "No repositories selected — base tools only"
    }

    Ensure-Bb

    Write-Host ""
    Write-Receipt               # persist what this run changed (for the uninstaller)
    if (-not (Verify-Setup)) { Print-Warning "Setup completed with some issues" }
    Print-Completion
}

# Run from a saved copy or `irm | iex`: keep the caller's current directory,
# and turn a stop into a message rather than a PowerShell stack trace.
Push-Location
try { Main }
catch {
    Print-Error "Setup stopped: $($_.Exception.Message)"
    Print-Info "Fix that, then run the same command again. It picks up where it left off."
    try { Write-Receipt } catch {}
}
finally { Pop-Location }
