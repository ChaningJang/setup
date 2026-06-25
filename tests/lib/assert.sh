# shellcheck shell=bash
# tests/lib/assert.sh — dependency-free assertions. Source this in test files.
# Each assertion prints PASS/FAIL and returns nonzero on failure so callers
# running under `set -e` abort on the first failure.

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-values equal}"
    if [[ "$expected" == "$actual" ]]; then
        echo "PASS: $msg"
    else
        echo "FAIL: $msg"
        echo "  expected: [$expected]"
        echo "  actual:   [$actual]"
        return 1
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-contains}"
    if [[ "$haystack" == *"$needle"* ]]; then
        echo "PASS: $msg"
    else
        echo "FAIL: $msg"
        echo "  '$needle' not found in: $haystack"
        return 1
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-does not contain}"
    if [[ "$haystack" != *"$needle"* ]]; then
        echo "PASS: $msg"
    else
        echo "FAIL: $msg"
        echo "  '$needle' unexpectedly found in: $haystack"
        return 1
    fi
}

# assert_json <file> <jq-filter> <expected> [msg]
assert_json() {
    local file="$1" filter="$2" expected="$3" msg="${4:-json $2}"
    local actual; actual="$(jq -r "$filter" "$file")"
    assert_eq "$expected" "$actual" "$msg"
}
