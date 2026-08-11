# Irrational Labs — Uninstaller (Windows). Reverses what bootstrap.ps1 added.
#   irm https://raw.githubusercontent.com/ChaningJang/setup/main/uninstall.ps1 | iex
$ErrorActionPreference = "Stop"

function Print-Step($m)    { Write-Host "`n> $m" -ForegroundColor Blue }
function Print-Success($m) { Write-Host "OK $m" -ForegroundColor Green }
function Print-Warning($m) { Write-Host "!! $m" -ForegroundColor Yellow }
function Print-Info($m)    { Write-Host "   $m" }
function Test-CommandExists($c) { $null -ne (Get-Command $c -ErrorAction SilentlyContinue) }

$script:DryRun = ($env:IL_DRY_RUN -eq "1")
function Run-Cmd([scriptblock]$Block, [string]$Desc) {
    if ($script:DryRun) { Write-Host "DRYRUN: $Desc" } else { & $Block }
}

function Get-ReceiptPath {
    if ($env:IL_SETUP_RECEIPT) { return $env:IL_SETUP_RECEIPT }
    return (Join-Path $env:LOCALAPPDATA "il-setup\receipt.json")
}

$script:Receipt = $null
function Load-Receipt {
    $p = Get-ReceiptPath
    if (Test-Path $p) { try { $script:Receipt = Get-Content -Raw $p | ConvertFrom-Json } catch { $script:Receipt = $null } }
    else { $script:Receipt = $null }
}
function Has-Receipt { return $null -ne $script:Receipt }
function R-Bool($name) { if ((Has-Receipt) -and ($script:Receipt.PSObject.Properties.Name -contains $name)) { return [bool]$script:Receipt.$name } return $false }

function Strip-IlSettings([string]$File) {
    if (-not (Test-Path $File)) { Print-Info "No settings.json — nothing to strip"; return }
    try { $s = Get-Content -Raw $File | ConvertFrom-Json } catch { Print-Warning "Could not parse $File"; return }
    if ($s.PSObject.Properties.Name -contains "extraKnownMarketplaces") { $s.extraKnownMarketplaces.PSObject.Properties.Remove("irrational-labs-plugins") }
    if ($s.PSObject.Properties.Name -contains "enabledPlugins") {
        foreach ($k in @("gws@irrational-labs-plugins","il-slides@irrational-labs-plugins","key-behavior@irrational-labs-plugins")) {
            $s.enabledPlugins.PSObject.Properties.Remove($k)
        }
    }
    if ($s.PSObject.Properties.Name -contains "env") {
        $s.env.PSObject.Properties.Remove("GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND")
    }
    $json = $s | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($File, $json, (New-Object System.Text.UTF8Encoding($false)))
    Print-Success "Removed IL keys from settings.json"
}

function Remove-IlPathBlock([string]$File) {
    if (-not (Test-Path $File)) { return }
    $lines = Get-Content $File
    if (-not ($lines -match "# >>> il-setup >>>")) { return }
    $out = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($l in $lines) {
        if ($l -match "# >>> il-setup >>>") { $skip = $true }
        if (-not $skip) { $out.Add($l) }
        if ($l -match "# <<< il-setup <<<") { $skip = $false }
    }
    Set-Content -Path $File -Value $out
    Print-Success "Removed il-setup PATH block from $(Split-Path $File -Leaf)"
}

function Restore-GitIdentity {
    if (-not (Has-Receipt)) { Print-Warning "No receipt — cannot restore git identity"; return }
    $name = $script:Receipt.git_identity_prior.name
    $email = $script:Receipt.git_identity_prior.email
    if ($name -or $email) {
        if ($name)  { Run-Cmd { git config --global user.name $name } "git config --global user.name $name" }
        if ($email) { Run-Cmd { git config --global user.email $email } "git config --global user.email $email" }
        Print-Success "Restored prior git identity"
    } else {
        Run-Cmd { try { git config --global --unset user.name } catch {} } "git config --global --unset user.name"
        Run-Cmd { try { git config --global --unset user.email } catch {} } "git config --global --unset user.email"
        Print-Success "Cleared git identity (none before setup)"
    }
}

function Remove-Repos {
    if (-not (Has-Receipt)) { Print-Warning "No receipt — skipping repos"; return }
    foreach ($r in @($script:Receipt.repos_cloned)) {
        if ($r.path) { Run-Cmd { Remove-Item -Recurse -Force $r.path } "Remove-Item -Recurse -Force $($r.path)"; Print-Success "Removed $($r.path)" }
    }
}

function Remove-Gws {
    # Keep the safe keyring backend set for the logout itself — logging out on
    # the default backend is the same path that silently eats credentials.
    $env:GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND = "file"
    if (Test-CommandExists "gws") { Run-Cmd { gws auth logout } "gws auth logout"; Print-Success "Cleared gws credentials" }
    if ((Has-Receipt) -and -not (R-Bool "gws_cli_installed_by_us")) { Print-Info "gws CLI not installed by setup — leaving it" }
    elseif (Test-CommandExists "npm") { Run-Cmd { npm uninstall -g '@googleworkspace/cli' } "npm uninstall -g @googleworkspace/cli"; Print-Success "Uninstalled gws CLI" }
    $cfg = if ($env:GOOGLE_WORKSPACE_CLI_CONFIG_DIR) { $env:GOOGLE_WORKSPACE_CLI_CONFIG_DIR } else { Join-Path $env:USERPROFILE ".config\gws" }
    if (Test-Path $cfg) { Run-Cmd { Remove-Item -Recurse -Force $cfg } "Remove-Item $cfg"; Print-Success "Removed leftover gws config" }
    # Only clear the persistent user env var if setup is what set it.
    if ((-not (Has-Receipt)) -or (R-Bool "gws_env_set_by_us")) {
        if ([Environment]::GetEnvironmentVariable("GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND", "User")) {
            Run-Cmd { [Environment]::SetEnvironmentVariable("GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND", $null, "User") } "clear GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND (User)"
            Print-Success "Cleared the gws keyring env var"
        }
    } else { Print-Info "Keyring env var predates setup — leaving it" }
}

function Remove-GitHubAuth {
    if ((Has-Receipt) -and (R-Bool "gh_was_authenticated_before")) { Print-Info "Was authed before setup — leaving gh auth"; return }
    if (Test-CommandExists "gh") { Run-Cmd { gh auth logout } "gh auth logout"; Print-Success "Logged out of GitHub CLI" }
}

function Remove-ClaudeCode {
    # bootstrap.ps1 installs Claude Code via `bun install -g`, so uninstall via bun.
    if (Test-CommandExists "claude") { Run-Cmd { bun remove -g '@anthropic-ai/claude-code' } "bun remove -g @anthropic-ai/claude-code"; Print-Success "Removed Claude Code (kept ~/.claude)" }
}

function Remove-DevTools {
    if (-not (Has-Receipt)) { Print-Warning "No receipt — refusing to guess dev tools"; return }
    foreach ($id in @($script:Receipt.formulae_installed_by_us)) {
        if ($id) { Run-Cmd { winget uninstall --id $id -e } "winget uninstall --id $id"; Print-Success "Uninstalled $id" }
    }
    $bun = Join-Path $env:USERPROFILE ".bun"
    if ((R-Bool "bun_installed_by_us") -and (Test-Path $bun)) { Run-Cmd { Remove-Item -Recurse -Force $bun } "Remove-Item $bun"; Print-Success "Removed Bun" }
}

function Remove-Plugins { Strip-IlSettings (Join-Path $env:USERPROFILE ".claude\settings.json") }

function Remove-PathEdits {
    if (Has-Receipt) { foreach ($p in @($script:Receipt.path_edits)) { if ($p) { Remove-IlPathBlock $p } } }
    else {
        Remove-IlPathBlock $PROFILE.CurrentUserAllHosts
        Remove-IlPathBlock $PROFILE
    }
}

function Run-Category($id) {
    switch ($id) {
        "repos"    { Remove-Repos }
        "gws"      { Remove-Gws }
        "plugins"  { Remove-Plugins }
        "gh"       { Remove-GitHubAuth }
        "gitid"    { Restore-GitIdentity }
        "path"     { Remove-PathEdits }
        "claude"   { Remove-ClaudeCode }
        "devtools" { Remove-DevTools }
        default    { Print-Warning "Unknown category: $id" }
    }
}

function Main {
    Write-Host "`nIrrational Labs - Uninstaller"
    Load-Receipt
    if (Has-Receipt) { Print-Info "Found receipt at $(Get-ReceiptPath)" } else { Print-Warning "No receipt - best-effort mode" }

    Write-Host ""
    Write-Host "  1) Recommended - IL footprint and access"
    Write-Host "  2) Everything the script installed"
    Write-Host "  3) Custom"
    Write-Host "  4) Cancel"
    $choice = Read-Host "Choose [1]"
    if (-not $choice) { $choice = "1" }

    $cats = @()
    switch ($choice) {
        "1" { $cats = @("repos","gws","plugins","gh","gitid","path") }
        "2" { $cats = @("repos","gws","plugins","gh","gitid","path","claude","devtools") }
        "3" { foreach ($id in @("repos","gws","plugins","gh","gitid","path","claude","devtools")) { if ((Read-Host "Remove '$id'? (y/N)") -match '^[Yy]') { $cats += $id } } }
        default { Print-Info "Cancelled."; return }
    }
    if ($cats.Count -eq 0) { Print-Info "Nothing selected."; return }

    Print-Step ("Will reverse: " + ($cats -join " "))
    if ((Read-Host "Proceed? (y/N)") -notmatch '^[Yy]') { Print-Info "Cancelled."; return }
    foreach ($id in $cats) { Run-Category $id }
    Print-Success "Uninstall complete. Open a new terminal to drop removed PATH entries."
}

Main
