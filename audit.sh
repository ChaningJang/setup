#!/usr/bin/env bash
#
# Irrational Labs — OFFBOARDING AUDIT (read-only)
# Created: 2026-08-24
#
# ─────────────────────────────────────────────────────────────────────────────
#  WHAT THIS SCRIPT DOES
#    It looks at your machine and prints a report of what the Irrational Labs
#    setup script (bootstrap.sh) may have put there, so a human can decide what
#    should actually be removed. That is all it does.
#
#  WHAT THIS SCRIPT DOES NOT DO — no exceptions
#    • It does not install anything.
#    • It does not uninstall or remove anything.
#    • It does not create, delete, move, or edit a single file or directory.
#      It does not even run `mkdir`. It writes nothing to disk at all —
#      the report goes to your terminal. If you want it in a file, YOU redirect
#      it:  bash audit.sh > ~/il-audit.txt
#    • It does not log in, log out, or touch any credential.
#    • It makes no network requests. Nothing is uploaded anywhere.
#
#  WHAT IT DELIBERATELY NEVER PRINTS
#    • The CONTENTS of any credential, token, API key, .env file, or SSH key.
#      It reports only that such a file EXISTS and where. Never its value.
#    • The contents of your shell profiles, your settings.json, or your repos.
#    • Your personal email addresses in full (they are masked, e.g. e****@x.com).
#    • Environment variable values, except one harmless setting we need to see
#      (GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND). Everything else: names only.
#
#  ONE HONEST FOOTNOTE
#    To tell you whether you have unsaved work in an IL repo, it runs git
#    read commands inside repos you already have. Git is invoked with
#    GIT_OPTIONAL_LOCKS=0, which tells git not to take locks or update its
#    index cache. No file in your repos is changed.
#
#  You are meant to read this before running it. Please do.
#  Then send the output back — it is safe to paste.
# ─────────────────────────────────────────────────────────────────────────────

# No `set -e`: a failed probe should degrade to "UNKNOWN", never abort the report.
export GIT_OPTIONAL_LOCKS=0
export GIT_PAGER=cat
export PAGER=cat

RECEIPT="${IL_SETUP_RECEIPT:-$HOME/.config/il-setup/receipt.json}"
HAVE_JQ=no; command -v jq >/dev/null 2>&1 && HAVE_JQ=yes
HAVE_RECEIPT=no; [ -f "$RECEIPT" ] && HAVE_RECEIPT=yes
RECEIPT_EPOCH=""
[ "$HAVE_RECEIPT" = yes ] && RECEIPT_EPOCH="$(stat -f '%m' "$RECEIPT" 2>/dev/null)"

N_REMOVE=0; N_KEEP=0; N_UNKNOWN=0; N_WORKLOSS=0

hdr()  { echo; echo "=============================================================="; echo "$1"; echo "=============================================================="; }
sub()  { echo; echo "-- $1"; }
item() { echo "   $1"; }
# tag <REMOVE|KEEP|UNKNOWN> <label> <detail...>
tag() {
  local _t="$1"; shift
  case "$_t" in
    REMOVE)  N_REMOVE=$((N_REMOVE+1)) ;;
    KEEP)    N_KEEP=$((N_KEEP+1)) ;;
    UNKNOWN) N_UNKNOWN=$((N_UNKNOWN+1)) ;;
  esac
  printf '   [%-7s] %s\n' "$_t" "$*"
}

# Mask an email so it is legible but not harvestable: alice@x.com -> a****@x.com
mask_email() {
  case "$1" in
    "" ) echo "(none)" ;;
    *@* ) echo "$(printf '%s' "${1%%@*}" | cut -c1)****@${1##*@}" ;;
    * ) echo "(masked)" ;;
  esac
}

# Modification date of a path, or "?" — used as weak provenance evidence.
fdate() { stat -f '%Sm' -t '%Y-%m-%d' "$1" 2>/dev/null || echo "?"; }
fepoch() { stat -f '%m' "$1" 2>/dev/null || echo ""; }

rjq() { [ "$HAVE_JQ" = yes ] && [ "$HAVE_RECEIPT" = yes ] && jq -r "$1" "$RECEIPT" 2>/dev/null; }

# Does the receipt claim we installed this brew formula?
receipt_claims_formula() {
  [ "$HAVE_RECEIPT" = yes ] || return 1
  rjq '(.formulae_installed_by_us // [])[]' | grep -qx "$1"
}

# Verdict for a shared tool: IL put it here, it predates IL, or we cannot tell.
# Prints one of REMOVE / KEEP / UNKNOWN plus the evidence used.
provenance() {
  local _name="$1" _path="$2" _isformula="$3" _pe
  if [ "$HAVE_RECEIPT" != yes ]; then
    echo "UNKNOWN|no receipt on this machine — cannot attribute"
    return
  fi
  if [ "$_isformula" = yes ] && receipt_claims_formula "$_name"; then
    # A receipt claim is only trustworthy if brew still agrees. If the receipt
    # says IL installed it but brew has no such formula, the binary on PATH is
    # something else (e.g. Apple's /usr/bin/jq) and removing it would be wrong.
    if brew list --versions "$_name" >/dev/null 2>&1; then
      echo "REMOVE|receipt says IL setup installed it, and brew still has it"
    else
      echo "UNKNOWN|receipt claims IL installed it, but brew does NOT have it — stale receipt; the binary at this path came from somewhere else"
    fi
    return
  fi
  _pe="$(fepoch "$_path")"
  if [ -n "$_pe" ] && [ -n "$RECEIPT_EPOCH" ] && [ "$_pe" -lt "$RECEIPT_EPOCH" ] 2>/dev/null; then
    echo "KEEP|predates the IL receipt (installed $(fdate "$_path")) — yours, not ours"
  else
    echo "KEEP|receipt does not claim it — IL setup found it already present"
  fi
}

# ── header ───────────────────────────────────────────────────────────────────
echo "IRRATIONAL LABS — OFFBOARDING AUDIT (read-only; nothing was changed)"
echo "Generated: $(date '+%Y-%m-%d %H:%M %Z')"
echo "Machine:   $(uname -s) $(uname -r) / $(uname -m)"
echo "Shell:     ${SHELL:-unknown}"
echo "Script:    audit.sh (inspect-only)"
if [ "$(uname -s)" != "Darwin" ]; then
  echo
  echo "!! This script targets macOS. Some checks below will be blank or wrong"
  echo "!! on this platform. Send the output anyway and say what OS you are on."
fi

# ── 1. the receipt ───────────────────────────────────────────────────────────
hdr "1. THE SETUP RECEIPT  (what the uninstaller depends on)"
if [ "$HAVE_RECEIPT" != yes ]; then
  item "NOT FOUND at $RECEIPT"
  item ""
  item ">> This is the important case. Without a receipt the uninstaller cannot"
  item ">> tell IL-installed tools from your own, and its fallback behaviour is"
  item ">> to guess. Everything below is therefore marked UNKNOWN rather than"
  item ">> assumed safe to remove. Do not run the uninstaller on this machine"
  item ">> until a human has read this report."
  item ""
  item "Most likely reasons: you never ran the IL bootstrap script; or you ran"
  item "it before receipts existed; or jq was missing when it ran, in which case"
  item "the installer skipped writing one."
else
  item "Found:        $RECEIPT"
  item "Written:      $(fdate "$RECEIPT")  (size $(wc -c < "$RECEIPT" | tr -d ' ') bytes)"
  if [ "$HAVE_JQ" != yes ]; then
    item "jq is NOT installed, so this script cannot parse the receipt."
    item "NOTE: the uninstaller ALSO needs jq. Without it, it silently treats"
    item "      the receipt as absent and falls back to guessing."
    N_UNKNOWN=$((N_UNKNOWN+1))
  else
    item "Schema:       $(rjq '.schema_version // "unknown"')"
    item "Brew installed by IL:        $(rjq '.brew_installed_by_us // false')"
    item "Bun installed by IL:         $(rjq '.bun_installed_by_us // false')"
    item "Claude Code installed by IL: $(rjq '.claude_code_installed_by_us // false')"
    item "gws CLI installed by IL:     $(rjq '.gws_cli_installed_by_us // false')"
    item "gh was logged in BEFORE IL:  $(rjq '.gh_was_authenticated_before // false')"
    item "Prior git identity:          $(rjq '.git_identity_prior.name // "(none)"') <$(mask_email "$(rjq '.git_identity_prior.email // ""')")>"
    item "Formulae IL installed:       $(rjq '(.formulae_installed_by_us // []) | join(", ") | if .=="" then "(none)" else . end')"
    item "Shell profiles IL edited:    $(rjq '(.path_edits // []) + (.gws_env_edits // []) | unique | join(", ") | if .=="" then "(none)" else . end')"

    sub "Receipt vs. reality — does the receipt still match this machine?"
    _stale=0
    for p in $(rjq '(.repos_cloned // [])[].path'); do
      [ -n "$p" ] || continue
      if [ -d "$p" ]; then item "OK      repo still present: $p"
      else item "STALE   receipt lists a repo that is GONE: $p"; _stale=$((_stale+1)); fi
    done
    for f in $(rjq '(.formulae_installed_by_us // [])[]'); do
      [ -n "$f" ] || continue
      if brew list --versions "$f" >/dev/null 2>&1; then item "OK      formula still installed: $f"
      else item "STALE   receipt claims IL installed '$f' but brew no longer has it"; _stale=$((_stale+1)); fi
    done
    [ "$_stale" -eq 0 ] && item "Receipt appears consistent with what is on disk." \
                        || item ">> $_stale stale entr(y/ies). The receipt is out of date; treat its claims with care."
  fi
fi

# ── 2. IL footprint ──────────────────────────────────────────────────────────
hdr "2. IL-SPECIFIC FOOTPRINT  (things that exist because of Irrational Labs)"

sub "IL repositories"
for d in irrational_labs_hq marketing_HQ IL-experiments; do
  t="$HOME/$d"
  if [ -d "$t/.git" ]; then
    origin="$(git -C "$t" remote get-url origin 2>/dev/null || echo '?')"
    tag REMOVE "IL repo: $t"
    item "          origin: $origin"
    item "          cloned/modified: $(fdate "$t")"
  elif [ -e "$t" ]; then
    tag UNKNOWN "$t exists but is not a git repo — do NOT let anything rm -rf this"
  fi
done

sub "Any other repo on this machine pointing at the IL GitHub org"
_found=0
for g in $(find "$HOME" -maxdepth 4 -name .git -type d \
            -not -path "*/Library/*" -not -path "*/.Trash/*" \
            -not -path "*/node_modules/*" 2>/dev/null | head -60); do
  r="${g%/.git}"
  u="$(git -C "$r" remote get-url origin 2>/dev/null)"
  case "$u" in
    *IrrationalLabs*|*irrationallabs*)
      case "$r" in
        "$HOME/irrational_labs_hq"|"$HOME/marketing_HQ"|"$HOME/IL-experiments") continue ;;
      esac
      tag REMOVE "IL-org repo not in the standard list: $r"
      item "          origin: $u"
      _found=$((_found+1)) ;;
  esac
done
[ "$_found" -eq 0 ] && item "None beyond the standard list above."

sub "gws (Google Workspace CLI) — IL's Google access"
if command -v gws >/dev/null 2>&1; then
  tag REMOVE "gws CLI installed at $(command -v gws)"
else
  item "gws CLI: not installed."
fi
GWSCFG="${GOOGLE_WORKSPACE_CLI_CONFIG_DIR:-$HOME/.config/gws}"
if [ -d "$GWSCFG" ]; then
  tag REMOVE "gws config directory exists: $GWSCFG  (modified $(fdate "$GWSCFG"))"
  if [ -f "$GWSCFG/credentials.enc" ]; then
    item "          credentials.enc EXISTS ($(wc -c < "$GWSCFG/credentials.enc" | tr -d ' ') bytes)."
    item "          >> This is a live Google login. Contents NOT shown and never will be."
    item "          >> Offboarding must revoke this."
  else
    item "          no credentials.enc — not currently signed in."
  fi
else
  item "No gws config directory."
fi
item "Keyring backend env var: ${GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND:-(not set in this shell)}"

sub "IL Claude Code plugin registration (~/.claude/settings.json)"
S="$HOME/.claude/settings.json"
if [ -f "$S" ] && [ "$HAVE_JQ" = yes ]; then
  item "settings.json present ($(fdate "$S")). Checking only for IL keys; nothing else is read out."
  for k in '.extraKnownMarketplaces["irrational-labs-plugins"]' \
           '.enabledPlugins["gws@irrational-labs-plugins"]' \
           '.enabledPlugins["il-slides@irrational-labs-plugins"]' \
           '.enabledPlugins["key-behavior@irrational-labs-plugins"]' \
           '.env.GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND'; do
    if [ "$(jq -r "$k // \"__absent__\"" "$S" 2>/dev/null)" != "__absent__" ]; then
      tag REMOVE "IL key present in settings.json: $k"
    fi
  done
  item "Total top-level keys in settings.json: $(jq -r 'keys | length' "$S" 2>/dev/null) (names not printed)"
elif [ -f "$S" ]; then
  tag UNKNOWN "settings.json exists but jq is missing — cannot inspect keys safely"
else
  item "No ~/.claude/settings.json."
fi

sub "il-setup blocks written into your shell startup files"
for p in "$HOME/.zshrc" "$HOME/.zshenv" "$HOME/.bash_profile" "$HOME/.bashrc" "$HOME/.profile"; do
  [ -f "$p" ] || continue
  n="$(grep -c '# >>> il-setup' "$p" 2>/dev/null || echo 0)"
  if [ "$n" -gt 0 ] 2>/dev/null; then
    tag REMOVE "$p contains $n il-setup block(s)"
    grep -n '# >>> il-setup' "$p" 2>/dev/null | sed 's/^/             marker at line /'
    item "          (the file has $(wc -l < "$p" | tr -d ' ') lines total; its contents are not printed)"
  fi
done
# The brew shellenv line the installer may have appended has NO marker.
for p in "$HOME/.zshrc" "$HOME/.bash_profile"; do
  [ -f "$p" ] || continue
  if grep -q 'brew shellenv' "$p" 2>/dev/null && ! grep -q '# >>> il-setup' "$p" 2>/dev/null; then
    tag UNKNOWN "$p has an unmarked 'brew shellenv' line — could be IL's or yours; the uninstaller will NOT remove it"
  fi
done

# Read off disk, NOT via `gh auth status`: running gh at all writes
# ~/.local/state/gh/device-id on first use (caught by CI). gh keeps its login in
# hosts.yml under $GH_CONFIG_DIR or ~/.config/gh. Only the github.com user
# handle is printed; the token line is never read out.
sub "GitHub CLI login (read from hosts.yml, gh is not run)"
gh_hosts="${GH_CONFIG_DIR:-$HOME/.config/gh}/hosts.yml"
if command -v gh >/dev/null 2>&1; then
  if [ -f "$gh_hosts" ] && grep -q '^github\.com:' "$gh_hosts" 2>/dev/null; then
    gh_user=$(awk '/^github\.com:/{f=1;next} /^[^ ]/{f=0} f && $1=="user:"{print $2; exit}' "$gh_hosts" 2>/dev/null)
    item "gh: github.com entry present in $gh_hosts${gh_user:+ (user $gh_user)}"
    if [ "$(rjq '.gh_was_authenticated_before // false')" = "true" ]; then
      tag KEEP "You were already signed into GitHub before IL setup — this login is YOURS"
    elif [ "$HAVE_RECEIPT" = yes ]; then
      tag REMOVE "GitHub login was established by IL setup"
    else
      tag UNKNOWN "GitHub login present, no receipt — cannot tell if IL created it. Default: KEEP."
    fi
    item "          >> Either way, the durable offboarding step is removing you from"
    item "          >> the IrrationalLabs-team GitHub org, which is done server-side."
  else
    item "gh installed but no github.com login in $gh_hosts."
  fi
else
  item "gh not installed."
fi

sub "Global git identity (what your commits are signed with right now)"
item "name:  $(git config --global user.name 2>/dev/null || echo '(unset)')"
item "email: $(mask_email "$(git config --global user.email 2>/dev/null)")"
if [ "$HAVE_RECEIPT" = yes ]; then
  item "receipt says it was, before IL setup: $(rjq '.git_identity_prior.name // "(none)"') <$(mask_email "$(rjq '.git_identity_prior.email // ""')")>"
else
  tag UNKNOWN "no receipt — if IL setup overwrote your git identity, we cannot restore it automatically"
fi

sub "Background jobs referencing IL or gws"
if [ -d "$HOME/Library/LaunchAgents" ]; then
  _la_hits=0; _la_all=0
  for _p in "$HOME/Library/LaunchAgents"/*; do
    [ -e "$_p" ] || continue
    _la_all=$((_la_all+1))
    case "$(basename "$_p" | tr '[:upper:]' '[:lower:]')" in
      *gws*|*irrational*|*il-setup*)
        tag REMOVE "launch agent: $(basename "$_p")"; _la_hits=$((_la_hits+1)) ;;
    esac
  done
  [ "$_la_hits" -eq 0 ] && item "No IL/gws launch agents. ($_la_all other agents present; names not printed.)"
fi
cl="$(crontab -l 2>/dev/null | grep -icE 'gws|irrational|il-setup')"
ct="$(crontab -l 2>/dev/null | wc -l | tr -d ' ')"
if [ "${cl:-0}" -gt 0 ] 2>/dev/null; then
  tag REMOVE "crontab has ${cl} line(s) referencing gws/IL (of ${ct} total)"
  crontab -l 2>/dev/null | grep -iE 'gws|irrational|il-setup' | sed 's/^/             /'
else
  item "No IL/gws crontab entries. (${ct:-0} crontab lines total; not printed.)"
fi

# Read off disk, NOT via `npm ls -g`: running npm at all writes files under
# ~/.npm (_logs/*.log and _update-notifier-last-checked) - proven empirically.
# bootstrap.sh installs node via Homebrew (line 177) and gws via `npm install -g`
# (line 663) with the default prefix, so the global root is <brew prefix>/lib/
# node_modules. A custom NPM_CONFIG_PREFIX or ~/.npm-global is checked too.
sub "Globally installed npm packages (names only, read from disk)"
npm_roots=""
[ -n "${NPM_CONFIG_PREFIX:-}" ] && npm_roots="$NPM_CONFIG_PREFIX/lib/node_modules"
npm_roots="$npm_roots /opt/homebrew/lib/node_modules /usr/local/lib/node_modules $HOME/.npm-global/lib/node_modules"
npm_found=0
for root in $npm_roots; do
  [ -d "$root" ] || continue
  npm_found=1
  item "$root:"
  # Scoped packages (@scope/name) live one level down; .bin is not a package.
  for d in "$root"/*/ "$root"/@*/*/; do
    [ -d "$d" ] || continue
    name="${d#"$root"/}"; name="${name%/}"
    case "$name" in .bin|@*/) continue ;; esac
    case "$name" in @*) [ "${name#*/}" = "$name" ] && continue ;; esac
    item "   $name"
  done | head -30
done
if [ "$npm_found" -eq 0 ]; then
  if command -v npm >/dev/null 2>&1; then
    item "npm is installed but no global node_modules dir was found in the usual places - not probed further."
  else
    item "npm not installed."
  fi
fi

# ── 3. shared tooling / provenance ───────────────────────────────────────────
hdr "3. SHARED DEVELOPER TOOLS  (IL setup can install these — but may not have)"
item "For each: did IL put it here, or was it already yours? Evidence shown."
item "When we cannot tell, it says UNKNOWN. We do not guess."
echo
for spec in "git:git:yes" "git-lfs:git-lfs:yes" "gh:gh:yes" "jq:jq:yes" "node:node:yes" \
            "ripgrep:rg:yes" "fd:fd:yes" "bat:bat:yes" "fzf:fzf:yes" "git-delta:delta:yes"; do
  f="${spec%%:*}"; rest="${spec#*:}"; c="${rest%%:*}"
  command -v "$c" >/dev/null 2>&1 || continue
  pth="$(command -v "$c")"
  res="$(provenance "$f" "$pth" yes)"
  tag "${res%%|*}" "$f  ($pth)"
  item "          ${res#*|}"
done

sub "Homebrew"
if command -v brew >/dev/null 2>&1; then
  if [ "$(rjq '.brew_installed_by_us // false')" = "true" ]; then
    tag UNKNOWN "Homebrew — receipt says IL setup installed it"
    item "          >> Removing Homebrew removes EVERY brew package on this machine,"
    item "          >> including ones that have nothing to do with IL. Human call."
    item "          >> Installed packages: $(brew list --formula 2>/dev/null | wc -l | tr -d ' ') formulae, $(brew list --cask 2>/dev/null | wc -l | tr -d ' ') casks."
  else
    tag KEEP "Homebrew at $(command -v brew) — not installed by IL setup"
  fi
else
  item "Homebrew not installed."
fi

sub "Bun"
if command -v bun >/dev/null 2>&1; then
  if [ "$(rjq '.bun_installed_by_us // false')" = "true" ]; then
    tag REMOVE "Bun (~/.bun) — receipt says IL setup installed it"
  elif [ "$HAVE_RECEIPT" = yes ]; then
    tag KEEP "Bun at $(command -v bun) — predates IL setup"
  else
    tag UNKNOWN "Bun present, no receipt — default KEEP"
  fi
fi

# ── 4. keep list ─────────────────────────────────────────────────────────────
hdr "4. KEEP  (yours — offboarding should not touch these)"
if command -v claude >/dev/null 2>&1; then
  if [ "$(rjq '.claude_code_installed_by_us // false')" = "true" ]; then
    tag KEEP "Claude Code at $(command -v claude) — receipt says IL installed it, but Chaning's instruction is KEEP."
    item "          >> WARNING: uninstaller preset 2 currently deletes this binary"
    item "          >> WITHOUT checking the receipt. Do not run preset 2."
  else
    tag KEEP "Claude Code at $(command -v claude) — yours, predates IL setup"
  fi
  item "          ~/.claude config dir: $([ -d "$HOME/.claude" ] && echo "present ($(fdate "$HOME/.claude")) — never removed" || echo 'absent')"
fi
if command -v gh >/dev/null 2>&1; then
  tag KEEP "GitHub CLI binary — general-purpose tool, keep regardless of org access"
fi
if [ -d "$HOME/.ssh" ]; then
  tag KEEP "SSH keys: $(ls "$HOME/.ssh"/*.pub 2>/dev/null | wc -l | tr -d ' ') public key(s) in ~/.ssh — personal, contents NEVER read"
fi
if [ -f "$HOME/.gitconfig" ]; then
  # shellcheck disable=SC2088  # display text, not a path to expand
  tag KEEP "~/.gitconfig — personal git config, only the IL-set identity should change"
fi
item ""
item "Also keep by default: every non-IL repo, every non-IL brew package, your"
item "shell config, your editor, your dotfiles, and anything not listed in"
item "section 2 above."

# ── 5. unsaved work ──────────────────────────────────────────────────────────
hdr "5. !! UNSAVED WORK  — the only thing here that cannot be undone !!"
item "Uninstalling deletes IL repo directories outright. Anything not committed"
item "AND pushed is gone permanently. This is the section to read first."
echo
_any=0
for g in $(find "$HOME" -maxdepth 4 -name .git -type d \
            -not -path "*/Library/*" -not -path "*/.Trash/*" \
            -not -path "*/node_modules/*" 2>/dev/null | head -60); do
  r="${g%/.git}"
  u="$(git -C "$r" remote get-url origin 2>/dev/null)"
  case "$u" in *IrrationalLabs*|*irrationallabs*) ;; *) continue ;; esac
  dirty="$(git -C "$r" status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  untr="$(git -C "$r" status --porcelain 2>/dev/null | grep -c '^??')"
  unpushed="$(git -C "$r" log --branches --not --remotes --oneline 2>/dev/null | wc -l | tr -d ' ')"
  stashes="$(git -C "$r" stash list 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${dirty:-0}" -gt 0 ] || [ "${unpushed:-0}" -gt 0 ] || [ "${stashes:-0}" -gt 0 ] 2>/dev/null; then
    _any=$((_any+1)); N_WORKLOSS=$((N_WORKLOSS+1))
    echo "   *** WORK AT RISK: $r"
    item "       uncommitted changes: ${dirty:-0}  (of which untracked: ${untr:-0})"
    item "       commits not pushed:  ${unpushed:-0}"
    item "       stashes:             ${stashes:-0}"
    item "       (filenames are not listed — they can reveal client names)"
  else
    item "clean, everything pushed: $r"
  fi
done
[ "$_any" -eq 0 ] && item "No unsaved work found in any IL repo. Good." \
                  || item ">> Push or back up the above BEFORE anyone runs an uninstaller."

# ── 6. summary ───────────────────────────────────────────────────────────────
hdr "6. SUMMARY"
printf '   CANDIDATE FOR REMOVAL : %d\n' "$N_REMOVE"
printf '   KEEP                  : %d\n' "$N_KEEP"
printf '   UNKNOWN (ask a human) : %d\n' "$N_UNKNOWN"
printf '   REPOS WITH WORK AT RISK: %d\n' "$N_WORKLOSS"
echo
item "Nothing on this machine was changed by running this. Send this output back"
item "to Chaning; the actual removal list will be decided by a human from it."
echo
