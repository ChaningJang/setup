#!/usr/bin/env bash
# The IL block in ~/.claude/CLAUDE.md: install, re-run, update, uninstall.
# Created: 2026-10-17
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/lib/assert.sh"

fresh_home() {
    export HOME; HOME="$(mktemp -d)"
    export IL_SETUP_RECEIPT="$HOME/.config/il-setup/receipt.json"
    export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
    git config --global user.name "Jo O'Neil & Co/Test"
    git config --global user.email "jo@irrationallabs.com"
    unset IL_SETUP_NO_CLAUDE_MD IL_SETUP_CLAUDE_MD
}
# Each step runs bootstrap's function in a subshell (fresh in-memory state, like
# a new setup run), then writes the receipt the way main() does.
setup_run() { ( source "$ROOT/bootstrap.sh"; ensure_il_claude_md; write_receipt ) >/dev/null 2>&1; }
uninstall_run() { ( source "$ROOT/uninstall.sh"; load_receipt; remove_il_claude_md ) >/dev/null 2>&1; }
F() { echo "$HOME/.claude/CLAUDE.md"; }
fail=0

# 1. No file: created with only the block, identity filled in safely.
fresh_home
setup_run
assert_contains "$(cat "$(F)")" "You're working with Jo O'Neil & Co/Test <jo@irrationallabs.com> at Irrational Labs" "creates the file and fills in name & email" || fail=1
assert_eq "$(sed -n 1p "$ROOT/templates/claude-md-block.md")" "$(sed -n 1p "$(F)")" "file starts with the BEGIN marker" || fail=1
before="$(cksum < "$(F)")"
setup_run
assert_eq "$before" "$(cksum < "$(F)")" "re-run changes nothing" || fail=1
uninstall_run
assert_eq "no" "$([[ -e "$(F)" ]] && echo yes || echo no)" "uninstall deletes the file setup created" || fail=1

# 2. Existing file with the person's own text: appended, then removed byte-for-byte.
fresh_home
mkdir -p "$HOME/.claude"; printf '# My notes\n\nAlways answer in haiku.\n' > "$(F)"
orig="$(cksum < "$(F)")"
setup_run
assert_contains "$(cat "$(F)")" "Always answer in haiku." "keeps the person's text" || fail=1
assert_contains "$(cat "$(F)")" "<!-- IL-SETUP:END -->" "appends the block" || fail=1
assert_eq "1" "$(ls "$HOME/.config/il-setup/backups" | wc -l | tr -d ' ')" "backs the file up once" || fail=1
# 3. A newer template replaces the block in place; text after it survives.
printf 'Text after the block.\n' >> "$(F)"
sed -i.bak 's/Never send email/NEVER send email/' "$(F)" && rm -f "$(F).bak"
setup_run
assert_contains "$(cat "$(F)")" "- Never send email" "re-run restores the current block text" || fail=1
assert_contains "$(cat "$(F)")" "Text after the block." "text after the block survives" || fail=1
assert_eq "1" "$(grep -c 'IL-SETUP:BEGIN' "$(F)")" "still exactly one block" || fail=1
# Uninstall: back to the person's text (plus the line they added after).
uninstall_run
assert_eq "$(printf '# My notes\n\nAlways answer in haiku.\nText after the block.')" "$(cat "$(F)")" "uninstall leaves exactly the person's text" || fail=1
# Re-install after uninstall adds it again (receipt flag cleared).
setup_run
assert_contains "$(cat "$(F)")" "IL-SETUP:BEGIN" "setup after uninstall adds the block again" || fail=1

# 4. The person deleted the block: it stays deleted.
fresh_home
mkdir -p "$HOME/.claude"; printf 'Mine.\n' > "$(F)"
setup_run
printf 'Mine.\n' > "$(F)"
setup_run
assert_eq "Mine." "$(cat "$(F)")" "a deleted block is not re-added" || fail=1
( export IL_SETUP_CLAUDE_MD=1; setup_run )
assert_contains "$(cat "$(F)")" "IL-SETUP:BEGIN" "IL_SETUP_CLAUDE_MD=1 puts it back" || fail=1

# 5. Partial block (hand-edited): left alone by setup and uninstall.
fresh_home
mkdir -p "$HOME/.claude"; printf 'A\n<!-- IL-SETUP:BEGIN v1 -->\nB\n' > "$(F)"
orig="$(cksum < "$(F)")"
setup_run
assert_eq "$orig" "$(cksum < "$(F)")" "setup refuses to edit a partial block" || fail=1
uninstall_run
assert_eq "$orig" "$(cksum < "$(F)")" "uninstall refuses to edit a partial block" || fail=1

# 6. A symlinked CLAUDE.md stays a symlink.
fresh_home
mkdir -p "$HOME/.claude" "$HOME/dotfiles"; printf 'dot\n' > "$HOME/dotfiles/CLAUDE.md"
ln -s "$HOME/dotfiles/CLAUDE.md" "$(F)"
setup_run
assert_eq "yes" "$([[ -L "$(F)" ]] && echo yes || echo no)" "symlink preserved on install" || fail=1
assert_contains "$(cat "$HOME/dotfiles/CLAUDE.md")" "IL-SETUP:BEGIN" "block written through the link" || fail=1
uninstall_run
assert_eq "yes" "$([[ -L "$(F)" ]] && echo yes || echo no)" "symlink preserved on uninstall" || fail=1

# 7. Opt-out.
fresh_home
( export IL_SETUP_NO_CLAUDE_MD=1; setup_run )
assert_eq "no" "$([[ -e "$(F)" ]] && echo yes || echo no)" "IL_SETUP_NO_CLAUDE_MD=1 writes nothing" || fail=1

[[ $fail -eq 0 ]] && echo "ALL PASS" || { echo "SOME FAILED"; exit 1; }
