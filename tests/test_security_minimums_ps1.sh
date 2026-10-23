#!/usr/bin/env bash
# tests/test_security_minimums_ps1.sh — Ensure-SecurityMinimums from
# bootstrap.ps1 against a stubbed `winget` and fake node.exe files. Nothing
# real is installed or upgraded. Same cases as tests/test_security_minimums.sh.
#
# Runs under pwsh on macOS or Linux. bootstrap.ps1 runs Main when loaded, so
# this pulls just the functions and the security block out of it with the
# PowerShell parser. The registry lookups find nothing off Windows, so Node
# from the installer is found the fallback way, under $env:ProgramFiles.
#
# Usage:  bash tests/test_security_minimums_ps1.sh      (needs pwsh on PATH)
#         PWSH=/path/to/pwsh bash tests/test_security_minimums_ps1.sh
set -u
cd "$(dirname "$0")/.." || exit 1
PWSH="${PWSH:-pwsh}"
command -v "$PWSH" >/dev/null 2>&1 || { echo "SKIP: pwsh not found (set PWSH=...)"; exit 0; }

T="$(mktemp -d "${TMPDIR:-/tmp}/secmin-ps1.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT

cat > "$T/test.ps1" <<'PS1'
param([string]$Bootstrap, [string]$Tmp)
$ErrorActionPreference = "Stop"

# Load every function plus the security block's variables, without running Main.
$ast = [System.Management.Automation.Language.Parser]::ParseFile($Bootstrap, [ref]$null, [ref]$null)
foreach ($f in $ast.FindAll({ $args[0] -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($f.Extent.Text))
}
foreach ($a in $ast.EndBlock.Statements | Where-Object { $_.Extent.Text -match '^\$SECURITY_' }) {
    . ([scriptblock]::Create($a.Extent.Text))
}
function Refresh-Path {}   # keep the fake PATH

$script:fail = 0
function Check([bool]$ok, [string]$what) {
    if ($ok) { Write-Host "  ok    $what" } else { Write-Host "  FAIL  $what"; $script:fail = 1 }
}

# A fake PC in $F. State lives in files so `winget upgrade` changes what the next run sees:
#   $F\winget-id        the id winget says manages Node (absent: winget doesn't know it)
#   $F\pf\nodejs\       the installer's Node; version in $F\node-version
#   $F\winget.log       every winget upgrade call
function New-Fake {
    $script:F = Join-Path $Tmp ([guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path "$F/pf" | Out-Null
    Set-Content "$F/winget.log" -Value $null
    $env:ProgramFiles = "$F/pf"
    $env:PATH = "/usr/bin:/bin"
    $script:Warnings = @()
    $script:FakeBb = $null
}
function Write-FakeNode([string]$Path, [string]$VersionFile) {
    Set-Content $Path -Value "#!/bin/bash`necho v`$(cat '$VersionFile')"
    chmod +x $Path
}
# Node from the Node.js installer, on PATH; -Winget also tells winget about it.
function Installer-Node([string]$Version, [string]$Id = "") {
    New-Item -ItemType Directory -Path "$F/pf/nodejs" -Force | Out-Null
    Set-Content "$F/node-version" -Value $Version
    Write-FakeNode "$F/pf/nodejs/node.exe" "$F/node-version"
    Write-FakeNode "$F/pf/nodejs/node" "$F/node-version"   # what Get-Command finds off Windows
    $env:PATH = "$F/pf/nodejs:$env:PATH"
    if ($Id) { Set-Content "$F/winget-id" -Value $Id }
}
# A node first on PATH that winget doesn't manage (nvm-windows).
function Nvm-Node([string]$Version) {
    New-Item -ItemType Directory -Path "$F/nvm" -Force | Out-Null
    Set-Content "$F/nvm-version" -Value $Version
    Write-FakeNode "$F/nvm/node" "$F/nvm-version"
    $env:PATH = "$F/nvm:$env:PATH"
}
function winget {
    $id = $args[2]
    if ($args[0] -eq "list") {
        if ((Test-Path "$F/winget-id") -and (Get-Content "$F/winget-id") -eq $id) {
            "Name     Id          Version"; "Node.js  $id  x"; $global:LASTEXITCODE = 0
        } else { "No installed package found matching input criteria."; $global:LASTEXITCODE = -1978335212 }
    } elseif ($args[0] -eq "upgrade") {
        Add-Content "$F/winget.log" -Value ($args -join " ")
        if (-not (Test-Path "$F/winget-has-no-fix")) { Set-Content "$F/node-version" -Value "26.12.1" }
        $global:LASTEXITCODE = 0
    }
}
function Test-BbInstalled { return [bool]$script:FakeBb }
function Upgrades { return @(Get-Content "$F/winget.log" | Where-Object { $_ }) }
function Run-Step { return (Ensure-SecurityMinimums 6>&1 | Out-String) }

$expect = "upgrade --id OpenJS.NodeJS -e --accept-source-agreements --accept-package-agreements"

# Old winget node: upgraded once, then up to date.
New-Fake; Installer-Node "24.9.0" "OpenJS.NodeJS"
$out = Run-Step
Check ((Upgrades) -join "|" -eq $expect) "old winget node: winget upgrade with both agreements"
Check ($out -match "Security updates installed") "reports the upgrade"
Check ($out -notmatch "Quit and reopen bb") "no bb line when bb is not installed"
$out = Run-Step
Check ((Upgrades).Count -eq 1) "second run upgrades nothing"
Check ($out -match "Security updates: up to date") "second run says up to date"

# bb installed + node upgraded: restart bb.
New-Fake; Installer-Node "26.11.0" "OpenJS.NodeJS"; $script:FakeBb = "C:\bb"
$out = Run-Step
Check ($out -match "Quit and reopen bb so it picks up the new Node\.") "bb installed + node upgraded: restart bb"

# The LTS package id is upgraded under its own id.
New-Fake; Installer-Node "22.11.0" "OpenJS.NodeJS.LTS"
Run-Step | Out-Null
Check ((Upgrades) -join "|" -eq ($expect -replace "NodeJS ", "NodeJS.LTS ")) "OpenJS.NodeJS.LTS: upgraded by that id"

# End-of-life lines get upgraded.
foreach ($v in "20.19.5", "25.1.0", "18.20.0", "23.0.0") {
    New-Fake; Installer-Node $v "OpenJS.NodeJS"
    Run-Step | Out-Null
    Check ((Upgrades).Count -eq 1) "end-of-life Node $v gets upgraded"
}

# Current versions: nothing happens.
foreach ($v in "26.12.1", "24.22.1", "22.23.4", "26.13.0", "27.0.0") {
    New-Fake; Installer-Node $v "OpenJS.NodeJS"; $script:FakeBb = "C:\bb"
    $out = Run-Step
    Check ((Upgrades).Count -eq 0) "Node ${v}: no upgrade"
    Check ($out -match "Security updates: up to date") "Node ${v}: up to date"
    Check ($out -notmatch "Quit and reopen bb") "Node ${v}: no bb line"
}

# nvm node: one plain-English line, no winget.
New-Fake; Nvm-Node "22.10.0"
$out = Run-Step
Check ((Upgrades).Count -eq 0) "nvm node: winget upgrade never runs"
Check ($out -match "wasn't installed by winget, so setup left it alone") "nvm node: one plain-English line"
Check (([regex]::Matches($out, "Node 22\.10\.0")).Count -eq 1) "nvm node: said once"
Check ($script:Warnings.Count -eq 1) "nvm node: in the end-of-run warnings"

# Old installer node winget doesn't know: same as nvm.
New-Fake; Installer-Node "24.1.0"
$out = Run-Step
Check ((Upgrades).Count -eq 0) "installer node unknown to winget: not upgraded"
Check ($out -match "left it alone") "installer node unknown to winget: told what to do"

# nvm node ahead of an old winget node: winget's still upgraded, no message.
New-Fake; Installer-Node "24.1.0" "OpenJS.NodeJS"; Nvm-Node "24.22.1"
$out = Run-Step
Check ((Upgrades).Count -eq 1) "winget node behind nvm still upgraded"
Check ($out -notmatch "left it alone") "current nvm node: no message"

# winget has no fixed version yet: say so, don't claim success.
New-Fake; Installer-Node "24.9.0" "OpenJS.NodeJS"; Set-Content "$F/winget-has-no-fix" -Value 1; $script:FakeBb = "C:\bb"
$out = Run-Step
Check ($out -match "Some security updates failed" -and $out -notmatch "Security updates installed") "upgrade that changes nothing: reported as failed"
Check ($out -notmatch "Quit and reopen bb") "upgrade that changes nothing: no bb line"

# No node at all.
New-Fake
$out = Run-Step
Check ((Upgrades).Count -eq 0 -and $out -match "Security updates: up to date") "no node: nothing upgraded, up to date"

$cases = @(@("24.9.0","24.22.1",$true), @("24.22.1","24.22.1",$false), @("2026.10.19","2026.8.3",$false), @("v24.9.0","24.22.1",$true))
Check (@($cases | Where-Object { (Test-VersionLt $_[0] $_[1]) -ne $_[2] }).Count -eq 0) "Test-VersionLt compares numerically"

exit $script:fail
PS1

"$PWSH" -NoProfile -NonInteractive -File "$T/test.ps1" -Bootstrap "$PWD/bootstrap.ps1" -Tmp "$T"
rc=$?
if [ "$rc" -eq 0 ]; then echo "OK: all bootstrap.ps1 security minimums tests passed"; else echo "FAILURES in bootstrap.ps1 security minimums tests"; fi
exit "$rc"
