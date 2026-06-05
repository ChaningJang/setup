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
ORG="IrrationalLabs-team"
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
    fi

    # Ensure brew is in PATH for this session
    if [[ -f "/opt/homebrew/bin/brew" ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
}

ensure_early_tools() {
    print_step "Installing core tools (git, git-lfs, gh, jq, bun)..."

    command_exists git     || { print_info "Installing git...";     brew install git; }
    print_success "git $(git --version | cut -d' ' -f3)"

    command_exists git-lfs || { print_info "Installing git-lfs..."; brew install git-lfs; }
    git lfs install >/dev/null 2>&1
    print_success "git-lfs ready"

    command_exists gh      || { print_info "Installing GitHub CLI..."; brew install gh; }
    print_success "gh $(gh --version | head -1 | cut -d' ' -f3)"

    command_exists jq      || { print_info "Installing jq...";      brew install jq; }
    print_success "jq ready"

    if command_exists bun; then
        print_success "bun $(bun --version)"
    else
        print_info "Installing Bun..."
        curl -fsSL https://bun.sh/install | bash
        export BUN_INSTALL="$HOME/.bun"
        export PATH="$BUN_INSTALL/bin:$PATH"
        if command_exists bun; then
            print_success "bun $(bun --version)"
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
        brew install "${to_install[@]}" || print_warning "Some shell helpers failed — continuing"
        print_success "Shell helpers installed"
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
        brew install "${to_install[@]}" || print_warning "Some HQ tools failed — continuing"
        print_success "HQ tools installed"
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
        mkdir -p "$(dirname "$target")"
        if ! gh repo clone "$slug" "$target"; then
            WARNINGS+=("Could not clone $slug — check your GitHub access")
            print_error "Failed to clone $slug (continuing)"
            return 0
        fi
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
            echo "" >> "$shell_profile"
            echo "# Claude Code" >> "$shell_profile"
            echo "$path_line" >> "$shell_profile"
            print_success "Added ~/.local/bin to PATH in $(basename "$shell_profile")"
            wrote_any=true
        fi
    done

    if [[ "$wrote_any" == false ]]; then
        print_info "~/.local/bin already on PATH in shell profile"
    fi

    # Final sanity check — fail loudly if claude still isn't resolvable.
    hash -r 2>/dev/null || true
    if ! command_exists claude; then
        print_error "claude installed but not found on PATH"
        print_info "Open a new terminal, or run: source ${profiles[0]}"
        WARNINGS+=("Claude Code installed but not yet on PATH — open a new terminal to use it")
    fi
}

ensure_il_claude_plugins() {
    print_step "Setting up Irrational Labs Claude Code plugins..."

    local claude_dir="$HOME/.claude"
    local settings="$claude_dir/settings.json"

    mkdir -p "$claude_dir"
    [[ -f "$settings" ]] || echo '{}' > "$settings"

    if ! command_exists jq; then
        print_warning "jq not available — skipping plugin setup"
        return 0
    fi

    # Marketplace registration is always (re)set — registering it is the
    # baseline requirement for everything else here. Per-plugin enabled flags
    # use |= with a null-check so we only set defaults the FIRST time the
    # bootstrap runs. If a teammate has explicitly disabled a plugin
    # (enabledPlugins[...] = false), re-running the bootstrap leaves their
    # decision intact.
    local tmp
    tmp=$(mktemp)

    jq '
      .extraKnownMarketplaces["irrational-labs-plugins"] = {
        "source": {
          "source": "github",
          "repo": "IrrationalLabs-team/knowledge-work-plugins"
        }
      }
      | .enabledPlugins["gws@irrational-labs-plugins"]          |= (if . == null then true else . end)
      | .enabledPlugins["il-slides@irrational-labs-plugins"]    |= (if . == null then true else . end)
      | .enabledPlugins["key-behavior@irrational-labs-plugins"] |= (if . == null then true else . end)
    ' "$settings" > "$tmp" && mv "$tmp" "$settings"

    print_success "IL plugin marketplace registered"
    print_info "Default-on: gws, il-slides, key-behavior"
    print_info "Available on demand: gorilla-scripting, pipedrive"
    print_info "  install with: /plugin install <name>@irrational-labs-plugins"
    print_info "(default plugins auto-install on next 'claude' launch)"
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
    local critical=("git" "git-lfs" "gh" "bun" "jq" "brew")
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
    ensure_github_auth          # step 4
    ensure_git_identity
    ensure_claude_code          # step 5: Claude available before anything that can fail
    ensure_il_claude_plugins
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
    verify_setup || print_warning "Setup completed with some issues"
    print_completion
}

main "$@"
