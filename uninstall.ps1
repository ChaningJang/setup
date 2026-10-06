# Irrational Labs — Uninstaller (Windows). Reverses what bootstrap.ps1 added.
#   irm https://raw.githubusercontent.com/ChaningJang/setup/test-flight/uninstall.ps1 | iex
#
# Driven by the receipt bootstrap.ps1 (and the IL Setup bb plugin) write to
# %LOCALAPPDATA%\il-setup\receipt.json: only what setup added is removed.
# Without a receipt it removes nothing it can't prove setup added.
#
# $env:IL_DRY_RUN = "1" prints each change instead of making it (every write
# here goes through it, unlike the Mac uninstaller's; see README).

function Print-Step($m)    { Write-Host "`n> $m" -ForegroundColor Blue }
function Print-Success($m) { Write-Host "OK $m" -ForegroundColor Green }
function Print-Warning($m) { Write-Host "!! $m" -ForegroundColor Yellow }
function Print-Info($m)    { Write-Host "   $m" }
function Test-CommandExists($c) { $null -ne (Get-Command $c -ErrorAction SilentlyContinue) }
function R-List($name) { if ((Has-Receipt) -and ($script:Receipt.PSObject.Properties.Name -contains $name) -and $script:Receipt.$name) { return @($script:Receipt.$name) } return @() }

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
    if (-not (Has-Receipt)) { Print-Info "No receipt — leaving settings.json as it is"; return }
    try { $s = [System.IO.File]::ReadAllText($File) | ConvertFrom-Json -ErrorAction Stop } catch { Print-Warning "Could not parse $File — left it alone"; return }
    $added = @(R-List "claude_settings_added")
    $legacy = ($added.Count -eq 0) -and ($script:Receipt.PSObject.Properties.Name -contains "claude_settings")
    $ourMarketplace = $legacy -or ($added -contains "extraKnownMarketplaces.irrational-labs-plugins")
    $changed = $false
    if ($ourMarketplace -and ($s.PSObject.Properties.Name -contains "extraKnownMarketplaces") -and
        ($s.extraKnownMarketplaces.PSObject.Properties.Name -contains "irrational-labs-plugins")) {
        $s.extraKnownMarketplaces.PSObject.Properties.Remove("irrational-labs-plugins"); $changed = $true
    }
    if ($s.PSObject.Properties.Name -contains "enabledPlugins") {
        foreach ($k in @($s.enabledPlugins.PSObject.Properties.Name)) {
            if (-not $k.EndsWith("@irrational-labs-plugins")) { continue }
            # Our marketplace: every IL plugin goes (IL Setup lets people switch any on).
            # Someone else's: only the defaults setup itself turned on.
            if ($ourMarketplace -or ($added -contains "enabledPlugins.$k")) { $s.enabledPlugins.PSObject.Properties.Remove($k); $changed = $true }
        }
    }
    if (($legacy -or ($added -contains "env.GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND")) -and
        ($s.PSObject.Properties.Name -contains "env") -and ($s.env.PSObject.Properties.Name -contains "GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND")) {
        $s.env.PSObject.Properties.Remove("GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND"); $changed = $true
    }
    if (-not $changed) { Print-Info "settings.json has nothing setup added — left it alone"; return }
    if ($script:DryRun) { Write-Host "DRYRUN: remove IL keys from $File"; return }
    Copy-Item $File "$File.il-uninstall-bak-$(Get-Date -Format yyyy-MM-dd-HHmmss)"
    $json = $s | ConvertTo-Json -Depth 32
    [System.IO.File]::WriteAllText($File, $json, (New-Object System.Text.UTF8Encoding($false)))
    Print-Success "Removed IL keys from settings.json (backup saved next to it)"
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
    if ($script:DryRun) { Write-Host "DRYRUN: remove il-setup block from $File"; return }
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
        if (-not $r.path -or -not (Test-Path $r.path)) { continue }
        if (-not (Test-Path (Join-Path $r.path ".git"))) { Print-Warning "$($r.path) is no longer a git checkout — left it"; continue }
        # Uncommitted changes, or commits no remote has, would be lost: keep the repo and say so.
        $dirty = git -C $r.path status --porcelain 2>$null
        $unpushed = git -C $r.path log --branches --not --remotes --oneline 2>$null
        if ($dirty -or $unpushed) { Print-Warning "$($r.path) has unsaved or unpushed work — left it. Push or copy it, then delete the folder."; continue }
        Run-Cmd { Remove-Item -Recurse -Force $r.path } "Remove-Item -Recurse -Force $($r.path)"; Print-Success "Removed $($r.path)"
    }
}

function Remove-Gws {
    if (-not (Has-Receipt)) { Print-Info "No receipt — leaving gws and your Google sign-in"; return }
    # Keep the safe keyring backend set for the logout itself — logging out on
    # the default backend is the same path that silently eats credentials.
    $env:GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND = "file"
    if (Test-CommandExists "gws") { Run-Cmd { gws auth logout } "gws auth logout"; Print-Success "Cleared gws credentials" }
    if (-not (R-Bool "gws_cli_installed_by_us")) { Print-Info "gws CLI not installed by setup — leaving it" }
    elseif (Test-CommandExists "npm") { Run-Cmd { npm uninstall -g '@googleworkspace/cli' } "npm uninstall -g @googleworkspace/cli"; Print-Success "Uninstalled gws CLI" }
    $cfg = if ($env:GOOGLE_WORKSPACE_CLI_CONFIG_DIR) { $env:GOOGLE_WORKSPACE_CLI_CONFIG_DIR } else { Join-Path $env:USERPROFILE ".config\gws" }
    if (Test-Path $cfg) { Run-Cmd { Remove-Item -Recurse -Force $cfg } "Remove-Item $cfg"; Print-Success "Removed leftover gws config" }
    # Only clear the persistent user env var if setup is what set it.
    if (R-Bool "gws_env_set_by_us") {
        if ([Environment]::GetEnvironmentVariable("GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND", "User")) {
            Run-Cmd { [Environment]::SetEnvironmentVariable("GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND", $null, "User") } "clear GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND (User)"
            Print-Success "Cleared the gws keyring env var"
        }
    } else { Print-Info "Keyring env var predates setup — leaving it" }
}

function Remove-GitHubAuth {
    if (-not (Has-Receipt)) { Print-Info "No receipt — leaving your GitHub sign-in"; return }
    if (R-Bool "gh_was_authenticated_before") { Print-Info "Was authed before setup — leaving gh auth"; return }
    if (Test-CommandExists "gh") { Run-Cmd { gh auth logout } "gh auth logout"; Print-Success "Logged out of GitHub CLI" }
}

function Remove-ClaudeCode {
    if (-not (R-Bool "claude_code_installed_by_us")) { Print-Info "Claude Code was not installed by setup — leaving it"; return }
    if ($script:Receipt.claude_code_install_method -eq "native") {
        # Anthropic's native installer: the binary plus its versions directory.
        foreach ($p in @((Join-Path $env:USERPROFILE ".local\bin\claude.exe"), (Join-Path $env:USERPROFILE ".local\share\claude"))) {
            if (Test-Path $p) { Run-Cmd { Remove-Item -Recurse -Force $p } "Remove-Item $p" }
        }
        Print-Success "Removed Claude Code (kept ~/.claude)"
    } elseif (Test-CommandExists "bun") {
        # Older setups installed it with `bun install -g`.
        Run-Cmd { bun remove -g '@anthropic-ai/claude-code' } "bun remove -g @anthropic-ai/claude-code"; Print-Success "Removed Claude Code (kept ~/.claude)"
    }
}

function Get-BbInstallDir {
    foreach ($root in @("HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
                        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall")) {
        $hit = Get-ChildItem $root -ErrorAction SilentlyContinue |
            ForEach-Object { Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue } |
            Where-Object { $_.DisplayName -match '^bb( |$)' -and $_.InstallLocation } | Select-Object -First 1
        if ($hit) { return $hit.InstallLocation.TrimEnd("\") }
    }
    $default = Join-Path $env:LOCALAPPDATA "Programs\bb"
    if (Test-Path $default) { return $default }
    return $null
}

# bb and everything in it (threads, the IL Setup plugin), but only if setup
# installed bb. Threads can hold client work, which is why this only runs when
# picked (it's in Recommended, as on the Mac).
function Remove-Bb {
    if (-not (R-Bool "bb_app_installed_by_us")) { Print-Info "bb was not installed by setup — leaving it"; return }
    Run-Cmd { Get-Process -Name "bb" -ErrorAction SilentlyContinue | Stop-Process -Force } "stop bb"
    $dir = Get-BbInstallDir
    if ($dir) {
        $uninstaller = Join-Path $dir "Uninstall bb.exe"
        if (Test-Path $uninstaller) {
            Run-Cmd { Start-Process -FilePath $uninstaller -ArgumentList "/S" -Wait } "`"$uninstaller`" /S"
            # NSIS hands off to a copy of itself in %TEMP%; wait for that to finish.
            if (-not $script:DryRun) { for ($i = 0; $i -lt 60 -and (Test-Path (Join-Path $dir "bb.exe")); $i++) { Start-Sleep -Seconds 1 } }
        }
        if (Test-Path $dir) { Run-Cmd { Remove-Item -Recurse -Force $dir -ErrorAction SilentlyContinue } "Remove-Item $dir" }
    }
    # The bb command setup added, only if it still points into bb.
    $shim = $script:Receipt.bb_cli_shim
    if ($shim -and (Test-Path $shim) -and ((Get-Content -Raw $shim) -match 'bb-app\\host-daemon')) { Run-Cmd { Remove-Item -Force $shim } "Remove-Item $shim" }
    foreach ($d in @((Join-Path $env:USERPROFILE ".bb"), (Join-Path $env:APPDATA "bb"), (Join-Path $env:LOCALAPPDATA "bb-updater"))) {
        if (Test-Path $d) { Run-Cmd { Remove-Item -Recurse -Force $d } "Remove-Item $d" }
    }
    Print-Success "Removed bb and its data (threads, settings, the IL Setup plugin)"
}

# Directories setup appended to the User PATH (registry, so the rest of the
# value and its REG_EXPAND_SZ type are untouched).
function Remove-UserPathEntries {
    $dirs = @(R-List "user_path_added")
    if ($dirs.Count -eq 0) { return }
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("Environment", $true)
    $raw = [string]$key.GetValue("Path", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    $drop = @($dirs | ForEach-Object { $_.TrimEnd("\") })
    $keep = @($raw -split ";" | Where-Object { $_ -and ($drop -notcontains [Environment]::ExpandEnvironmentVariables($_).TrimEnd("\")) })
    if ($keep.Count -eq @($raw -split ";" | Where-Object { $_ }).Count) { $key.Close(); return }
    # Leave ~\.local\bin if something else still lives there (Claude Code we didn't install, say).
    if ($script:DryRun) { Write-Host "DRYRUN: remove $($drop -join ', ') from User PATH"; $key.Close(); return }
    $key.SetValue("Path", ($keep -join ";"), [Microsoft.Win32.RegistryValueKind]::ExpandString)
    $key.Close()
    [Environment]::SetEnvironmentVariable("IL_SETUP_PATH_REFRESH", "1", "User")
    [Environment]::SetEnvironmentVariable("IL_SETUP_PATH_REFRESH", $null, "User")
    Print-Success "Removed setup's PATH entries"
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
    if (Has-Receipt) {
        foreach ($p in @($script:Receipt.path_edits)) { if ($p) { Remove-IlPathBlock $p } }
        Remove-UserPathEntries
    }
    else {
        Remove-IlPathBlock $PROFILE.CurrentUserAllHosts
        Remove-IlPathBlock $PROFILE
    }
}

function Run-Category($id) {
    switch ($id) {
        "repos"    { Remove-Repos }
        "gws"      { Remove-Gws }
        "bb"       { Remove-Bb }
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
    $ErrorActionPreference = "Continue"   # this scope only: don't change the caller's session
    Write-Host "`nIrrational Labs - Uninstaller"
    Load-Receipt
    if (Has-Receipt) { Print-Info "Found receipt at $(Get-ReceiptPath)" } else { Print-Warning "No receipt - best-effort mode" }

    $all = @("repos","gws","plugins","bb","gh","gitid","path","claude","devtools")
    Write-Host ""
    Write-Host "  1) Recommended - IL footprint and access (repos, Google sign-in + gws, IL plugins,"
    Write-Host "     bb and its threads if setup installed it, GitHub sign-in if setup did it, git identity, PATH)"
    Write-Host "  2) Everything the script installed"
    Write-Host "  3) Custom"
    Write-Host "  4) Cancel"
    $choice = Read-Host "Choose [1]"
    if (-not $choice) { $choice = "1" }

    $cats = @()
    switch -Regex ($choice) {
        '^1$' { $cats = @("repos","gws","plugins","bb","gh","gitid","path") }
        '^2$' { $cats = $all }
        '^3$' { foreach ($id in $all) { if ((Read-Host "Remove '$id'? (y/N)") -match '^[Yy]') { $cats += $id } } }
        default { Print-Info "Cancelled."; return }
    }
    if ($cats.Count -eq 0) { Print-Info "Nothing selected."; return }

    Print-Step ("Will reverse: " + ($cats -join " "))
    if ((Read-Host "Proceed? (y/N)") -notmatch '^[Yy]') { Print-Info "Cancelled."; return }
    foreach ($id in $cats) { Run-Category $id }
    Print-Success "Uninstall complete. Open a new terminal to drop removed PATH entries."
}

Main
