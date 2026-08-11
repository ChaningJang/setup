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
