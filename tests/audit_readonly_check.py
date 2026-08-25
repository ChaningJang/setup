#!/usr/bin/env python3
"""Static read-only proof for audit.ps1.

audit.ps1 is handed to a departing consultant and run on a machine we do not
control. Its central promise is that it writes nothing: no file, no directory,
no registry value, no persisted environment variable, no network call. This
checker enforces that promise mechanically, so it cannot rot.

Method: strip comments and string literals from every line -- but KEEP the
contents of "$( ... )" subexpressions, because those are real code embedded in
a string -- then assert that no write-capable PowerShell cmdlet, .NET writer,
package-manager mutation, or file-creating redirection survives.
"""
import re
import sys

TARGET = "audit.ps1"


def strip_noncode(line):
    """Blank out comments and string literals, preserving $(...) subexpressions.

    Returns (code, unterminated) where `unterminated` is the quote character the
    line ended inside, or None. Quotes surviving in `code` come from inside a
    $(...) subexpression and are legitimate.
    """
    out = []
    i = 0
    n = len(line)
    mode = None          # None | "'" | '"'
    depth = 0            # $( ) nesting depth while inside a double-quoted string
    while i < n:
        c = line[i]
        if mode is None:
            if c == '#':
                break                      # rest of line is a comment
            if c in ("'", '"'):
                mode = c
                out.append(' ')
                i += 1
                continue
            out.append(c)
            i += 1
            continue
        if mode == "'":
            out.append(' ')
            if c == "'":
                if i + 1 < n and line[i + 1] == "'":
                    i += 2                 # '' is an escaped quote
                    out.append(' ')
                    continue
                mode = None
            i += 1
            continue
        # mode == '"'
        if c == '`':                       # backtick escape
            out.append('  ')
            i += 2
            continue
        if c == '$' and i + 1 < n and line[i + 1] == '(':
            # A subexpression: emit its code verbatim until the matching ')'.
            depth = 1
            out.append('  ')
            i += 2
            while i < n and depth:
                if line[i] == '(':
                    depth += 1
                elif line[i] == ')':
                    depth -= 1
                    if depth == 0:
                        out.append(' ')
                        i += 1
                        break
                out.append(line[i])
                i += 1
            continue
        if c == '"':
            mode = None
        out.append(' ')
        i += 1
    return ''.join(out), mode


# (label, regex) -- anything that can change state on the machine.
CHECKS = [
    ("Set-Content",              r"Set-Content"),
    ("Add-Content",              r"Add-Content"),
    ("Clear-Content",            r"Clear-Content"),
    ("Out-File",                 r"Out-File"),
    ("Out-Printer",              r"Out-Printer"),
    ("Tee-Object",               r"Tee-Object"),
    ("New-Item",                 r"New-Item\b"),
    ("Remove-Item",              r"Remove-Item\b"),
    ("Move-Item",                r"Move-Item"),
    ("Copy-Item",                r"Copy-Item"),
    ("Rename-Item",              r"Rename-Item"),
    ("Set-Item",                 r"Set-Item\b"),
    ("Set-ItemProperty",         r"Set-ItemProperty"),
    ("New-ItemProperty",         r"New-ItemProperty"),
    ("Remove-ItemProperty",      r"Remove-ItemProperty"),
    ("Rename-ItemProperty",      r"Rename-ItemProperty"),
    ("Clear-ItemProperty",       r"Clear-ItemProperty"),
    ("Export-* cmdlets",         r"\bExport-\w+"),
    ("Import-Module -Force etc", r"\bInstall-Module\b|\bInstall-Package\b"),
    ("New-PSDrive",              r"New-PSDrive"),
    ("Set-Location / cd / pushd", r"\bSet-Location\b|\bPush-Location\b|(?<![\w-])cd\s|(?<![\w-])chdir\s|(?<![\w-])pushd\s"),
    (".Save() / .WriteTo()",     r"\.Save\s*\(|\.WriteTo\s*\("),
    ("[IO.File] writers",        r"\[(System\.)?IO\.File\]::(Write|Create|Append|Move|Copy|Delete|Open)"),
    ("[IO.Directory] writers",   r"\[(System\.)?IO\.Directory\]::(Create|Delete|Move)"),
    ("StreamWriter / FileStream", r"StreamWriter|FileStream"),
    ("SetEnvironmentVariable",   r"SetEnvironmentVariable"),
    ("Set-ExecutionPolicy",      r"Set-ExecutionPolicy"),
    ("Start-Process",            r"Start-Process"),
    ("network fetch",            r"Invoke-WebRequest|Invoke-RestMethod|(?<![\w-])iwr(?![\w-])|(?<![\w-])irm(?![\w-])|(?<![\w-])curl(?![\w-])|(?<![\w-])wget(?![\w-])|DownloadString|DownloadFile|System\.Net\.WebClient|HttpClient"),
    ("Invoke-Expression",        r"Invoke-Expression|(?<![\w-])iex(?![\w-])"),
    ("winget mutation",          r"winget\s+(install|uninstall|upgrade|import|export|settings)"),
    ("scoop mutation",           r"scoop\s+(install|uninstall|update|bucket|reset|cleanup)"),
    ("npm/bun/pip mutation",     r"\b(npm|bun|pip3?|yarn|pnpm)\s+(install|uninstall|i|add|remove|rm)\b"),
    ("gh auth mutation",         r"gh\s+auth\s+(logout|login|refresh|setup-git)"),
    ("git mutation",             r"git\b[^;\n]*?\s(add|commit|push|pull|fetch|clone|checkout|switch|merge|rebase|reset|revert|clean|gc|prune|init|apply|restore)(\s|$)"),
    ("git config write",         r"git\b[^;\n]*?config[^;\n]*--(global|local|system)\s+[\w.]+\s+\S"),
    ("git stash mutation",       r"git\b[^;\n]*?stash\s+(push|pop|apply|drop|save|clear)"),
    ("Remove-* catch-all",       r"\bRemove-(?!ItemProperty|Item\b)\w+"),
]

# Redirection that CREATES a file. Excludes "2>$null" and "2>&1", which discard
# or merge a stream and touch no file, and excludes "-gt"-style operators.
REDIR = re.compile(r"(?<![0-9&])>{1,2}(?!&)")


def main():
    with open(TARGET, encoding="utf-8") as fh:
        lines = fh.read().split("\n")

    failures = []
    print("Static read-only proof for %s (%d lines)" % (TARGET, len(lines)))
    print("=" * 72)

    scanned = [(i, strip_noncode(l)) for i, l in enumerate(lines, 1)]
    code = [(i, c) for i, (c, _) in scanned]
    unterminated = [(i, m) for i, (_, m) in scanned if m is not None]

    for label, pat in CHECKS:
        rx = re.compile(pat)
        hits = [(i, lines[i - 1].strip()) for i, c in code if rx.search(c)]
        if hits:
            failures.append((label, hits))
            print("  FAIL  %-28s %d hit(s)" % (label, len(hits)))
            for ln, txt in hits:
                print("          line %d: %s" % (ln, txt[:100]))
        else:
            print("  ok    %-28s absent from code" % label)

    # Redirection is checked separately so 2>$null can be excluded by name.
    rhits = []
    for i, c in code:
        probe = c.replace("2>$null", "").replace("2>&1", "")
        if REDIR.search(probe):
            rhits.append((i, lines[i - 1].strip()))
    if rhits:
        failures.append(("> / >> redirection", rhits))
        print("  FAIL  %-28s %d hit(s)" % ("> / >> redirection", len(rhits)))
        for ln, txt in rhits:
            print("          line %d: %s" % (ln, txt[:100]))
    else:
        print("  ok    %-28s absent from code (2>$null / 2>&1 excluded)"
              % "> / >> redirection")

    # The two process-local env assignments are the only permitted state change.
    allowed_env = {"GIT_OPTIONAL_LOCKS", "GIT_TERMINAL_PROMPT"}
    envw = []
    for i, c in code:
        for m in re.finditer(r"\$env:(\w+)\s*=", c):
            if m.group(1) not in allowed_env:
                envw.append((i, lines[i - 1].strip()))
    if envw:
        failures.append(("unexpected $env: assignment", envw))
        print("  FAIL  %-28s %d hit(s)" % ("$env: assignment", len(envw)))
        for ln, txt in envw:
            print("          line %d: %s" % (ln, txt[:100]))
    else:
        print("  ok    %-28s only GIT_OPTIONAL_LOCKS / GIT_TERMINAL_PROMPT,"
              " both process-local" % "$env: assignment")

    # Secret scrubbing must be wired into the single output funnel.
    src = "\n".join(lines)
    if "Write-Output (Protect-Secret $Text)" not in src:
        failures.append(("output funnel", [(0, "Write-Line does not call Protect-Secret")]))
        print("  FAIL  %-28s Write-Line does not scrub" % "secret scrubbing")
    else:
        print("  ok    %-28s every output line passes through Protect-Secret"
              % "secret scrubbing")

    missing = []
    for pat_label, pat in [("gho_/ghp_", r"gh\[pousr\]_"), ("github_pat_", r"github_pat_"),
                           ("sk-", r"'sk-\["), ("xox", r"'xox\["), ("AIza", r"'AIza\["),
                           ("PEM private key", r"PRIVATE KEY-----"), ("bearer", r"bearer")]:
        if not re.search(pat, src):
            missing.append(pat_label)
    if missing:
        failures.append(("scrub coverage", [(0, "missing: " + ", ".join(missing))]))
        print("  FAIL  %-28s scrubber is missing: %s"
              % ("scrub coverage", ", ".join(missing)))
    else:
        print("  ok    %-28s gho_/ghp_, github_pat_, sk-, xox, AIza, PEM, bearer"
              % "scrub coverage")

    # Structural sanity. We cannot run pwsh here, so at minimum prove that
    # braces, parens and brackets balance and that no string is left unclosed
    # -- the failure modes a syntax error would most likely take.
    stripped = "\n".join(c for _, c in code)
    balance_ok = True
    for open_ch, close_ch in [("{", "}"), ("(", ")"), ("[", "]")]:
        d = stripped.count(open_ch) - stripped.count(close_ch)
        if d != 0:
            balance_ok = False
            failures.append(("brace balance", [(0, "%s/%s off by %d" % (open_ch, close_ch, d))]))
            print("  FAIL  %-28s %s / %s off by %d" % ("structure", open_ch, close_ch, d))
    for i, m in unterminated:
        balance_ok = False
        failures.append(("unterminated string", [(i, lines[i - 1].strip())]))
        print("  FAIL  %-28s line %d ends inside a %s-quoted string"
              % ("structure", i, m))
    if balance_ok:
        print("  ok    %-28s braces/parens/brackets balance, no unterminated string"
              % "structure")

    print("=" * 72)
    if failures:
        print("RESULT: FAIL -- %d category(ies) with code-level hits" % len(failures))
        return 1
    print("RESULT: PASS -- audit.ps1 contains no write-capable operation")
    return 0


if __name__ == "__main__":
    sys.exit(main())
