# Irrational Labs Setup

One-command setup for new team members.

## Prerequisites

- A Mac
- A GitHub account added to the [IrrationalLabs-team](https://github.com/IrrationalLabs-team) org

## Install

Open Terminal and paste:

```bash
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/ChaningJang/setup/main/bootstrap.sh)"
```

This installs everything: Homebrew, Git, GitHub CLI, Bun, Claude Code, CLI tools, and clones the project repo.

## After setup

```bash
cd ~/irrational_labs_hq && claude
```

## Re-run to fix issues

The script is safe to run again — it skips anything already installed and repairs what's broken.
