# Irrational Labs Setup

One-command setup for new team members. Installs your dev tools, sets up Claude Code, then asks which repositories you want to clone.

## Prerequisites

- A Mac or Windows PC
- A GitHub account added to the [IrrationalLabs-team](https://github.com/IrrationalLabs-team) org

## Install

### macOS

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ChaningJang/setup/main/bootstrap.sh)"
```

### Windows (PowerShell)

```powershell
irm https://raw.githubusercontent.com/ChaningJang/setup/main/bootstrap.ps1 | iex
```

> Execution-policy error? Run `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser` first.

## What it does

1. Installs base tools: Git, Git LFS, GitHub CLI, jq, Node (npm), Bun, Claude Code, and shell helpers (ripgrep, fd, bat, fzf, delta).
2. Signs you in to GitHub and sets your commit identity.
3. Sets up **Google Workspace (`gws`)** end to end — see [below](#google-workspace-gws).
4. **Asks which repositories to clone** — the menu only shows repos your GitHub account can access.
5. For **Irrational Labs HQ**, runs its full setup (media tools, Git LFS, dependencies, secrets). Other repos get a generic best-effort setup (dependencies, LFS, `.env` scaffold).

## Google Workspace (`gws`)

A working `gws` needs three separate things, and you're broken if any one is missing. The script installs all three:

| Piece | What it is | Why it's needed |
|---|---|---|
| `gws` CLI | the [npm package](https://www.npmjs.com/package/@googleworkspace/cli), installed globally | the actual binary |
| `gws` Claude Code plugin | registers the `IrrationalLabs-team/knowledge-work-plugins` marketplace and enables `gws`, `il-slides`, `key-behavior` | supplies `/gws:setup`, the `gws` skill, and the destructive-operation guard hook |
| `GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file` | written to `~/.zshenv`, `~/.bash_profile`, `~/.bashrc`, and `~/.claude/settings.json` (`env`) | **critical** — see below |

After the script finishes: **restart Claude Code**, then run `/gws:setup` and sign in with your @irrationallabs.com account.

### ⚠️ The keyring variable is not optional

`gws`'s default keyring backend (macOS Keychain) **silently deletes** `~/.config/gws/credentials.enc`. A single `gws` invocation without `GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file` can wipe an already-working login, and it fails with no error — you just find out days later that `gws` "randomly stopped working."

It must be set for **every** `gws` invocation, not just interactive ones. That's why it goes in `~/.zshenv` rather than `~/.zshrc`: `.zshrc` is interactive-only, and cron jobs or scripts calling `gws` are exactly the case that re-triggers the wipe. Any new cron job, launchd agent, or script that shells out to `gws` must set it explicitly too.

Don't remove these blocks, and don't "simplify" the setup back down to just the npm install.

### Why the plugin is registered here rather than pushed by the org

The IL claude.ai org can mark plugins "Installed by default" in the admin Plugins panel, and between 2026-07-30 and 2026-08-11 this script relied on that alone. It did not reach fresh machines — teammates ended up with the bare CLI, no `/gws:setup`, and no keyring guard. The registration is explicit again. If the org push also works, no harm done: Claude Code dedupes by marketplace name.

## Uninstall / offboarding

### Step 1 — audit first (read-only)

**Before anyone runs the uninstaller, run the audit.** It inspects the machine
and prints a three-way split — CANDIDATE FOR REMOVAL / KEEP / UNKNOWN — plus a
loud warning for any IL repo with uncommitted or unpushed work.

It installs nothing, removes nothing, and writes no file. Download it and read
it before running — for an offboarding this is deliberately *not* a
`curl | bash` (or `irm | iex`) one-liner. Onboarding and offboarding have
opposite trust dynamics: on the way in you are asking to be set up, on the way
out someone is asking to inspect your machine. Piping to a shell also leaves a
TOCTOU gap — you would be reading one script and running whatever the URL
serves a second later. Downloading first closes both.

**macOS / Linux — `audit.sh`:**

```bash
curl -fsSL https://raw.githubusercontent.com/ChaningJang/setup/main/audit.sh -o il-audit.sh
less il-audit.sh          # read it — it is meant to be read
bash il-audit.sh          # prints the report; redirect it yourself if you like
```

**Windows — `audit.ps1`:**

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/ChaningJang/setup/main/audit.ps1 -OutFile il-audit.ps1
notepad il-audit.ps1      # read it — it is meant to be read
powershell -ExecutionPolicy Bypass -File .\il-audit.ps1
```

`audit.ps1` is a port of `audit.sh`, not a translation of its paths: every
location it checks is traced to a line in `bootstrap.ps1` (winget and scoop
package ids, `%LOCALAPPDATA%\il-setup\receipt.json`, the PowerShell profile
instead of `.zshrc`, the persistent **User** environment block instead of
`.zshenv`, `~\.bun\bin` on the User PATH). Anything that cannot be traced to a
line is reported UNKNOWN rather than guessed. It refuses to run anywhere but
Windows — an empty report reads too much like a clean machine.

The output is safe to paste back: credential *values*, `.env` contents, SSH
keys and repo contents are never printed, email addresses are masked, and on
the PowerShell side every output line additionally passes through a scrubber
for `gho_`/`ghp_`/`github_pat_`, `sk-`, `xox`, `AIza`, PEM private-key headers
and bearer tokens. A human then decides the removal list from that report.

#### Verifying the audit scripts before you trust them

`audit.sh` was verified empirically on a real machine: key-file mtimes
unchanged across two runs, home-directory entry count unchanged, `.git/index`
mtime unchanged, and an output scan for every secret pattern.

`audit.ps1` was written without access to a Windows machine, so it is verified
two ways, both in CI.

**Empirically**, by `tests/test_audit_ps1.sh` (needs `pwsh`; ubuntu runners
have it): it builds a fake Windows-shaped home in a temp dir — a receipt under
`%LOCALAPPDATA%`, an IL repo with unpushed and uncommitted work, a second
IL-org repo whose remote URL embeds a `ghp_` token, a personal repo, a
`settings.json` with IL keys and a planted `sk-` key, a profile with an
il-setup block, a `credentials.enc` — then runs the script twice and asserts:
every mtime in the fixture unchanged, entry count unchanged, `.git/index`
unchanged, no secret pattern and no unmasked email in the output, and that the
report says the right things (REMOVE / KEEP / WORK AT RISK with the right
counts). The shipped script refuses to run off Windows and has no test hook to
bypass that; the test rewrites exactly one line of a *copy* and asserts only
one line changed. This exercises everything except the Windows-only probes
(winget, HKLM, scheduled tasks, the User environment block), which degrade to
UNKNOWN as designed.

Running it found two bugs the static check could not see: PowerShell unrolls a
one-element array on `return`, so every git origin URL came back as its first
character and every repo read as non-IL — section 5 would have said "nothing to
lose" on a machine full of unpushed work; and `npm ls -g` wrote log files into
the home directory (the same hole existed in `audit.sh`; both now read the
global `node_modules` off disk).

**Statically**, by `tests/audit_readonly_check.py`: it strips comments and
string literals (keeping `$( ... )` subexpressions, which are real code) and
then asserts that no write-capable operation survives — `Set-Content`,
`Add-Content`, `Out-File`, `New-Item`, `Remove-Item`, `Move-Item`, `Copy-Item`,
`Rename-Item`, `Set-Item`, `Set-ItemProperty`, `New-ItemProperty`,
`Remove-ItemProperty`, `Clear-Content`, `Export-*`, `Tee-Object`,
`StreamWriter`/`FileStream`, `.Save()`, `[IO.File]::Write*`, `New-PSDrive`,
`Set-Location`, `Set-ExecutionPolicy`, `Start-Process`, `Invoke-Expression`,
any network fetch, any winget/scoop/npm/bun mutation, any `git` mutation, and
the `>` / `>>` file-creating redirections. It also asserts that the only two
`$env:` assignments are the process-local `GIT_OPTIONAL_LOCKS` and
`GIT_TERMINAL_PROMPT`, and that every output line goes through the scrubber.

**Still run this on the first real Windows box, before sending `audit.ps1` to
anyone.** The fixture run was under PowerShell 7.4 on macOS; Emily's machine
runs Windows PowerShell 5.1, and the Windows-only probes have never executed.
These are the same four checks `audit.sh` passed.

```powershell
# 0. Syntax + linter, which cannot run on macOS
$tokens = $null; $errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile(
        "$PWD\audit.ps1", [ref]$tokens, [ref]$errs)
$errs                                         # MUST be empty
Invoke-ScriptAnalyzer -Path .\audit.ps1      # MUST report no Error-severity rule

# 1. Key-file mtimes unchanged across two runs
$watch = @("$HOME\.gitconfig", "$HOME\.claude\settings.json",
           "$env:LOCALAPPDATA\il-setup\receipt.json",
           "$HOME\irrational_labs_hq\.git\index")
$before = $watch | Where-Object { Test-Path $_ } |
          ForEach-Object { [PSCustomObject]@{ P=$_; T=(Get-Item $_).LastWriteTime } }
.\audit.ps1 | Out-Null; .\audit.ps1 | Out-Null
$after  = $before | ForEach-Object { [PSCustomObject]@{ P=$_.P; T=(Get-Item $_.P).LastWriteTime } }
Compare-Object $before $after -Property P,T   # MUST be empty

# 2. Home-directory entry count unchanged (no stray file or dir created).
#    Depth 1 misses writes deep in caches, so the npm cache is checked too -
#    that is where the npm bug hid.
$n1 = (Get-ChildItem $HOME -Force -Recurse -Depth 1 -EA SilentlyContinue).Count
$c1 = (Get-ChildItem "$env:LOCALAPPDATA\npm-cache" -Force -Recurse -EA SilentlyContinue).Count
.\audit.ps1 | Out-Null
$n2 = (Get-ChildItem $HOME -Force -Recurse -Depth 1 -EA SilentlyContinue).Count
$c2 = (Get-ChildItem "$env:LOCALAPPDATA\npm-cache" -Force -Recurse -EA SilentlyContinue).Count
"$n1 -> $n2 ; npm-cache $c1 -> $c2"           # MUST be identical

# 3. .git\index mtime unchanged (proves GIT_OPTIONAL_LOCKS=0 took effect)
#    covered by check 1; repeat per IL repo present on the machine.

# 4. Output scan for every secret pattern
.\audit.ps1 | Select-String -Pattern 'gh[pousr]_[A-Za-z0-9]{6,}','github_pat_',
    'sk-[A-Za-z0-9]{12,}','xox[abprse]-','AIza[A-Za-z0-9_-]{10,}',
    'PRIVATE KEY-----','(?i)bearer [A-Za-z0-9._-]{8,}'   # MUST be empty
```

Until those four pass on real hardware, treat `audit.ps1` as proven under
PowerShell 7 on a fixture, not on Windows.

### Step 2 — the uninstaller


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

#### ⚠️ Known gaps in the uninstaller (audited 2026-08-24 — fix before next use)

- **`IL_DRY_RUN=1` is not a dry run.** It is a test hook. `run_cmd` covers the
  shell-outs, but `strip_il_settings` and `remove_il_marker_block` `mv` their
  temp file over the real target regardless — so a "dry run" still edits
  `~/.claude/settings.json` and your shell profiles for real. Never hand it to
  a user as a preview. Use `audit.sh` above instead.
- **Preset 2 deletes the Claude Code binary without checking the receipt.**
  `remove_claude_code` only tests `command -v claude`; it ignores
  `.claude_code_installed_by_us`. It will remove a Claude Code that predated IL.
- **No receipt ⇒ the destructive paths still run.** With no receipt (or no
  `jq`), `remove_gws` still npm-uninstalls the `gws` CLI and `rm -rf`s
  `~/.config/gws`, and `remove_github_auth` still runs `gh auth logout` — on
  tools and logins that may have predated IL.
- **`remove_repos` does no safety check before `rm -rf`.** It does not look for
  uncommitted or unpushed commits, and does not verify the path is still the
  repo the receipt recorded.
- **The unmarked `brew shellenv` line** the installer may append to `.zshrc` has
  no `il-setup` marker, so it is never cleaned up.

## Just the tools, or a specific repo

Skip the menu with flags:

```bash
# macOS — base tools only, clone nothing
/bin/bash -c "$(curl -fsSL .../bootstrap.sh)" _ --base-only

# macOS — clone specific repos by key
/bin/bash -c "$(curl -fsSL .../bootstrap.sh)" _ --repos hq,marketing
```

```powershell
# Windows
& ([scriptblock]::Create((irm .../bootstrap.ps1))) -BaseOnly
& ([scriptblock]::Create((irm .../bootstrap.ps1))) -Repos hq,marketing
```

Repo keys come from [`repos.json`](repos.json).

## Re-run anytime

Both scripts are idempotent — re-running skips what's installed, repairs what's broken, and re-shows the menu so you can add another repo later.

## Add a repo to the menu

Edit [`repos.json`](repos.json): add an entry with a `key`, `slug`, `dir`, and `setup` (`"hq"` or `"generic"`). Both platforms pick it up automatically.
