#!/usr/bin/env bash
# Empirical read-only proof for audit.ps1.
# Created: 2026-08-27
#
# tests/audit_readonly_check.py proves statically that no write-capable
# operation exists in audit.ps1. This test proves it EMPIRICALLY, the same way
# audit.sh was proven on a real machine: build a fake Windows-shaped home,
# run the script twice, and show that
#   1. every file mtime in the fixture is unchanged,
#   2. the fixture entry count is unchanged (no stray file or dir),
#   3. .git/index mtime is unchanged (GIT_OPTIONAL_LOCKS=0 took effect),
#   4. the output contains no secret pattern and no unmasked email,
#   5. the report actually says the right things (REMOVE / KEEP / WORK AT RISK).
#
# It runs under pwsh on macOS or Linux, so it cannot exercise Windows-only
# probes (winget, HKLM, Get-ScheduledTask, the User environment block); those
# degrade to UNKNOWN / "not installed" exactly as designed. What it does
# exercise is everything else: receipt parsing, repo discovery, git reads,
# settings.json key inspection, profile-marker search, the scrubber, the email
# mask, and the section 5 work-at-risk arithmetic.
#
# The shipped script refuses to run off Windows and has no test hook to bypass
# that (test hooks in shipped offboarding scripts are how IL_DRY_RUN went
# wrong). So this test copies audit.ps1 and rewrites exactly ONE line -- the
# guard's `if` -- and asserts that exactly one line changed.
#
# Usage:  bash tests/test_audit_ps1.sh            (needs pwsh on PATH)
#         PWSH=/path/to/pwsh bash tests/test_audit_ps1.sh
set -u
cd "$(dirname "$0")/.." || exit 1
PWSH="${PWSH:-pwsh}"
command -v "$PWSH" >/dev/null 2>&1 || { echo "SKIP: pwsh not found (set PWSH=...)"; exit 0; }

fail=0
ok()   { echo "  ok    $*"; }
bad()  { echo "  FAIL  $*"; fail=$((fail + 1)); }

# Portable "mtime path" listing.
# The snapshot excludes ONE path: the fixture's .cache/powershell, which the
# pwsh host rewrites on every start (StartupProfileData-*) regardless of what
# script it runs. Nothing else is excluded; the home dir's own mtime is in.
if stat -f '%m' / >/dev/null 2>&1; then
    mtimes() { find "$1" -not -path '*/.cache/powershell*' -exec stat -f '%m %N' {} + | LC_ALL=C sort; }
    mtime()  { stat -f '%m' "$1"; }
else
    mtimes() { find "$1" -not -path '*/.cache/powershell*' -exec stat -c '%Y %n' {} + | LC_ALL=C sort; }
    mtime()  { stat -c '%Y' "$1"; }
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/audit-ps1-test.XXXXXX")" || { echo "FAIL: could not create temp dir"; exit 1; }
if [ -z "${KEEP_FIXTURE:-}" ]; then trap 'rm -rf "$T"' EXIT; else echo "fixture kept at $T"; fi
F="$T/fixture"; H="$F/home"
mkdir -p "$H/.claude" "$H/.config/gws" "$H/Documents/WindowsPowerShell" \
         "$H/.ssh" "$F/LOCALAPPDATA/il-setup" "$F/APPDATA"

# --- fixture: what a consultant's Windows home looks like after bootstrap.ps1
printf '[user]\n\tname = Test Consultant\n\temail = consultant@irrationallabs.com\n[core]\n\tlongpaths = true\n' > "$H/.gitconfig"
cat > "$H/.claude/settings.json" <<'EOF'
{"extraKnownMarketplaces":{"irrational-labs-plugins":{"source":{"source":"github","repo":"x/y"}}},
 "enabledPlugins":{"gws@irrational-labs-plugins":true},
 "env":{"GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND":"file","PLANTED":"sk-PLANTEDSECRET0123456789"},
 "other":1}
EOF
printf 'x\n# >>> il-setup >>>\n$env:Path += ";x"\n# <<< il-setup <<<\n' > "$H/Documents/WindowsPowerShell/profile.ps1"
echo "not-really-encrypted" > "$H/.config/gws/credentials.enc"
echo "ssh-ed25519 AAAA consultant" > "$H/.ssh/id_ed25519.pub"
cat > "$F/LOCALAPPDATA/il-setup/receipt.json" <<EOF
{"schema_version":1,"bun_installed_by_us":false,"claude_code_installed_by_us":true,
 "gws_cli_installed_by_us":true,"gws_env_set_by_us":true,"gh_was_authenticated_before":false,
 "git_identity_prior":{"name":"Prior Name","email":"prior.personal@example.com"},
 "formulae_installed_by_us":["Git.Git","jq"],"path_edits":["profile.ps1"],
 "repos_cloned":[{"path":"$H/irrational_labs_hq"},{"path":"$H/gone_repo"}]}
EOF
mkdir -p "$F/APPDATA/npm/node_modules/@googleworkspace/cli" "$F/APPDATA/npm/node_modules/.bin" "$F/APPDATA/npm/node_modules/corepack"
# gh login on disk, with a planted token: must be reported as present, never printed.
mkdir -p "$F/APPDATA/GitHub CLI"
printf 'github.com:\n    user: test-consultant\n    oauth_token: gho_PLANTEDGHTOKEN0123456789\n    git_protocol: https\n' > "$F/APPDATA/GitHub CLI/hosts.yml"
mkrepo() {
    git init -q "$1"
    git -C "$1" -c user.name=t -c user.email=t@t.t commit -q --allow-empty -m init
    git -C "$1" remote add origin "$2"
}
mkrepo "$H/irrational_labs_hq"   "https://github.com/IrrationalLabs-team/irrational_labs_hq.git"
git -C "$H/irrational_labs_hq" -c user.name=t -c user.email=t@t.t commit -q --allow-empty -m "unpushed"
echo dirty > "$H/irrational_labs_hq/client-name.txt"
# A token embedded in a remote URL is a real-world way secrets reach a report.
mkrepo "$H/projects/il-scrolly" "https://ghp_PLANTEDTOKEN0123456789@github.com/IrrationalLabs-team/il-scrolly.git"
mkrepo "$H/personal"            "https://github.com/someone/personal.git"

# --- guard-stripped copy: exactly one line may differ
sed 's/^if (-not \$onWindows) {$/if ($false) {/' audit.ps1 > "$T/audit-noguard.ps1"
changed=$(diff audit.ps1 "$T/audit-noguard.ps1" | grep -c '^[<>]')
if [ "$changed" -eq 2 ]; then ok "guard bypass touches exactly one line of the copy"
else bad "guard bypass changed $changed diff lines, expected 2"; fi

echo "Empirical read-only proof for audit.ps1 under $("$PWSH" -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')"
echo "========================================================================"

# --- pre-warm the PowerShell host. pwsh creates its own ~/.cache and
# ~/.local/share/powershell on first start regardless of -NoProfile; that is
# the host, not the script, so let it happen BEFORE the snapshot.
env HOME="$H" USERPROFILE="$H" LOCALAPPDATA="$F/LOCALAPPDATA" APPDATA="$F/APPDATA" \
    "$PWSH" -NoProfile -NonInteractive -Command 'exit 0' >/dev/null 2>&1

# --- snapshot, run twice, snapshot
mtimes "$F" > "$T/snap0"; mtime "$H/irrational_labs_hq/.git/index" > "$T/idx0"
run() {
    env HOME="$H" USERPROFILE="$H" LOCALAPPDATA="$F/LOCALAPPDATA" APPDATA="$F/APPDATA" \
        "$PWSH" -NoProfile -NonInteractive -File "$T/audit-noguard.ps1"
}
run > "$T/out1" 2> "$T/err1"; rc1=$?
run > "$T/out2" 2> "$T/err2"; rc2=$?
mtimes "$F" > "$T/snap1"; mtime "$H/irrational_labs_hq/.git/index" > "$T/idx1"

[ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && ok "exit code 0 on both runs" || bad "exit codes $rc1 / $rc2"
[ ! -s "$T/err1" ] && ok "nothing on stderr" || { bad "stderr not empty:"; head -5 "$T/err1"; }

# 1+2. mtimes and entry count
if diff -q "$T/snap0" "$T/snap1" >/dev/null; then
    ok "every fixture mtime unchanged and entry count unchanged ($(wc -l < "$T/snap1" | tr -d ' ') entries)"
else
    bad "fixture changed between runs:"; diff "$T/snap0" "$T/snap1" | head
fi
# Regression guard: an earlier version shelled out to `npm ls -g`, and npm
# wrote _logs/*.log and _update-notifier-last-checked into the home dir.
[ ! -e "$H/.npm" ] && ok "no .npm cache created (script does not shell out to npm)" || bad ".npm appeared in the fixture home: a subprocess wrote files"
# Regression guard: `gh auth status` writes ~/.local/state/gh/device-id on
# first use (caught by CI on ubuntu, where gh is newer than on the dev Mac).
[ ! -e "$H/.local/state/gh" ] && ok "no gh state dir created (script does not shell out to gh)" || bad ".local/state/gh appeared: gh was run"
# 3. .git/index
[ "$(cat "$T/idx0")" = "$(cat "$T/idx1")" ] && ok ".git/index mtime unchanged (GIT_OPTIONAL_LOCKS=0 held)" || bad ".git/index was rewritten"
# Determinism: only the Generated: line may differ between runs.
if [ "$(diff "$T/out1" "$T/out2" | grep -c '^[<>]' )" -le 2 ]; then ok "two runs produce the same report (timestamp aside)"
else bad "reports differ between runs beyond the timestamp"; diff "$T/out1" "$T/out2" | head; fi

# 4. secret scan and email mask
if grep -nE 'gh[pousr]_[A-Za-z0-9]{6,}|github_pat_|sk-[A-Za-z0-9]{12,}|xox[abprse]-|AIza[A-Za-z0-9_-]{10,}|PRIVATE KEY-----|[Bb]earer [A-Za-z0-9._-]{8,}|PLANTED' "$T/out1"; then
    bad "secret pattern survived in output (above)"
else ok "no secret pattern in output; planted ghp_ token and sk- key both scrubbed"; fi
if grep -nE '[A-Za-z0-9._%+-]{2,}@[A-Za-z0-9.-]+\.[a-z]{2,}' "$T/out1"; then bad "unmasked email in output (above)"
else ok "no unmasked email address in output"; fi
grep -q 'c\*\*\*\*@irrationallabs.com' "$T/out1" && ok "git identity email is masked, not dropped" || bad "masked git identity email missing"
grep -q 'p\*\*\*\*@example.com' "$T/out1"      && ok "receipt prior-identity email is masked" || bad "masked prior email missing"

# 5. the report says the right things
expect() { grep -qF -- "$2" "$T/out1" && ok "$1" || { bad "$1 -- expected text not found: $2"; }; }
expect "receipt found and parsed"                 "Schema:       1"
expect "stale receipt entry detected"             "STALE   receipt lists a repo that is GONE"
expect "standard IL repo -> REMOVE"               "[REMOVE ] IL repo: $H/irrational_labs_hq"
expect "non-standard IL-org repo -> REMOVE"       "IL-org repo not in the standard list: $H/projects/il-scrolly"
expect "scrubbed origin URL printed as redacted"  "gh*_***REDACTED***@github.com"
expect "gws credentials.enc reported as EXISTS"   "credentials.enc EXISTS"
expect "settings.json marketplace key -> REMOVE"  'extraKnownMarketplaces["irrational-labs-plugins"]'
expect "settings.json plugin key -> REMOVE"       'enabledPlugins["gws@irrational-labs-plugins"]'
expect "settings.json env key -> REMOVE"          "env.GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND"
expect "profile il-setup marker found"            "contains 1 il-setup block(s)"
expect "core.longpaths reported"                  "git core.longpaths=true is set globally"
expect "npm globals read off disk (scoped)"      "@googleworkspace/cli"
expect "npm globals read off disk (unscoped)"    "   corepack"
if grep -q '^   \.bin$' "$T/out1"; then bad ".bin listed as an npm package"; else ok "npm .bin dir skipped"; fi
expect "gh login read from hosts.yml"            "gh: github.com entry present"
expect "gh user handle reported"                 "(user test-consultant)"
expect "gh login -> REMOVE (receipt says IL logged in)" "[REMOVE ] GitHub login was established by IL setup"
expect "SSH keys -> KEEP"                         "[KEEP   ] SSH keys: 1 public key(s)"
expect "personal repo counted as KEEP"            "[KEEP   ] 1 non-IL git repo(s)"
expect "work at risk flagged"                     "*** WORK AT RISK: $H/irrational_labs_hq"
expect "uncommitted count correct"                "uncommitted changes: 1  (of which untracked: 1)"
expect "unpushed count correct"                   "commits not pushed:  2"
expect "work-at-risk totals (il-scrolly is unpushed too)"                      "*** 2 of 2 IL repo(s) have work at risk."
expect "summary work-at-risk count"               "REPOS WITH WORK AT RISK: 2"
if grep -q 'client-name.txt' "$T/out1"; then bad "dirty filename leaked into report"; else ok "dirty filenames not listed"; fi
if grep -q '"other"' "$T/out1"; then bad "non-IL settings.json key leaked"; else ok "non-IL settings.json keys not printed"; fi

echo "========================================================================"
if [ "$fail" -gt 0 ]; then echo "RESULT: FAIL -- $fail check(s) failed"; echo "--- report ---"; cat "$T/out1"; exit 1; fi
echo "RESULT: PASS -- audit.ps1 ran twice against a fixture home and changed nothing"
