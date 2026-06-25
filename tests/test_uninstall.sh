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

test_preset_mapping
exit $fail
