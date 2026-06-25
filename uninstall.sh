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
