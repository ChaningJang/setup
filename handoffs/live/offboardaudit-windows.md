# Offboarding audit — Windows port

## Done-with-evidence
- **Saved at-risk work.** Commit `77a23ad` "Add read-only offboarding audit script (macOS/bash)".
  3 files: `audit.sh` (435 lines, new), `README.md` (+43), `.github/workflows/lint.yml` (+1/-1).
  Evidence: `git log --oneline -1` -> `77a23ad`. **Not pushed.**
- **`audit.ps1` written** — 976 lines. Faithful port of `audit.sh`; same 6 sections,
  same 3 buckets, same KEEP-by-default list, loud section 5 for work at risk
  (unpushed and uncommitted counted separately, plus per-repo and grand totals).
  Windows paths all traced to a `bootstrap.ps1` line (cited inline in the script):
  receipt L46, repos L697, gws CLI L543, keyring User env var L456, bun on User
  PATH L415-422, `~\.claude\settings.json` L465-490, profile marker L121-128,
  winget ids L202/210/218/235/649, scoop apps L226/630/644, longpaths L267/277.
  gws config dir is NOT traceable to bootstrap.ps1 -> probed and reported UNKNOWN.
- **Static read-only proof** — `tests/audit_readonly_check.py` (196 lines), PASS.
  Strips comments + string literals (keeps `$(...)` code), then asserts 38
  write/network/mutation categories absent, `>`/`>>` absent, only two
  process-local `$env:` assignments, scrubber wired into the single output funnel,
  braces balance, no unterminated string.
  Evidence: `python3 tests/audit_readonly_check.py` -> "RESULT: PASS", exit 0.
- **Negative control** — 9 injected faults (Set-Content; a write inside `$()`;
  `>` redirect; persisted env var; network call; `git checkout`; unbalanced brace;
  unterminated quote; scrubber removed). All 9 CAUGHT. The checker is not vacuous.
- **README + lint** — README 240 lines: both scripts documented download-and-read,
  plus the 4-check empirical plan to run on the first Windows box.
  `lint.yml` runs `audit.ps1` under PSScriptAnalyzer and runs the read-only check.

- **2026-08-27 — empirical proof, and two real bugs.** A portable `pwsh` 7.4.6
  (unpacked in `$TMPDIR`, nothing installed) ran `audit.ps1` against a fixture
  home via `tests/test_audit_ps1.sh`. Found and fixed:
  1. `Get-GitOutput` returned a one-element array, which PowerShell unrolls to a
     string, so `$o[0]` was the first *character*: every origin was `h`, every
     repo read as non-IL, section 5 said "nothing to lose". Fixed with `return ,@(...)`
     (also in `Get-CandidateRepo`).
  2. `npm ls -g` wrote `_logs/*.log` + `_update-notifier-last-checked` into the
     home dir. Same hole in `audit.sh`. Both now read global `node_modules` off disk.
  3. `gh auth status` wrote `~/.local/state/gh/device-id` (CI-only: ubuntu's gh is
     newer than the Mac's). Both scripts now read gh's `hosts.yml` off disk instead.
  After the fixes: 38/38 empirical checks pass, static checker PASS, PSScriptAnalyzer
  1 Information note only, parser 0 errors. `audit.sh` re-proven on Chaning's Mac
  with a full `~/.npm` mtime snapshot: unchanged, 19/5/13 totals unchanged.
  Evidence: `PWSH=<pwsh> bash tests/test_audit_ps1.sh` -> "RESULT: PASS".

## In flight
- Nothing.

## Next
- Someone with a real Windows box runs README "Verifying the audit scripts"
  checks 0-4 under Windows PowerShell 5.1. The fixture proof was pwsh 7 on macOS;
  the Windows-only probes (winget, HKLM, scheduled tasks, User env block) have
  never executed.
- Chaning decides whether to push. Pushing publishes the README "Known gaps"
  section about uninstall.sh.
- Separate thread: the 4 uninstaller gaps. Not touched here.

## Decisions
- Commit only, never push — publishing "Known gaps" is Chaning's call.
- Download-and-read, not `irm | iex` — offboarding inverts the onboarding trust
  dynamic, and downloading first closes the TOCTOU gap.
- `audit.ps1` **exits 2** on non-Windows rather than only bannering like
  `audit.sh` does on non-Darwin: every check is a Windows path, so the report
  would be uniformly empty and an empty report reads like a clean machine.
- Pure ASCII, no tabs, no trailing whitespace — avoids PSScriptAnalyzer's BOM
  rule and Windows console encoding surprises.
- `winget list` is called with `--disable-interactivity` and **no**
  `--accept-source-agreements` (that would persist an acceptance = a write) and
  with no bare-`winget list` fallback (that can hang on a prompt). If it cannot
  be read, every winget verdict degrades to UNKNOWN.
- scoop inventory read off disk (`%USERPROFILE%\scoop\apps`) rather than via
  `scoop list`, so nothing can trigger a bucket refresh.
- Pagination disabled per-invocation with `git --no-pager`, not `GIT_PAGER=cat`
  (`cat` is not a Windows command). `GIT_TERMINAL_PROMPT=0` added so git can
  never block asking for credentials.
- Added `tests/audit_readonly_check.py` beyond the literal ask, because a
  one-off grep in a transcript rots; a CI check does not.

## World assumptions
- Emily Rosenzweig offboards ~2026-09-08, on **Windows**. ~2 weeks.
- No Windows machine here. `pwsh` was NOT installed on this Mac; a portable
  7.4.6 tarball was unpacked into `$TMPDIR` for the test run and is gone with it.
  CI (ubuntu) has pwsh, so the empirical test runs there on every push.
- Do not contact Emily; Chaning owns that.
