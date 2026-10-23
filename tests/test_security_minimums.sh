#!/usr/bin/env bash
# tests/test_security_minimums.sh — ensure_security_minimums against a stubbed
# `brew` and `node` on PATH. Nothing real is installed or upgraded.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/lib/assert.sh"

# shellcheck disable=SC1090
source "$ROOT/bootstrap.sh"
set +e

fail=0
REAL_PATH="$PATH"

# A fake Homebrew in $FAKE/prefix. State lives in files so `brew upgrade` can
# change what the next run sees:
#   $FAKE/installed/<formula>   one line: its version
#   $FAKE/upgrades.log          every `brew upgrade` call
new_fake() {
    FAKE="$(mktemp -d)"
    mkdir -p "$FAKE/bin" "$FAKE/installed" "$FAKE/prefix/bin" "$FAKE/app"
    : > "$FAKE/upgrades.log"
    cat > "$FAKE/bin/brew" <<STUB
#!/bin/bash
F="$FAKE"
case "\$1" in
    --prefix) echo "\$F/prefix" ;;
    list)
        if [[ "\${2:-}" == "--formula" ]]; then ls "\$F/installed"; exit 0; fi
        if [[ "\${2:-}" == "--versions" ]]; then
            [[ -f "\$F/installed/\$3" ]] && echo "\$3 \$(cat "\$F/installed/\$3")"; exit 0
        fi
        [[ -f "\$F/installed/\$2" ]] ;;
    upgrade)
        shift
        echo "NO_ASK=\${HOMEBREW_NO_ASK:-} \$*" >> "\$F/upgrades.log"
        for f in "\$@"; do
            case "\$f" in
                node)       echo 26.12.1 > "\$F/installed/node" ;;
                certifi)    echo 2026.10.19 > "\$F/installed/certifi" ;;
                python@*)   echo 26.2.2 > "\$F/pip-\$f" ;;
            esac
        done ;;
esac
STUB
    chmod +x "$FAKE/bin/brew"
    PATH="$FAKE/bin:/usr/bin:/bin"
    BB_APP="$FAKE/no-bb.app"
    WARNINGS=()
}

# brew_formula <name> <version>: a Homebrew formula, with a node or python stub.
brew_formula() {
    echo "$2" > "$FAKE/installed/$1"
    case "$1" in
        node)
            mkdir -p "$FAKE/prefix/opt/node/bin"
            printf '#!/bin/bash\necho v$(cat %s/installed/node)\n' "$FAKE" > "$FAKE/prefix/opt/node/bin/node"
            chmod +x "$FAKE/prefix/opt/node/bin/node"
            ln -sf ../opt/node/bin/node "$FAKE/prefix/bin/node"
            PATH="$FAKE/prefix/bin:$PATH" ;;
        python@*)
            local short="${1#python@}"
            echo "$3" > "$FAKE/pip-$1"
            mkdir -p "$FAKE/prefix/opt/$1/bin"
            printf '#!/bin/bash\necho "pip $(cat %s/pip-%s) from somewhere (python %s)"\n' "$FAKE" "$1" "$short" \
                > "$FAKE/prefix/opt/$1/bin/python$short"
            chmod +x "$FAKE/prefix/opt/$1/bin/python$short" ;;
    esac
}

# nvm_node <version>: a node first on PATH that Homebrew doesn't own.
nvm_node() {
    mkdir -p "$FAKE/nvm/bin"
    printf '#!/bin/bash\necho v%s\n' "$1" > "$FAKE/nvm/bin/node"
    chmod +x "$FAKE/nvm/bin/node"
    PATH="$FAKE/nvm/bin:$PATH"
}

# Run the step the way main does: in bash with set -e on.
run_step() { ( set -euo pipefail; ensure_security_minimums ) 2>&1; }

test_old_brew_node_upgrades() {
    new_fake; brew_formula node 24.9.0
    local out; out="$(run_step)"
    assert_eq "NO_ASK=1 node" "$(cat "$FAKE/upgrades.log")" 'old Homebrew node: brew upgrade node, without the prompt' || fail=1
    assert_contains "$out" 'Security updates installed' 'reports the upgrade' || fail=1
    assert_not_contains "$out" 'Quit and reopen bb' 'no bb line when bb is not installed' || fail=1
    out="$(run_step)"
    assert_eq "1" "$(wc -l < "$FAKE/upgrades.log" | tr -d ' ')" 'second run upgrades nothing' || fail=1
    assert_contains "$out" 'Security updates: up to date' 'second run says up to date' || fail=1
}

test_old_brew_node_with_bb_says_restart_bb() {
    new_fake; brew_formula node 26.11.0
    mkdir -p "$FAKE/bb.app"; BB_APP="$FAKE/bb.app"
    local out; out="$(run_step)"
    assert_contains "$out" 'Quit and reopen bb so it picks up the new Node.' 'bb installed + node upgraded: restart bb' || fail=1
}

test_eol_brew_node_upgrades() {
    local v
    for v in 20.19.5 25.1.0 18.20.0 23.0.0; do
        new_fake; brew_formula node "$v"
        run_step >/dev/null
        assert_eq "NO_ASK=1 node" "$(cat "$FAKE/upgrades.log")" "end-of-life Node $v gets upgraded" || fail=1
    done
}

test_current_node_is_a_noop() {
    local v
    for v in 26.12.1 24.22.1 22.23.4 26.13.0 27.0.0; do
        new_fake; brew_formula node "$v"
        mkdir -p "$FAKE/bb.app"; BB_APP="$FAKE/bb.app"
        local out; out="$(run_step)"
        assert_eq "" "$(cat "$FAKE/upgrades.log")" "Node $v: no upgrade" || fail=1
        assert_contains "$out" 'Security updates: up to date' "Node $v: up to date" || fail=1
        assert_not_contains "$out" 'Quit and reopen bb' "Node $v: no bb line" || fail=1
    done
}

test_nvm_node_gets_a_message_only() {
    new_fake; nvm_node 22.10.0
    local out; out="$(run_step)"
    assert_eq "" "$(cat "$FAKE/upgrades.log")" 'nvm node: brew upgrade never runs' || fail=1
    assert_contains "$out" "wasn't installed by Homebrew, so setup left it alone" 'nvm node: one plain-English line' || fail=1
    assert_eq "1" "$(grep -c 'Node 22.10.0' <<<"$out")" 'nvm node: said once' || fail=1
}

test_nvm_node_ahead_of_old_brew_node() {
    new_fake; brew_formula node 24.1.0; nvm_node 24.22.1
    local out; out="$(run_step)"
    assert_eq "NO_ASK=1 node" "$(cat "$FAKE/upgrades.log")" 'Homebrew node behind nvm still upgraded' || fail=1
    assert_not_contains "$out" "left it alone" 'current nvm node: no message' || fail=1
}

test_no_node_is_a_noop() {
    new_fake
    local out; out="$(run_step)"
    assert_eq "" "$(cat "$FAKE/upgrades.log")" 'no node: nothing upgraded' || fail=1
    assert_contains "$out" 'Security updates: up to date' 'no node: up to date' || fail=1
}

test_python_pip_and_certifi() {
    new_fake; brew_formula node 26.12.1; brew_formula certifi 2026.8.3; brew_formula python@3.15 3.15.0 26.1
    run_step >/dev/null
    assert_eq "NO_ASK=1 certifi python@3.15" "$(cat "$FAKE/upgrades.log")" 'old certifi + old pip: one brew upgrade' || fail=1
    local out; out="$(run_step)"
    assert_eq "1" "$(wc -l < "$FAKE/upgrades.log" | tr -d ' ')" 'python: second run upgrades nothing' || fail=1
    assert_contains "$out" 'Security updates: up to date' 'python: second run up to date' || fail=1
}

test_version_lt() {
    version_lt 24.9.0 24.22.1      && ok1=y || ok1=n
    version_lt 24.22.1 24.22.1     && ok2=y || ok2=n
    version_lt 2026.10.19 2026.8.3 && ok3=y || ok3=n
    version_lt 2026.8.3_1 2026.10.19 && ok4=y || ok4=n
    assert_eq "y n n y" "$ok1 $ok2 $ok3 $ok4" 'version_lt compares numerically, ignores _revision' || fail=1
}

test_old_brew_node_upgrades
test_old_brew_node_with_bb_says_restart_bb
test_eol_brew_node_upgrades
test_current_node_is_a_noop
test_nvm_node_gets_a_message_only
test_nvm_node_ahead_of_old_brew_node
test_no_node_is_a_noop
test_python_pip_and_certifi
test_version_lt

PATH="$REAL_PATH"
if [[ "$fail" -eq 0 ]]; then echo "OK: all security minimums tests passed"; else echo "FAILURES in security minimums tests"; fi
exit "$fail"
