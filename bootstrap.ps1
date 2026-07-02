# =============================================================================
# Irrational Labs HQ - Bootstrap Script (Windows)
# =============================================================================
# One-command setup for new team members on Windows.
#
# Usage (from PowerShell):
#   irm https://raw.githubusercontent.com/ChaningJang/setup/main/bootstrap.ps1 | iex
#
# This script is idempotent — safe to re-run to fix problems.
# =============================================================================

param(
    [string]$Repos = "",       # comma-separated repo keys
    [switch]$BaseOnly
)

$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
$SETUP_RAW_BASE = "https://raw.githubusercontent.com/ChaningJang/setup/main"
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
$script:ILSettings   = $false
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

    $receipt = [ordered]@{
        schema_version             = 1
        formulae_installed_by_us   = @($formulae)
        path_edits                 = @($paths)
        repos_cloned               = @($repos)
        brew_installed_by_us       = ((_bool $existing 'brew_installed_by_us') -or $script:ILBrew)
        bun_installed_by_us        = ((_bool $existing 'bun_installed_by_us') -or $script:ILBun)
        claude_code_installed_by_us= ((_bool $existing 'claude_code_installed_by_us') -or $script:ILClaude)
        gws_cli_installed_by_us    = ((_bool $existing 'gws_cli_installed_by_us') -or $script:ILGws)
    }
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

function Ensure-Scoop {
    Print-Step "Checking Scoop..."

    if (Test-CommandExists "scoop") {
        Print-Success "Scoop already installed"
    } else {
        Print-Info "Installing Scoop..."
        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
        Invoke-RestMethod -Uri https://get.scoop.sh | Invoke-Expression
        Refresh-Path
        if (Test-CommandExists "scoop") {
            Print-Success "Scoop installed"
        } else {
            Print-Error "Scoop installation failed"
            throw "Scoop is required to continue"
        }
    }

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
        scoop install jq 2>$null
        Refresh-Path
        if (Test-CommandExists "jq") { $script:ILFormulae += "jq" }
    }
    Print-Success "jq ready"

    # Node gives us npm, needed to install global CLI tools like the gws
    # (Google Workspace) CLI in Ensure-IlClaudePlugins.
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
        powershell -c "irm bun.sh/install.ps1 | iex"
        Refresh-Path
        $bunPath = "$HOME\.bun\bin"
        if (Test-Path $bunPath) { $env:Path = "$bunPath;$env:Path" }
        if (Test-CommandExists "bun") {
            Print-Success "bun $(bun --version)"
            $script:ILBun = $true
        }
        else { Print-Error "Bun installation failed"; throw "Bun is required" }
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
    if (-not $ghUserJson) {
        Print-Warning "Could not determine Git identity from GitHub — skipping"
        return
    }

    $ghUser = $ghUserJson | ConvertFrom-Json
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
        Print-Info "Installing Claude Code..."
        bun install -g @anthropic-ai/claude-code 2>$null
        Refresh-Path
        $bunBin = "$HOME\.bun\bin"
        if (Test-Path $bunBin) { $env:Path = "$bunBin;$env:Path" }
        if (Test-CommandExists "claude") { $script:ILClaude = $true }
    }

    # Persist bun global bin on the User PATH so future terminals find claude.
    $bunBin = "$HOME\.bun\bin"
    if (Test-Path $bunBin) {
        $psProfile = $PROFILE.CurrentUserAllHosts
        Add-IlPathBlock $psProfile "`$env:Path = `"$bunBin;`$env:Path`""
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if ($userPath -notlike "*$bunBin*") {
            [Environment]::SetEnvironmentVariable("Path", "$userPath;$bunBin", "User")
            Print-Success "Added $bunBin to your PATH"
        }
    }

    Refresh-Path
    if (Test-CommandExists "claude") {
        Print-Success "Claude Code ready"
    } else {
        Print-Warning "claude installed but not yet on PATH — open a new terminal"
        $script:Warnings += "Claude Code installed but not yet on PATH — open a new terminal to use it"
    }
}

function Ensure-IlClaudePlugins {
    Print-Step "Setting up Irrational Labs Claude Code plugins..."

    $claudeDir = "$HOME\.claude"
    $settingsPath = "$claudeDir\settings.json"
    if (-not (Test-Path $claudeDir)) { New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null }

    if (Test-Path $settingsPath) {
        try { $settings = Get-Content -Raw $settingsPath | ConvertFrom-Json }
        catch { $settings = [PSCustomObject]@{} }
    } else {
        $settings = [PSCustomObject]@{}
    }

    # Helper to ensure a property exists on a PSCustomObject
    function Ensure-Prop($obj, $name, $value) {
        if (-not ($obj.PSObject.Properties.Name -contains $name)) {
            $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value
        }
    }

    # Marketplace registration is always (re)set.
    $marketplace = [PSCustomObject]@{
        source = [PSCustomObject]@{
            source = "github"
            repo   = "IrrationalLabs-team/knowledge-work-plugins"
        }
    }
    Ensure-Prop $settings "extraKnownMarketplaces" ([PSCustomObject]@{})
    if ($settings.extraKnownMarketplaces.PSObject.Properties.Name -contains "irrational-labs-plugins") {
        $settings.extraKnownMarketplaces."irrational-labs-plugins" = $marketplace
    } else {
        $settings.extraKnownMarketplaces | Add-Member -NotePropertyName "irrational-labs-plugins" -NotePropertyValue $marketplace
    }

    # Default-on plugins — only set when the key is absent (preserve explicit disables).
    Ensure-Prop $settings "enabledPlugins" ([PSCustomObject]@{})
    foreach ($p in @("gws@irrational-labs-plugins","il-slides@irrational-labs-plugins","key-behavior@irrational-labs-plugins")) {
        if (-not ($settings.enabledPlugins.PSObject.Properties.Name -contains $p)) {
            $settings.enabledPlugins | Add-Member -NotePropertyName $p -NotePropertyValue $true
        }
    }

    # Write BOM-free UTF-8 (Set-Content -Encoding UTF8 emits a BOM on Windows
    # PowerShell 5.1, which can break JSON parsers reading settings.json).
    $json = $settings | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($settingsPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    $script:ILSettings = $true
    Print-Success "IL plugin marketplace registered"
    Print-Info "Default-on: gws, il-slides, key-behavior"
    Print-Info "Available on demand: gorilla-scripting, pipedrive"

    # The gws plugin drives the `gws` Google Workspace CLI (a separate npm
    # package). Install it globally so /gws:setup works out of the box.
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
    Print-Info "After restart, run /gws:setup and sign in with your @irrationallabs.com account"
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
    $criticalCmds = @("git", "git-lfs", "gh", "bun", "jq")
    foreach ($cmd in $criticalCmds) {
        if (Test-CommandExists $cmd) { Print-Success $cmd }
        else { Print-Error "$cmd not found"; $allGood = $false }
    }
    if (Test-CommandExists "scoop") { Print-Success "scoop" } else { Print-Warning "scoop not in PATH" }
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
    Write-Host "  1. Open a new terminal window (to pick up PATH changes)"
    Write-Host "  2. cd into a cloned repo and run:  claude"
    Write-Host "  3. Ask Claude: 'Give me a tour of this project'"
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
    Ensure-IlClaudePlugins     # step 5 (new in Task 8)
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

    Write-Host ""
    Write-Receipt               # persist what this run changed (for the uninstaller)
    if (-not (Verify-Setup)) { Print-Warning "Setup completed with some issues" }
    Print-Completion
}

Main
