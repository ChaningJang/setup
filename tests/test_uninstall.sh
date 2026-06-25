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

test_preset_mapping
test_strip_il_settings
exit $fail
