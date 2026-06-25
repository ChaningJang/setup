#!/usr/bin/env bash
# Irrational Labs — Uninstaller. Reverses what bootstrap.sh added, using the
# receipt at ~/.config/il-setup/receipt.json. Run via:
#   curl -fsSL https://raw.githubusercontent.com/ChaningJang/setup/main/uninstall.sh | bash
set -euo pipefail

# ---- output helpers (mirror bootstrap.sh) ------------------------------------
if [[ -t 1 ]]; then
    BOLD=$'\033[1m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; RED=$'\033[0;31m'; BLUE=$'\033[0;34m'; NC=$'\033[0m'
else
    BOLD=""; GREEN=""; YELLOW=""; RED=""; BLUE=""; NC=""
fi
print_step()    { echo -e "\n${BLUE}▶ $1${NC}"; }
print_success() { echo -e "${GREEN}✓ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠ $1${NC}"; }
print_error()   { echo -e "${RED}✗ $1${NC}"; }
print_info()    { echo -e "  $1"; }
command_exists() { command -v "$1" &>/dev/null; }

# DRY-RUN: when IL_DRY_RUN=1, run_cmd prints instead of executing (used by tests).
run_cmd() {
    if [[ "${IL_DRY_RUN:-0}" == "1" ]]; then
        echo "DRYRUN: $*"
    else
        "$@"
    fi
}

# shellcheck disable=SC2034
WARNINGS=()
RECEIPT_FOUND=false
RECEIPT_PATH=""

il_receipt_path() {
    echo "${IL_SETUP_RECEIPT:-$HOME/.config/il-setup/receipt.json}"
}

load_receipt() {
    RECEIPT_PATH="$(il_receipt_path)"
    if command_exists jq && [[ -f "$RECEIPT_PATH" ]]; then
        RECEIPT_FOUND=true
    else
        RECEIPT_FOUND=false
    fi
}

# Echo the category ids for a preset. Homebrew (brew) is never in a preset.
categories_for_preset() {
    case "$1" in
        1) echo "repos gws plugins gh gitid path" ;;
        2) echo "repos gws plugins gh gitid path claude devtools" ;;
        *) echo "" ;;
    esac
}

# Remove only the IL keys this tool added; preserve all other settings.
strip_il_settings() {
    local file="$1"
    [[ -f "$file" ]] || { print_info "No settings.json at $file — nothing to strip"; return 0; }
    command_exists jq || { print_warning "jq unavailable — cannot edit settings.json safely"; return 0; }
    local tmp; tmp="$(mktemp)"
    if jq '
        del(.extraKnownMarketplaces["irrational-labs-plugins"])
        | del(.enabledPlugins["gws@irrational-labs-plugins"])
        | del(.enabledPlugins["il-slides@irrational-labs-plugins"])
        | del(.enabledPlugins["key-behavior@irrational-labs-plugins"])
    ' "$file" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$file"
        print_success "Removed IL marketplace + plugin keys from $(basename "$file")"
    else
        rm -f "$tmp"
        print_warning "Could not edit $file"
    fi
}

# Delete the il-setup marker block (inclusive) from a profile.
remove_il_path_block() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    grep -qF '# >>> il-setup >>>' "$file" 2>/dev/null || { print_info "No il-setup PATH block in $(basename "$file")"; return 0; }
    local tmp; tmp="$(mktemp)"
    awk '
        /# >>> il-setup >>>/ { skip=1 }
        skip != 1 { print }
        /# <<< il-setup <<</ { skip=0 }
    ' "$file" > "$tmp" && mv "$tmp" "$file"
    print_success "Removed il-setup PATH block from $(basename "$file")"
}

# Restore prior git identity from the receipt, or unset if none existed.
restore_git_identity() {
    if [[ "$RECEIPT_FOUND" != true ]]; then
        print_warning "No receipt — cannot restore prior git identity (skipping)"
        return 0
    fi
    local name email
    name="$(jq -r '.git_identity_prior.name // ""' "$RECEIPT_PATH")"
    email="$(jq -r '.git_identity_prior.email // ""' "$RECEIPT_PATH")"
    if [[ -n "$name" || -n "$email" ]]; then
        [[ -n "$name" ]]  && run_cmd git config --global user.name "$name"
        [[ -n "$email" ]] && run_cmd git config --global user.email "$email"
        print_success "Restored prior git identity (${name:-} <${email:-}>)"
    else
        run_cmd git config --global --unset user.name || true
        run_cmd git config --global --unset user.email || true
        print_success "Cleared git identity (none existed before setup)"
    fi
}

remove_repos() {
    [[ "$RECEIPT_FOUND" == true ]] || { print_warning "No receipt — skipping repo removal"; return 0; }
    local n; n="$(jq -r '(.repos_cloned // []) | length' "$RECEIPT_PATH")"
    [[ "$n" -gt 0 ]] || { print_info "No cloned repos recorded"; return 0; }
    local i path
    for (( i=0; i<n; i++ )); do
        path="$(jq -r ".repos_cloned[$i].path" "$RECEIPT_PATH")"
        [[ -n "$path" && "$path" != "null" ]] || continue
        run_cmd rm -rf "$path"
        print_success "Removed repo $path"
    done
}

remove_gws() {
    # Clear OAuth credentials FIRST, while gws is still installed. `gws auth
    # logout` is the supported command — it "clears saved credentials and token
    # cache" (verified via `gws auth --help`).
    if command_exists gws; then
        run_cmd gws auth logout || true
        print_success "Cleared gws credentials (gws auth logout)"
    fi
    if [[ "$RECEIPT_FOUND" == true && "$(jq -r '.gws_cli_installed_by_us // false' "$RECEIPT_PATH")" != "true" ]]; then
        print_info "gws CLI was not installed by setup — leaving the binary"
    elif command_exists npm; then
        run_cmd npm uninstall -g @googleworkspace/cli
        print_success "Uninstalled gws CLI"
    else
        print_warning "npm not found — cannot uninstall gws CLI"
    fi
    # Belt-and-suspenders: remove the config dir if it survived logout. Default
    # is ~/.config/gws; respect the documented GOOGLE_WORKSPACE_CLI_CONFIG_DIR.
    local cfg="${GOOGLE_WORKSPACE_CLI_CONFIG_DIR:-$HOME/.config/gws}"
    if [[ -d "$cfg" ]]; then
        run_cmd rm -rf "$cfg"
        print_success "Removed leftover gws config at $cfg"
    fi
}

remove_github_auth() {
    if [[ "$RECEIPT_FOUND" == true && "$(jq -r '.gh_was_authenticated_before // false' "$RECEIPT_PATH")" == "true" ]]; then
        print_info "You were signed into GitHub before setup — leaving gh auth intact"
        return 0
    fi
    if command_exists gh; then
        run_cmd gh auth logout
        print_success "Logged out of GitHub CLI"
    fi
}

remove_claude_code() {
    if command_exists claude; then
        # claude.ai installer drops the binary in ~/.local/bin
        run_cmd rm -f "$HOME/.local/bin/claude"
        print_success "Removed Claude Code binary (kept ~/.claude — it's yours)"
    fi
}

remove_dev_tools() {
    [[ "$RECEIPT_FOUND" == true ]] || { print_warning "No receipt — refusing to guess which dev tools to remove"; return 0; }
    local n; n="$(jq -r '(.formulae_installed_by_us // []) | length' "$RECEIPT_PATH")"
    local i f
    for (( i=0; i<n; i++ )); do
        f="$(jq -r ".formulae_installed_by_us[$i]" "$RECEIPT_PATH")"
        [[ -n "$f" && "$f" != "null" ]] || continue
        if brew uses --installed "$f" 2>/dev/null | grep -q .; then
            print_warning "Skipping $f — other installed formulae depend on it"
            continue
        fi
        run_cmd brew uninstall "$f"
        print_success "Uninstalled $f"
    done
    if [[ "$(jq -r '.bun_installed_by_us // false' "$RECEIPT_PATH")" == "true" && -d "$HOME/.bun" ]]; then
        run_cmd rm -rf "$HOME/.bun"
        print_success "Removed Bun (~/.bun)"
    fi
}

remove_homebrew() {
    if [[ "$RECEIPT_FOUND" == true && "$(jq -r '.brew_installed_by_us // false' "$RECEIPT_PATH")" == "true" ]]; then
        print_warning "About to uninstall Homebrew ENTIRELY — this removes ALL brew packages, IL or not."
        run_cmd /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)"
        print_success "Uninstalled Homebrew"
    else
        print_info "Homebrew was not installed by setup — leaving it"
    fi
}

main() {
    echo ""
    echo -e "${BOLD}Irrational Labs — Uninstaller${NC}"
    load_receipt
    if [[ "$RECEIPT_FOUND" == true ]]; then
        print_info "Found setup receipt at $RECEIPT_PATH"
    else
        print_warning "No setup receipt found — falling back to best-effort known-list mode"
    fi
    # menu + execution wired in Task 10
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
