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
