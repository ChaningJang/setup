#!/bin/bash
# =============================================================================
# Irrational Labs HQ - Bootstrap Script
# =============================================================================
# One-command setup for new team members on macOS.
#
# Usage (from any terminal):
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ChaningJang/setup/main/bootstrap.sh)"
#
# This script is idempotent — safe to re-run to fix problems.
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
SETUP_RAW_BASE="https://raw.githubusercontent.com/ChaningJang/setup/main"
LFS_MIN_SIZE=1000

# Minimal fallback manifest if repos.json can't be fetched (offline / local run).
EMBEDDED_REPOS_JSON='{"repos":[{"key":"hq","name":"Irrational Labs HQ","slug":"IrrationalLabs-team/irrational_labs_hq","dir":"irrational_labs_hq","setup":"hq","default":true,"description":"Main workspace"}]}'

# Runtime state
FLAG_REPOS=""          # comma-separated repo keys, or empty
FLAG_BASE_ONLY=false
REPOS_JSON=""          # loaded manifest (string)
SELECTED_KEYS=()       # repo keys chosen to clone
WARNINGS=()            # non-fatal issues, reprinted at the end

# ---- Receipt state (what this run changed; written to disk by write_receipt) -
IL_FORMULAE_INSTALLED=()   # brew formulae we installed this run
IL_PATH_PROFILES=()        # shell profiles we added the il-setup PATH block to
IL_GWS_ENV_PROFILES=()     # shell profiles we added the il-setup:gws env block to
IL_REPOS_CLONED=()         # "path|created_dir" entries
IL_BREW_INSTALLED=false
IL_BUN_INSTALLED=false
IL_CLAUDE_INSTALLED=false
IL_GWS_INSTALLED=false
IL_SETTINGS_TOUCHED=false  # we wrote IL keys into ~/.claude/settings.json
IL_PRIOR_GIT_NAME=""
IL_PRIOR_GIT_EMAIL=""
IL_GH_AUTHED_BEFORE=""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

print_step()    { echo -e "\n${BLUE}${BOLD}▶ $1${NC}"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error()   { echo -e "${RED}✗ $1${NC}"; }
print_info()    { echo -e "  $1"; }

print_usage() {
    cat <<USAGE
Irrational Labs setup

Usage:
  bootstrap.sh [--repos key1,key2] [--base-only]

Options:
  --repos LIST   Comma-separated repo keys to clone (skips the menu).
                 e.g. --repos hq,marketing
  --base-only    Install base tools only; clone nothing.
  -h, --help     Show this help.

With no options, an interactive menu asks which repos to clone.
USAGE
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repos)      FLAG_REPOS="${2:-}"; shift 2 ;;
            --repos=*)    FLAG_REPOS="${1#*=}"; shift ;;
            --base-only)  FLAG_BASE_ONLY=true; shift ;;
            -h|--help)    print_usage; exit 0 ;;
            *)            print_warning "Unknown option: $1"; shift ;;
        esac
    done
}

command_exists() { command -v "$1" &>/dev/null; }

# -----------------------------------------------------------------------------
# Setup Steps
# -----------------------------------------------------------------------------

check_macos() {
    if [[ "$(uname -s)" != "Darwin" ]]; then
        print_error "This script currently only supports macOS."
        exit 1
    fi
}

ensure_xcode_cli() {
    print_step "Checking Xcode Command Line Tools..."

    if xcode-select -p &>/dev/null; then
        print_success "Xcode CLI tools already installed"
    else
        print_info "Installing Xcode Command Line Tools..."
        print_info "A popup may appear — click 'Install' and wait for it to complete."
        xcode-select --install 2>/dev/null || true

        until xcode-select -p &>/dev/null; do
            sleep 5
        done
        print_success "Xcode CLI tools installed"
    fi
}

ensure_homebrew() {
    print_step "Checking Homebrew..."

    if command_exists brew; then
        print_success "Homebrew already installed"
    else
        print_info "Installing Homebrew (you may need to enter your password)..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

        # Add brew to PATH for Apple Silicon
        if [[ -f "/opt/homebrew/bin/brew" ]]; then
            eval "$(/opt/homebrew/bin/brew shellenv)"
            SHELL_PROFILE=""
            if [[ -f "$HOME/.zshrc" ]]; then
                SHELL_PROFILE="$HOME/.zshrc"
            elif [[ -f "$HOME/.bash_profile" ]]; then
                SHELL_PROFILE="$HOME/.bash_profile"
            fi

            if [[ -n "$SHELL_PROFILE" ]]; then
                local brew_init='eval "$(/opt/homebrew/bin/brew shellenv)"'
                if ! grep -q "$brew_init" "$SHELL_PROFILE" 2>/dev/null; then
                    echo "$brew_init" >> "$SHELL_PROFILE"
                fi
            fi
        fi
        print_success "Homebrew installed"
        IL_BREW_INSTALLED=true
    fi

    # Ensure brew is in PATH for this session
    if [[ -f "/opt/homebrew/bin/brew" ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
}

ensure_early_tools() {
    print_step "Installing core tools (git, git-lfs, gh, jq, node, bun)..."

    if ! command_exists git;     then print_info "Installing git...";     brew install git     && record_formula_installed git;     fi
    print_success "git $(git --version | cut -d' ' -f3)"

    if ! command_exists git-lfs; then print_info "Installing git-lfs..."; brew install git-lfs && record_formula_installed git-lfs; fi
    git lfs install >/dev/null 2>&1
    print_success "git-lfs ready"

    if ! command_exists gh;      then print_info "Installing GitHub CLI..."; brew install gh   && record_formula_installed gh;      fi
    print_success "gh $(gh --version | head -1 | cut -d' ' -f3)"

    if ! command_exists jq;      then print_info "Installing jq...";      brew install jq      && record_formula_installed jq;      fi
    print_success "jq ready"

    # Node gives us npm, which we need to install global CLI tools like the
    # gws (Google Workspace) CLI in ensure_gws_cli. The Homebrew
    # node formula bundles npm, so this single install covers both.
    if ! command_exists npm;     then print_info "Installing Node (provides npm)..."; brew install node && record_formula_installed node; fi
    print_success "node $(node --version) / npm $(npm --version)"

    if command_exists bun; then
        print_success "bun $(bun --version)"
    else
        print_info "Installing Bun..."
        curl -fsSL https://bun.sh/install | bash
        export BUN_INSTALL="$HOME/.bun"
        export PATH="$BUN_INSTALL/bin:$PATH"
        if command_exists bun; then
            print_success "bun $(bun --version)"
            IL_BUN_INSTALLED=true
        else
            print_error "Bun installation failed"
            exit 1
        fi
    fi
}

ensure_github_auth() {
    print_step "Checking GitHub authentication..."

    if gh auth status &>/dev/null; then
        local gh_user
        gh_user=$(gh auth status 2>&1 | grep -o "Logged in to github.com account [^ ]*" | cut -d" " -f6 || echo "unknown")
        print_success "Already authenticated with GitHub as $gh_user"
    else
        print_info "Opening browser to authenticate with GitHub..."
        print_info "Please click 'Authorize' when prompted in your browser."
        echo ""

        gh auth login --web --git-protocol https

        if gh auth status &>/dev/null; then
            print_success "GitHub authentication successful"
        else
            print_error "GitHub authentication failed"
            print_info "Please try running: gh auth login"
            exit 1
        fi
    fi
}

ensure_git_identity() {
    print_step "Setting up Git commit identity..."

    local current_name current_email
    current_name=$(git config --global user.name 2>/dev/null || echo "")
    current_email=$(git config --global user.email 2>/dev/null || echo "")

    # Skip if already set to something sensible.
    # The "*.local" pattern is the OS default (user@hostname.local) — replace it.
    if [[ -n "$current_name" && -n "$current_email" && "$current_email" != *.local ]]; then
        print_success "Git identity already set ($current_name <$current_email>)"
        return 0
    fi

    if [[ "$current_email" == *.local ]]; then
        print_info "Existing email '$current_email' is an OS default — replacing with your GitHub identity"
    fi

    # Pull name and email from the authenticated GitHub account.
    local gh_name gh_email gh_login gh_id
    gh_name=$(gh api user --jq '.name // empty' 2>/dev/null || echo "")
    gh_email=$(gh api user --jq '.email // empty' 2>/dev/null || echo "")
    gh_login=$(gh api user --jq '.login // empty' 2>/dev/null || echo "")
    gh_id=$(gh api user --jq '.id // empty' 2>/dev/null || echo "")

    [[ -z "$gh_name" ]] && gh_name="$gh_login"

    # If the user keeps their email private, GitHub returns null.
    # Fall back to the privacy-preserving noreply address.
    if [[ -z "$gh_email" && -n "$gh_id" && -n "$gh_login" ]]; then
        gh_email="${gh_id}+${gh_login}@users.noreply.github.com"
        print_info "Your GitHub email is private — using $gh_email"
    fi

    if [[ -z "$gh_name" || -z "$gh_email" ]]; then
        print_warning "Could not determine Git identity from GitHub — skipping"
        print_info "Set manually: git config --global user.email \"you@example.com\""
        return 0
    fi

    git config --global user.name "$gh_name"
    git config --global user.email "$gh_email"
    print_success "Git identity set to $gh_name <$gh_email>"
}

install_shell_helpers() {
    print_step "Installing shell helpers..."
    local helpers=("ripgrep" "fd" "bat" "fzf" "git-delta")
    local to_install=() tool cmd
    for tool in "${helpers[@]}"; do
        cmd="$tool"
        case "$tool" in
            ripgrep)   cmd="rg" ;;
            git-delta) cmd="delta" ;;
        esac
        command_exists "$cmd" || to_install+=("$tool")
    done
    if [[ ${#to_install[@]} -eq 0 ]]; then
        print_success "Shell helpers already installed"
    else
        print_info "Installing: ${to_install[*]}"
        if brew install "${to_install[@]}"; then
            for _f in "${to_install[@]}"; do record_formula_installed "$_f"; done
            print_success "Shell helpers installed"
        else
            print_warning "Some shell helpers failed — continuing"
        fi
    fi
}

install_hq_extras() {
    print_step "Installing HQ media/doc tools..."
    local tools=(
        "marp-cli" "ghostscript" "ffmpeg" "exiftool" "yt-dlp" "pandoc"
        "imagemagick" "yq" "miller" "sd" "gawk" "coreutils" "parallel"
        "trash" "eza"
    )
    local to_install=() tool cmd
    for tool in "${tools[@]}"; do
        cmd="$tool"
        case "$tool" in
            "marp-cli")    cmd="marp" ;;
            "ghostscript") cmd="gs" ;;
            "imagemagick") cmd="magick" ;;
            "coreutils")   cmd="gtimeout" ;;
            "miller")      cmd="mlr" ;;
        esac
        command_exists "$cmd" || to_install+=("$tool")
    done
    if [[ ${#to_install[@]} -eq 0 ]]; then
        print_success "HQ tools already installed"
    else
        print_info "Installing: ${to_install[*]}"
        if brew install "${to_install[@]}"; then
            for _f in "${to_install[@]}"; do record_formula_installed "$_f"; done
            print_success "HQ tools installed"
        else
            print_warning "Some HQ tools failed — continuing"
        fi
    fi
}

repair_lfs_if_needed() {
    local dir="$1"
    local needs_repair=false
    local test_file="$dir/templates/powerpoint/irrational_labs_powerpoint_template_3.pptx"
    if [[ -f "$test_file" ]]; then
        local size
        size=$(stat -f%z "$test_file" 2>/dev/null || echo "0")
        [[ "$size" -lt "$LFS_MIN_SIZE" ]] && needs_repair=true
    else
        needs_repair=true
    fi
    if [[ "$needs_repair" == true ]]; then
        print_info "Downloading LFS files (this may take a few minutes)..."
        cd "$dir"
        git lfs install --local
        git lfs pull
        print_success "LFS files downloaded"
    else
        print_success "LFS files verified"
    fi
}

install_precommit_hook() {
    local dir="$1"
    cd "$dir"
    mkdir -p .git/hooks
    local hook_file=".git/hooks/pre-commit"
    cat > "$hook_file" << 'HOOK'
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
HOOK
    chmod +x "$hook_file"
    print_success "Pre-commit hook installed"
}

load_hq_secrets() {
    local dir="$1"
    cd "$dir"
    if [[ -f ".env" ]]; then
        print_info ".env already exists (run scripts/load_infisical_env.ts --force to refresh)"
    else
        print_info "Fetching secrets from Infisical..."
        if bun run scripts/load_infisical_env.ts; then
            print_success "Secrets loaded to .env"
        else
            WARNINGS+=("HQ: could not load Infisical secrets — ask an admin for access")
            print_warning "Could not load secrets — continuing"
        fi
    fi
}

setup_hq() {
    local dir="$1"
    print_step "Running HQ setup..."
    install_hq_extras
    repair_lfs_if_needed "$dir"
    cd "$dir"
    print_info "Running bun install..."
    bun install || WARNINGS+=("HQ: bun install failed")
    install_precommit_hook "$dir"
    load_hq_secrets "$dir"
    print_success "HQ setup complete"
}

setup_generic() {
    local dir="$1"
    local base
    base=$(basename "$dir")
    print_step "Running generic setup for $base..."
    cd "$dir"
    if [[ -f package.json ]]; then
        print_info "Found package.json — running bun install"
        bun install || WARNINGS+=("$base: bun install failed")
    fi
    if [[ -f .gitattributes ]] && grep -q "filter=lfs" .gitattributes 2>/dev/null; then
        print_info "Repo uses Git LFS — pulling LFS files"
        git lfs install --local >/dev/null 2>&1 || true
        git lfs pull || WARNINGS+=("$base: git lfs pull failed")
    fi
    if [[ ! -f .env ]]; then
        local example=""
        [[ -f .env.example ]] && example=".env.example"
        [[ -z "$example" && -f .env.sample ]] && example=".env.sample"
        if [[ -n "$example" ]]; then
            cp "$example" .env
            print_info "Created .env from $example — fill in secrets before use"
            WARNINGS+=("$base: created .env from $example — needs your secrets")
        fi
    fi
    print_success "$base ready — check its README for any extra setup"
}

clone_and_setup_repo() {
    local key="$1"
    local slug dir setup target
    slug=$(repo_field "$key" slug)
    dir=$(repo_field "$key" dir)
    setup=$(repo_field "$key" setup)
    target="$HOME/$dir"

    if [[ -z "$slug" ]]; then
        print_warning "Unknown repo key '$key' — skipping"
        return 0
    fi

    print_step "Setting up $slug..."

    if [[ -d "$target/.git" ]]; then
        print_info "Already cloned at $target — pulling latest"
        ( cd "$target" && git pull --ff-only ) || true
    else
        local parent created_dir=false
        parent="$(dirname "$target")"
        [[ -d "$parent" ]] || created_dir=true
        mkdir -p "$parent"
        if ! gh repo clone "$slug" "$target"; then
            WARNINGS+=("Could not clone $slug — check your GitHub access")
            print_error "Failed to clone $slug (continuing)"
            return 0
        fi
        record_repo_cloned "$target" "$created_dir"
        print_success "Cloned $slug"
    fi

    case "$setup" in
        hq)      setup_hq "$target" ;;
        generic) setup_generic "$target" ;;
        *)       setup_generic "$target" ;;
    esac
}

ensure_claude_code() {
    print_step "Checking Claude Code..."

    # Ensure ~/.local/bin is on PATH for this session
    export PATH="$HOME/.local/bin:$PATH"

    if command_exists claude; then
        print_success "Claude Code already installed"
    else
        print_info "Installing Claude Code..."
        curl -fsSL https://claude.ai/install.sh | bash

        # Re-add in case the installer overwrote PATH
        export PATH="$HOME/.local/bin:$PATH"

        if command_exists claude; then
            print_success "Claude Code installed"
            IL_CLAUDE_INSTALLED=true
        else
            print_error "Claude Code installation failed"
            print_info "Please try manually: curl -fsSL https://claude.ai/install.sh | bash"
            WARNINGS+=("Claude Code install failed — try manually: curl -fsSL https://claude.ai/install.sh | bash")
        fi
    fi

    # Persist ~/.local/bin in shell profile(s) so future terminals find claude.
    # Pick profiles based on $SHELL (not just what files exist) — otherwise a
    # bash user with a stock ~/.zshrc gets the PATH line written to a file
    # their shell never sources.
    local profiles=()
    case "${SHELL:-}" in
        */zsh)
            profiles=("$HOME/.zshrc")
            ;;
        */bash)
            profiles=("$HOME/.bash_profile" "$HOME/.bashrc")
            ;;
        *)
            # Unknown shell — cover the common macOS cases.
            profiles=("$HOME/.zshrc" "$HOME/.bash_profile")
            ;;
    esac

    local path_line='export PATH="$HOME/.local/bin:$PATH"'
    local wrote_any=false
    for shell_profile in "${profiles[@]}"; do
        if ! grep -qF '.local/bin' "$shell_profile" 2>/dev/null; then
            write_il_path_block "$shell_profile" "$path_line"
            print_success "Added ~/.local/bin to PATH in $(basename "$shell_profile")"
            wrote_any=true
        fi
    done

    if [[ "$wrote_any" == false ]]; then
        print_info "PATH already includes ~/.local/bin in your shell profile"
    fi

    # Final sanity check — fail loudly if claude still isn't resolvable.
    hash -r 2>/dev/null || true
    if ! command_exists claude; then
        print_error "claude installed but not found on PATH"
        print_info "Open a new terminal, or run: source ${profiles[0]}"
        WARNINGS+=("Claude Code installed but not yet on PATH — open a new terminal to use it")
    fi
}

# -----------------------------------------------------------------------------
# gws (Google Workspace) — the whole stack, installed here rather than assumed
# -----------------------------------------------------------------------------
# A working gws needs THREE things, and a teammate is broken if any one of them
# is missing:
#
#   1. the `gws` npm CLI                    -> ensure_gws_cli
#   2. the IL `gws` Claude Code plugin      -> ensure_il_claude_plugins
#      (supplies /gws:setup, the gws skill, and the destructive-op guard hook)
#   3. GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file  -> ensure_gws_keyring_env
#
# Between 2026-07-30 and now, (2) was left to the claude.ai org's "Installed by
# default" push and (3) was never installed at all. The org push did not reach
# teammates' machines, so people ended up with the bare CLI, no /gws:setup, and
# — for anyone who authed anyway — a keyring backend that silently eats their
# credentials. All three are installed explicitly here now. Do not "simplify"
# this back down to the npm install.

ensure_gws_keyring_env() {
    print_step "Installing the gws keyring guard..."

    # CRITICAL, non-negotiable. gws's default keyring backend (macOS Keychain)
    # silently DELETES ~/.config/gws/credentials.enc — a single invocation
    # without this var set can wipe an already-working login, and the failure
    # looks like "gws randomly stopped working" days later. The var must be set
    # for EVERY gws invocation, not just interactive ones, so this writes to:
    #
    #   ~/.zshenv   — read by ALL zsh invocations, including non-interactive
    #                 ones (cron, launchd, scripts). ~/.zshrc is NOT enough:
    #                 it is interactive-only, and cron jobs calling gws are
    #                 exactly the case that re-triggers the wipe.
    #   ~/.bash_profile + ~/.bashrc — same coverage for bash users.
    #   ~/.claude/settings.json "env" — covers Claude Code's own Bash calls
    #                 regardless of which shell/profile the user ends up in.
    local export_line='export GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file'
    local profiles=("$HOME/.zshenv" "$HOME/.bash_profile" "$HOME/.bashrc")
    local shell_profile wrote_any=false

    for shell_profile in "${profiles[@]}"; do
        # Create the file if absent — .zshenv in particular often doesn't exist
        # yet, and it is the one that matters most.
        [[ -f "$shell_profile" ]] || : > "$shell_profile"
        if grep -qF 'GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND' "$shell_profile" 2>/dev/null; then
            continue
        fi
        write_il_marker_block "$shell_profile" "gws" "$export_line" && wrote_any=true
        IL_GWS_ENV_PROFILES+=("$shell_profile")
    done

    if [[ "$wrote_any" == true ]]; then
        print_success "GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file added to your shell profiles"
    else
        print_info "Keyring guard already present in your shell profiles"
    fi

    # Belt and braces: also set it for Claude Code sessions directly, so the
    # guard holds even if the user's login shell never sources those profiles.
    local settings="$HOME/.claude/settings.json"
    mkdir -p "$HOME/.claude"
    [[ -f "$settings" ]] || echo '{}' > "$settings"
    if command_exists jq; then
        local tmp; tmp="$(mktemp)"
        if jq '.env["GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND"] = "file"' "$settings" > "$tmp" 2>/dev/null; then
            mv "$tmp" "$settings"
            IL_SETTINGS_TOUCHED=true
            print_success "Keyring guard set for Claude Code sessions too"
        else
            rm -f "$tmp"
            print_warning "Couldn't set the keyring guard in settings.json (left untouched)"
        fi
    fi

    # Make it true for the rest of THIS run as well — ensure_gws_cli and any
    # later gws call in this process must not run on the keychain backend.
    export GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file
}

ensure_il_claude_plugins() {
    print_step "Registering the Irrational Labs Claude Code plugins..."

    local claude_dir="$HOME/.claude"
    local settings="$claude_dir/settings.json"

    mkdir -p "$claude_dir"
    [[ -f "$settings" ]] || echo '{}' > "$settings"

    if ! command_exists jq; then
        print_warning "jq not available — skipping plugin registration"
        WARNINGS+=("IL plugins not registered (jq missing) — re-run this script once jq is installed")
        return 0
    fi

    # Registered explicitly rather than left to the claude.ai org's
    # "Installed by default" push. The org push is a nice-to-have that has not
    # proven reliable on fresh machines; this line is what actually guarantees
    # a teammate gets /gws:setup and the gws skill from the one setup command.
    # Registering it twice is harmless — Claude Code dedupes by marketplace name.
    #
    # Marketplace registration is always (re)set. Per-plugin enabled flags use
    # |= with a null-check so defaults are only set the FIRST time: if someone
    # has explicitly disabled a plugin, re-running leaves that decision intact.
    local tmp; tmp="$(mktemp)"
    if jq '
      .extraKnownMarketplaces["irrational-labs-plugins"] = {
        "source": {
          "source": "github",
          "repo": "IrrationalLabs-team/knowledge-work-plugins"
        }
      }
      | .enabledPlugins["gws@irrational-labs-plugins"]          |= (if . == null then true else . end)
      | .enabledPlugins["il-slides@irrational-labs-plugins"]    |= (if . == null then true else . end)
      | .enabledPlugins["key-behavior@irrational-labs-plugins"] |= (if . == null then true else . end)
    ' "$settings" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$settings"
        IL_SETTINGS_TOUCHED=true
        print_success "IL plugin marketplace registered"
        print_info "Default-on: gws, il-slides, key-behavior"
        print_info "Available on demand: pipedrive, figma-port, my-chief-of-staff, il-qol"
        print_info "  install with: /plugin install <name>@irrational-labs-plugins"
    else
        rm -f "$tmp"
        print_warning "Couldn't write plugin registration to settings.json"
        WARNINGS+=("IL plugins not registered — settings.json may be malformed")
    fi
}

ensure_gws_cli() {
    print_step "Setting up the gws (Google Workspace) CLI..."

    # The npm CLI the gws plugin drives. (npm is guaranteed by
    # ensure_early_tools, which runs earlier in main.)
    if command_exists gws; then
        print_success "gws CLI $(gws --version 2>/dev/null | head -1 | cut -d' ' -f2)"
    elif command_exists npm; then
        print_info "Installing gws (Google Workspace) CLI..."
        if npm install -g @googleworkspace/cli >/dev/null 2>&1; then
            hash -r 2>/dev/null || true
            print_success "gws CLI installed"
            IL_GWS_INSTALLED=true
        else
            print_warning "gws CLI install failed"
            WARNINGS+=("gws CLI not installed — run: npm install -g @googleworkspace/cli")
        fi
    else
        print_warning "npm not available — skipping gws CLI install"
        WARNINGS+=("gws CLI not installed (npm missing) — run: npm install -g @googleworkspace/cli")
    fi
    print_info "Next: restart Claude Code, then run /gws:setup and sign in with @irrationallabs.com"
}

load_manifest() {
    print_step "Loading repo list..."
    local fetched=""
    fetched=$(curl -fsSL "$SETUP_RAW_BASE/repos.json" 2>/dev/null || echo "")
    if [[ -n "$fetched" ]] && echo "$fetched" | jq empty >/dev/null 2>&1; then
        REPOS_JSON="$fetched"
        print_success "Repo list loaded"
    else
        REPOS_JSON="$EMBEDDED_REPOS_JSON"
        print_warning "Couldn't fetch repo list — using built-in default (HQ only)"
    fi
}

# repo_field <key> <field>  -> prints the field value (empty if not found)
repo_field() {
    echo "$REPOS_JSON" | jq -r --arg k "$1" --arg f "$2" \
        '.repos[] | select(.key==$k) | .[$f] // empty'
}

all_repo_keys() {
    echo "$REPOS_JSON" | jq -r '.repos[].key'
}

select_repos() {
    SELECTED_KEYS=()

    if [[ "$FLAG_BASE_ONLY" == true ]]; then
        print_info "Base-only mode — no repositories will be cloned"
        return 0
    fi

    # Non-interactive: keys passed via --repos
    if [[ -n "$FLAG_REPOS" ]]; then
        local IFS=','
        local k
        for k in $FLAG_REPOS; do
            k=$(echo "$k" | tr -d '[:space:]')
            [[ -z "$k" ]] && continue
            if [[ -n "$(repo_field "$k" key)" ]]; then
                SELECTED_KEYS+=("$k")
            else
                print_warning "Unknown repo key '$k' — skipping"
            fi
        done
        return 0
    fi

    # Interactive: build the access-filtered list
    print_step "Checking which repos you can access..."
    local keys=() names=() descs=()
    local key slug
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        slug=$(repo_field "$key" slug)
        if gh repo view "$slug" >/dev/null 2>&1; then
            keys+=("$key")
            names+=("$(repo_field "$key" name)")
            descs+=("$(repo_field "$key" description)")
        fi
    done <<EOF
$(all_repo_keys)
EOF

    # Fallback: if access couldn't be verified for anything, show the full list.
    if [[ ${#keys[@]} -eq 0 ]]; then
        print_warning "Couldn't verify repo access — showing the full list"
        while IFS= read -r key; do
            [[ -z "$key" ]] && continue
            keys+=("$key")
            names+=("$(repo_field "$key" name)")
            descs+=("$(repo_field "$key" description)")
        done <<EOF
$(all_repo_keys)
EOF
    fi

    # Render the menu to the terminal (stdin is the piped script, so use /dev/tty).
    {
        echo ""
        echo "Which repositories do you want to clone?"
        local i num
        for i in "${!keys[@]}"; do
            num=$((i + 1))
            printf "  %d) %s — %s\n" "$num" "${names[$i]}" "${descs[$i]}"
        done
        echo "  0) None (base tools only)"
        echo ""
        printf "Enter numbers separated by spaces or commas (default: 1): "
    } > /dev/tty

    local answer=""
    read -r answer < /dev/tty || answer=""
    [[ -z "$answer" ]] && answer="1"
    answer="${answer//,/ }"

    local tok idx
    for tok in $answer; do
        if [[ "$tok" == "0" ]]; then
            SELECTED_KEYS=()
            return 0
        fi
        if [[ "$tok" =~ ^[0-9]+$ ]]; then
            idx=$((tok - 1))
            if [[ $idx -ge 0 && $idx -lt ${#keys[@]} ]]; then
                SELECTED_KEYS+=("${keys[$idx]}")
            else
                print_warning "Ignoring out-of-range choice: $tok"
            fi
        fi
    done
}


verify_setup() {
    print_step "Verifying setup..."
    local all_good=true cmd
    local critical=("git" "git-lfs" "gh" "bun" "jq" "node" "npm" "brew")
    for cmd in "${critical[@]}"; do
        if command_exists "$cmd"; then
            print_success "$cmd"
        else
            print_error "$cmd not found"
            all_good=false
        fi
    done
    if command_exists claude; then
        print_success "claude"
    else
        print_warning "claude not in PATH (may need terminal restart)"
    fi
    [[ "$all_good" == true ]] && return 0 || return 1
}

print_completion() {
    echo ""
    echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}  Setup Complete!${NC}"
    echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"

    if [[ ${#WARNINGS[@]} -gt 0 ]]; then
        echo ""
        echo -e "${YELLOW}${BOLD}Heads up — a few things need attention:${NC}"
        local w
        for w in "${WARNINGS[@]}"; do
            echo -e "  ${YELLOW}•${NC} $w"
        done
    fi

    echo ""
    echo -e "${BOLD}Next steps:${NC}"
    echo "  1. Open a new terminal window (to pick up PATH changes)"
    echo "  2. cd into a cloned repo and run:  claude"
    echo "  3. Ask Claude: 'Give me a tour of this project'"
    echo ""
    echo -e "${BOLD}If you run into issues:${NC}"
    echo "  • Re-run this script to repair problems"
    echo "  • Ask Chaning or Kristen for help"
    echo ""
}

il_receipt_path() {
    echo "${IL_SETUP_RECEIPT:-$HOME/.config/il-setup/receipt.json}"
}

record_formula_installed() { IL_FORMULAE_INSTALLED+=("$1"); }
record_path_profile()      { IL_PATH_PROFILES+=("$1"); }
record_repo_cloned()       { IL_REPOS_CLONED+=("$1|$2"); }   # path, created_dir(true/false)

# Read state we are about to overwrite. Prefer values already saved in the
# receipt (so re-runs keep the ORIGINAL pre-setup state), else read live.
capture_prior_state() {
    local path; path="$(il_receipt_path)"
    if command_exists jq && [[ -f "$path" ]] && [[ "$(jq -r 'has("git_identity_prior")' "$path" 2>/dev/null)" == "true" ]]; then
        IL_PRIOR_GIT_NAME="$(jq -r '.git_identity_prior.name // ""' "$path")"
        IL_PRIOR_GIT_EMAIL="$(jq -r '.git_identity_prior.email // ""' "$path")"
    else
        IL_PRIOR_GIT_NAME="$(git config --global user.name 2>/dev/null || echo "")"
        IL_PRIOR_GIT_EMAIL="$(git config --global user.email 2>/dev/null || echo "")"
    fi
    if command_exists jq && [[ -f "$path" ]] && [[ "$(jq -r 'has("gh_was_authenticated_before")' "$path" 2>/dev/null)" == "true" ]]; then
        IL_GH_AUTHED_BEFORE="$(jq -r '.gh_was_authenticated_before' "$path")"
    elif gh auth status >/dev/null 2>&1; then
        IL_GH_AUTHED_BEFORE="true"
    else
        IL_GH_AUTHED_BEFORE="false"
    fi
}

# Serialize in-memory receipt state to disk. Merges with any existing receipt so
# re-runs accumulate; prior-state fields are written only if not already present.
write_receipt() {
    command_exists jq || { print_warning "jq unavailable — skipping setup receipt"; return 0; }
    local path; path="$(il_receipt_path)"
    mkdir -p "$(dirname "$path")"
    [[ -f "$path" ]] || echo '{}' > "$path"

    local formulae_json profiles_json repos_json gwsenv_json
    formulae_json="$(printf '%s\n' "${IL_FORMULAE_INSTALLED[@]:-}" | jq -R 'select(length>0)' | jq -s .)"
    profiles_json="$(printf '%s\n' "${IL_PATH_PROFILES[@]:-}"   | jq -R 'select(length>0)' | jq -s .)"
    gwsenv_json="$(printf '%s\n' "${IL_GWS_ENV_PROFILES[@]:-}"  | jq -R 'select(length>0)' | jq -s .)"
    repos_json="$(printf '%s\n' "${IL_REPOS_CLONED[@]:-}" \
        | jq -R 'select(length>0) | split("|") | {path: .[0], created_dir: (.[1]=="true")}' | jq -s .)"

    local tmp; tmp="$(mktemp)"
    jq \
        --argjson formulae "$formulae_json" \
        --argjson profiles "$profiles_json" \
        --argjson gwsenv "$gwsenv_json" \
        --argjson repos "$repos_json" \
        --arg settings "$IL_SETTINGS_TOUCHED" \
        --arg brew "$IL_BREW_INSTALLED" \
        --arg bun "$IL_BUN_INSTALLED" \
        --arg claude "$IL_CLAUDE_INSTALLED" \
        --arg gws "$IL_GWS_INSTALLED" \
        --arg gname "$IL_PRIOR_GIT_NAME" \
        --arg gemail "$IL_PRIOR_GIT_EMAIL" \
        --arg ghbefore "$IL_GH_AUTHED_BEFORE" \
        '
        .schema_version = 1
        | .formulae_installed_by_us = (((.formulae_installed_by_us // []) + $formulae) | unique)
        | .path_edits = (((.path_edits // []) + $profiles) | unique)
        | .gws_env_edits = (((.gws_env_edits // []) + $gwsenv) | unique)
        | .repos_cloned = (((.repos_cloned // []) + $repos) | unique_by(.path))
        | .brew_installed_by_us       = ((.brew_installed_by_us // false)       or ($brew == "true"))
        | .bun_installed_by_us        = ((.bun_installed_by_us // false)        or ($bun == "true"))
        | .claude_code_installed_by_us= ((.claude_code_installed_by_us // false) or ($claude == "true"))
        | .gws_cli_installed_by_us    = ((.gws_cli_installed_by_us // false)    or ($gws == "true"))
        | (if (has("git_identity_prior")) then . else .git_identity_prior = {name: $gname, email: $gemail} end)
        | (if (has("gh_was_authenticated_before")) then . else .gh_was_authenticated_before = ($ghbefore == "true") end)
        ' "$path" > "$tmp" && mv "$tmp" "$path"
}

# Append a marker-delimited block to a profile, once. The marker is keyed so a
# profile can carry several independent il-setup blocks (PATH, gws env, ...)
# without one suppressing the others. Key "" keeps the original unkeyed marker
# so machines bootstrapped before this change still uninstall cleanly.
#   write_il_marker_block <profile> <key> <line>
write_il_marker_block() {
    local profile="$1" key="$2" line="$3"
    local open close
    if [[ -n "$key" ]]; then
        open="# >>> il-setup:$key >>>"; close="# <<< il-setup:$key <<<"
    else
        open="# >>> il-setup >>>";      close="# <<< il-setup <<<"
    fi
    if grep -qF "$open" "$profile" 2>/dev/null; then
        return 1
    fi
    {
        echo ""
        echo "$open"
        echo "$line"
        echo "$close"
    } >> "$profile"
    return 0
}

# Append a marker-delimited PATH block to a profile, once, and record it so the
# uninstaller can remove exactly this block.
write_il_path_block() {
    local profile="$1" line="$2"
    if grep -qF '# >>> il-setup >>>' "$profile" 2>/dev/null; then
        return 0
    fi
    {
        echo ""
        echo "# >>> il-setup >>>"
        echo "$line"
        echo "# <<< il-setup <<<"
    } >> "$profile"
    record_path_profile "$profile"
}

# -----------------------------------------------------------------------------
# Main
# -----------------------------------------------------------------------------

main() {
    parse_args "$@"

    echo ""
    echo -e "${BOLD}Irrational Labs — Setup${NC}"
    echo -e "This will install your dev tools, then ask which repos to clone."
    echo ""

    check_macos
    ensure_xcode_cli
    ensure_homebrew
    ensure_early_tools          # step 3: git, git-lfs, gh, jq, bun
    capture_prior_state         # record pre-setup git identity + gh auth state
    ensure_github_auth          # step 4
    ensure_git_identity
    ensure_claude_code          # step 5: Claude available before anything that can fail
    ensure_gws_keyring_env      # MUST precede any gws call — see the function comment
    ensure_il_claude_plugins
    ensure_gws_cli
    load_manifest               # step 6
    select_repos
    install_shell_helpers       # step 7

    if [[ ${#SELECTED_KEYS[@]} -gt 0 ]]; then          # guard: bash 3.2 + set -u
        local k
        set +e
        for k in "${SELECTED_KEYS[@]}"; do
            clone_and_setup_repo "$k"
        done
        set -e
    else
        print_info "No repositories selected — base tools only"
    fi

    echo ""
    write_receipt               # persist what this run changed (for the uninstaller)
    verify_setup || print_warning "Setup completed with some issues"
    print_completion
}

# Run main unless this file is being sourced (e.g. by tests).
(return 0 2>/dev/null) || main "$@"
