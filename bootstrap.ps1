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

$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
$REPO_URL = "IrrationalLabs-team/irrational_labs_hq"
$PROJECT_DIR = "$HOME\irrational_labs_hq"
$LFS_MIN_SIZE = 1000

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

function Ensure-Git {
    Print-Step "Setting up Git and Git LFS..."

    if (-not (Test-CommandExists "git")) {
        Print-Info "Installing Git..."
        winget install --id Git.Git --accept-source-agreements --accept-package-agreements -e
        Refresh-Path
    }
    if (Test-CommandExists "git") {
        Print-Success "git $(git --version)"
    } else {
        Print-Error "Git installation failed"
        throw "Git is required to continue"
    }

    if (-not (Test-CommandExists "git-lfs")) {
        Print-Info "Installing Git LFS..."
        winget install --id GitHub.GitLFS --accept-source-agreements --accept-package-agreements -e
        Refresh-Path
    }
    git lfs install 2>$null | Out-Null
    if (Test-CommandExists "git-lfs") {
        Print-Success "git-lfs installed"
    } else {
        Print-Warning "git-lfs may need a terminal restart to appear in PATH"
    }

    if (-not (Test-CommandExists "gh")) {
        Print-Info "Installing GitHub CLI..."
        winget install --id GitHub.cli --accept-source-agreements --accept-package-agreements -e
        Refresh-Path
    }
    if (Test-CommandExists "gh") {
        Print-Success "gh $(gh --version | Select-Object -First 1)"
    } else {
        Print-Warning "GitHub CLI may need a terminal restart to appear in PATH"
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

function Setup-Repository {
    Print-Step "Setting up repository..."

    if (Test-Path "$PROJECT_DIR\.git") {
        Print-Info "Repository already exists at $PROJECT_DIR"
        Set-Location $PROJECT_DIR

        $remoteUrl = git remote get-url origin 2>$null
        if ($remoteUrl -notlike "*irrational_labs_hq*") {
            Print-Error "Directory exists but is not the irrational_labs_hq repo!"
            Print-Info "Please remove or rename $PROJECT_DIR and re-run this script."
            throw "Wrong repository in $PROJECT_DIR"
        }

        Print-Info "Pulling latest changes..."
        git pull --ff-only 2>$null

        Print-Info "Verifying LFS files..."
        Repair-LfsIfNeeded
    } else {
        Print-Info "Cloning repository to $PROJECT_DIR..."

        gh repo clone $REPO_URL $PROJECT_DIR
        Set-Location $PROJECT_DIR
        Print-Success "Repository cloned successfully"

        Repair-LfsIfNeeded
    }
}

function Repair-LfsIfNeeded {
    $needsRepair = $false
    $testFile = "$PROJECT_DIR\templates\powerpoint\irrational_labs_powerpoint_template_3.pptx"

    if (Test-Path $testFile) {
        $fileSize = (Get-Item $testFile).Length
        if ($fileSize -lt $LFS_MIN_SIZE) {
            Print-Warning "LFS files appear to be pointer files (not downloaded)"
            $needsRepair = $true
        }
    } else {
        $needsRepair = $true
    }

    if ($needsRepair) {
        Print-Info "Downloading LFS files (this may take a few minutes)..."
        Set-Location $PROJECT_DIR
        git lfs install --local
        git lfs pull
        Print-Success "LFS files downloaded"
    } else {
        Print-Success "LFS files verified"
    }
}

function Ensure-Bun {
    Print-Step "Checking Bun..."

    if (Test-CommandExists "bun") {
        Print-Success "bun $(bun --version)"
    } else {
        Print-Info "Installing Bun..."
        powershell -c "irm bun.sh/install.ps1 | iex"
        Refresh-Path

        # Also add to current session
        $bunPath = "$HOME\.bun\bin"
        if (Test-Path $bunPath) {
            $env:Path = "$bunPath;$env:Path"
        }

        if (Test-CommandExists "bun") {
            Print-Success "bun $(bun --version)"
        } else {
            Print-Error "Bun installation failed"
            Print-Info "Please try manually: powershell -c 'irm bun.sh/install.ps1 | iex'"
            throw "Bun is required to continue"
        }
    }
}

function Install-CliTools {
    Print-Step "Installing CLI tools..."

    # Tools installed via scoop (best for CLI dev tools)
    $scoopTools = @{
        "ffmpeg"     = "ffmpeg"
        "exiftool"   = "exiftool"
        "yt-dlp"     = "yt-dlp"
        "pandoc"     = "pandoc"
        "imagemagick"= "magick"
        "yq"         = "yq"
        "jq"         = "jq"
        "eza"        = "eza"
        "fd"         = "fd"
        "ripgrep"    = "rg"
        "sd"         = "sd"
        "bat"        = "bat"
        "fzf"        = "fzf"
        "delta"      = "delta"
        "miller"     = "mlr"
    }

    $toInstall = @()
    foreach ($tool in $scoopTools.GetEnumerator()) {
        if (-not (Test-CommandExists $tool.Value)) {
            $toInstall += $tool.Key
        }
    }

    if ($toInstall.Count -eq 0) {
        Print-Success "All CLI tools already installed"
    } else {
        Print-Info "Installing via scoop: $($toInstall -join ', ')"
        foreach ($tool in $toInstall) {
            scoop install $tool 2>$null
            if ($LASTEXITCODE -ne 0) {
                Print-Warning "Failed to install $tool — continuing"
            }
        }
        Refresh-Path
        Print-Success "CLI tools installed"
    }

    # marp-cli via bun (npm package)
    if (-not (Test-CommandExists "marp")) {
        Print-Info "Installing marp-cli..."
        bun install -g @marp-team/marp-cli 2>$null
    }

    # ghostscript via winget (better Windows support)
    if (-not (Test-CommandExists "gswin64c") -and -not (Test-CommandExists "gs")) {
        Print-Info "Installing Ghostscript..."
        winget install --id ArtifexSoftware.GhostScript --accept-source-agreements --accept-package-agreements -e 2>$null
        Refresh-Path
    }
}

function Install-ProjectDeps {
    Print-Step "Installing project dependencies..."

    Set-Location $PROJECT_DIR

    Print-Info "Running bun install..."
    bun install
    Print-Success "Project dependencies installed"
}

function Ensure-ClaudeCode {
    Print-Step "Checking Claude Code..."

    if (Test-CommandExists "claude") {
        Print-Success "Claude Code already installed"
    } else {
        Print-Info "Installing Claude Code..."

        # Claude Code installs via npm/bun
        bun install -g @anthropic-ai/claude-code 2>$null
        Refresh-Path

        if (Test-CommandExists "claude") {
            Print-Success "Claude Code installed"
        } else {
            Print-Warning "Claude Code installed but may need a terminal restart to appear in PATH"
            Print-Info "You can also install manually: bun install -g @anthropic-ai/claude-code"
        }
    }
}

function Setup-GitHooks {
    Print-Step "Setting up git hooks..."

    Set-Location $PROJECT_DIR
    $hooksDir = ".git\hooks"
    if (-not (Test-Path $hooksDir)) {
        New-Item -ItemType Directory -Path $hooksDir -Force | Out-Null
    }

    # Write a shell hook (Git for Windows uses bash for hooks)
    $hookContent = @'
#!/bin/sh
PROJECT_ROOT=$(git rev-parse --show-toplevel)
if ! bun run "$PROJECT_ROOT/scripts/validate_filenames.ts" --staged --quiet; then
    printf "\n"
    printf "Commit rejected: One or more filenames contain Windows-incompatible characters.\n"
    printf "Please rename the files to remove invalid characters before committing.\n"
    printf "\n"
    exit 1
fi
exit 0
'@
    Set-Content -Path "$hooksDir\pre-commit" -Value $hookContent -NoNewline
    Print-Success "Pre-commit hook installed"
}

function Setup-Secrets {
    Print-Step "Setting up API keys and secrets..."

    Set-Location $PROJECT_DIR

    if (Test-Path ".env") {
        Print-Info ".env file already exists"
        Print-Info "Run 'bun run scripts/load_infisical_env.ts --force' to refresh secrets"
    } else {
        Print-Info "Fetching secrets from Infisical..."
        try {
            bun run scripts/load_infisical_env.ts
            Print-Success "Secrets loaded to .env"
        } catch {
            Print-Warning "Could not load secrets — you may not have Infisical access"
            Print-Info "Contact Kristen or another admin to get access"
            Print-Info "You can still use the project, but some tools will be limited"
        }
    }
}

function Verify-Setup {
    Print-Step "Verifying setup..."

    Set-Location $PROJECT_DIR
    $allGood = $true

    $criticalCmds = @("git", "git-lfs", "gh", "bun")
    foreach ($cmd in $criticalCmds) {
        if (Test-CommandExists $cmd) {
            Print-Success $cmd
        } else {
            Print-Error "$cmd not found"
            $allGood = $false
        }
    }

    if (Test-CommandExists "scoop") {
        Print-Success "scoop"
    } else {
        Print-Warning "scoop not in PATH"
    }

    if (Test-CommandExists "claude") {
        Print-Success "claude"
    } else {
        Print-Warning "claude not in PATH (may need terminal restart)"
    }

    $pptxFile = "$PROJECT_DIR\templates\powerpoint\irrational_labs_powerpoint_template_3.pptx"
    if (Test-Path $pptxFile) {
        $size = (Get-Item $pptxFile).Length
        if ($size -gt $LFS_MIN_SIZE) {
            Print-Success "LFS files downloaded correctly"
        } else {
            Print-Error "LFS files are still pointer files"
            $allGood = $false
        }
    }

    return $allGood
}

function Print-Completion {
    Write-Host ""
    Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "  Setup Complete!" -ForegroundColor Green
    Write-Host "════════════════════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""
    Write-Host "Project location: $PROJECT_DIR"
    Write-Host ""
    Write-Host "Next steps:" -NoNewline; Write-Host ""
    Write-Host "  1. Open a new terminal window (to pick up PATH changes)"
    Write-Host "  2. Run:  cd ~\irrational_labs_hq; claude"
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
    Write-Host "Irrational Labs HQ — Setup (Windows)" -ForegroundColor White
    Write-Host "This will install everything you need."
    Write-Host "Takes about 5–10 minutes."
    Write-Host ""

    Ensure-Winget
    Ensure-Scoop
    Ensure-Git
    Ensure-GitHubAuth
    Ensure-GitIdentity
    Setup-Repository
    Ensure-Bun
    Install-CliTools
    Install-ProjectDeps
    Ensure-ClaudeCode
    Setup-GitHooks
    Setup-Secrets

    Write-Host ""
    if (Verify-Setup) {
        Print-Completion
    } else {
        Print-Warning "Setup completed with some issues"
        Print-Info "Try re-running this script or ask for help"
        Print-Completion
    }
}

Main
