#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/lib/assert.sh"
# shellcheck disable=SC1090
source "$ROOT/uninstall.sh"

fail=0

test_preset_mapping() {
    assert_eq "repos gws plugins gh gitid path" "$(categories_for_preset 1)" "preset 1 = IL footprint" || fail=1
    assert_eq "repos gws plugins gh gitid path claude devtools" "$(categories_for_preset 2)" "preset 2 = everything-but-brew" || fail=1
    assert_not_contains "$(categories_for_preset 2)" "brew" "preset 2 never includes homebrew" || fail=1
}

test_strip_il_settings() {
    local f; f="$(mktemp)"
    cat > "$f" <<'JSON'
{
  "theme": "dark",
  "extraKnownMarketplaces": {
    "irrational-labs-plugins": {"source": {"source": "github", "repo": "x"}},
    "someone-elses": {"source": {"source": "github", "repo": "y"}}
  },
  "enabledPlugins": {
    "gws@irrational-labs-plugins": true,
    "il-slides@irrational-labs-plugins": true,
    "key-behavior@irrational-labs-plugins": true,
    "their-plugin@other-market": true
  }
}
JSON
    strip_il_settings "$f"
    assert_json "$f" '.theme' 'dark' "unrelated key preserved" || fail=1
    assert_json "$f" '.extraKnownMarketplaces | has("irrational-labs-plugins")' 'false' "IL marketplace removed" || fail=1
    assert_json "$f" '.extraKnownMarketplaces | has("someone-elses")' 'true' "other marketplace preserved" || fail=1
    assert_json "$f" '.enabledPlugins | has("gws@irrational-labs-plugins")' 'false' "IL plugin removed" || fail=1
    assert_json "$f" '.enabledPlugins | has("their-plugin@other-market")' 'true' "other plugin preserved" || fail=1
    rm -f "$f"
}

test_remove_il_path_block() {
    local f; f="$(mktemp)"
    cat > "$f" <<'EOF'
line before

# >>> il-setup >>>
export PATH="$HOME/.local/bin:$PATH"
# <<< il-setup <<<
line after
EOF
    remove_il_path_block "$f"
    local content; content="$(cat "$f")"
    assert_contains "$content" "line before" "content before block preserved" || fail=1
    assert_contains "$content" "line after" "content after block preserved" || fail=1
    assert_not_contains "$content" "il-setup" "markers removed" || fail=1
    assert_not_contains "$content" ".local/bin" "path line removed" || fail=1
    rm -f "$f"
}

test_restore_git_identity_with_prior() {
    export IL_SETUP_RECEIPT; IL_SETUP_RECEIPT="$(mktemp)"
    echo '{"git_identity_prior":{"name":"Old Name","email":"old@x.com"}}' > "$IL_SETUP_RECEIPT"
    load_receipt
    local out; out="$(IL_DRY_RUN=1 restore_git_identity)"
    assert_contains "$out" 'DRYRUN: git config --global user.email old@x.com' "restores prior email" || fail=1
    assert_contains "$out" 'DRYRUN: git config --global user.name Old Name' "restores prior name" || fail=1
    rm -f "$IL_SETUP_RECEIPT"
}

test_restore_git_identity_no_prior() {
    export IL_SETUP_RECEIPT; IL_SETUP_RECEIPT="$(mktemp)"
    echo '{"git_identity_prior":{"name":"","email":""}}' > "$IL_SETUP_RECEIPT"
    load_receipt
    local out; out="$(IL_DRY_RUN=1 restore_git_identity)"
    assert_contains "$out" 'DRYRUN: git config --global --unset user.email' "unsets email when no prior" || fail=1
    rm -f "$IL_SETUP_RECEIPT"
}

test_remove_repos_dryrun() {
    export IL_SETUP_RECEIPT; IL_SETUP_RECEIPT="$(mktemp)"
    echo '{"repos_cloned":[{"path":"/tmp/il/hq","created_dir":true},{"path":"/tmp/pre/repo","created_dir":false}]}' > "$IL_SETUP_RECEIPT"
    load_receipt
    local out; out="$(IL_DRY_RUN=1 remove_repos)"
    assert_contains "$out" 'DRYRUN: rm -rf /tmp/il/hq' "deletes created-dir repo path" || fail=1
    assert_contains "$out" 'DRYRUN: rm -rf /tmp/pre/repo' "deletes repo subdir even when parent pre-existed" || fail=1
    rm -f "$IL_SETUP_RECEIPT"
}

test_remove_gws_dryrun() {
    export IL_SETUP_RECEIPT; IL_SETUP_RECEIPT="$(mktemp)"
    echo '{"gws_cli_installed_by_us":true}' > "$IL_SETUP_RECEIPT"
    load_receipt
    local out; out="$(IL_DRY_RUN=1 remove_gws)"
    assert_contains "$out" 'DRYRUN: npm uninstall -g @googleworkspace/cli' "uninstalls gws cli when we installed it" || fail=1
    rm -f "$IL_SETUP_RECEIPT"
}

test_remove_gws_skips_when_not_ours() {
    export IL_SETUP_RECEIPT; IL_SETUP_RECEIPT="$(mktemp)"
    echo '{"gws_cli_installed_by_us":false}' > "$IL_SETUP_RECEIPT"
    load_receipt
    local out; out="$(IL_DRY_RUN=1 remove_gws)"
    assert_not_contains "$out" 'npm uninstall -g @googleworkspace/cli' "does NOT uninstall gws CLI when receipt says we did not install it" || fail=1
    rm -f "$IL_SETUP_RECEIPT"
}

test_remove_github_auth_gated() {
    export IL_SETUP_RECEIPT; IL_SETUP_RECEIPT="$(mktemp)"
    echo '{"gh_was_authenticated_before":true}' > "$IL_SETUP_RECEIPT"
    load_receipt
    local out; out="$(IL_DRY_RUN=1 remove_github_auth)"
    assert_not_contains "$out" 'gh auth logout' "does NOT log out if user was authed before setup" || fail=1
    echo '{"gh_was_authenticated_before":false}' > "$IL_SETUP_RECEIPT"
    load_receipt
    out="$(IL_DRY_RUN=1 remove_github_auth)"
    assert_contains "$out" 'DRYRUN: gh auth logout' "logs out when setup is what authed them" || fail=1
    rm -f "$IL_SETUP_RECEIPT"
}

test_remove_dev_tools_only_receipt_formulae() {
    export IL_SETUP_RECEIPT; IL_SETUP_RECEIPT="$(mktemp)"
    echo '{"formulae_installed_by_us":["node","ffmpeg"],"bun_installed_by_us":true}' > "$IL_SETUP_RECEIPT"
    load_receipt
    # Stub brew so `brew uses --installed` reports no dependents (safe to remove).
    brew() { if [[ "$1" == "uses" ]]; then return 0; fi; echo "DRYRUN: brew $*"; }
    export -f brew 2>/dev/null || true
    local out; out="$(IL_DRY_RUN=1 remove_dev_tools)"
    assert_contains "$out" 'DRYRUN: brew uninstall node' "uninstalls receipt formula node" || fail=1
    assert_contains "$out" 'DRYRUN: brew uninstall ffmpeg' "uninstalls receipt formula ffmpeg" || fail=1
    assert_not_contains "$out" 'brew uninstall git' "never touches a non-receipt formula" || fail=1
    unset -f brew
    rm -f "$IL_SETUP_RECEIPT"
}

test_preset_mapping
test_strip_il_settings
test_remove_il_path_block
test_restore_git_identity_with_prior
test_restore_git_identity_no_prior
test_remove_repos_dryrun
test_remove_gws_dryrun
test_remove_gws_skips_when_not_ours
test_remove_github_auth_gated
test_remove_dev_tools_only_receipt_formulae
exit $fail
