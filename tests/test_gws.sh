#!/usr/bin/env bash
# tests/test_gws.sh — the gws stack: keyring guard, plugin registration, and
# the round-trip through the uninstaller.
#
# The keyring guard is the one that actually matters. gws's default keyring
# backend silently DELETES ~/.config/gws/credentials.enc, so a teammate whose
# profiles lack GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file will lose their login
# without any error message. These tests exist so nobody "simplifies" it away.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/lib/assert.sh"

# Source the bootstrap to load its functions WITHOUT running main.
# shellcheck disable=SC1090
source "$ROOT/bootstrap.sh"

fail=0
REAL_HOME="$HOME"

# Silence the installer's chatter inside tests.
print_step() { :; }; print_success() { :; }; print_info() { :; }; print_warning() { :; }

new_home() { HOME="$(mktemp -d)"; mkdir -p "$HOME/.claude"; IL_GWS_ENV_PROFILES=(); WARNINGS=(); }

test_keyring_guard_written_to_all_profiles() {
    new_home
    ensure_gws_keyring_env

    # .zshenv is the critical one: it is read by NON-interactive zsh too, which
    # is where cron/launchd gws callers live. .zshrc would not cover them.
    assert_contains "$(cat "$HOME/.zshenv")" \
        'export GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file' 'guard in .zshenv' || fail=1
    assert_contains "$(cat "$HOME/.bash_profile")" \
        'GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file' 'guard in .bash_profile' || fail=1
    assert_contains "$(cat "$HOME/.bashrc")" \
        'GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file' 'guard in .bashrc' || fail=1

    # Claude Code's own Bash calls are covered independently of the shell.
    assert_json "$HOME/.claude/settings.json" '.env.GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND' \
        'file' 'guard set for Claude Code sessions' || fail=1

    # And it must hold for the remainder of this very run.
    assert_eq "file" "${GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND:-}" 'guard exported into current process' || fail=1

    assert_eq "3" "${#IL_GWS_ENV_PROFILES[@]}" 'all three profiles recorded for the receipt' || fail=1
    HOME="$REAL_HOME"
}

test_keyring_guard_is_idempotent() {
    new_home
    ensure_gws_keyring_env
    ensure_gws_keyring_env
    ensure_gws_keyring_env
    local count; count="$(grep -c 'GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND' "$HOME/.zshenv")"
    assert_eq "1" "$count" 'guard written only once across re-runs' || fail=1
    HOME="$REAL_HOME"
}

test_keyring_guard_respects_a_hand_rolled_export() {
    new_home
    # Someone who already fixed this by hand (as Chaning did) must not get a
    # second, redundant export appended on every re-run.
    echo 'export GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file' > "$HOME/.zshenv"
    ensure_gws_keyring_env
    local count; count="$(grep -c 'GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND' "$HOME/.zshenv")"
    assert_eq "1" "$count" 'existing hand-written export not duplicated' || fail=1
    assert_not_contains "$(cat "$HOME/.zshenv")" '# >>> il-setup:gws >>>' 'no redundant block added' || fail=1
    HOME="$REAL_HOME"
}

test_keyring_guard_preserves_existing_profile_content() {
    new_home
    printf 'export EDITOR=vim\n' > "$HOME/.zshenv"
    ensure_gws_keyring_env
    assert_contains "$(cat "$HOME/.zshenv")" 'export EDITOR=vim' 'pre-existing profile line kept' || fail=1
    HOME="$REAL_HOME"
}

test_settings_env_merge_preserves_other_keys() {
    new_home
    echo '{"env":{"FOO":"bar"},"model":"opus"}' > "$HOME/.claude/settings.json"
    ensure_gws_keyring_env
    assert_json "$HOME/.claude/settings.json" '.env.FOO' 'bar' 'unrelated env var preserved' || fail=1
    assert_json "$HOME/.claude/settings.json" '.model' 'opus' 'unrelated setting preserved' || fail=1
    assert_json "$HOME/.claude/settings.json" '.env.GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND' 'file' 'guard still added' || fail=1
    HOME="$REAL_HOME"
}

test_plugin_registration() {
    new_home
    ensure_il_claude_plugins
    local s="$HOME/.claude/settings.json"
    assert_json "$s" '.extraKnownMarketplaces["irrational-labs-plugins"].source.repo' \
        'IrrationalLabs-team/knowledge-work-plugins' 'marketplace registered locally' || fail=1
    assert_json "$s" '.enabledPlugins["gws@irrational-labs-plugins"]' 'true' 'gws plugin enabled' || fail=1
    assert_json "$s" '.enabledPlugins["il-slides@irrational-labs-plugins"]' 'true' 'il-slides enabled' || fail=1
    assert_json "$s" '.enabledPlugins["key-behavior@irrational-labs-plugins"]' 'true' 'key-behavior enabled' || fail=1
    HOME="$REAL_HOME"
}

test_plugin_registration_preserves_explicit_disable() {
    new_home
    echo '{"enabledPlugins":{"gws@irrational-labs-plugins":false}}' > "$HOME/.claude/settings.json"
    ensure_il_claude_plugins
    assert_json "$HOME/.claude/settings.json" '.enabledPlugins["gws@irrational-labs-plugins"]' \
        'false' 'an explicit disable survives a re-run' || fail=1
    HOME="$REAL_HOME"
}

test_plugin_registration_preserves_unrelated_settings() {
    new_home
    echo '{"statusLine":{"type":"command","command":"mine"},"enabledPlugins":{"other@x":true}}' \
        > "$HOME/.claude/settings.json"
    ensure_il_claude_plugins
    assert_json "$HOME/.claude/settings.json" '.statusLine.command' 'mine' 'custom statusLine untouched' || fail=1
    assert_json "$HOME/.claude/settings.json" '.enabledPlugins["other@x"]' 'true' 'third-party plugin untouched' || fail=1
    HOME="$REAL_HOME"
}

test_receipt_records_gws_env_edits() {
    new_home
    export IL_SETUP_RECEIPT; IL_SETUP_RECEIPT="$(mktemp)"; rm -f "$IL_SETUP_RECEIPT"
    ensure_gws_keyring_env
    write_receipt
    assert_json "$IL_SETUP_RECEIPT" '.gws_env_edits | length' '3' 'receipt records the three profiles' || fail=1
    assert_json "$IL_SETUP_RECEIPT" '.gws_env_edits | map(select(endswith("/.zshenv"))) | length' \
        '1' 'receipt records .zshenv specifically' || fail=1
    rm -f "$IL_SETUP_RECEIPT"; unset IL_SETUP_RECEIPT
    HOME="$REAL_HOME"
}

# --- Round trip: what the installer writes, the uninstaller must remove -------
test_uninstaller_removes_the_guard() {
    new_home
    printf 'export EDITOR=vim\n' > "$HOME/.zshenv"
    ensure_gws_keyring_env
    ensure_il_claude_plugins

    # Load the uninstaller's helpers in a subshell-safe way. It shares helper
    # names with the bootstrap, so run the check in a subshell and report out.
    local out
    out="$(
        # shellcheck disable=SC1090
        source "$ROOT/uninstall.sh" >/dev/null 2>&1 || true
        print_info() { :; }; print_success() { :; }; print_warning() { :; }
        RECEIPT_FOUND=false
        remove_gws_env_edits >/dev/null 2>&1
        strip_il_settings "$HOME/.claude/settings.json" >/dev/null 2>&1
        echo "ZSHENV:$(cat "$HOME/.zshenv")"
        echo "SETTINGS:$(cat "$HOME/.claude/settings.json" | tr -d '\n ')"
    )"
    assert_not_contains "$out" 'GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND' 'uninstaller removes the guard' || fail=1
    assert_contains "$out" 'export EDITOR=vim' 'uninstaller keeps unrelated profile lines' || fail=1
    assert_not_contains "$out" 'irrational-labs-plugins' 'uninstaller removes IL plugin keys' || fail=1
    HOME="$REAL_HOME"
}

test_keyring_guard_written_to_all_profiles
test_keyring_guard_is_idempotent
test_keyring_guard_respects_a_hand_rolled_export
test_keyring_guard_preserves_existing_profile_content
test_settings_env_merge_preserves_other_keys
test_plugin_registration
test_plugin_registration_preserves_explicit_disable
test_plugin_registration_preserves_unrelated_settings
test_receipt_records_gws_env_edits
test_uninstaller_removes_the_guard

HOME="$REAL_HOME"
if [[ "$fail" -eq 0 ]]; then echo "OK: all gws stack tests passed"; else echo "FAILURES in gws stack tests"; fi
exit "$fail"
