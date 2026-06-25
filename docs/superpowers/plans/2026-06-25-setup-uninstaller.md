# Setup Uninstaller Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give a departing consultant a one-command, menu-driven uninstaller that reverses what `ChaningJang/setup` added — using a receipt the installer writes so it removes only what it installed and restores what it overwrote.

**Architecture:** The bootstraps (`bootstrap.sh`/`bootstrap.ps1`) collect "what we changed" facts in in-memory variables during the run and write a single JSON receipt at the end (when `jq` is guaranteed present). The uninstallers (`uninstall.sh`/`uninstall.ps1`) read that receipt, present presets + a custom category picker, and reverse each category precisely; with no receipt they fall back to a best-effort known-list.

**Tech Stack:** Bash 3.2 (macOS default), `jq`, ShellCheck; PowerShell 5.1+, PSScriptAnalyzer. Scripts are self-contained (`curl|bash` / `irm|iex`) — no sibling sourcing. Tests are dependency-free bash scripts run in CI.

## Global Constraints

- **Bash 3.2 compatible** — no associative arrays, no `readarray`/`mapfile`. Guard empty-array expansion under `set -u` with `"${arr[@]:-}"`. (Existing scripts already target this.)
- **`set -euo pipefail`** at the top of every `.sh` (matches existing scripts).
- **ShellCheck `-S warning` must pass** on every `.sh` (CI gate in `lint.yml`).
- **PSScriptAnalyzer Severity Error must pass** on every `.ps1` (CI gate).
- **Self-contained scripts** — `bootstrap.sh`/`uninstall.sh` are fetched standalone via `curl`; they may NOT `source` other repo files. Shared logic is duplicated, not imported.
- **`jq` is required** for receipt read/write. The installer installs it early; the uninstaller checks for it and degrades to no-receipt fallback if absent.
- **Receipt path:** `${IL_SETUP_RECEIPT:-$HOME/.config/il-setup/receipt.json}` (macOS/Linux); `$env:IL_SETUP_RECEIPT` else `$env:LOCALAPPDATA\il-setup\receipt.json` (Windows). The env override exists for testing.
- **Never** `rm -rf ~/.claude` or delete `settings.json` — remove only the specific IL keys.
- **Never** remove a tool not recorded as installed-by-us.
- **`main`/entrypoint is source-guarded** so tests can source the script to unit-test functions without executing it.
- Repo for all work: `ChaningJang/setup`. Branch: `add-uninstaller` (already created off `main`).

---

## File Structure

- `bootstrap.sh` — MODIFY: add receipt globals + helpers (`il_receipt_path`, `record_*`, `capture_prior_state`, `write_receipt`), wire recording into install branches, marker-wrap PATH edits, source-guard `main`.
- `bootstrap.ps1` — MODIFY: PowerShell parity for all of the above.
- `uninstall.sh` — CREATE: receipt load, presets + category picker, category reversers, source-guard.
- `uninstall.ps1` — CREATE: PowerShell parity.
- `tests/lib/assert.sh` — CREATE: dependency-free assert helpers.
- `tests/test_receipt.sh` — CREATE: tests for bootstrap receipt logic.
- `tests/test_uninstall.sh` — CREATE: tests for uninstaller logic.
- `.github/workflows/lint.yml` — MODIFY: shellcheck new scripts + run the bash tests.
- `README.md` — MODIFY: add "Uninstall / offboarding" section.

---

## PHASE 1 — Receipt writing (macOS `bootstrap.sh`)

### Task 1: Test harness + receipt path + write_receipt foundation

**Files:**
- Create: `tests/lib/assert.sh`
- Create: `tests/test_receipt.sh`
- Modify: `bootstrap.sh` (add receipt globals + `il_receipt_path` + `write_receipt`; source-guard `main`)

**Interfaces:**
- Produces: `il_receipt_path() -> string`; `write_receipt()` (reads in-memory globals `IL_FORMULAE_INSTALLED[]`, `IL_PATH_PROFILES[]`, `IL_REPOS_CLONED[]`, `IL_BREW_INSTALLED`, `IL_BUN_INSTALLED`, `IL_CLAUDE_INSTALLED`, `IL_GWS_INSTALLED`, `IL_SETTINGS_TOUCHED`, `IL_PRIOR_GIT_NAME`, `IL_PRIOR_GIT_EMAIL`, `IL_GH_AUTHED_BEFORE`; writes JSON to `il_receipt_path`)
- Assert helpers: `assert_eq expected actual [msg]`, `assert_contains haystack needle [msg]`, `assert_json receipt jq_filter expected [msg]`

- [ ] **Step 1: Create the assert library**

```bash
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
```

- [ ] **Step 2: Write the failing test for write_receipt**

```bash
# tests/test_receipt.sh
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
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bash tests/test_receipt.sh`
Expected: FAIL — `source: bootstrap.sh` runs `main` (no source guard yet) or `write_receipt: command not found`.

- [ ] **Step 4: Add the source guard, receipt globals, and helpers to bootstrap.sh**

Change the very last line of `bootstrap.sh` from:

```bash
main "$@"
```

to:

```bash
# Only run main when executed directly — allows tests to source this file.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
```

Add these globals immediately after the existing `WARNINGS=()` line near the top of the file:

```bash
# ---- Receipt state (what this run changed; written to disk by write_receipt) -
IL_FORMULAE_INSTALLED=()   # brew formulae we installed this run
IL_PATH_PROFILES=()        # shell profiles we added the il-setup PATH block to
IL_REPOS_CLONED=()         # "path|created_dir" entries
IL_BREW_INSTALLED=false
IL_BUN_INSTALLED=false
IL_CLAUDE_INSTALLED=false
IL_GWS_INSTALLED=false
IL_SETTINGS_TOUCHED=false
IL_PRIOR_GIT_NAME=""
IL_PRIOR_GIT_EMAIL=""
IL_GH_AUTHED_BEFORE=""
```

Add these functions just above `main()`:

```bash
il_receipt_path() {
    echo "${IL_SETUP_RECEIPT:-$HOME/.config/il-setup/receipt.json}"
}

# Serialize in-memory receipt state to disk. Merges with any existing receipt so
# re-runs accumulate; prior-state fields are written only if not already present.
write_receipt() {
    command_exists jq || { print_warning "jq unavailable — skipping setup receipt"; return 0; }
    local path; path="$(il_receipt_path)"
    mkdir -p "$(dirname "$path")"
    [[ -f "$path" ]] || echo '{}' > "$path"

    local formulae_json profiles_json repos_json
    formulae_json="$(printf '%s\n' "${IL_FORMULAE_INSTALLED[@]:-}" | jq -R 'select(length>0)' | jq -s .)"
    profiles_json="$(printf '%s\n' "${IL_PATH_PROFILES[@]:-}"   | jq -R 'select(length>0)' | jq -s .)"
    repos_json="$(printf '%s\n' "${IL_REPOS_CLONED[@]:-}" \
        | jq -R 'select(length>0) | split("|") | {path: .[0], created_dir: (.[1]=="true")}' | jq -s .)"

    local tmp; tmp="$(mktemp)"
    jq \
        --argjson formulae "$formulae_json" \
        --argjson profiles "$profiles_json" \
        --argjson repos "$repos_json" \
        --arg brew "$IL_BREW_INSTALLED" \
        --arg bun "$IL_BUN_INSTALLED" \
        --arg claude "$IL_CLAUDE_INSTALLED" \
        --arg gws "$IL_GWS_INSTALLED" \
        --arg settings "$IL_SETTINGS_TOUCHED" \
        --arg gname "$IL_PRIOR_GIT_NAME" \
        --arg gemail "$IL_PRIOR_GIT_EMAIL" \
        --arg ghbefore "$IL_GH_AUTHED_BEFORE" \
        '
        .schema_version = 1
        | .formulae_installed_by_us = (((.formulae_installed_by_us // []) + $formulae) | unique)
        | .path_edits = (((.path_edits // []) + $profiles) | unique)
        | .repos_cloned = (((.repos_cloned // []) + $repos) | unique_by(.path))
        | .brew_installed_by_us       = ((.brew_installed_by_us // false)       or ($brew == "true"))
        | .bun_installed_by_us        = ((.bun_installed_by_us // false)        or ($bun == "true"))
        | .claude_code_installed_by_us= ((.claude_code_installed_by_us // false) or ($claude == "true"))
        | .gws_cli_installed_by_us    = ((.gws_cli_installed_by_us // false)    or ($gws == "true"))
        | (if ($settings == "true") then
              .claude_settings = {marketplace: "irrational-labs-plugins",
                                  plugins: ["gws@irrational-labs-plugins",
                                            "il-slides@irrational-labs-plugins",
                                            "key-behavior@irrational-labs-plugins"]}
           else . end)
        | (if (has("git_identity_prior")) then . else .git_identity_prior = {name: $gname, email: $gemail} end)
        | (if (has("gh_was_authenticated_before")) then . else .gh_was_authenticated_before = ($ghbefore == "true") end)
        ' "$path" > "$tmp" && mv "$tmp" "$path"
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_receipt.sh`
Expected: all `PASS:` lines, exit 0.

- [ ] **Step 6: ShellCheck**

Run: `shellcheck -S warning bootstrap.sh tests/lib/assert.sh tests/test_receipt.sh`
Expected: no output (clean). The `# shellcheck disable=SC1090` above the dynamic `source` suppresses the not-followable warning.

- [ ] **Step 7: Commit**

```bash
git add bootstrap.sh tests/lib/assert.sh tests/test_receipt.sh
git commit -m "feat(receipt): add write_receipt + test harness, source-guard main"
```

---

### Task 2: capture_prior_state + record helpers (in-memory)

**Files:**
- Modify: `bootstrap.sh` (add `capture_prior_state`, `record_formula_installed`, `record_repo_cloned`, `record_path_profile`)
- Modify: `tests/test_receipt.sh` (add tests)

**Interfaces:**
- Produces: `capture_prior_state()` (sets `IL_PRIOR_GIT_NAME/EMAIL`, `IL_GH_AUTHED_BEFORE`, preserving existing receipt values); `record_formula_installed <name>`; `record_repo_cloned <path> <created_dir>`; `record_path_profile <file>`

- [ ] **Step 1: Write failing tests for capture_prior_state preservation**

Add to `tests/test_receipt.sh` (before the final `exit $fail`), and add `test_capture_prior_state` to the run list:

```bash
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
```

And add the calls near the bottom run section:

```bash
test_capture_prior_state_first_run
test_capture_prior_state_preserves_on_rerun
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_receipt.sh`
Expected: FAIL — `capture_prior_state: command not found`.

- [ ] **Step 3: Implement the helpers**

Add just above `write_receipt` in `bootstrap.sh`:

```bash
record_formula_installed() { IL_FORMULAE_INSTALLED+=("$1"); }
record_path_profile()      { IL_PATH_PROFILES+=("$1"); }
record_repo_cloned()       { IL_REPOS_CLONED+=("$1|$2"); }   # path, created_dir(true/false)

# Read state we are about to overwrite. Prefer values already saved in the
# receipt (so re-runs keep the ORIGINAL pre-setup state), else read live.
capture_prior_state() {
    local path; path="$(il_receipt_path)"
    if command_exists jq && [[ -f "$path" ]] && [[ "$(jq -r 'has("git_identity_prior")' "$path" 2>/dev/null)" == "true" ]]; then
        IL_PRIOR_GIT_NAME="$(jq -r '.git_identity_prior.name // ""' "$path")"
        IL_PRIOR_GIT_EMAIL="$(jq -r '.git_identity_prior.email // ""' "$path")"
    else
        IL_PRIOR_GIT_NAME="$(git config --global user.name 2>/dev/null || echo "")"
        IL_PRIOR_GIT_EMAIL="$(git config --global user.email 2>/dev/null || echo "")"
    fi
    if command_exists jq && [[ -f "$path" ]] && [[ "$(jq -r 'has("gh_was_authenticated_before")' "$path" 2>/dev/null)" == "true" ]]; then
        IL_GH_AUTHED_BEFORE="$(jq -r '.gh_was_authenticated_before' "$path")"
    elif gh auth status >/dev/null 2>&1; then
        IL_GH_AUTHED_BEFORE="true"
    else
        IL_GH_AUTHED_BEFORE="false"
    fi
}
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/test_receipt.sh`
Expected: all PASS, exit 0.

- [ ] **Step 5: ShellCheck + commit**

```bash
shellcheck -S warning bootstrap.sh tests/test_receipt.sh
git add bootstrap.sh tests/test_receipt.sh
git commit -m "feat(receipt): add capture_prior_state + record helpers"
```

---

### Task 3: Wire recording into the install path

**Files:**
- Modify: `bootstrap.sh` — `ensure_homebrew`, `ensure_early_tools`, `ensure_il_claude_plugins`, `clone_and_setup_repo`, `main`

**Interfaces:**
- Consumes: helpers from Tasks 1–2.
- Produces: a populated receipt after a real `bootstrap.sh` run.

This task wires the in-memory recorders into the existing install branches. It is verified by ShellCheck + a scripted sanity check (a full install is the manual-matrix item), since unit-testing live `brew install` is out of scope per the spec.

- [ ] **Step 1: Record Homebrew install.** In `ensure_homebrew`, inside the `else` branch (right after `print_success "Homebrew installed"`), add:

```bash
        IL_BREW_INSTALLED=true
```

- [ ] **Step 2: Record core formula installs.** In `ensure_early_tools`, convert each guarded one-liner so a successful install is recorded. Replace lines 146–163 (the git/git-lfs/gh/jq/node block) with:

```bash
    if ! command_exists git;     then print_info "Installing git...";     brew install git     && record_formula_installed git;     fi
    print_success "git $(git --version | cut -d' ' -f3)"

    if ! command_exists git-lfs; then print_info "Installing git-lfs..."; brew install git-lfs && record_formula_installed git-lfs; fi
    git lfs install >/dev/null 2>&1
    print_success "git-lfs ready"

    if ! command_exists gh;      then print_info "Installing GitHub CLI..."; brew install gh   && record_formula_installed gh;      fi
    print_success "gh $(gh --version | head -1 | cut -d' ' -f3)"

    if ! command_exists jq;      then print_info "Installing jq...";      brew install jq      && record_formula_installed jq;      fi
    print_success "jq ready"

    # Node gives us npm, which we need to install global CLI tools like the
    # gws (Google Workspace) CLI in ensure_il_claude_plugins. The Homebrew
    # node formula bundles npm, so this single install covers both.
    if ! command_exists npm;     then print_info "Installing Node (provides npm)..."; brew install node && record_formula_installed node; fi
    print_success "node $(node --version) / npm $(npm --version)"
```

- [ ] **Step 3: Record Bun install.** In `ensure_early_tools`, inside the `else` branch where bun is installed, after the inner `print_success "bun $(bun --version)"` (the one following the successful install), add:

```bash
            IL_BUN_INSTALLED=true
```

- [ ] **Step 4: Record Claude Code install.** In `ensure_claude_code`, inside the `else` branch, after `print_success "Claude Code installed"`, add:

```bash
            IL_CLAUDE_INSTALLED=true
```

- [ ] **Step 5: Record settings + gws CLI.** In `ensure_il_claude_plugins`, immediately after the `jq … > "$tmp" && mv "$tmp" "$settings"` line, add:

```bash
    IL_SETTINGS_TOUCHED=true
```

And inside the `elif command_exists npm; then` branch, after the successful `print_success "gws CLI installed"`, add:

```bash
            IL_GWS_INSTALLED=true
```

- [ ] **Step 6: Record cloned repos.** In `clone_and_setup_repo`, replace the `else` clone branch (currently lines 417–425) with one that tracks whether we created the parent dir and records the clone:

```bash
    else
        local parent created_dir=false
        parent="$(dirname "$target")"
        [[ -d "$parent" ]] || created_dir=true
        mkdir -p "$parent"
        if ! gh repo clone "$slug" "$target"; then
            WARNINGS+=("Could not clone $slug — check your GitHub access")
            print_error "Failed to clone $slug (continuing)"
            return 0
        fi
        record_repo_cloned "$target" "$created_dir"
        print_success "Cloned $slug"
    fi
```

- [ ] **Step 7: Wire capture + write into main.** In `main()`, add `capture_prior_state` right after `ensure_early_tools` (so `jq` exists and it runs before identity/auth get overwritten), and `write_receipt` right before `print_completion`:

```bash
    ensure_early_tools          # step 3: git, git-lfs, gh, jq, bun
    capture_prior_state         # record pre-setup git identity + gh auth state
    ensure_github_auth          # step 4
```

```bash
    echo ""
    write_receipt               # persist what this run changed (for the uninstaller)
    verify_setup || print_warning "Setup completed with some issues"
    print_completion
```

- [ ] **Step 8: Sanity check (scripted, no real installs).** Confirm `main` is still source-guarded and the script parses and lints:

```bash
bash -n bootstrap.sh && echo "parse OK"
shellcheck -S warning bootstrap.sh
```
Expected: `parse OK` and no ShellCheck output.

- [ ] **Step 9: Re-run the receipt unit tests** (still green after wiring, since sourcing doesn't run installs):

Run: `bash tests/test_receipt.sh`
Expected: all PASS, exit 0.

- [ ] **Step 10: Commit**

```bash
git add bootstrap.sh
git commit -m "feat(receipt): record installs, clones, settings, prior state during bootstrap"
```

---

### Task 4: Marker-wrapped PATH edits

**Files:**
- Modify: `bootstrap.sh` — `ensure_claude_code` PATH-writing block
- Modify: `tests/test_receipt.sh` — add `write_il_path_block` tests

**Interfaces:**
- Produces: `write_il_path_block <profile> <line>` — appends a marker-delimited block once (idempotent) and calls `record_path_profile`. Markers: `# >>> il-setup >>>` / `# <<< il-setup <<<`.

- [ ] **Step 1: Write failing tests**

Add to `tests/test_receipt.sh` and to the run list:

```bash
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
```
Add `test_write_il_path_block` to the run list.

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_receipt.sh`
Expected: FAIL — `write_il_path_block: command not found`.

- [ ] **Step 3: Implement `write_il_path_block` and use it.** Add the function above `main()`:

```bash
# Append a marker-delimited PATH block to a profile, once, and record it so the
# uninstaller can remove exactly this block.
write_il_path_block() {
    local profile="$1" line="$2"
    if grep -qF '# >>> il-setup >>>' "$profile" 2>/dev/null; then
        return 0
    fi
    {
        echo ""
        echo "# >>> il-setup >>>"
        echo "$line"
        echo "# <<< il-setup <<<"
    } >> "$profile"
    record_path_profile "$profile"
}
```

Then replace the PATH-writing loop in `ensure_claude_code` (currently lines 476–490) with:

```bash
    local path_line='export PATH="$HOME/.local/bin:$PATH"'
    local wrote_any=false
    for shell_profile in "${profiles[@]}"; do
        if ! grep -qF '.local/bin' "$shell_profile" 2>/dev/null; then
            write_il_path_block "$shell_profile" "$path_line"
            print_success "Added ~/.local/bin to PATH in $(basename "$shell_profile")"
            wrote_any=true
        fi
    done

    if [[ "$wrote_any" == false ]]; then
        print_info "PATH already includes ~/.local/bin in your shell profile"
    fi
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/test_receipt.sh`
Expected: all PASS, exit 0.

- [ ] **Step 5: ShellCheck + commit**

```bash
shellcheck -S warning bootstrap.sh tests/test_receipt.sh
git add bootstrap.sh tests/test_receipt.sh
git commit -m "feat(receipt): wrap PATH edits in il-setup markers for clean removal"
```

---

## PHASE 2 — Uninstaller (macOS `uninstall.sh`)

### Task 5: uninstall.sh skeleton — receipt load + preset→category mapping

**Files:**
- Create: `uninstall.sh`
- Create: `tests/test_uninstall.sh`

**Interfaces:**
- Produces: `il_receipt_path()` (duplicated, self-contained); `load_receipt()` sets `RECEIPT_FOUND=true|false` and `RECEIPT_PATH`; `categories_for_preset <1|2>` echoes a space-separated category-id list. Category ids: `repos gws plugins gh gitid path claude devtools brew`.

- [ ] **Step 1: Write the failing test**

```bash
# tests/test_uninstall.sh
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
```

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_uninstall.sh`
Expected: FAIL — `uninstall.sh` does not exist / `categories_for_preset: command not found`.

- [ ] **Step 3: Create uninstall.sh skeleton**

```bash
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
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/test_uninstall.sh`
Expected: all PASS, exit 0.

- [ ] **Step 5: ShellCheck + commit**

```bash
shellcheck -S warning uninstall.sh tests/test_uninstall.sh
git add uninstall.sh tests/test_uninstall.sh
git commit -m "feat(uninstall): skeleton with receipt load + preset mapping"
```

---

### Task 6: Surgical settings.json key removal

**Files:**
- Modify: `uninstall.sh` (add `strip_il_settings`)
- Modify: `tests/test_uninstall.sh`

**Interfaces:**
- Produces: `strip_il_settings <settings_file>` — removes `extraKnownMarketplaces["irrational-labs-plugins"]` and the three `enabledPlugins["*@irrational-labs-plugins"]` keys, leaving everything else intact. Empty parent objects are left as `{}` (harmless).

- [ ] **Step 1: Write the failing test**

Add to `tests/test_uninstall.sh` and the run list:

```bash
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
```
Add `test_strip_il_settings` to the run list.

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_uninstall.sh`
Expected: FAIL — `strip_il_settings: command not found`.

- [ ] **Step 3: Implement**

Add to `uninstall.sh` above `main()`:

```bash
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
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/test_uninstall.sh`
Expected: all PASS, exit 0.

- [ ] **Step 5: ShellCheck + commit**

```bash
shellcheck -S warning uninstall.sh tests/test_uninstall.sh
git add uninstall.sh tests/test_uninstall.sh
git commit -m "feat(uninstall): surgical settings.json IL-key removal"
```

---

### Task 7: PATH marker-block removal

**Files:**
- Modify: `uninstall.sh` (add `remove_il_path_block`)
- Modify: `tests/test_uninstall.sh`

**Interfaces:**
- Produces: `remove_il_path_block <profile>` — deletes the lines between (and including) `# >>> il-setup >>>` and `# <<< il-setup <<<`, leaving the rest untouched.

- [ ] **Step 1: Write the failing test**

Add to `tests/test_uninstall.sh` and the run list:

```bash
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
```
Add `test_remove_il_path_block` to the run list.

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_uninstall.sh`
Expected: FAIL — `remove_il_path_block: command not found`.

- [ ] **Step 3: Implement** (using `awk` for bash-3.2-safe range deletion)

Add to `uninstall.sh` above `main()`:

```bash
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
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/test_uninstall.sh`
Expected: all PASS, exit 0.

- [ ] **Step 5: ShellCheck + commit**

```bash
shellcheck -S warning uninstall.sh tests/test_uninstall.sh
git add uninstall.sh tests/test_uninstall.sh
git commit -m "feat(uninstall): remove il-setup PATH marker block"
```

---

### Task 8: Git identity restore

**Files:**
- Modify: `uninstall.sh` (add `restore_git_identity`)
- Modify: `tests/test_uninstall.sh`

**Interfaces:**
- Produces: `restore_git_identity` — reads `git_identity_prior` from the receipt; if name/email non-empty, `git config --global` sets them back; if both empty (no prior identity), unsets `user.name`/`user.email`. Uses `run_cmd` so dry-run is observable.

- [ ] **Step 1: Write the failing test (dry-run assertions)**

Add to `tests/test_uninstall.sh` and the run list:

```bash
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
```
Add both to the run list.

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_uninstall.sh`
Expected: FAIL — `restore_git_identity: command not found`.

- [ ] **Step 3: Implement**

Add to `uninstall.sh` above `main()`:

```bash
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
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/test_uninstall.sh`
Expected: all PASS, exit 0.

- [ ] **Step 5: ShellCheck + commit**

```bash
shellcheck -S warning uninstall.sh tests/test_uninstall.sh
git add uninstall.sh tests/test_uninstall.sh
git commit -m "feat(uninstall): restore prior git identity from receipt"
```

---

### Task 9: Destructive category actions (dry-run testable)

**Files:**
- Modify: `uninstall.sh` (add `remove_repos`, `remove_gws`, `remove_github_auth`, `remove_claude_code`, `remove_dev_tools`, `remove_homebrew`)
- Modify: `tests/test_uninstall.sh`

**Interfaces:**
- Consumes: receipt fields, `run_cmd`, `RECEIPT_FOUND`/`RECEIPT_PATH`.
- Produces: the six reverser functions. Each respects `IL_DRY_RUN`. `remove_dev_tools` only targets receipt-listed formulae, each guarded by `brew uses --installed`. `remove_repos` respects `created_dir`. `remove_github_auth` only logs out when `gh_was_authenticated_before == false`.

- [ ] **Step 1: Write failing tests**

Add to `tests/test_uninstall.sh` and the run list:

```bash
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
```
Add all four to the run list.

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_uninstall.sh`
Expected: FAIL — the reverser functions are not defined.

- [ ] **Step 3: Implement the reversers**

Add to `uninstall.sh` above `main()`:

```bash
remove_repos() {
    [[ "$RECEIPT_FOUND" == true ]] || { print_warning "No receipt — skipping repo removal"; return 0; }
    local n; n="$(jq -r '(.repos_cloned // []) | length' "$RECEIPT_PATH")"
    [[ "$n" -gt 0 ]] || { print_info "No cloned repos recorded"; return 0; }
    local i path
    for (( i=0; i<n; i++ )); do
        path="$(jq -r ".repos_cloned[$i].path" "$RECEIPT_PATH")"
        [[ -n "$path" && "$path" != "null" ]] || continue
        run_cmd rm -rf "$path"
        print_success "Removed repo $path"
    done
}

remove_gws() {
    # Clear OAuth credentials FIRST, while gws is still installed. `gws auth
    # logout` is the supported command — it "clears saved credentials and token
    # cache" (verified via `gws auth --help`).
    if command_exists gws; then
        run_cmd gws auth logout || true
        print_success "Cleared gws credentials (gws auth logout)"
    fi
    if [[ "$RECEIPT_FOUND" == true && "$(jq -r '.gws_cli_installed_by_us // false' "$RECEIPT_PATH")" != "true" ]]; then
        print_info "gws CLI was not installed by setup — leaving the binary"
    elif command_exists npm; then
        run_cmd npm uninstall -g @googleworkspace/cli
        print_success "Uninstalled gws CLI"
    else
        print_warning "npm not found — cannot uninstall gws CLI"
    fi
    # Belt-and-suspenders: remove the config dir if it survived logout. Default
    # is ~/.config/gws; respect the documented GOOGLE_WORKSPACE_CLI_CONFIG_DIR.
    local cfg="${GOOGLE_WORKSPACE_CLI_CONFIG_DIR:-$HOME/.config/gws}"
    if [[ -d "$cfg" ]]; then
        run_cmd rm -rf "$cfg"
        print_success "Removed leftover gws config at $cfg"
    fi
}

remove_github_auth() {
    if [[ "$RECEIPT_FOUND" == true && "$(jq -r '.gh_was_authenticated_before // false' "$RECEIPT_PATH")" == "true" ]]; then
        print_info "You were signed into GitHub before setup — leaving gh auth intact"
        return 0
    fi
    if command_exists gh; then
        run_cmd gh auth logout
        print_success "Logged out of GitHub CLI"
    fi
}

remove_claude_code() {
    if command_exists claude; then
        # claude.ai installer drops the binary in ~/.local/bin
        run_cmd rm -f "$HOME/.local/bin/claude"
        print_success "Removed Claude Code binary (kept ~/.claude — it's yours)"
    fi
}

remove_dev_tools() {
    [[ "$RECEIPT_FOUND" == true ]] || { print_warning "No receipt — refusing to guess which dev tools to remove"; return 0; }
    local n; n="$(jq -r '(.formulae_installed_by_us // []) | length' "$RECEIPT_PATH")"
    local i f
    for (( i=0; i<n; i++ )); do
        f="$(jq -r ".formulae_installed_by_us[$i]" "$RECEIPT_PATH")"
        [[ -n "$f" && "$f" != "null" ]] || continue
        if brew uses --installed "$f" 2>/dev/null | grep -q .; then
            print_warning "Skipping $f — other installed formulae depend on it"
            continue
        fi
        run_cmd brew uninstall "$f"
        print_success "Uninstalled $f"
    done
    if [[ "$(jq -r '.bun_installed_by_us // false' "$RECEIPT_PATH")" == "true" && -d "$HOME/.bun" ]]; then
        run_cmd rm -rf "$HOME/.bun"
        print_success "Removed Bun (~/.bun)"
    fi
}

remove_homebrew() {
    if [[ "$RECEIPT_FOUND" == true && "$(jq -r '.brew_installed_by_us // false' "$RECEIPT_PATH")" == "true" ]]; then
        print_warning "About to uninstall Homebrew ENTIRELY — this removes ALL brew packages, IL or not."
        run_cmd /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/uninstall.sh)"
        print_success "Uninstalled Homebrew"
    else
        print_info "Homebrew was not installed by setup — leaving it"
    fi
}
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/test_uninstall.sh`
Expected: all PASS, exit 0.

- [ ] **Step 5: ShellCheck + commit**

```bash
shellcheck -S warning uninstall.sh tests/test_uninstall.sh
git add uninstall.sh tests/test_uninstall.sh
git commit -m "feat(uninstall): category reversers (repos, gws, gh, claude, dev tools, brew)"
```

---

### Task 10: Interactive menu + plugins reverser + confirmation + report

**Files:**
- Modify: `uninstall.sh` (add `remove_plugins`, `remove_path_edits`, `run_category`, `confirm`, `menu`, wire `main`)
- Modify: `tests/test_uninstall.sh`

**Interfaces:**
- Consumes: all reversers from Tasks 6–9.
- Produces: `remove_plugins` (calls `strip_il_settings "$HOME/.claude/settings.json"`); `remove_path_edits` (iterates receipt `path_edits`, calls `remove_il_path_block`); `run_category <id>` dispatches an id to its reverser; `menu` reads a choice on stdin and emits the selected category ids.

- [ ] **Step 1: Write the failing test for run_category dispatch**

Add to `tests/test_uninstall.sh` and the run list:

```bash
test_run_category_dispatch() {
    export IL_SETUP_RECEIPT; IL_SETUP_RECEIPT="$(mktemp)"
    echo '{"repos_cloned":[{"path":"/tmp/x","created_dir":true}]}' > "$IL_SETUP_RECEIPT"
    load_receipt
    local out; out="$(IL_DRY_RUN=1 run_category repos)"
    assert_contains "$out" 'DRYRUN: rm -rf /tmp/x' "run_category repos calls remove_repos" || fail=1
    out="$(IL_DRY_RUN=1 run_category path)"
    assert_contains "$out" "" "run_category path is a no-op with no path_edits (no crash)" || fail=1
    rm -f "$IL_SETUP_RECEIPT"
}
```
Add `test_run_category_dispatch` to the run list.

- [ ] **Step 2: Run to verify failure**

Run: `bash tests/test_uninstall.sh`
Expected: FAIL — `run_category: command not found`.

- [ ] **Step 3: Implement remaining functions + wire main**

Add to `uninstall.sh` above `main()`:

```bash
remove_plugins() {
    strip_il_settings "$HOME/.claude/settings.json"
}

remove_path_edits() {
    if [[ "$RECEIPT_FOUND" == true ]]; then
        local n; n="$(jq -r '(.path_edits // []) | length' "$RECEIPT_PATH")"
        local i p
        for (( i=0; i<n; i++ )); do
            p="$(jq -r ".path_edits[$i]" "$RECEIPT_PATH")"
            [[ -n "$p" && "$p" != "null" ]] && remove_il_path_block "$p"
        done
    else
        # Fallback: try the common profiles
        remove_il_path_block "$HOME/.zshrc"
        remove_il_path_block "$HOME/.bash_profile"
    fi
}

run_category() {
    case "$1" in
        repos)    remove_repos ;;
        gws)      remove_gws ;;
        plugins)  remove_plugins ;;
        gh)       remove_github_auth ;;
        gitid)    restore_git_identity ;;
        path)     remove_path_edits ;;
        claude)   remove_claude_code ;;
        devtools) remove_dev_tools ;;
        brew)     remove_homebrew ;;
        *)        print_warning "Unknown category: $1" ;;
    esac
}

confirm() {
    local prompt="$1" reply
    read -r -p "$prompt [y/N] " reply
    [[ "$reply" == "y" || "$reply" == "Y" ]]
}
```

Replace the `main()` body with the full flow:

```bash
main() {
    echo ""
    echo -e "${BOLD}Irrational Labs — Uninstaller${NC}"
    load_receipt
    if [[ "$RECEIPT_FOUND" == true ]]; then
        print_info "Found setup receipt at $RECEIPT_PATH"
    else
        print_warning "No receipt found — best-effort mode (won't touch dev tools; can't restore git identity)"
    fi

    echo ""
    echo "  1) Recommended — remove IL footprint & access (repos, gws, IL plugins, GitHub login, git identity, PATH)"
    echo "  2) Everything the script installed (preset 1 + Claude Code, dev tools, Bun)"
    echo "  3) Custom — choose categories"
    echo "  4) Cancel"
    echo ""
    local choice cats=""
    read -r -p "Choose [1]: " choice
    choice="${choice:-1}"

    case "$choice" in
        1) cats="$(categories_for_preset 1)" ;;
        2) cats="$(categories_for_preset 2)" ;;
        3)
            local all="repos gws plugins gh gitid path claude devtools brew" id
            for id in $all; do
                if confirm "Remove category '$id'?"; then cats="$cats $id"; fi
            done
            ;;
        *) print_info "Cancelled."; return 0 ;;
    esac

    [[ -n "${cats// /}" ]] || { print_info "Nothing selected — cancelled."; return 0; }

    echo ""
    print_step "Will reverse:${cats}"
    if ! confirm "Proceed?"; then print_info "Cancelled."; return 0; fi

    local id
    for id in $cats; do
        run_category "$id" || WARNINGS+=("category '$id' had issues")
    done

    echo ""
    if [[ ${#WARNINGS[@]} -gt 0 ]]; then
        print_warning "Completed with warnings:"
        local w; for w in "${WARNINGS[@]}"; do echo "  • $w"; done
    else
        print_success "Uninstall complete."
    fi
    print_info "Open a new terminal to drop the removed PATH entries."
}
```

- [ ] **Step 4: Run to verify pass**

Run: `bash tests/test_uninstall.sh`
Expected: all PASS, exit 0.

- [ ] **Step 5: Integration smoke test (piped input, dry-run).** Confirm preset 1 runs end-to-end without executing destructive commands:

```bash
export IL_SETUP_RECEIPT="$(mktemp)"
echo '{"repos_cloned":[{"path":"/tmp/x","created_dir":true}],"git_identity_prior":{"name":"","email":""},"gh_was_authenticated_before":false}' > "$IL_SETUP_RECEIPT"
printf '1\ny\n' | IL_DRY_RUN=1 bash uninstall.sh
```
Expected: prints `Will reverse: repos gws plugins gh gitid path` then `DRYRUN:` lines, no real deletions.

- [ ] **Step 6: ShellCheck + commit**

```bash
shellcheck -S warning uninstall.sh tests/test_uninstall.sh
git add uninstall.sh tests/test_uninstall.sh
git commit -m "feat(uninstall): interactive menu, presets, confirmation, report"
```

---

## PHASE 3 — Windows parity, docs, CI

### Task 11: bootstrap.ps1 receipt parity

**Files:**
- Modify: `bootstrap.ps1`

**Interfaces:**
- Produces: `Get-ReceiptPath`, `Write-Receipt`, `Capture-PriorState`, recording into install branches, marker-wrapped PATH edits — mirroring the macOS receipt fields exactly.

PowerShell is verified structurally (PSScriptAnalyzer + logic review + manual matrix), per the spec's testing stance — there is no Pester harness in this repo.

- [ ] **Step 1: Add receipt state + helpers.** Near the top of `bootstrap.ps1` (after the print-helper definitions), add module-scope state and functions:

```powershell
# ---- Receipt state -----------------------------------------------------------
$script:ILFormulae   = @()        # winget/scoop ids we installed
$script:ILPathFiles  = @()        # profile files we edited
$script:ILRepos      = @()        # @{ path=...; created_dir=$true/$false }
$script:ILBrew       = $false     # n/a on Windows; kept for schema parity
$script:ILBun        = $false
$script:ILClaude     = $false
$script:ILGws        = $false
$script:ILSettings   = $false
$script:ILPriorGitName  = ""
$script:ILPriorGitEmail = ""
$script:ILGhBefore      = $null

function Get-ReceiptPath {
    if ($env:IL_SETUP_RECEIPT) { return $env:IL_SETUP_RECEIPT }
    return (Join-Path $env:LOCALAPPDATA "il-setup\receipt.json")
}

function Capture-PriorState {
    $path = Get-ReceiptPath
    $existing = $null
    if (Test-Path $path) { try { $existing = Get-Content -Raw $path | ConvertFrom-Json } catch { $existing = $null } }
    if ($existing -and ($existing.PSObject.Properties.Name -contains "git_identity_prior")) {
        $script:ILPriorGitName  = $existing.git_identity_prior.name
        $script:ILPriorGitEmail = $existing.git_identity_prior.email
    } else {
        $script:ILPriorGitName  = (git config --global user.name) 2>$null
        $script:ILPriorGitEmail = (git config --global user.email) 2>$null
        if (-not $script:ILPriorGitName)  { $script:ILPriorGitName  = "" }
        if (-not $script:ILPriorGitEmail) { $script:ILPriorGitEmail = "" }
    }
    if ($existing -and ($existing.PSObject.Properties.Name -contains "gh_was_authenticated_before")) {
        $script:ILGhBefore = $existing.gh_was_authenticated_before
    } else {
        gh auth status *> $null
        $script:ILGhBefore = ($LASTEXITCODE -eq 0)
    }
}

function Write-Receipt {
    $path = Get-ReceiptPath
    $dir = Split-Path $path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $existing = [PSCustomObject]@{}
    if (Test-Path $path) { try { $existing = Get-Content -Raw $path | ConvertFrom-Json } catch { $existing = [PSCustomObject]@{} } }

    function _arr($o,$n) { if ($o.PSObject.Properties.Name -contains $n -and $o.$n) { return @($o.$n) } else { return @() } }
    function _bool($o,$n) { if ($o.PSObject.Properties.Name -contains $n) { return [bool]$o.$n } else { return $false } }

    $formulae = (@(_arr $existing 'formulae_installed_by_us') + $script:ILFormulae) | Sort-Object -Unique
    $paths    = (@(_arr $existing 'path_edits') + $script:ILPathFiles) | Sort-Object -Unique

    $repos = @()
    $seen = @{}
    foreach ($r in @(_arr $existing 'repos_cloned')) { if ($r.path -and -not $seen.ContainsKey($r.path)) { $repos += $r; $seen[$r.path]=$true } }
    foreach ($r in $script:ILRepos) { if ($r.path -and -not $seen.ContainsKey($r.path)) { $repos += $r; $seen[$r.path]=$true } }

    $receipt = [ordered]@{
        schema_version             = 1
        formulae_installed_by_us   = @($formulae)
        path_edits                 = @($paths)
        repos_cloned               = @($repos)
        brew_installed_by_us       = ((_bool $existing 'brew_installed_by_us') -or $script:ILBrew)
        bun_installed_by_us        = ((_bool $existing 'bun_installed_by_us') -or $script:ILBun)
        claude_code_installed_by_us= ((_bool $existing 'claude_code_installed_by_us') -or $script:ILClaude)
        gws_cli_installed_by_us    = ((_bool $existing 'gws_cli_installed_by_us') -or $script:ILGws)
    }
    if ($script:ILSettings) {
        $receipt.claude_settings = [ordered]@{ marketplace = "irrational-labs-plugins";
            plugins = @("gws@irrational-labs-plugins","il-slides@irrational-labs-plugins","key-behavior@irrational-labs-plugins") }
    } elseif ($existing.PSObject.Properties.Name -contains 'claude_settings') {
        $receipt.claude_settings = $existing.claude_settings
    }
    if ($existing.PSObject.Properties.Name -contains 'git_identity_prior') {
        $receipt.git_identity_prior = $existing.git_identity_prior
    } else {
        $receipt.git_identity_prior = [ordered]@{ name = $script:ILPriorGitName; email = $script:ILPriorGitEmail }
    }
    if ($existing.PSObject.Properties.Name -contains 'gh_was_authenticated_before') {
        $receipt.gh_was_authenticated_before = $existing.gh_was_authenticated_before
    } else {
        $receipt.gh_was_authenticated_before = [bool]$script:ILGhBefore
    }

    $json = [PSCustomObject]$receipt | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
}
```

- [ ] **Step 2: Record installs.** In `Ensure-EarlyTools`, after each successful `winget install`/`scoop install`, append the id: e.g. after the node install, `$script:ILFormulae += "OpenJS.NodeJS"`; after git, `+= "Git.Git"`; git-lfs `+= "GitHub.GitLFS"`; gh `+= "GitHub.cli"`; jq `+= "jq"`. In the Bun `else` branch, `$script:ILBun = $true`. In `Ensure-ClaudeCode` install branch, `$script:ILClaude = $true`. In `Ensure-IlClaudePlugins`, after writing settings.json set `$script:ILSettings = $true`, and after the successful gws install set `$script:ILGws = $true`.

- [ ] **Step 3: Marker PATH edits.** In `Ensure-ClaudeCode` (and any other profile-writing block), wrap the appended PATH line in markers and record the file. Add a helper and use it:

```powershell
function Add-IlPathBlock([string]$ProfilePath, [string]$Line) {
    if (-not (Test-Path $ProfilePath)) { New-Item -ItemType File -Path $ProfilePath -Force | Out-Null }
    if (Select-String -Path $ProfilePath -SimpleMatch "# >>> il-setup >>>" -Quiet) { return }
    Add-Content -Path $ProfilePath -Value "`n# >>> il-setup >>>`n$Line`n# <<< il-setup <<<"
    $script:ILPathFiles += $ProfilePath
}
```

- [ ] **Step 4: Record cloned repos.** In the repo-clone function, before cloning compute `$createdDir = -not (Test-Path (Split-Path $target))`, and after a successful clone: `$script:ILRepos += [PSCustomObject]@{ path = $target; created_dir = $createdDir }`.

- [ ] **Step 5: Wire main.** Call `Capture-PriorState` right after `Ensure-EarlyTools` (before GitHub auth / git identity), and `Write-Receipt` near the end before the completion message.

- [ ] **Step 6: Lint (matches CI).**

```bash
pwsh -c "Install-Module PSScriptAnalyzer -Force -Scope CurrentUser; \$r = Invoke-ScriptAnalyzer -Path bootstrap.ps1 -Severity Error; if (\$r) { \$r | Format-Table; exit 1 }"
```
Expected: exit 0, no Error-severity findings. (If `pwsh` is unavailable locally, rely on CI; do a manual logic review against the macOS receipt fields to confirm parity.)

- [ ] **Step 7: Commit**

```bash
git add bootstrap.ps1
git commit -m "feat(receipt): Windows parity — write receipt in bootstrap.ps1"
```

---

### Task 12: uninstall.ps1

**Files:**
- Create: `uninstall.ps1`

**Interfaces:**
- Mirrors `uninstall.sh`: receipt load, presets, custom picker, category reversers, surgical settings strip, marker-block removal, git identity restore. PowerShell verified structurally (PSScriptAnalyzer + manual matrix).

- [ ] **Step 1: Create uninstall.ps1**

```powershell
# Irrational Labs — Uninstaller (Windows). Reverses what bootstrap.ps1 added.
#   irm https://raw.githubusercontent.com/ChaningJang/setup/main/uninstall.ps1 | iex
$ErrorActionPreference = "Stop"

function Print-Step($m)    { Write-Host "`n> $m" -ForegroundColor Blue }
function Print-Success($m) { Write-Host "OK $m" -ForegroundColor Green }
function Print-Warning($m) { Write-Host "!! $m" -ForegroundColor Yellow }
function Print-Info($m)    { Write-Host "   $m" }
function Test-CommandExists($c) { $null -ne (Get-Command $c -ErrorAction SilentlyContinue) }

$script:DryRun = ($env:IL_DRY_RUN -eq "1")
function Run-Cmd([scriptblock]$Block, [string]$Desc) {
    if ($script:DryRun) { Write-Host "DRYRUN: $Desc" } else { & $Block }
}

function Get-ReceiptPath {
    if ($env:IL_SETUP_RECEIPT) { return $env:IL_SETUP_RECEIPT }
    return (Join-Path $env:LOCALAPPDATA "il-setup\receipt.json")
}

$script:Receipt = $null
function Load-Receipt {
    $p = Get-ReceiptPath
    if (Test-Path $p) { try { $script:Receipt = Get-Content -Raw $p | ConvertFrom-Json } catch { $script:Receipt = $null } }
    else { $script:Receipt = $null }
}
function Has-Receipt { return $null -ne $script:Receipt }
function R-Bool($name) { if ((Has-Receipt) -and ($script:Receipt.PSObject.Properties.Name -contains $name)) { return [bool]$script:Receipt.$name } return $false }

function Strip-IlSettings([string]$File) {
    if (-not (Test-Path $File)) { Print-Info "No settings.json — nothing to strip"; return }
    try { $s = Get-Content -Raw $File | ConvertFrom-Json } catch { Print-Warning "Could not parse $File"; return }
    if ($s.PSObject.Properties.Name -contains "extraKnownMarketplaces") { $s.extraKnownMarketplaces.PSObject.Properties.Remove("irrational-labs-plugins") }
    if ($s.PSObject.Properties.Name -contains "enabledPlugins") {
        foreach ($k in @("gws@irrational-labs-plugins","il-slides@irrational-labs-plugins","key-behavior@irrational-labs-plugins")) {
            $s.enabledPlugins.PSObject.Properties.Remove($k)
        }
    }
    $json = $s | ConvertTo-Json -Depth 12
    [System.IO.File]::WriteAllText($File, $json, (New-Object System.Text.UTF8Encoding($false)))
    Print-Success "Removed IL keys from settings.json"
}

function Remove-IlPathBlock([string]$File) {
    if (-not (Test-Path $File)) { return }
    $lines = Get-Content $File
    $out = New-Object System.Collections.Generic.List[string]
    $skip = $false
    foreach ($l in $lines) {
        if ($l -match "# >>> il-setup >>>") { $skip = $true }
        if (-not $skip) { $out.Add($l) }
        if ($l -match "# <<< il-setup <<<") { $skip = $false }
    }
    Set-Content -Path $File -Value $out
    Print-Success "Removed il-setup PATH block from $(Split-Path $File -Leaf)"
}

function Restore-GitIdentity {
    if (-not (Has-Receipt)) { Print-Warning "No receipt — cannot restore git identity"; return }
    $name = $script:Receipt.git_identity_prior.name
    $email = $script:Receipt.git_identity_prior.email
    if ($name -or $email) {
        if ($name)  { Run-Cmd { git config --global user.name $name } "git config --global user.name $name" }
        if ($email) { Run-Cmd { git config --global user.email $email } "git config --global user.email $email" }
        Print-Success "Restored prior git identity"
    } else {
        Run-Cmd { git config --global --unset user.name } "git config --global --unset user.name"
        Run-Cmd { git config --global --unset user.email } "git config --global --unset user.email"
        Print-Success "Cleared git identity (none before setup)"
    }
}

function Remove-Repos {
    if (-not (Has-Receipt)) { Print-Warning "No receipt — skipping repos"; return }
    foreach ($r in @($script:Receipt.repos_cloned)) {
        if ($r.path) { Run-Cmd { Remove-Item -Recurse -Force $r.path } "Remove-Item -Recurse -Force $($r.path)"; Print-Success "Removed $($r.path)" }
    }
}

function Remove-Gws {
    if (Test-CommandExists "gws") { Run-Cmd { gws auth logout } "gws auth logout"; Print-Success "Cleared gws credentials" }
    if ((Has-Receipt) -and -not (R-Bool "gws_cli_installed_by_us")) { Print-Info "gws CLI not installed by setup — leaving it" }
    elseif (Test-CommandExists "npm") { Run-Cmd { npm uninstall -g '@googleworkspace/cli' } "npm uninstall -g @googleworkspace/cli"; Print-Success "Uninstalled gws CLI" }
    $cfg = if ($env:GOOGLE_WORKSPACE_CLI_CONFIG_DIR) { $env:GOOGLE_WORKSPACE_CLI_CONFIG_DIR } else { Join-Path $env:USERPROFILE ".config\gws" }
    if (Test-Path $cfg) { Run-Cmd { Remove-Item -Recurse -Force $cfg } "Remove-Item $cfg"; Print-Success "Removed leftover gws config" }
}

function Remove-GitHubAuth {
    if ((Has-Receipt) -and (R-Bool "gh_was_authenticated_before")) { Print-Info "Was authed before setup — leaving gh auth"; return }
    if (Test-CommandExists "gh") { Run-Cmd { gh auth logout } "gh auth logout"; Print-Success "Logged out of GitHub CLI" }
}

function Remove-ClaudeCode {
    # bootstrap.ps1 installs Claude Code via `bun install -g`, so uninstall via bun.
    if (Test-CommandExists "claude") { Run-Cmd { bun remove -g '@anthropic-ai/claude-code' } "bun remove -g @anthropic-ai/claude-code"; Print-Success "Removed Claude Code (kept ~/.claude)" }
}

function Remove-DevTools {
    if (-not (Has-Receipt)) { Print-Warning "No receipt — refusing to guess dev tools"; return }
    foreach ($id in @($script:Receipt.formulae_installed_by_us)) {
        if ($id) { Run-Cmd { winget uninstall --id $id -e } "winget uninstall --id $id"; Print-Success "Uninstalled $id" }
    }
    $bun = Join-Path $env:USERPROFILE ".bun"
    if ((R-Bool "bun_installed_by_us") -and (Test-Path $bun)) { Run-Cmd { Remove-Item -Recurse -Force $bun } "Remove-Item $bun"; Print-Success "Removed Bun" }
}

function Remove-Plugins { Strip-IlSettings (Join-Path $env:USERPROFILE ".claude\settings.json") }

function Remove-PathEdits {
    if (Has-Receipt) { foreach ($p in @($script:Receipt.path_edits)) { if ($p) { Remove-IlPathBlock $p } } }
    else { Remove-IlPathBlock $PROFILE }
}

function Run-Category($id) {
    switch ($id) {
        "repos"    { Remove-Repos }
        "gws"      { Remove-Gws }
        "plugins"  { Remove-Plugins }
        "gh"       { Remove-GitHubAuth }
        "gitid"    { Restore-GitIdentity }
        "path"     { Remove-PathEdits }
        "claude"   { Remove-ClaudeCode }
        "devtools" { Remove-DevTools }
        default    { Print-Warning "Unknown category: $id" }
    }
}

function Main {
    Write-Host "`nIrrational Labs - Uninstaller"
    Load-Receipt
    if (Has-Receipt) { Print-Info "Found receipt at $(Get-ReceiptPath)" } else { Print-Warning "No receipt - best-effort mode" }

    Write-Host ""
    Write-Host "  1) Recommended - IL footprint and access"
    Write-Host "  2) Everything the script installed"
    Write-Host "  3) Custom"
    Write-Host "  4) Cancel"
    $choice = Read-Host "Choose [1]"
    if (-not $choice) { $choice = "1" }

    $cats = @()
    switch ($choice) {
        "1" { $cats = @("repos","gws","plugins","gh","gitid","path") }
        "2" { $cats = @("repos","gws","plugins","gh","gitid","path","claude","devtools") }
        "3" { foreach ($id in @("repos","gws","plugins","gh","gitid","path","claude","devtools")) { if ((Read-Host "Remove '$id'? (y/N)") -match '^[Yy]') { $cats += $id } } }
        default { Print-Info "Cancelled."; return }
    }
    if ($cats.Count -eq 0) { Print-Info "Nothing selected."; return }

    Print-Step ("Will reverse: " + ($cats -join " "))
    if ((Read-Host "Proceed? (y/N)") -notmatch '^[Yy]') { Print-Info "Cancelled."; return }
    foreach ($id in $cats) { Run-Category $id }
    Print-Success "Uninstall complete. Open a new terminal to drop removed PATH entries."
}

Main
```

- [ ] **Step 2: Lint (matches CI).**

```bash
pwsh -c "Install-Module PSScriptAnalyzer -Force -Scope CurrentUser; \$r = Invoke-ScriptAnalyzer -Path uninstall.ps1 -Severity Error; if (\$r) { \$r | Format-Table; exit 1 }"
```
Expected: exit 0. (If `pwsh` unavailable locally, rely on CI; manually review parity with `uninstall.sh` categories.)

- [ ] **Step 3: Commit**

```bash
git add uninstall.ps1
git commit -m "feat(uninstall): Windows uninstaller (uninstall.ps1)"
```

---

### Task 13: README + CI

**Files:**
- Modify: `README.md`
- Modify: `.github/workflows/lint.yml`

- [ ] **Step 1: Add README section.** After the existing "What it does" section, add:

```markdown
## Uninstall / offboarding

To reverse what setup added (e.g. when a consultant leaves), run:

    curl -fsSL https://raw.githubusercontent.com/ChaningJang/setup/main/uninstall.sh | bash

Windows (PowerShell):

    irm https://raw.githubusercontent.com/ChaningJang/setup/main/uninstall.ps1 | iex

It reads a receipt the installer wrote (`~/.config/il-setup/receipt.json`) and
presents a menu:

1. **Recommended** — remove the IL footprint & access: cloned repos, `gws` CLI +
   Google credentials, IL Claude plugins, GitHub login, git identity, PATH edits.
2. **Everything the script installed** — preset 1 plus Claude Code, the dev tools
   the script installed, and Bun.
3. **Custom** — pick categories one by one.

It only removes tools the script itself installed (never ones that predated it),
restores your previous git identity, and edits only the IL keys in
`settings.json` — it never deletes `~/.claude`. Removing Homebrew entirely is
available only via the custom picker, with a warning.
```

- [ ] **Step 2: Extend CI to lint the new scripts and run the tests.** In `.github/workflows/lint.yml`, change the ShellCheck step to cover all `.sh` files and add a test step. Replace the `ShellCheck bootstrap.sh` step with:

```yaml
      - name: ShellCheck
        run: sudo apt-get update && sudo apt-get install -y shellcheck && shellcheck -S warning bootstrap.sh uninstall.sh tests/lib/assert.sh tests/test_receipt.sh tests/test_uninstall.sh
      - name: Unit tests
        run: bash tests/test_receipt.sh && bash tests/test_uninstall.sh
```

And add `uninstall.ps1` to the PSScriptAnalyzer step:

```yaml
          $r = Invoke-ScriptAnalyzer -Path bootstrap.ps1,uninstall.ps1 -Severity Error
```

- [ ] **Step 3: Run the full local gate.**

```bash
shellcheck -S warning bootstrap.sh uninstall.sh tests/lib/assert.sh tests/test_receipt.sh tests/test_uninstall.sh
bash tests/test_receipt.sh && bash tests/test_uninstall.sh
```
Expected: clean ShellCheck, all tests PASS.

- [ ] **Step 4: Commit, push, open PR.**

```bash
git add README.md .github/workflows/lint.yml
git commit -m "docs+ci: document uninstaller, lint new scripts, run unit tests"
git push -u origin add-uninstaller
gh pr create --title "Add menu-driven uninstaller + install receipt" --body "Implements docs/superpowers/specs/2026-06-25-setup-uninstaller-design.md. Receipt-backed, menu-driven uninstaller for offboarding consultants. macOS + Windows."
```

- [ ] **Step 5: Verify CI is green** on the PR before merging.

```bash
gh pr checks --watch
```
Expected: ShellCheck, Unit tests, PSScriptAnalyzer, repos.json all pass.

---

## Manual Verification Matrix (post-implementation, before merge)

These cannot be unit-tested and must be run by hand on a real machine:

1. **macOS happy path:** run `bootstrap.sh` on a test account → inspect `~/.config/il-setup/receipt.json` for correct fields → run `uninstall.sh` preset 1 → confirm repos/plugins/gws/PATH removed, git identity restored, dev tools untouched.
2. **Pre-existing-tool safety:** install `git` (or `node`) manually first, then run `bootstrap.sh`, then `uninstall.sh` preset 2 → confirm the pre-existing tool is NOT removed (it won't be in `formulae_installed_by_us`).
3. **Re-run idempotency:** run `bootstrap.sh` twice → confirm `git_identity_prior` still holds the ORIGINAL pre-setup identity, not the IL one.
4. **No-receipt fallback:** delete the receipt, run `uninstall.sh` → confirm it warns, skips dev tools, and still removes plugins/PATH best-effort.
5. **Windows:** run `bootstrap.ps1` and `uninstall.ps1` on a Windows box if available; otherwise flag as pending a real-world pass.
