# Irrational Labs Setup

One-command setup for new team members.

## Prerequisites

- A Mac or Windows PC
- A GitHub account added to the [IrrationalLabs-team](https://github.com/IrrationalLabs-team) org

## Install

### macOS

Open Terminal and paste:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ChaningJang/setup/main/bootstrap.sh)"
```

### Windows

Open PowerShell and paste:

```powershell
irm https://raw.githubusercontent.com/ChaningJang/setup/main/bootstrap.ps1 | iex
```

> If you get an execution policy error, run this first:
> `Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser`

Both scripts install: Git, GitHub CLI, Bun, Claude Code, CLI tools, and clone the project repo.

## After setup

```bash
cd ~/irrational_labs_hq && claude
```

## Re-run to fix issues

The scripts are safe to run again — they skip anything already installed and repair what's broken.
