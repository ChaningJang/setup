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
REPO_URL="IrrationalLabs-team/irrational_labs_hq"
PROJECT_DIR="$HOME/irrational_labs_hq"
LFS_MIN_SIZE=1000

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

ensure_git_tools() {
    print_step "Setting up Git and Git LFS..."

    if ! command_exists git; then
        print_info "Installing git..."
        brew install git
    fi
    print_success "git $(git --version | cut -d' ' -f3)"

    if ! command_exists git-lfs; then
        print_info "Installing git-lfs..."
        brew install git-lfs
    fi
    git lfs install >/dev/null 2>&1
    print_success "git-lfs $(git lfs version | head -1 | cut -d' ' -f1 | cut -d'/' -f2)"

    if ! command_exists gh; then
        print_info "Installing GitHub CLI..."
        brew install gh
    fi
    print_success "gh $(gh --version | head -1 | cut -d' ' -f3)"
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

setup_repository() {
    print_step "Setting up repository..."

    if [[ -d "$PROJECT_DIR/.git" ]]; then
        print_info "Repository already exists at $PROJECT_DIR"
        cd "$PROJECT_DIR"

        local remote_url
        remote_url=$(git remote get-url origin 2>/dev/null || echo "")

        if [[ "$remote_url" != *"irrational_labs_hq"* ]]; then
            print_error "Directory exists but is not the irrational_labs_hq repo!"
            print_info "Please remove or rename $PROJECT_DIR and re-run this script."
            exit 1
        fi

        print_info "Pulling latest changes..."
        git pull --ff-only || true

        print_info "Verifying LFS files..."
        repair_lfs_if_needed
    else
        print_info "Cloning repository to $PROJECT_DIR..."
        mkdir -p "$(dirname "$PROJECT_DIR")"

        gh repo clone "$REPO_URL" "$PROJECT_DIR"
        cd "$PROJECT_DIR"
        print_success "Repository cloned successfully"

        repair_lfs_if_needed
    fi
}

repair_lfs_if_needed() {
    local needs_repair=false
    local test_file="$PROJECT_DIR/templates/powerpoint/irrational_labs_powerpoint_template_3.pptx"

    if [[ -f "$test_file" ]]; then
        local file_size
        file_size=$(stat -f%z "$test_file" 2>/dev/null || echo "0")
        if [[ "$file_size" -lt "$LFS_MIN_SIZE" ]]; then
            print_warning "LFS files appear to be pointer files (not downloaded)"
            needs_repair=true
        fi
    else
        needs_repair=true
    fi

    if [[ "$needs_repair" == true ]]; then
        print_info "Downloading LFS files (this may take a few minutes)..."
        cd "$PROJECT_DIR"
        git lfs install --local
        git lfs pull
        print_success "LFS files downloaded"
    else
        print_success "LFS files verified"
    fi
}

ensure_bun() {
    print_step "Checking Bun..."

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
            print_info "Please try manually: curl -fsSL https://bun.sh/install | bash"
            exit 1
        fi
    fi
}

install_cli_tools() {
    print_step "Installing CLI tools..."

    local core_tools=(
        "marp-cli"
        "ghostscript"
        "ffmpeg"
        "exiftool"
        "yt-dlp"
        "pandoc"
        "imagemagick"
        "yq"
        "jq"
    )

    local enhanced_tools=(
        "eza"
        "fd"
        "ripgrep"
        "sd"
        "gawk"
        "bat"
        "coreutils"
        "fzf"
        "git-delta"
        "miller"
        "parallel"
        "trash"
    )

    local all_tools=("${core_tools[@]}" "${enhanced_tools[@]}")
    local to_install=()

    for tool in "${all_tools[@]}"; do
        local cmd="$tool"
        case "$tool" in
            "marp-cli") cmd="marp" ;;
            "ghostscript") cmd="gs" ;;
            "imagemagick") cmd="magick" ;;
            "ripgrep") cmd="rg" ;;
            "coreutils") cmd="gtimeout" ;;
            "git-delta") cmd="delta" ;;
            "miller") cmd="mlr" ;;
            "trash") cmd="trash" ;;
        esac

        if ! command_exists "$cmd"; then
            to_install+=("$tool")
        fi
    done

    if [[ ${#to_install[@]} -eq 0 ]]; then
        print_success "All CLI tools already installed"
    else
        print_info "Installing: ${to_install[*]}"
        brew install "${to_install[@]}" || {
            print_warning "Some tools failed to install — continuing anyway"
        }
        print_success "CLI tools installed"
    fi
}

install_project_deps() {
    print_step "Installing project dependencies..."

    cd "$PROJECT_DIR"

    print_info "Running bun install..."
    bun install
    print_success "Project dependencies installed"
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
            exit 1
        fi
    fi

    # Persist ~/.local/bin in shell profile so future terminals find claude
    local shell_profile="$HOME/.zshrc"
    [[ -f "$shell_profile" ]] || shell_profile="$HOME/.bash_profile"
    [[ -f "$shell_profile" ]] || shell_profile="$HOME/.zshrc"  # default to zshrc

    local path_line='export PATH="$HOME/.local/bin:$PATH"'
    if ! grep -qF '.local/bin' "$shell_profile" 2>/dev/null; then
        echo "" >> "$shell_profile"
        echo "# Claude Code" >> "$shell_profile"
        echo "$path_line" >> "$shell_profile"
        print_success "Added ~/.local/bin to PATH in $(basename "$shell_profile")"
    fi
}

setup_git_hooks() {
    print_step "Setting up git hooks..."

    cd "$PROJECT_DIR"
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

setup_secrets() {
    print_step "Setting up API keys and secrets..."

    cd "$PROJECT_DIR"

    if [[ -f ".env" ]]; then
        print_info ".env file already exists"
        print_info "Run 'bun run scripts/load_infisical_env.ts --force' to refresh secrets"
    else
        print_info "Fetching secrets from Infisical..."
        if bun run scripts/load_infisical_env.ts; then
            print_success "Secrets loaded to .env"
        else
            print_warning "Could not load secrets — you may not have Infisical access"
            print_info "Contact Kristen or another admin to get access"
            print_info "You can still use the project, but some tools will be limited"
        fi
    fi
}

verify_setup() {
    print_step "Verifying setup..."

    cd "$PROJECT_DIR"
    local all_good=true

    local critical_cmds=("git" "git-lfs" "gh" "bun" "brew")
    for cmd in "${critical_cmds[@]}"; do
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

    local pptx_file="$PROJECT_DIR/templates/powerpoint/irrational_labs_powerpoint_template_3.pptx"
    if [[ -f "$pptx_file" ]]; then
        local size
        size=$(stat -f%z "$pptx_file" 2>/dev/null || echo "0")
        if [[ "$size" -gt "$LFS_MIN_SIZE" ]]; then
            print_success "LFS files downloaded correctly"
        else
            print_error "LFS files are still pointer files"
            all_good=false
        fi
    fi

    if [[ "$all_good" == true ]]; then
        return 0
    else
        return 1
    fi
}

print_completion() {
    echo ""
    echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}${BOLD}  Setup Complete!${NC}"
    echo -e "${GREEN}${BOLD}════════════════════════════════════════════════════════════${NC}"
    echo ""
    echo -e "Project location: ${BOLD}$PROJECT_DIR${NC}"
    echo ""
    echo -e "${BOLD}Next steps:${NC}"
    echo "  1. Open a new terminal window (to pick up PATH changes)"
    echo "  2. Run:  cd ~/irrational_labs_hq && claude"
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
    echo ""
    echo -e "${BOLD}Irrational Labs HQ — Setup${NC}"
    echo -e "This will install everything you need."
    echo -e "Takes about 5–10 minutes."
    echo ""

    check_macos
    ensure_xcode_cli
    ensure_homebrew
    ensure_git_tools
    ensure_github_auth
    setup_repository
    ensure_bun
    install_cli_tools
    install_project_deps
    ensure_claude_code
    setup_git_hooks
    setup_secrets

    echo ""
    if verify_setup; then
        print_completion
    else
        print_warning "Setup completed with some issues"
        print_info "Try re-running this script or ask for help"
        print_completion
    fi
}

main "$@"
