#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/lib/assert.sh"

# Source the bootstrap to load its functions WITHOUT running main.
# shellcheck disable=SC1090
source "$ROOT/bootstrap.sh"

fail=0

test_write_receipt_basic() {
    export IL_SETUP_RECEIPT; IL_SETUP_RECEIPT="$(mktemp)"
    rm -f "$IL_SETUP_RECEIPT"
    # Set in-memory state
    IL_FORMULAE_INSTALLED=("node" "ffmpeg")
    IL_BUN_INSTALLED=true
    IL_CLAUDE_INSTALLED=false
    IL_GWS_INSTALLED=true
    IL_PATH_PROFILES=("$HOME/.zshrc")
    IL_REPOS_CLONED=("$HOME/irrational_labs_hq|true")
    IL_PRIOR_GIT_NAME="Old Name"
    IL_PRIOR_GIT_EMAIL="old@example.com"
    IL_GH_AUTHED_BEFORE=false

    write_receipt

    assert_json "$IL_SETUP_RECEIPT" '.schema_version' '1' 'schema_version is 1' || fail=1
    assert_json "$IL_SETUP_RECEIPT" '.formulae_installed_by_us | sort | join(",")' 'ffmpeg,node' 'formulae recorded' || fail=1
    assert_json "$IL_SETUP_RECEIPT" '.bun_installed_by_us' 'true' 'bun flag' || fail=1
    assert_json "$IL_SETUP_RECEIPT" '.gws_cli_installed_by_us' 'true' 'gws flag' || fail=1
    assert_json "$IL_SETUP_RECEIPT" '.path_edits[0]' "$HOME/.zshrc" 'path edit recorded' || fail=1
    assert_json "$IL_SETUP_RECEIPT" '.repos_cloned[0].path' "$HOME/irrational_labs_hq" 'repo path recorded' || fail=1
    assert_json "$IL_SETUP_RECEIPT" '.repos_cloned[0].created_dir' 'true' 'repo created_dir recorded' || fail=1
    assert_json "$IL_SETUP_RECEIPT" '.git_identity_prior.email' 'old@example.com' 'prior git email recorded' || fail=1
    assert_json "$IL_SETUP_RECEIPT" '.gh_was_authenticated_before' 'false' 'gh-before recorded as false' || fail=1
    rm -f "$IL_SETUP_RECEIPT"
}

test_capture_prior_state_first_run() {
    export IL_SETUP_RECEIPT; IL_SETUP_RECEIPT="$(mktemp)"; rm -f "$IL_SETUP_RECEIPT"
    # Fake a git identity via a temp HOME gitconfig
    local tmphome; tmphome="$(mktemp -d)"
    HOME="$tmphome" git config --global user.name "Pre Existing" 2>/dev/null
    HOME="$tmphome" git config --global user.email "pre@host.com" 2>/dev/null
    ( export HOME="$tmphome"
      IL_PRIOR_GIT_NAME=""; IL_PRIOR_GIT_EMAIL=""; IL_GH_AUTHED_BEFORE=""
      capture_prior_state
      assert_eq "Pre Existing" "$IL_PRIOR_GIT_NAME" "captures live name on first run"
      assert_eq "pre@host.com" "$IL_PRIOR_GIT_EMAIL" "captures live email on first run" ) || fail=1
    rm -rf "$tmphome" "$IL_SETUP_RECEIPT"
}

test_capture_prior_state_preserves_on_rerun() {
    export IL_SETUP_RECEIPT; IL_SETUP_RECEIPT="$(mktemp)"
    # A receipt already recording the ORIGINAL identity
    echo '{"git_identity_prior":{"name":"Original","email":"orig@x.com"},"gh_was_authenticated_before":true}' > "$IL_SETUP_RECEIPT"
    local tmphome; tmphome="$(mktemp -d)"
    # Live identity is now the IL one — must NOT overwrite the saved original
    HOME="$tmphome" git config --global user.email "now-il@irrationallabs.com" 2>/dev/null
    ( export HOME="$tmphome"
      IL_PRIOR_GIT_NAME=""; IL_PRIOR_GIT_EMAIL=""; IL_GH_AUTHED_BEFORE=""
      capture_prior_state
      assert_eq "orig@x.com" "$IL_PRIOR_GIT_EMAIL" "preserves original email on re-run"
      assert_eq "true" "$IL_GH_AUTHED_BEFORE" "preserves gh-before on re-run" ) || fail=1
    rm -rf "$tmphome" "$IL_SETUP_RECEIPT"
}

test_write_il_path_block() {
    local prof; prof="$(mktemp)"
    printf 'existing line\n' > "$prof"
    IL_PATH_PROFILES=()
    write_il_path_block "$prof" 'export PATH="$HOME/.local/bin:$PATH"'
    local content; content="$(cat "$prof")"
    assert_contains "$content" "# >>> il-setup >>>" "opening marker written"
    assert_contains "$content" "# <<< il-setup <<<" "closing marker written"
    assert_contains "$content" 'export PATH="$HOME/.local/bin:$PATH"' "path line written"
    assert_contains "$content" "existing line" "existing content preserved"
    assert_eq "$prof" "${IL_PATH_PROFILES[0]}" "profile recorded"

    # Idempotent: second call must NOT add a second block
    write_il_path_block "$prof" 'export PATH="$HOME/.local/bin:$PATH"'
    local count; count="$(grep -c '# >>> il-setup >>>' "$prof")"
    assert_eq "1" "$count" "block written only once"
    rm -f "$prof"
}

test_write_receipt_basic
test_capture_prior_state_first_run
test_capture_prior_state_preserves_on_rerun
test_write_il_path_block
exit $fail
