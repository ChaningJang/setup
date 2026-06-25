# Setup Uninstaller — Design

- **Date:** 2026-06-25
- **Repo:** `ChaningJang/setup` (local: `~/setup`)
- **Status:** Approved design, ready for implementation plan

## Problem

`bootstrap.sh` / `bootstrap.ps1` onboard a machine by installing tools, signing
into GitHub, registering IL Claude plugins, installing the `gws` CLI, and cloning
IL repos. When a **consultant** leaves, there is no clean way to reverse this — to
remove IL code and access from their machine and return it to roughly the state it
was in before they ran the script.

The hard part is *"roughly the state it was in before."* A consultant almost
certainly had some of these tools already (Homebrew, `git`, maybe `node` or Claude
Code). A naive "uninstall everything the script can install" would remove tools
that predated the script and were never ours to touch. Worse, the installer
**overwrites** `git config --global` identity and **merges** keys into a shared
`~/.claude/settings.json` — neither is reversible unless we recorded the prior
state at install time.

## Goals

- Give a departing consultant (or whoever offboards them) a one-command
  uninstaller that removes the IL footprint and access this script added.
- Reverse **only what the script actually changed** — never remove a pre-existing
  tool, never blank a config we didn't originally set.
- Make it **menu-driven**: a small set of presets plus a custom category picker,
  so nobody has to remember a flag. Default to the security-relevant subset
  (repos, access, IL config).
- Maintain macOS ↔ Windows parity, matching the existing two-script structure.

## Non-Goals

- A perfect bit-for-bit machine restore. We revert what the script did; we do not
  snapshot the whole system.
- Uninstalling tools the consultant installed independently of the script.
- A containerized uninstall-test harness. Like the bootstrap, this is
  integration-heavy and idempotent; static analysis + a manual matrix is the
  right level (consistent with the bootstrap spec's testing stance).

## Key Decisions

| Decision | Choice |
|----------|--------|
| How to know what's safe to remove | **Hybrid receipt.** Installer writes a receipt of what it changed; uninstaller reads it. Falls back to best-effort known-list if absent. |
| User interface | **Menu-driven** — 3 presets + custom category picker. No flags. |
| Default scope | **IL footprint & access** (repos, gws access, IL plugins, GitHub login, git identity, PATH). Dev tools / Bun / Node / Claude Code / Homebrew are opt-in. |
| Platforms | macOS (`uninstall.sh`) **and** Windows (`uninstall.ps1`), with receipt-writing added to both bootstraps. |
| Invocation | `curl … \| bash` / `irm … \| iex` one-liner — not a script inside a cloned repo (the repo is one of the things it deletes). |
| `settings.json` handling | Surgical key removal only — never delete the file or `~/.claude`. |

## Architecture

### Component 1 — The receipt (install-time changes to the bootstraps)

A receipt file records *only what the installer actually changed*, written as the
installer runs.

- **Location:** `~/.config/il-setup/receipt.json` (macOS/Linux),
  `%LOCALAPPDATA%\il-setup\receipt.json` (Windows). JSON. Merged across re-runs.
- **Mechanism:** the installer already guards each install with
  `command_exists X || install`. A `record_*` helper is appended *inside* each
  `||` branch, so an entry is written **only when we actually installed X**.
  Pre-existing tools are never recorded, therefore never removed.

Recorded fields:

| Field | Meaning |
|-------|---------|
| `schema_version`, `timestamp`, `setup_commit` | Provenance. |
| `brew_installed_by_us` | `true` only if Homebrew was missing and we installed it. |
| `formulae_installed_by_us` | Array of brew formulae we added (e.g. `node`, `ffmpeg`). Only ones whose `command_exists` guard fired. |
| `bun_installed_by_us`, `claude_code_installed_by_us`, `gws_cli_installed_by_us` | Booleans. |
| `claude_settings` | Which keys we added: the `irrational-labs-plugins` marketplace entry + the three plugin keys. Used to strip exactly those keys. |
| `git_identity_prior` | `{name, email}` captured **before** the script overwrote it (empty strings if none). Enables restore, not blank. |
| `gh_was_authenticated_before` | Bool — so we only `gh auth logout` if the script is what logged them in. |
| `path_edits` | The profile files we appended to. PATH additions are wrapped in delimited markers (`# >>> il-setup >>>` … `# <<< il-setup <<<`) so removal is a clean delete-between-markers. |
| `repos_cloned` | `[{path, created_dir}]` — each IL repo and whether we created its containing directory. |

Correctness rules:

- **Prior-state fields are captured only the first time** (null-check on re-run),
  so a second `bootstrap` run does not overwrite the saved old git identity with
  the now-IL identity, nor flip `gh_was_authenticated_before`.
- The receipt is **purely additive** — re-running setup never loses earlier
  records.

### Component 2 — The uninstaller (`uninstall.sh` / `uninstall.ps1`)

Flow:

1. Load the receipt (or enter no-receipt fallback mode).
2. Print what was found.
3. Present the preset menu:

   ```
   1) Recommended — remove IL footprint & access
        (repos, gws access, IL plugins, GitHub login, git identity, PATH)
   2) Everything the script installed
        (preset 1 + dev tools, Bun, Node, Claude Code)
   3) Custom — pick categories one by one
   4) Cancel
   ```

   Homebrew-itself (category 9) is **never** part of a preset — even preset 2
   excludes it, because uninstalling Homebrew removes all brew packages
   (IL-related or not). It is only reachable via the custom picker, with a
   warning.

4. Custom walks the categories below, each pre-checked per the recommended
   default and stating exactly what it will do.
5. Print a **final summary of what will happen** and ask for one confirmation.
6. Execute non-fatally (collect warnings, continue), then print a closing report.

Categories:

| # | Category | Action | Default |
|---|----------|--------|:------:|
| 1 | Cloned IL repos | Delete repo dirs from the receipt (lists + confirms). If `created_dir: false`, delete only the repo subdir, not the parent. | on |
| 2 | Google Workspace access | Clear `gws` OAuth credentials + `npm uninstall -g @googleworkspace/cli`. | on |
| 3 | Claude Code IL plugins | Remove the IL marketplace + 3 plugin keys from `settings.json` (surgical). | on |
| 4 | GitHub auth | `gh auth logout` — only offered if `gh_was_authenticated_before` is false. | on |
| 5 | Git identity | Restore prior `user.name`/`email` from receipt, or unset if none. | on |
| 6 | PATH edits | Delete the `il-setup` marker blocks from shell profiles. | on |
| 7 | Claude Code | Uninstall the binary; keep `~/.claude` (it is the user's). | off |
| 8 | Dev tools | `brew uninstall` only receipt-listed formulae, each guarded by `brew uses --installed`; + Bun, Node. | off |
| 9 | Homebrew itself | Only shown if `brew_installed_by_us`; heavy + scary, explicitly warned. | off |

**No-receipt fallback:** if no receipt exists (ran the old installer), say so and
offer a best-effort menu of the *known* footprint. Do **not** touch dev tools
(can't prove we installed them) and cannot restore git identity; warn about both.

## Safety Rules

- Never `rm -rf ~/.claude` or delete `settings.json` — remove only our specific
  keys (via `jq` on macOS / object-property delete on Windows), mirroring how the
  installer wrote them.
- Never remove a tool not recorded as installed-by-us. The dev-tools category
  iterates the **receipt's** list, never a hardcoded "remove everything" list.
- `brew uninstall` a formula only after `brew uses --installed <f>` confirms
  nothing else depends on it; otherwise skip + warn.
- Repo deletion lists full paths, requires confirmation, and respects
  `created_dir`.
- Git identity is **restored** to the saved prior value, never blanked.
- The uninstaller is stateless and idempotent — safe to re-run; already-removed
  items are no-ops.

## Repo Structure

- `bootstrap.sh` / `bootstrap.ps1` — add receipt-writing: a `record_*` helper
  inside each existing install branch; capture git identity before overwrite;
  wrap PATH edits in markers.
- `uninstall.sh` / `uninstall.ps1` — new, mirroring the installer's helper and
  print style so the pair stays in lockstep.
- `README.md` — an "Uninstall / offboarding" section with the one-liner.

## Testing

- ShellCheck (`-S warning`) + PSScriptAnalyzer (Severity Error) must pass; extend
  the existing `lint.yml` CI to lint the two new scripts.
- macOS manual pass: run `bootstrap.sh` → inspect generated `receipt.json` → run
  `uninstall.sh`; confirm each category reverses and that a tool installed *before*
  the script (e.g. a pre-existing `git`) is left untouched.
- Receipt round-trip: simulate "tool already present" vs "we installed it" and
  confirm only the latter is removed.
- Windows: validate structurally (PSScriptAnalyzer + logic review); flag for a
  real-world pass if a Windows machine is available.
