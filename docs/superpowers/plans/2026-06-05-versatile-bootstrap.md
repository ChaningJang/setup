# Versatile Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor `bootstrap.sh` / `bootstrap.ps1` so one pasted command installs a lean base toolset, installs Claude Code early, then offers an access-filtered menu of curated repos to clone — running HQ's full bespoke setup or a generic best-effort setup per repo — while bringing the Windows script to full parity with macOS.

**Architecture:** Two platform scripts (kept native for the `curl|bash` / `irm|iex` paste UX), refactored into clear ordered stages, driven by a shared `repos.json` manifest that both scripts read (with an embedded fallback). The curated repo list lives only in `repos.json`, so the menu can't drift between platforms. See spec: `docs/superpowers/specs/2026-06-05-versatile-bootstrap-design.md`.

**Tech Stack:** Bash 3.2 (macOS system bash — the one-liner runs `/bin/bash`), PowerShell 5+, `gh` CLI, `jq` (macOS) / `ConvertFrom-Json` (Windows), Homebrew / winget+Scoop.

---

## Critical Constraints (read before any task)

1. **Bash 3.2 only.** The macOS one-liner is `/bin/bash -c "$(curl …)"` → system bash 3.2. **Do not use:** associative arrays (`declare -A`), `mapfile`/`readarray`, `${var^^}`. Indexed arrays, `+=`, `${!arr[@]}`, `[[ ]]`, `case` are fine.
2. **`set -u` + empty arrays.** In bash 3.2, expanding an empty array (`"${ARR[@]}"`) under `set -u` throws "unbound variable". **Always guard** array expansions with `if [[ ${#ARR[@]} -gt 0 ]]` first. This applies to `SELECTED_KEYS` and `WARNINGS`.
3. **Interactive input over a pipe.** Under `curl|bash`, stdin is the script, so every interactive `read` must use `read -r ans < /dev/tty`, and prompts that must reach the user go to `> /dev/tty`. PowerShell's `irm|iex` runs in the live console, so `Read-Host` works directly.
4. **Idempotent.** Every step keeps its skip-if-present check; re-runs must be safe.
5. **Verification reality:** `shellcheck`/`pwsh` are not assumed present. Primary gates: `bash -n` (syntax) and `jq empty` (JSON). `shellcheck` is run if available (`brew install shellcheck`). PowerShell correctness is verified by manual review on macOS + a real run on Windows (test matrix in Task 12).

---

## File Structure

```
setup/
├── README.md          # Task 10 — updated install commands + menu/flags docs
├── repos.json         # Task 1 — NEW, curated menu, single source of truth
├── bootstrap.sh       # Tasks 2-6 — refactored (macOS)
├── bootstrap.ps1       # Tasks 7-9 — refactored to parity (Windows)
└── docs/superpowers/...# spec + this plan
```

`bootstrap.sh` function map after refactor:

| Function | Status | Step (flow) |
|----------|--------|-------------|
| `parse_args` | NEW | 1 |
| `print_usage` | NEW | (help) |
| `check_macos`, `ensure_xcode_cli`, `ensure_homebrew` | keep | 2 |
| `ensure_early_tools` | NEW (merges `ensure_git_tools` + jq + bun) | 3 |
| `ensure_github_auth`, `ensure_git_identity` | keep | 4 |
| `ensure_claude_code`, `ensure_il_claude_plugins` | keep, **moved up** | 5 |
| `load_manifest` | NEW | 6 |
| `repo_field`, `all_repo_keys` | NEW (jq helpers) | 6 |
| `select_repos` | NEW (menu + flags + access-filter) | 6 |
| `install_shell_helpers` | NEW | 7 |
| `clone_and_setup_repo` | NEW (dispatch) | 8 |
| `install_hq_extras` | NEW (heavy tools, from old `install_cli_tools`) | 8 |
| `setup_hq` | NEW (wraps existing HQ recipe) | 8 |
| `repair_lfs_if_needed`, `install_precommit_hook`, `load_hq_secrets` | keep (renamed from `setup_git_hooks`/`setup_secrets`), now take a dir arg | 8 |
| `setup_generic` | NEW | 8 |
| `verify_setup`, `print_completion` | keep, adapted for warnings | 9 |
| `main` | rewritten ordering | — |

---

## Task 1: Create the branch and the `repos.json` manifest

**Files:**
- Create: `repos.json`

- [ ] **Step 1: Create a feature branch off main**

```bash
cd ~/setup
git checkout main && git pull --ff-only
git checkout -b feat/versatile-bootstrap
```

- [ ] **Step 2: Write `repos.json`**

Create `repos.json`:

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
    },
    {
      "key": "experiments",
      "name": "IL Experiments",
      "slug": "IrrationalLabs-team/IL-experiments",
      "dir": "IL-experiments",
      "setup": "generic",
      "default": false,
      "description": "Prolific / Netlify A/B experiment platform"
    }
  ]
}
```

> Note: `setup` is maintainer-only metadata (`"hq"` or `"generic"`). End users never type it; they pick repos by name (menu) or `key` (`--repos`). Add/remove repos here only.

- [ ] **Step 3: Validate the JSON**

Run: `jq empty repos.json && jq -r '.repos[] | "\(.key)\t\(.setup)\t\(.slug)"' repos.json`
Expected: no error; three tab-separated rows (hq/marketing/experiments).

- [ ] **Step 4: Confirm each slug resolves (manual sanity)**

Run: `for s in $(jq -r '.repos[].slug' repos.json); do echo -n "$s: "; gh repo view "$s" --json name -q .name 2>/dev/null || echo "NO ACCESS"; done`
Expected: each prints its repo name (or "NO ACCESS" if you personally lack access — that's fine, it proves the filter probe works).

- [ ] **Step 5: Commit**

```bash
git add repos.json docs/superpowers/specs/2026-06-05-versatile-bootstrap-design.md docs/superpowers/plans/2026-06-05-versatile-bootstrap.md
git commit -m "feat: add repos.json manifest + design/plan for versatile bootstrap"
```

---

## Task 2: `bootstrap.sh` — config, flag parsing, usage, embedded fallback

**Files:**
- Modify: `bootstrap.sh` (top configuration block + new functions)

- [ ] **Step 1: Add config + globals**

In `bootstrap.sh`, replace the Configuration block (currently `REPO_URL` / `PROJECT_DIR` / `LFS_MIN_SIZE`) with:

```bash
# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
ORG="IrrationalLabs-team"
SETUP_RAW_BASE="https://raw.githubusercontent.com/ChaningJang/setup/main"
LFS_MIN_SIZE=1000

# Minimal fallback manifest if repos.json can't be fetched (offline / local run).
EMBEDDED_REPOS_JSON='{"repos":[{"key":"hq","name":"Irrational Labs HQ","slug":"IrrationalLabs-team/irrational_labs_hq","dir":"irrational_labs_hq","setup":"hq","default":true,"description":"Main workspace"}]}'

# Runtime state
FLAG_REPOS=""          # comma-separated repo keys, or empty
FLAG_BASE_ONLY=false
REPOS_JSON=""          # loaded manifest (string)
SELECTED_KEYS=()       # repo keys chosen to clone
WARNINGS=()            # non-fatal issues, reprinted at the end
```

- [ ] **Step 2: Add `print_usage` and `parse_args`**

Add after the print helper functions:

```bash
print_usage() {
    cat <<USAGE
Irrational Labs setup

Usage:
  bootstrap.sh [--repos key1,key2] [--base-only]

Options:
  --repos LIST   Comma-separated repo keys to clone (skips the menu).
                 e.g. --repos hq,marketing
  --base-only    Install base tools only; clone nothing.
  -h, --help     Show this help.

With no options, an interactive menu asks which repos to clone.
USAGE
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repos)      FLAG_REPOS="${2:-}"; shift 2 ;;
            --repos=*)    FLAG_REPOS="${1#*=}"; shift ;;
            --base-only)  FLAG_BASE_ONLY=true; shift ;;
            -h|--help)    print_usage; exit 0 ;;
            *)            print_warning "Unknown option: $1"; shift ;;
        esac
    done
}
```

- [ ] **Step 3: Syntax check**

Run: `bash -n bootstrap.sh`
Expected: no output (exit 0).

- [ ] **Step 4: Commit**

```bash
git add bootstrap.sh
git commit -m "feat(macos): add flag parsing, usage, and manifest config"
```

---

## Task 3: `bootstrap.sh` — early tools, reorder main, move Claude Code up

**Files:**
- Modify: `bootstrap.sh`

- [ ] **Step 1: Add `ensure_early_tools` (git, git-lfs, gh, jq, bun)**

Replace `ensure_git_tools` and `ensure_bun` with one function:

```bash
ensure_early_tools() {
    print_step "Installing core tools (git, git-lfs, gh, jq, bun)..."

    command_exists git     || { print_info "Installing git...";     brew install git; }
    print_success "git $(git --version | cut -d' ' -f3)"

    command_exists git-lfs || { print_info "Installing git-lfs..."; brew install git-lfs; }
    git lfs install >/dev/null 2>&1
    print_success "git-lfs ready"

    command_exists gh      || { print_info "Installing GitHub CLI..."; brew install gh; }
    print_success "gh $(gh --version | head -1 | cut -d' ' -f3)"

    command_exists jq      || { print_info "Installing jq...";      brew install jq; }
    print_success "jq ready"

    if command_exists bun; then
        print_success "bun $(bun --version)"
    else
        print_info "Installing Bun..."
        curl -fsSL https://bun.sh/install | bash
        export BUN_INSTALL="$HOME/.bun"
        export PATH="$BUN_INSTALL/bin:$PATH"
        if command_exists bun; then
            print_success "bun $(bun --version)"
        else
            print_error "Bun installation failed"
            exit 1
        fi
    fi
}
```

- [ ] **Step 2: Rewrite `main` to the new ordering**

Replace `main` with:

```bash
main() {
    parse_args "$@"

    echo ""
    echo -e "${BOLD}Irrational Labs — Setup${NC}"
    echo -e "This will install your dev tools, then ask which repos to clone."
    echo ""

    check_macos
    ensure_xcode_cli
    ensure_homebrew
    ensure_early_tools          # step 3: git, git-lfs, gh, jq, bun
    ensure_github_auth          # step 4
    ensure_git_identity
    ensure_claude_code          # step 5: Claude available before anything that can fail
    ensure_il_claude_plugins
    load_manifest               # step 6
    select_repos
    install_shell_helpers       # step 7

    if [[ ${#SELECTED_KEYS[@]} -gt 0 ]]; then          # guard: bash 3.2 + set -u
        local k
        for k in "${SELECTED_KEYS[@]}"; do
            clone_and_setup_repo "$k"
        done
    else
        print_info "No repositories selected — base tools only"
    fi

    echo ""
    verify_setup || print_warning "Setup completed with some issues"
    print_completion
}

main "$@"
```

> `ensure_claude_code` and `ensure_il_claude_plugins` already exist — keep their bodies as-is; they are simply called earlier now. Delete the old standalone `ensure_bun`, `install_cli_tools`, `install_project_deps`, `setup_repository`, `setup_git_hooks`, and `setup_secrets` calls from the old `main` (their logic is relocated in Tasks 4–5; do not delete the functions yet).

- [ ] **Step 3: Syntax check**

Run: `bash -n bootstrap.sh`
Expected: no output. (It will reference not-yet-defined functions `load_manifest`/`select_repos`/etc. — that's fine for `bash -n`, which only checks syntax, not definitions. They are added in Tasks 4–5 before any real run.)

- [ ] **Step 4: Commit**

```bash
git add bootstrap.sh
git commit -m "feat(macos): split early tools and reorder main; Claude Code installs early"
```

---

## Task 4: `bootstrap.sh` — manifest load + repo selection (menu, flags, access-filter)

**Files:**
- Modify: `bootstrap.sh`

- [ ] **Step 1: Add manifest loader + jq helpers**

```bash
load_manifest() {
    print_step "Loading repo list..."
    local fetched=""
    fetched=$(curl -fsSL "$SETUP_RAW_BASE/repos.json" 2>/dev/null || echo "")
    if [[ -n "$fetched" ]] && echo "$fetched" | jq empty >/dev/null 2>&1; then
        REPOS_JSON="$fetched"
        print_success "Repo list loaded"
    else
        REPOS_JSON="$EMBEDDED_REPOS_JSON"
        print_warning "Couldn't fetch repo list — using built-in default (HQ only)"
    fi
}

# repo_field <key> <field>  -> prints the field value (empty if not found)
repo_field() {
    echo "$REPOS_JSON" | jq -r --arg k "$1" --arg f "$2" \
        '.repos[] | select(.key==$k) | .[$f] // empty'
}

all_repo_keys() {
    echo "$REPOS_JSON" | jq -r '.repos[].key'
}
```

- [ ] **Step 2: Add `select_repos`**

```bash
select_repos() {
    SELECTED_KEYS=()

    if [[ "$FLAG_BASE_ONLY" == true ]]; then
        print_info "Base-only mode — no repositories will be cloned"
        return 0
    fi

    # Non-interactive: keys passed via --repos
    if [[ -n "$FLAG_REPOS" ]]; then
        local IFS=','
        local k
        for k in $FLAG_REPOS; do
            k=$(echo "$k" | tr -d '[:space:]')
            [[ -z "$k" ]] && continue
            if [[ -n "$(repo_field "$k" key)" ]]; then
                SELECTED_KEYS+=("$k")
            else
                print_warning "Unknown repo key '$k' — skipping"
            fi
        done
        return 0
    fi

    # Interactive: build the access-filtered list
    print_step "Checking which repos you can access..."
    local keys=() names=() descs=()
    local key slug
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        slug=$(repo_field "$key" slug)
        if gh repo view "$slug" >/dev/null 2>&1; then
            keys+=("$key")
            names+=("$(repo_field "$key" name)")
            descs+=("$(repo_field "$key" description)")
        fi
    done <<EOF
$(all_repo_keys)
EOF

    # Fallback: if access couldn't be verified for anything, show the full list.
    if [[ ${#keys[@]} -eq 0 ]]; then
        print_warning "Couldn't verify repo access — showing the full list"
        while IFS= read -r key; do
            [[ -z "$key" ]] && continue
            keys+=("$key")
            names+=("$(repo_field "$key" name)")
            descs+=("$(repo_field "$key" description)")
        done <<EOF
$(all_repo_keys)
EOF
    fi

    # Render the menu to the terminal (stdin is the piped script, so use /dev/tty).
    {
        echo ""
        echo "Which repositories do you want to clone?"
        local i num
        for i in "${!keys[@]}"; do
            num=$((i + 1))
            printf "  %d) %s — %s\n" "$num" "${names[$i]}" "${descs[$i]}"
        done
        echo "  0) None (base tools only)"
        echo ""
        printf "Enter numbers separated by spaces or commas (default: 1): "
    } > /dev/tty

    local answer=""
    read -r answer < /dev/tty || answer=""
    [[ -z "$answer" ]] && answer="1"
    answer="${answer//,/ }"

    local tok idx
    for tok in $answer; do
        if [[ "$tok" == "0" ]]; then
            SELECTED_KEYS=()
            return 0
        fi
        if [[ "$tok" =~ ^[0-9]+$ ]]; then
            idx=$((tok - 1))
            if [[ $idx -ge 0 && $idx -lt ${#keys[@]} ]]; then
                SELECTED_KEYS+=("${keys[$idx]}")
            else
                print_warning "Ignoring out-of-range choice: $tok"
            fi
        fi
    done
}
```

- [ ] **Step 3: Syntax check**

Run: `bash -n bootstrap.sh`
Expected: no output.

- [ ] **Step 4: Isolated logic test (no installs)**

This verifies parsing + jq helpers without running the installer. Run:

```bash
bash -c '
  REPOS_JSON=$(cat repos.json)
  repo_field(){ echo "$REPOS_JSON" | jq -r --arg k "$1" --arg f "$2" ".repos[] | select(.key==\$k) | .[\$f] // empty"; }
  all_repo_keys(){ echo "$REPOS_JSON" | jq -r ".repos[].key"; }
  echo "keys: $(all_repo_keys | tr "\n" " ")"
  echo "hq slug: $(repo_field hq slug)"
  echo "marketing setup: $(repo_field marketing setup)"
  echo "missing: [$(repo_field nope slug)]"
'
```

Expected:
```
keys: hq marketing experiments
hq slug: IrrationalLabs-team/irrational_labs_hq
marketing setup: generic
missing: []
```

- [ ] **Step 5: Commit**

```bash
git add bootstrap.sh
git commit -m "feat(macos): manifest load + access-filtered repo selection menu and flags"
```

---

## Task 5: `bootstrap.sh` — shell helpers, clone dispatch, HQ recipe, generic pass

**Files:**
- Modify: `bootstrap.sh`

- [ ] **Step 1: Add `install_shell_helpers`**

```bash
install_shell_helpers() {
    print_step "Installing shell helpers..."
    local helpers=("ripgrep" "fd" "bat" "fzf" "git-delta")
    local to_install=() tool cmd
    for tool in "${helpers[@]}"; do
        cmd="$tool"
        case "$tool" in
            ripgrep)   cmd="rg" ;;
            git-delta) cmd="delta" ;;
        esac
        command_exists "$cmd" || to_install+=("$tool")
    done
    if [[ ${#to_install[@]} -eq 0 ]]; then
        print_success "Shell helpers already installed"
    else
        print_info "Installing: ${to_install[*]}"
        brew install "${to_install[@]}" || print_warning "Some shell helpers failed — continuing"
        print_success "Shell helpers installed"
    fi
}
```

- [ ] **Step 2: Add `install_hq_extras` (heavy media/doc tools)**

This is the old `install_cli_tools` list **minus** the shell helpers and jq that moved to base:

```bash
install_hq_extras() {
    print_step "Installing HQ media/doc tools..."
    local tools=(
        "marp-cli" "ghostscript" "ffmpeg" "exiftool" "yt-dlp" "pandoc"
        "imagemagick" "yq" "miller" "sd" "gawk" "coreutils" "parallel"
        "trash" "eza"
    )
    local to_install=() tool cmd
    for tool in "${tools[@]}"; do
        cmd="$tool"
        case "$tool" in
            "marp-cli")    cmd="marp" ;;
            "ghostscript") cmd="gs" ;;
            "imagemagick") cmd="magick" ;;
            "coreutils")   cmd="gtimeout" ;;
            "miller")      cmd="mlr" ;;
        esac
        command_exists "$cmd" || to_install+=("$tool")
    done
    if [[ ${#to_install[@]} -eq 0 ]]; then
        print_success "HQ tools already installed"
    else
        print_info "Installing: ${to_install[*]}"
        brew install "${to_install[@]}" || print_warning "Some HQ tools failed — continuing"
        print_success "HQ tools installed"
    fi
}
```

- [ ] **Step 3: Adapt the kept HQ helpers to take a directory argument**

Rename `setup_git_hooks` → `install_precommit_hook` and `setup_secrets` → `load_hq_secrets`, and make `repair_lfs_if_needed` take the dir. Replace those three functions with:

```bash
repair_lfs_if_needed() {
    local dir="$1"
    local needs_repair=false
    local test_file="$dir/templates/powerpoint/irrational_labs_powerpoint_template_3.pptx"
    if [[ -f "$test_file" ]]; then
        local size
        size=$(stat -f%z "$test_file" 2>/dev/null || echo "0")
        [[ "$size" -lt "$LFS_MIN_SIZE" ]] && needs_repair=true
    else
        needs_repair=true
    fi
    if [[ "$needs_repair" == true ]]; then
        print_info "Downloading LFS files (this may take a few minutes)..."
        cd "$dir"
        git lfs install --local
        git lfs pull
        print_success "LFS files downloaded"
    else
        print_success "LFS files verified"
    fi
}

install_precommit_hook() {
    local dir="$1"
    cd "$dir"
    mkdir -p .git/hooks
    local hook_file=".git/hooks/pre-commit"
    cat > "$hook_file" << 'HOOK'
#!/bin/sh
PROJECT_ROOT=$(git rev-parse --show-toplevel)
if ! bun run "$PROJECT_ROOT/scripts/validate_filenames.ts" --staged --quiet; then
    printf "\n"
    printf "Commit rejected: One or more filenames contain Windows-incompatible characters.\n"
    printf "Please rename the files to remove invalid characters before committing.\n"
    printf "\n"
    exit 1
fi
exit 0
HOOK
    chmod +x "$hook_file"
    print_success "Pre-commit hook installed"
}

load_hq_secrets() {
    local dir="$1"
    cd "$dir"
    if [[ -f ".env" ]]; then
        print_info ".env already exists (run scripts/load_infisical_env.ts --force to refresh)"
    else
        print_info "Fetching secrets from Infisical..."
        if bun run scripts/load_infisical_env.ts; then
            print_success "Secrets loaded to .env"
        else
            WARNINGS+=("HQ: could not load Infisical secrets — ask an admin for access")
            print_warning "Could not load secrets — continuing"
        fi
    fi
}
```

- [ ] **Step 4: Add `setup_hq` and `setup_generic`**

```bash
setup_hq() {
    local dir="$1"
    print_step "Running HQ setup..."
    install_hq_extras
    repair_lfs_if_needed "$dir"
    cd "$dir"
    print_info "Running bun install..."
    bun install || WARNINGS+=("HQ: bun install failed")
    install_precommit_hook "$dir"
    load_hq_secrets "$dir"
    print_success "HQ setup complete"
}

setup_generic() {
    local dir="$1"
    local base
    base=$(basename "$dir")
    print_step "Running generic setup for $base..."
    cd "$dir"
    if [[ -f package.json ]]; then
        print_info "Found package.json — running bun install"
        bun install || WARNINGS+=("$base: bun install failed")
    fi
    if [[ -f .gitattributes ]] && grep -q "filter=lfs" .gitattributes 2>/dev/null; then
        print_info "Repo uses Git LFS — pulling LFS files"
        git lfs install --local >/dev/null 2>&1 || true
        git lfs pull || WARNINGS+=("$base: git lfs pull failed")
    fi
    if [[ ! -f .env ]]; then
        local example=""
        [[ -f .env.example ]] && example=".env.example"
        [[ -z "$example" && -f .env.sample ]] && example=".env.sample"
        if [[ -n "$example" ]]; then
            cp "$example" .env
            print_info "Created .env from $example — fill in secrets before use"
            WARNINGS+=("$base: created .env from $example — needs your secrets")
        fi
    fi
    print_success "$base ready — check its README for any extra setup"
}
```

- [ ] **Step 5: Add `clone_and_setup_repo` (dispatch)**

```bash
clone_and_setup_repo() {
    local key="$1"
    local slug dir setup target
    slug=$(repo_field "$key" slug)
    dir=$(repo_field "$key" dir)
    setup=$(repo_field "$key" setup)
    target="$HOME/$dir"

    if [[ -z "$slug" ]]; then
        print_warning "Unknown repo key '$key' — skipping"
        return 0
    fi

    print_step "Setting up $slug..."

    if [[ -d "$target/.git" ]]; then
        print_info "Already cloned at $target — pulling latest"
        ( cd "$target" && git pull --ff-only ) || true
    else
        mkdir -p "$(dirname "$target")"
        if ! gh repo clone "$slug" "$target"; then
            WARNINGS+=("Could not clone $slug — check your GitHub access")
            print_error "Failed to clone $slug (continuing)"
            return 0
        fi
        print_success "Cloned $slug"
    fi

    case "$setup" in
        hq)      setup_hq "$target" ;;
        generic) setup_generic "$target" ;;
        *)       setup_generic "$target" ;;
    esac
}
```

- [ ] **Step 6: Syntax check**

Run: `bash -n bootstrap.sh`
Expected: no output.

- [ ] **Step 7: Commit**

```bash
git add bootstrap.sh
git commit -m "feat(macos): shell helpers, clone dispatch, HQ recipe + generic pass"
```

---

## Task 6: `bootstrap.sh` — verify, completion with warnings, smoke test

**Files:**
- Modify: `bootstrap.sh`

- [ ] **Step 1: Update `verify_setup`**

Replace the LFS-specific check (no fixed PROJECT_DIR anymore) with a base-tools check:

```bash
verify_setup() {
    print_step "Verifying setup..."
    local all_good=true cmd
    local critical=("git" "git-lfs" "gh" "bun" "jq" "brew")
    for cmd in "${critical[@]}"; do
        if command_exists "$cmd"; then
            print_success "$cmd"
        else
            print_error "$cmd not found"
            all_good=false
        fi
    done
    if command_exists claude; then
        print_success "claude"
    else
        print_warning "claude not in PATH (may need terminal restart)"
    fi
    [[ "$all_good" == true ]] && return 0 || return 1
}
```

- [ ] **Step 2: Update `print_completion` to surface warnings**

Add, before the "Next steps" block:

```bash
    if [[ ${#WARNINGS[@]} -gt 0 ]]; then          # guard: bash 3.2 + set -u
        echo ""
        echo -e "${YELLOW}${BOLD}Heads up — a few things need attention:${NC}"
        local w
        for w in "${WARNINGS[@]}"; do
            echo -e "  ${YELLOW}•${NC} $w"
        done
    fi
```

Also change the hard-coded `cd ~/irrational_labs_hq && claude` next-step line to be generic:

```bash
    echo "  1. Open a new terminal window (to pick up PATH changes)"
    echo "  2. cd into a cloned repo and run:  claude"
    echo "  3. Ask Claude: 'Give me a tour of this project'"
```

- [ ] **Step 3: Full syntax check + optional shellcheck**

Run: `bash -n bootstrap.sh && echo "syntax ok"`
Expected: `syntax ok`

If shellcheck is available: `command -v shellcheck >/dev/null && shellcheck -S warning bootstrap.sh || echo "shellcheck not installed (optional)"`
Expected: no errors, or the "not installed" note. Fix any `error`-level findings.

- [ ] **Step 4: Dry smoke test of help + base-only parsing (no installs)**

Run: `bash -n bootstrap.sh && grep -c 'SELECTED_KEYS' bootstrap.sh`
Expected: syntax ok and a count ≥ 4 (defined + guarded + assigned + iterated). This is a structural sanity check; the full install is exercised in the Task 12 manual matrix.

- [ ] **Step 5: Commit**

```bash
git add bootstrap.sh
git commit -m "feat(macos): generic verify + warnings summary in completion"
```

---

## Task 7: `bootstrap.ps1` — config, flags, early tools, reorder, Claude up

**Files:**
- Modify: `bootstrap.ps1`

> PowerShell mirrors the bash flow 1:1. `irm|iex` runs in the live console, so `Read-Host` works directly (no `/dev/tty` equivalent needed).

- [ ] **Step 1: Replace the config block + add params/state**

Make the script accept params (works with `irm|iex` when the user appends them, and when run as a file). At the very top, before `$ErrorActionPreference`:

```powershell
param(
    [string]$Repos = "",       # comma-separated repo keys
    [switch]$BaseOnly
)
```

Then replace the Configuration block:

```powershell
$ORG            = "IrrationalLabs-team"
$SETUP_RAW_BASE = "https://raw.githubusercontent.com/ChaningJang/setup/main"
$LFS_MIN_SIZE   = 1000
$EMBEDDED_REPOS_JSON = '{"repos":[{"key":"hq","name":"Irrational Labs HQ","slug":"IrrationalLabs-team/irrational_labs_hq","dir":"irrational_labs_hq","setup":"hq","default":true,"description":"Main workspace"}]}'

$script:ReposJson    = $null
$script:SelectedKeys = @()
$script:Warnings     = @()
```

- [ ] **Step 2: Add `Ensure-EarlyTools` (git, git-lfs, gh, jq, bun)**

Replace `Ensure-Git` and `Ensure-Bun` with one function that also installs `jq`:

```powershell
function Ensure-EarlyTools {
    Print-Step "Installing core tools (git, git-lfs, gh, jq, bun)..."

    if (-not (Test-CommandExists "git")) {
        winget install --id Git.Git --accept-source-agreements --accept-package-agreements -e
        Refresh-Path
    }
    if (Test-CommandExists "git") { Print-Success "git $(git --version)" }
    else { Print-Error "Git installation failed"; throw "Git is required" }

    if (-not (Test-CommandExists "git-lfs")) {
        winget install --id GitHub.GitLFS --accept-source-agreements --accept-package-agreements -e
        Refresh-Path
    }
    git lfs install 2>$null | Out-Null
    Print-Success "git-lfs ready"

    if (-not (Test-CommandExists "gh")) {
        winget install --id GitHub.cli --accept-source-agreements --accept-package-agreements -e
        Refresh-Path
    }
    if (Test-CommandExists "gh") { Print-Success "gh installed" }
    else { Print-Warning "gh may need a terminal restart" }

    if (-not (Test-CommandExists "jq")) {
        scoop install jq 2>$null
        Refresh-Path
    }
    Print-Success "jq ready"

    if (Test-CommandExists "bun") {
        Print-Success "bun $(bun --version)"
    } else {
        Print-Info "Installing Bun..."
        powershell -c "irm bun.sh/install.ps1 | iex"
        Refresh-Path
        $bunPath = "$HOME\.bun\bin"
        if (Test-Path $bunPath) { $env:Path = "$bunPath;$env:Path" }
        if (Test-CommandExists "bun") { Print-Success "bun $(bun --version)" }
        else { Print-Error "Bun installation failed"; throw "Bun is required" }
    }
}
```

- [ ] **Step 3: Rewrite `Main` ordering**

```powershell
function Main {
    Write-Host ""
    Write-Host "Irrational Labs — Setup (Windows)" -ForegroundColor White
    Write-Host "This will install your dev tools, then ask which repos to clone."
    Write-Host ""

    Ensure-Winget
    Ensure-Scoop
    Ensure-EarlyTools          # step 3
    Ensure-GitHubAuth          # step 4
    Ensure-GitIdentity
    Ensure-ClaudeCode          # step 5 (moved up; hardened in Task 8)
    Ensure-IlClaudePlugins     # step 5 (new in Task 8)
    Load-Manifest              # step 6
    Select-Repos
    Install-ShellHelpers       # step 7

    if ($script:SelectedKeys.Count -gt 0) {
        foreach ($k in $script:SelectedKeys) { Clone-AndSetupRepo $k }
    } else {
        Print-Info "No repositories selected — base tools only"
    }

    Write-Host ""
    if (-not (Verify-Setup)) { Print-Warning "Setup completed with some issues" }
    Print-Completion
}

# Apply flags from params
if ($Repos)   { } # consumed in Select-Repos via $Repos
Main
```

> Keep `Ensure-Winget`, `Ensure-Scoop`, `Ensure-GitHubAuth`, `Ensure-GitIdentity` as-is. Remove the old `Setup-Repository`, `Install-CliTools`, `Install-ProjectDeps`, `Setup-GitHooks`, `Setup-Secrets` calls from `Main` (logic relocates in Tasks 8–9).

- [ ] **Step 4: Manual review (no pwsh on macOS)**

Read the diff. Confirm: `param(...)` is the first statement; `Main` calls match the new order; no removed function is still called. Note for Task 12 Windows run.

- [ ] **Step 5: Commit**

```bash
git add bootstrap.ps1
git commit -m "feat(windows): flags, early tools, reorder main, Claude Code early"
```

---

## Task 8: `bootstrap.ps1` — close parity gaps (plugins + Claude PATH/sanity)

**Files:**
- Modify: `bootstrap.ps1`

- [ ] **Step 1: Harden `Ensure-ClaudeCode` (PATH persistence + hard check)**

Replace `Ensure-ClaudeCode` with:

```powershell
function Ensure-ClaudeCode {
    Print-Step "Checking Claude Code..."

    if (Test-CommandExists "claude") {
        Print-Success "Claude Code already installed"
    } else {
        Print-Info "Installing Claude Code..."
        bun install -g @anthropic-ai/claude-code 2>$null
        Refresh-Path
        $bunBin = "$HOME\.bun\bin"
        if (Test-Path $bunBin) { $env:Path = "$bunBin;$env:Path" }
    }

    # Persist bun global bin on the User PATH so future terminals find claude.
    $bunBin = "$HOME\.bun\bin"
    if (Test-Path $bunBin) {
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        if ($userPath -notlike "*$bunBin*") {
            [Environment]::SetEnvironmentVariable("Path", "$userPath;$bunBin", "User")
            Print-Success "Added $bunBin to your PATH"
        }
    }

    Refresh-Path
    if (Test-CommandExists "claude") {
        Print-Success "Claude Code ready"
    } else {
        Print-Warning "claude installed but not yet on PATH — open a new terminal"
    }
}
```

> Implementation note: if a native Windows Claude installer exists at run time (e.g. `irm https://claude.ai/install.ps1 | iex`), prefer it and adjust the PATH dir accordingly. Verify during Task 12.

- [ ] **Step 2: Add `Ensure-IlClaudePlugins` (the missing parity step)**

Port the macOS plugin registration using native JSON cmdlets. This must preserve an explicit user *disable* (only set a default when the key is absent):

```powershell
function Ensure-IlClaudePlugins {
    Print-Step "Setting up Irrational Labs Claude Code plugins..."

    $claudeDir = "$HOME\.claude"
    $settingsPath = "$claudeDir\settings.json"
    if (-not (Test-Path $claudeDir)) { New-Item -ItemType Directory -Path $claudeDir -Force | Out-Null }

    if (Test-Path $settingsPath) {
        try { $settings = Get-Content -Raw $settingsPath | ConvertFrom-Json }
        catch { $settings = [PSCustomObject]@{} }
    } else {
        $settings = [PSCustomObject]@{}
    }

    # Helper to ensure a property exists on a PSCustomObject
    function Ensure-Prop($obj, $name, $value) {
        if (-not ($obj.PSObject.Properties.Name -contains $name)) {
            $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value
        }
    }

    # Marketplace registration is always (re)set.
    $marketplace = [PSCustomObject]@{
        source = [PSCustomObject]@{
            source = "github"
            repo   = "IrrationalLabs-team/knowledge-work-plugins"
        }
    }
    Ensure-Prop $settings "extraKnownMarketplaces" ([PSCustomObject]@{})
    if ($settings.extraKnownMarketplaces.PSObject.Properties.Name -contains "irrational-labs-plugins") {
        $settings.extraKnownMarketplaces."irrational-labs-plugins" = $marketplace
    } else {
        $settings.extraKnownMarketplaces | Add-Member -NotePropertyName "irrational-labs-plugins" -NotePropertyValue $marketplace
    }

    # Default-on plugins — only set when the key is absent (preserve explicit disables).
    Ensure-Prop $settings "enabledPlugins" ([PSCustomObject]@{})
    foreach ($p in @("gws@irrational-labs-plugins","il-slides@irrational-labs-plugins","key-behavior@irrational-labs-plugins")) {
        if (-not ($settings.enabledPlugins.PSObject.Properties.Name -contains $p)) {
            $settings.enabledPlugins | Add-Member -NotePropertyName $p -NotePropertyValue $true
        }
    }

    $settings | ConvertTo-Json -Depth 12 | Set-Content -Path $settingsPath -Encoding UTF8
    Print-Success "IL plugin marketplace registered"
    Print-Info "Default-on: gws, il-slides, key-behavior"
    Print-Info "Available on demand: gorilla-scripting, pipedrive"
}
```

- [ ] **Step 3: Manual review**

Confirm the JSON merge logic only adds default plugin keys when absent, and always overwrites the marketplace entry. Note for Task 12 Windows run that re-running must not flip a manually-disabled plugin back on.

- [ ] **Step 4: Commit**

```bash
git add bootstrap.ps1
git commit -m "fix(windows): add IL plugin registration + harden Claude Code PATH (parity)"
```

---

## Task 9: `bootstrap.ps1` — manifest, selection, helpers, dispatch, recipes

**Files:**
- Modify: `bootstrap.ps1`

- [ ] **Step 1: Add manifest loader + field helpers**

```powershell
function Load-Manifest {
    Print-Step "Loading repo list..."
    $fetched = $null
    try { $fetched = Invoke-RestMethod -Uri "$SETUP_RAW_BASE/repos.json" -ErrorAction Stop } catch { $fetched = $null }
    if ($fetched -and $fetched.repos) {
        $script:ReposJson = $fetched
        Print-Success "Repo list loaded"
    } else {
        $script:ReposJson = ($EMBEDDED_REPOS_JSON | ConvertFrom-Json)
        Print-Warning "Couldn't fetch repo list — using built-in default (HQ only)"
    }
}

function Get-RepoEntry($key) {
    return $script:ReposJson.repos | Where-Object { $_.key -eq $key } | Select-Object -First 1
}
```

> `Invoke-RestMethod` auto-parses JSON into objects, so no separate jq step is needed.

- [ ] **Step 2: Add `Select-Repos`**

```powershell
function Select-Repos {
    $script:SelectedKeys = @()

    if ($BaseOnly) {
        Print-Info "Base-only mode — no repositories will be cloned"
        return
    }

    if ($Repos) {
        foreach ($k in ($Repos -split ",")) {
            $k = $k.Trim()
            if (-not $k) { continue }
            if (Get-RepoEntry $k) { $script:SelectedKeys += $k }
            else { Print-Warning "Unknown repo key '$k' — skipping" }
        }
        return
    }

    Print-Step "Checking which repos you can access..."
    $accessible = @()
    foreach ($r in $script:ReposJson.repos) {
        gh repo view $r.slug *> $null
        if ($LASTEXITCODE -eq 0) { $accessible += $r }
    }
    if ($accessible.Count -eq 0) {
        Print-Warning "Couldn't verify repo access — showing the full list"
        $accessible = $script:ReposJson.repos
    }

    Write-Host ""
    Write-Host "Which repositories do you want to clone?"
    for ($i = 0; $i -lt $accessible.Count; $i++) {
        $n = $i + 1
        Write-Host ("  {0}) {1} — {2}" -f $n, $accessible[$i].name, $accessible[$i].description)
    }
    Write-Host "  0) None (base tools only)"
    Write-Host ""
    $answer = Read-Host "Enter numbers separated by spaces or commas (default: 1)"
    if (-not $answer) { $answer = "1" }
    $answer = $answer -replace ",", " "

    foreach ($tok in ($answer -split "\s+")) {
        if (-not $tok) { continue }
        if ($tok -eq "0") { $script:SelectedKeys = @(); return }
        if ($tok -match '^\d+$') {
            $idx = [int]$tok - 1
            if ($idx -ge 0 -and $idx -lt $accessible.Count) {
                $script:SelectedKeys += $accessible[$idx].key
            } else {
                Print-Warning "Ignoring out-of-range choice: $tok"
            }
        }
    }
}
```

- [ ] **Step 3: Add `Install-ShellHelpers`**

```powershell
function Install-ShellHelpers {
    Print-Step "Installing shell helpers..."
    $helpers = @{ "ripgrep" = "rg"; "fd" = "fd"; "bat" = "bat"; "fzf" = "fzf"; "delta" = "delta" }
    foreach ($h in $helpers.GetEnumerator()) {
        if (-not (Test-CommandExists $h.Value)) {
            scoop install $h.Key 2>$null
        }
    }
    Refresh-Path
    Print-Success "Shell helpers installed"
}
```

- [ ] **Step 4: Add `Install-HqExtras`**

```powershell
function Install-HqExtras {
    Print-Step "Installing HQ media/doc tools..."
    $scoopTools = @{
        "ffmpeg"="ffmpeg"; "exiftool"="exiftool"; "yt-dlp"="yt-dlp"; "pandoc"="pandoc";
        "imagemagick"="magick"; "yq"="yq"; "miller"="mlr"; "sd"="sd"; "gawk"="gawk"; "eza"="eza"
    }
    foreach ($t in $scoopTools.GetEnumerator()) {
        if (-not (Test-CommandExists $t.Value)) { scoop install $t.Key 2>$null }
    }
    Refresh-Path
    if (-not (Test-CommandExists "marp")) { bun install -g @marp-team/marp-cli 2>$null }
    if (-not (Test-CommandExists "gswin64c") -and -not (Test-CommandExists "gs")) {
        winget install --id ArtifexSoftware.GhostScript --accept-source-agreements --accept-package-agreements -e 2>$null
        Refresh-Path
    }
    Print-Success "HQ tools installed"
}
```

- [ ] **Step 5: Add recipes + dispatch**

```powershell
function Repair-LfsIfNeeded($dir) {
    $testFile = "$dir\templates\powerpoint\irrational_labs_powerpoint_template_3.pptx"
    $needs = $true
    if (Test-Path $testFile) { if ((Get-Item $testFile).Length -ge $LFS_MIN_SIZE) { $needs = $false } }
    if ($needs) {
        Print-Info "Downloading LFS files..."
        Set-Location $dir; git lfs install --local; git lfs pull
        Print-Success "LFS files downloaded"
    } else { Print-Success "LFS files verified" }
}

function Install-PrecommitHook($dir) {
    Set-Location $dir
    if (-not (Test-Path ".git\hooks")) { New-Item -ItemType Directory -Path ".git\hooks" -Force | Out-Null }
    $hook = @'
#!/bin/sh
PROJECT_ROOT=$(git rev-parse --show-toplevel)
if ! bun run "$PROJECT_ROOT/scripts/validate_filenames.ts" --staged --quiet; then
    printf "\nCommit rejected: filenames contain Windows-incompatible characters.\n\n"
    exit 1
fi
exit 0
'@
    Set-Content -Path ".git\hooks\pre-commit" -Value $hook -NoNewline
    Print-Success "Pre-commit hook installed"
}

function Load-HqSecrets($dir) {
    Set-Location $dir
    if (Test-Path ".env") {
        Print-Info ".env already exists"
    } else {
        Print-Info "Fetching secrets from Infisical..."
        try { bun run scripts/load_infisical_env.ts; Print-Success "Secrets loaded to .env" }
        catch { $script:Warnings += "HQ: could not load Infisical secrets — ask an admin"; Print-Warning "Could not load secrets" }
    }
}

function Setup-Hq($dir) {
    Print-Step "Running HQ setup..."
    Install-HqExtras
    Repair-LfsIfNeeded $dir
    Set-Location $dir
    bun install
    Install-PrecommitHook $dir
    Load-HqSecrets $dir
    Print-Success "HQ setup complete"
}

function Setup-Generic($dir) {
    $base = Split-Path $dir -Leaf
    Print-Step "Running generic setup for $base..."
    Set-Location $dir
    if (Test-Path "package.json") {
        Print-Info "Found package.json — running bun install"
        try { bun install } catch { $script:Warnings += "$base: bun install failed" }
    }
    if ((Test-Path ".gitattributes") -and (Select-String -Path ".gitattributes" -Pattern "filter=lfs" -Quiet)) {
        Print-Info "Repo uses Git LFS — pulling LFS files"
        git lfs install --local 2>$null | Out-Null
        git lfs pull
    }
    if (-not (Test-Path ".env")) {
        $example = $null
        if (Test-Path ".env.example") { $example = ".env.example" }
        elseif (Test-Path ".env.sample") { $example = ".env.sample" }
        if ($example) {
            Copy-Item $example ".env"
            Print-Info "Created .env from $example — fill in secrets before use"
            $script:Warnings += "$base: created .env from $example — needs your secrets"
        }
    }
    Print-Success "$base ready — check its README for any extra setup"
}

function Clone-AndSetupRepo($key) {
    $entry = Get-RepoEntry $key
    if (-not $entry) { Print-Warning "Unknown repo key '$key' — skipping"; return }
    $target = "$HOME\$($entry.dir)"
    Print-Step "Setting up $($entry.slug)..."

    if (Test-Path "$target\.git") {
        Print-Info "Already cloned — pulling latest"
        Set-Location $target; git pull --ff-only 2>$null
    } else {
        gh repo clone $entry.slug $target
        if ($LASTEXITCODE -ne 0) {
            $script:Warnings += "Could not clone $($entry.slug) — check your GitHub access"
            Print-Error "Failed to clone $($entry.slug) (continuing)"
            return
        }
        Print-Success "Cloned $($entry.slug)"
    }

    switch ($entry.setup) {
        "hq"      { Setup-Hq $target }
        "generic" { Setup-Generic $target }
        default   { Setup-Generic $target }
    }
}
```

- [ ] **Step 6: Update `Verify-Setup` + `Print-Completion` for warnings**

In `Verify-Setup`, add `jq` to `$criticalCmds` and drop the fixed HQ pptx LFS check. In `Print-Completion`, before "Next steps", add:

```powershell
    if ($script:Warnings.Count -gt 0) {
        Write-Host ""
        Write-Host "Heads up — a few things need attention:" -ForegroundColor Yellow
        foreach ($w in $script:Warnings) { Write-Host "  • $w" -ForegroundColor Yellow }
    }
```

And change the hard-coded `cd ~\irrational_labs_hq; claude` next-step to a generic "cd into a cloned repo and run: claude".

- [ ] **Step 7: Manual review**

Read the full `bootstrap.ps1` diff. Confirm every `bootstrap.sh` function has a PowerShell counterpart (parity map in Task 12). Note Windows run for Task 12.

- [ ] **Step 8: Commit**

```bash
git add bootstrap.ps1
git commit -m "feat(windows): manifest, repo selection, helpers, dispatch + recipes"
```

---

## Task 10: Update `README.md`

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Rewrite the body**

Replace the README contents with:

```markdown
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

1. Installs base tools: Git, Git LFS, GitHub CLI, jq, Bun, Claude Code, and shell helpers (ripgrep, fd, bat, fzf, delta).
2. Signs you in to GitHub and sets your commit identity.
3. Registers the IL Claude Code plugins.
4. **Asks which repositories to clone** — the menu only shows repos your GitHub account can access.
5. For **Irrational Labs HQ**, runs its full setup (media tools, Git LFS, dependencies, secrets). Other repos get a generic best-effort setup (dependencies, LFS, `.env` scaffold).

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
```

- [ ] **Step 2: Verify the flagged macOS invocation form**

Run: `bash -c 'echo "$0 / $1 / $2"' _ --repos hq,marketing`
Expected: `_ / --repos / hq,marketing` — confirms the `_ --flag` arg form reaches `$@`.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: document menu, flags, and adding repos to the manifest"
```

---

## Task 11 (optional): CI lint + manifest validity

**Files:**
- Create: `.github/workflows/lint.yml`

- [ ] **Step 1: Add a lightweight CI check**

```yaml
name: lint
on: [push, pull_request]
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Validate repos.json
        run: jq empty repos.json && jq -e '.repos | length > 0' repos.json
      - name: ShellCheck bootstrap.sh
        run: sudo apt-get update && sudo apt-get install -y shellcheck && shellcheck -S warning bootstrap.sh
      - name: PSScriptAnalyzer bootstrap.ps1
        shell: pwsh
        run: |
          Install-Module PSScriptAnalyzer -Force -Scope CurrentUser
          $r = Invoke-ScriptAnalyzer -Path bootstrap.ps1 -Severity Error
          if ($r) { $r | Format-Table; exit 1 }
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/lint.yml
git commit -m "ci: lint bootstrap scripts and validate repos.json"
```

---

## Task 12: Parity map + manual test matrix

**Files:** none (verification + docs only)

- [ ] **Step 1: Build the parity function map**

Confirm every functional step exists in both scripts (mechanics may differ):

```bash
grep -oE '^(function )?[A-Za-z_-]+ ?\(?\)?' bootstrap.sh | sed 's/() *{//' | sort -u > /tmp/sh.txt
grep -oE '^function [A-Za-z-]+' bootstrap.ps1 | sed 's/function //' | sort -u > /tmp/ps.txt
echo "=== sh ===" && cat /tmp/sh.txt && echo "=== ps1 ===" && cat /tmp/ps.txt
```

Expected: each bash stage (`ensure_early_tools`↔`Ensure-EarlyTools`, `load_manifest`↔`Load-Manifest`, `select_repos`↔`Select-Repos`, `install_shell_helpers`↔`Install-ShellHelpers`, `clone_and_setup_repo`↔`Clone-AndSetupRepo`, `setup_hq`↔`Setup-Hq`, `setup_generic`↔`Setup-Generic`, plus `Ensure-IlClaudePlugins`) has a counterpart. Note any gap and fix.

- [ ] **Step 2: macOS manual matrix**

On a Mac (ideally a fresh user or VM), run and confirm each:
- [ ] Default: menu appears after Claude install; pick HQ → full setup completes.
- [ ] Re-run: skips installed tools, re-shows menu (idempotency).
- [ ] `… bootstrap.sh) _ --base-only` → no clone, base tools present.
- [ ] `… bootstrap.sh) _ --repos hq,marketing` → both cloned; HQ full, marketing generic.
- [ ] A teammate without engagement access: that repo row is absent from the menu.

- [ ] **Step 3: Windows manual matrix**

On Windows, repeat the equivalent runs. Specifically verify the two parity fixes:
- [ ] `~/.claude/settings.json` gains the `irrational-labs-plugins` marketplace + default-on plugins.
- [ ] Manually set one plugin to `false`, re-run → it stays `false` (explicit disable preserved).
- [ ] `claude` resolves in a new terminal (PATH persisted).

- [ ] **Step 4: Final commit (if any fixes)**

```bash
git add -A
git commit -m "test: parity map verified + manual matrix fixes"
```

---

## Self-Review (completed by plan author)

- **Spec coverage:** hybrid access-filtered menu (Task 4/9), HQ-special + generic (Task 5/9), lean base + shell helpers split (Tasks 3,5/9), interactive + flags (Tasks 2,4/7,9), `repos.json` single source + fallback (Tasks 1,4,9), Claude-up ordering (Tasks 3,7), Windows parity gaps (Task 8), error isolation + warnings (Tasks 5,6,9), testing (Tasks 11,12). All spec sections map to tasks.
- **Placeholders:** none — every code step shows complete code; `setup` metadata and flag forms are concrete.
- **Type/name consistency:** `repo_field`/`Get-RepoEntry`, `SELECTED_KEYS`/`$script:SelectedKeys`, `WARNINGS`/`$script:Warnings`, `setup_hq`/`Setup-Hq`, `setup_generic`/`Setup-Generic` used consistently across tasks.
- **Bash 3.2 + set -u:** empty-array expansions guarded in `main` and `print_completion`; no associative arrays / `mapfile`.
```
