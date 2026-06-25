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
    IL_SETTINGS_TOUCHED=true
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
    assert_json "$IL_SETUP_RECEIPT" '.claude_settings.marketplace' 'irrational-labs-plugins' 'settings recorded' || fail=1
    assert_json "$IL_SETUP_RECEIPT" '.path_edits[0]' "$HOME/.zshrc" 'path edit recorded' || fail=1
    assert_json "$IL_SETUP_RECEIPT" '.repos_cloned[0].path' "$HOME/irrational_labs_hq" 'repo path recorded' || fail=1
    assert_json "$IL_SETUP_RECEIPT" '.repos_cloned[0].created_dir' 'true' 'repo created_dir recorded' || fail=1
    assert_json "$IL_SETUP_RECEIPT" '.git_identity_prior.email' 'old@example.com' 'prior git email recorded' || fail=1
    assert_json "$IL_SETUP_RECEIPT" '.gh_was_authenticated_before' 'false' 'gh-before recorded as false' || fail=1
    rm -f "$IL_SETUP_RECEIPT"
}

test_write_receipt_basic
exit $fail
