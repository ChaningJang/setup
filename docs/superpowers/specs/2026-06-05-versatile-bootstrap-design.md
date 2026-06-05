# Versatile Bootstrap — Design

- **Date:** 2026-06-05
- **Repo:** `ChaningJang/setup` (local: `~/setup`)
- **Status:** Approved design, ready for implementation plan

## Problem

`bootstrap.sh` / `bootstrap.ps1` are a one-command onboarding for new IL team
members: install base dev tools, then clone `irrational_labs_hq` and run its
full setup. Two issues:

1. **Windows lags macOS.** `bootstrap.ps1` is missing functional steps the
   macOS script has (notably the IL Claude plugin registration and the
   Claude-Code PATH/sanity hardening). The two scripts are hand-maintained and
   drift apart.
2. **HQ is no longer the only repo people need.** Teammates increasingly need
   `marketing_HQ`, `IL-experiments`, client engagements, etc. The current
   script always installs the full (HQ-oriented) toolset and only knows how to
   clone HQ. There's no way to get "just the base tools" or to pick a different
   repo.

## Goals

- Bring `bootstrap.ps1` to full functional parity with `bootstrap.sh`.
- Make the bootstrap versatile: a single pasted command installs base tools,
  then asks which repo(s) to clone. HQ gets its full bespoke setup; other repos
  get a generic best-effort setup. People who want only base tools can stop
  there.
- Reduce the macOS↔Windows drift surface, since that drift is the root cause of
  the parity problem.

## Non-Goals

- Rewriting both scripts in a single cross-platform language. The native
  `curl|bash` / `irm|iex` paste UX is the whole value; we keep two platform
  scripts.
- A mock/containerized install-test harness. A bootstrap is integration-heavy
  and idempotent; static analysis + a manual matrix is the right level.
- Per-repo bespoke recipes for non-HQ repos. Only HQ has a real recipe; the
  rest use one generic pass.

## Key Decisions

| Decision | Choice |
|----------|--------|
| Repo menu source | **Hybrid:** curated list, filtered by the user's actual GitHub access |
| Per-repo setup | **HQ-special, generic for the rest** (HQ keeps bespoke recipe; others get best-effort) |
| Base vs extras | **Lean base + shell helpers** for everyone; heavy media/doc tools are HQ-only extras |
| Entry / interaction | **Interactive menu by default + flags** (`--repos`, `--base-only`) |
| Architecture | **Modularize in place + shared `repos.json` manifest** (Approach 1) |

## Architecture

### File layout

```
setup/
├── README.md          # updated install commands + repo-menu explanation
├── repos.json         # NEW — single source of truth for the curated menu
├── bootstrap.sh       # macOS, refactored
└── bootstrap.ps1      # Windows, refactored to full parity
```

### `repos.json` — the curated, access-filtered menu

Read by both scripts so the menu can never drift between platforms.

```json
{
  "repos": [
    {
      "key": "hq",
      "name": "Irrational Labs HQ",
      "slug": "IrrationalLabs-team/irrational_labs_hq",
      "dir": "irrational_labs_hq",
      "setup": "hq",
      "default": true,
      "description": "Main workspace — slides, templates, scripts"
    },
    {
      "key": "marketing",
      "name": "Marketing HQ",
      "slug": "IrrationalLabs-team/marketing_HQ",
      "dir": "marketing_HQ",
      "setup": "generic",
      "default": false,
      "description": "ActiveCampaign, conferences, LinkedIn, Substack"
    }
  ]
}
```

Field notes:

- `setup` is **metadata**, one of `"hq"` | `"generic"`. It is set by the
  maintainer (Chaning) and is invisible to the person running the bootstrap.
  They only ever select repos by name (menu) or by `key` (`--repos`). The
  script reads the chosen repo's `setup` field to pick the recipe.
- **Access filter:** before the menu renders, each entry is probed with
  `gh repo view <slug>`. Entries the user can't access are silently dropped — no
  errors, no unusable rows. (Requires gh installed + authenticated; see flow.)
- **Manifest fetch + fallback:** both scripts fetch `repos.json` from
  `raw.githubusercontent.com/ChaningJang/setup/main/repos.json`. On fetch
  failure (offline / local run) they fall back to a minimal embedded default
  (HQ only) so the script never hard-breaks.
- **Parsing:** `jq` on macOS (a base tool), `ConvertFrom-Json` on Windows
  (built into PowerShell). Same JSON, two native parsers.

## Execution Flow

Ordering is driven by two constraints: (1) the access-filter needs gh installed
**and** authenticated; (2) Claude Code is installed early so it can be used to
troubleshoot anything that fails afterward.

```
1. Parse flags (--repos, --base-only, --help)
2. OS / package-manager check (brew | winget+scoop)
3. Install EARLY tools:  git, git-lfs, gh, jq, bun
      └ fast; unblocks auth, manifest parsing, and the Claude install
4. gh auth login  +  git identity
   ──────────────────────────────────────────────
5. Claude Code  +  IL plugin marketplace        ← installed before anything
      └ if a later step fails, the user runs `claude` and asks it to fix it
   ──────────────────────────────────────────────
6. Fetch repos.json → access-filter (`gh repo view`) → SHOW MENU
      (skipped if --repos / --base-only passed)
7. Install remaining shell helpers:  ripgrep, fd, bat, fzf, git-delta
8. For each selected repo:  clone → (HQ recipe | generic pass)
9. Verify + print completion (incl. any collected warnings)
```

Rationale:

- **Steps 3–4 before the menu:** gh must exist and be authed before any
  `gh repo view` access probe or private-repo clone.
- **Claude Code at step 5 (moved up):** present before the menu, cloning, and
  the heavy HQ setup. Plugins still auto-install on first `claude` launch; step
  5 installs the binary, fixes PATH, and registers the marketplace.
- **Menu after Claude Code:** guarantees Claude is available even if the
  manifest fetch hiccups. Costs the user ~1–2 min before the menu appears.
- **`--base-only`** stops after step 7 (no clone). **`--repos hq,marketing`**
  skips the menu but still runs 3–4 (auth needed to clone private repos).

## Tool Buckets

- **Early base (step 3), always:** `git`, `git-lfs`, `gh`, `jq`, `bun`
- **Shell helpers (step 7), always:** `ripgrep`, `fd`, `bat`, `fzf`, `git-delta`
- **Claude Code (step 5), always:** binary + `~/.local/bin` on PATH + IL plugin
  marketplace
- **HQ extras (step 8, only if HQ selected):** `marp-cli`, `ghostscript`,
  `ffmpeg`, `exiftool`, `yt-dlp`, `pandoc`, `imagemagick`, `yq`, `miller`, `sd`,
  `gawk`, `coreutils`, `parallel`, `trash`, `eza`

## Per-Repo Setup

### HQ recipe (`setup: "hq"`) — current bespoke flow, unchanged in substance

1. Install HQ extras (list above)
2. `git lfs pull` + pointer-file repair
3. `bun install`
4. Install pre-commit filename-validation hook
5. Fetch Infisical secrets → `.env`

### Generic pass (`setup: "generic"`) — best-effort, conservative

1. If `package.json` present → `bun install`
2. If `.gitattributes` mentions LFS → `git lfs pull`
3. If `.env.example` / `.env.sample` present and no `.env` → copy it and print a
   "fill in your secrets" note (do not fetch — secret source is unknown)
4. Print "cloned to `<dir>` — check its README for any extra setup"

## Repo Selection Model

The person running the bootstrap never types `hq`/`generic` setup types. They
select repos two ways:

- **Menu:** numbered list (`1) Irrational Labs HQ  2) Marketing HQ …`),
  multi-select.
- **Flag:** `--repos hq,marketing` — values are repo `key`s from the manifest.

The script maps selection → manifest entry → `slug` (clone) + `setup` (recipe).
Adding a repo = add an entry to `repos.json`; menu and flags pick it up with no
other code change.

## Windows Parity

**Pre-existing gaps to close in `bootstrap.ps1`:**

1. **IL Claude plugin marketplace registration** — missing entirely. Port using
   native `ConvertFrom-Json`/`ConvertTo-Json` on `~/.claude/settings.json`:
   register the `irrational-labs-plugins` marketplace; default-on
   `gws`/`il-slides`/`key-behavior` with the same null-check so an explicit user
   *disable* survives a re-run.
2. **Claude Code PATH persistence + hard failure** — match macOS: ensure the
   install dir is on the User PATH, refresh, and resolve-or-fail at the end
   (vs. today's soft "may need a terminal restart" warning).

**New-flow elements — build identically in both scripts:**

3. Flag parsing (`--repos`, `--base-only`, `--help`)
4. Early-bundle ordering (git/git-lfs/gh/jq/bun → auth → Claude Code → menu →
   helpers → clone)
5. `repos.json` fetch + embedded fallback
6. Access-filter via `gh repo view`
7. Menu + HQ-recipe / generic-pass dispatch per selected repo
8. Generic pass (package.json→`bun install`, LFS, `.env.example` scaffold)

**Legitimately platform-specific (not gaps):**

- Package manager: `brew` ↔ `winget`+`scoop`
- Claude Code install: `claude.ai/install.sh` ↔ `bun -g`
  *(implementation: check whether a native Windows installer now exists; prefer
  it for closer parity if so)*
- Menu input mechanics: bash `read < /dev/tty` (stdin is the piped script) ↔
  PowerShell `Read-Host` (runs in the live console)
- Xcode CLI tools check (macOS only)

**Invariant:** every functional step exists in both scripts; only install
mechanics differ. Verify with a side-by-side function map at the end of
implementation.

## Error Handling & Idempotency

- **Idempotent:** every install step keeps its skip-if-present check; cloning
  pulls if the dir already exists; the generic pass is re-run-safe; plugin
  registration preserves explicit disables. Re-running with no flags re-shows
  the menu — a fine way to add a repo later.
- **Per-repo isolation:** the clone+setup loop wraps each repo so one failure
  (no access, network blip) reports and continues to the next instead of
  aborting the run. In bash, relax `set -e` inside the loop.
- **Auth failure:** menu falls back to the full curated list with a note;
  per-repo 403s caught at clone.
- **Manifest fetch failure:** fall back to embedded minimal default (HQ).
- **Partial-failure summary:** collect non-fatal warnings and reprint them in
  the completion banner.

## Testing

A bootstrap is integration-heavy and side-effectful; a full unit/mock harness
is over-engineering. Plan:

1. **Static analysis:** `shellcheck` on `bootstrap.sh`, `PSScriptAnalyzer` on
   `bootstrap.ps1`. Optional: a tiny GitHub Action on push.
2. **`repos.json` validity:** quick parse check (valid JSON, required keys).
3. **Manual test matrix:**
   - fresh macOS
   - fresh Windows
   - re-run (idempotency)
   - `--base-only`
   - `--repos hq,marketing`
   - a user *without* engagement access (verify those rows are filtered out)

## Open Implementation-Time Questions

- Does a native Windows Claude Code installer exist now? If so, use it in
  `bootstrap.ps1` for closer parity instead of `bun -g`.
- Final curated set of repos for `repos.json` beyond HQ + marketing_HQ (e.g.
  `IL-experiments`). Decide the initial list during implementation.
