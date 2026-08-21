<#
.SYNOPSIS
    Deploy the Ratchet harness into a target repository (Windows).

.DESCRIPTION
    Ratchet is a gated autonomous-delivery harness for Claude Code: the run
    moves forward or it stops, and it never quietly slides back. This script is
    the Windows half of install.sh, and it is feature-equivalent.

    THE PROMISE THIS SCRIPT MAKES:
      IT WILL NOT DAMAGE AN EXISTING PROJECT.
      - An existing .claude\settings.json is MERGED, never overwritten, and is
        backed up first.
      - An existing CLAUDE.md is never clobbered; CLAUDE.ratchet.md is written
        instead and you are told.
      - Human-owned documents (.context\, docs\, .agent-development\) are
        written only when ABSENT.
      - -WhatIf prints every action and performs none.
      - Re-running is an upgrade, not a reinstall. It is idempotent.

    WINDOWS SPECIFICS THAT ACTUALLY MATTER, stated plainly:

    1. THE HOOKS ARE BASH SCRIPTS AND THAT IS NOT NEGOTIABLE IN v1. Claude Code
       runs them through a shell. On Windows that shell is Git-Bash (shipped
       with Git for Windows) or WSL. If neither is present this script FAILS
       rather than installing a harness whose every gate would error out. It
       records which bash it found in .claude\hooks\.ratchet-bash so you can
       see, later, what the gates are actually running under.

    2. LINE ENDINGS. A hook file saved with CRLF has a shebang line reading
       "#!/usr/bin/env bash\r", and the kernel then looks for an interpreter
       literally named "bash\r". The error says "bad interpreter: no such file
       or directory" while naming a file that plainly exists, which is one of
       the more expensive ten minutes in Windows development. Every file this
       script writes is written LF, and it checks your core.autocrlf setting
       and tells you what to do about it.

    3. FILE PERMISSIONS ON secrets\. There is no chmod. This script removes
       inherited ACLs from secrets\ and grants only the current user, which is
       the closest Windows equivalent to 0700 -- but be honest with yourself
       about what that is and is not: it stops another standard user account
       reading the escalation key. It does not stop an administrator, and it
       does not stop anything at all if the folder ends up in OneDrive or on a
       network share. The control that actually matters is that secrets\ is
       gitignored, and this script VERIFIES that rather than assuming it.

    4. THE WINDOWS STORE PYTHON STUB. "python3" exists on a default Windows 11
       PATH and does nothing except open the Microsoft Store. Testing for the
       command's existence therefore proves nothing. This script runs the
       interpreter and requires it to print a 3.

.PARAMETER Target
    Repository to install into. Default: the current directory.

.PARAMETER Stack
    python-pytest | node-jest | generic. Default: auto-detected.

.PARAMETER ProjectName
    Human label used in pager payloads and the recap. Default: repo folder name.

.PARAMETER Domain
    none | interactive. Whether to run the domain interview. Default: none.

.PARAMETER EscalationMode
    light | strict. Default: light.

.PARAMETER BaseBranch
    The protected branch. Default: detected, else main.

.PARAMETER Force
    Proceed despite modified tracked files.

.PARAMETER Uninstall
    Reverse the install, restoring the pre-Ratchet settings backup.

.PARAMETER SubstituteOnly
    Only re-run the brace-marker substitution.

.PARAMETER SkipVerify
    Do not run test_hooks.py at the end.

.EXAMPLE
    .\install.ps1 -Target ..\my-repo -Stack python-pytest -ProjectName "My Repo"

.EXAMPLE
    .\install.ps1 -Target ..\my-repo -WhatIf

.NOTES
    PowerShell 5.1 and PowerShell 7 compatible. No modules required.
    Exit codes: 0 ok, 1 installed but verification failed, 2 refused.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]   $Target         = '.',
    [ValidateSet('python-pytest', 'node-jest', 'generic', '')]
    [string]   $Stack          = '',
    [string]   $ProjectName    = '',
    [ValidateSet('none', 'interactive')]
    [string]   $Domain         = 'none',
    [ValidateSet('light', 'strict')]
    [string]   $EscalationMode = 'light',
    [string]   $BaseBranch     = '',
    [switch]   $Force,
    [switch]   $Uninstall,
    [switch]   $SubstituteOnly,
    [switch]   $SkipVerify
)

# StrictMode 1.0, not 2.0 or Latest. 1.0 catches the bug that actually bites a
# script like this -- a typo'd variable silently evaluating to $null and a
# refusal quietly not happening. 2.0 additionally throws on reading a property
# that does not exist, which would make every defensive "does this JSON have a
# permissions key" check throw instead of answering.
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Continue'   # NOT Stop: a failed optional step is
                                      # reported, never allowed to abort a
                                      # half-finished install silently.

$RtInstallerVersion = '1.0.0'
$script:Warnings    = 0
$script:MissingFiles = New-Object System.Collections.Generic.List[string]
$script:HostFatal   = $false

# --------------------------------------------------------------- output ----
function Write-Head { param([string]$Text) Write-Host ''; Write-Host $Text -ForegroundColor White }
function Write-Ok   { param([string]$Text) Write-Host ('  ok    ' + $Text) -ForegroundColor Green }
function Write-Info { param([string]$Text) Write-Host ('  ..    ' + $Text) }
function Write-Warn {
    param([string]$Text)
    Write-Host ('  WARN  ' + $Text) -ForegroundColor Yellow
    $script:Warnings++
}
function Write-Fail { param([string]$Text) Write-Host ('  FAIL  ' + $Text) -ForegroundColor Red }
function Write-Cont { param([string]$Text) Write-Host ('        ' + $Text) }

# -WhatIf plumbing. $PSCmdlet.ShouldProcess is the idiomatic call, but it is an
# automatic variable of the SCRIPT's advanced-function scope, and reaching it
# from inside a plain function relies on dynamic scoping that is easy to break
# by refactoring. This wrapper reads $WhatIfPreference (which -WhatIf sets, and
# which is visible everywhere), prints the action the way install.sh prints its
# DRY lines, and returns $false so the caller skips the work.
function Confirm-Change {
    param([string]$Item, [string]$Action)
    if ($WhatIfPreference) {
        Write-Host ('  DRY   ' + $Action + ': ' + $Item) -ForegroundColor Yellow
        return $false
    }
    return $true
}

function Stop-Install {
    param([string]$Reason)
    Write-Host ''
    Write-Host ('install refused: ' + $Reason) -ForegroundColor Red
    Write-Host ''
    exit 2
}

# Approved-verb helper names below: Test-*, Get-*, Copy-*, Write-*, Install-*,
# Remove-*, Invoke-*, Confirm-*. PSScriptAnalyzer clean on verbs.

# ===========================================================================
# SECTION 1 -- HOST CHECKS, first, before anything on disk is touched.
# ===========================================================================
Write-Head ("RATCHET installer $RtInstallerVersion -- host checks (Windows)")

# --- PowerShell ------------------------------------------------------------
Write-Ok ("PowerShell $($PSVersionTable.PSVersion)")
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Fail 'PowerShell 5.1 or newer is required.'
    $script:HostFatal = $true
}

function Test-Command {
    param([string]$Name)
    $c = Get-Command $Name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source } else { return $null }
}

# --- git -------------------------------------------------------------------
$gitPath = Test-Command 'git'
if ($gitPath) {
    Write-Ok ('git ' + ((& git --version) -split ' ')[2])
} else {
    Write-Fail 'git not found. Ratchet''s gates read the worktree on every hook firing.'
    Write-Cont 'Fix:  winget install Git.Git      (this also gives you Git-Bash, which'
    Write-Cont '      the hooks need -- see the bash check below)'
    $script:HostFatal = $true
}

# --- BASH: the one that people get wrong -----------------------------------
# Every Ratchet hook is a bash script. Claude Code invokes them through a
# shell. On Windows that means Git-Bash or WSL, and if neither exists the
# harness installs perfectly and then fails on the first tool call. Better to
# refuse now and say exactly what to install.
$script:BashPath  = $null
$script:BashKind  = $null

$bashCandidates = @()
$cmdBash = Test-Command 'bash'
if ($cmdBash) { $bashCandidates += ,@($cmdBash, 'PATH') }
$bashCandidates += ,@("$env:ProgramFiles\Git\bin\bash.exe",      'Git-Bash')
$bashCandidates += ,@("${env:ProgramFiles(x86)}\Git\bin\bash.exe",'Git-Bash (x86)')
$bashCandidates += ,@("$env:LOCALAPPDATA\Programs\Git\bin\bash.exe", 'Git-Bash (user)')
$bashCandidates += ,@("$env:SystemRoot\System32\bash.exe",       'WSL')

foreach ($cand in $bashCandidates) {
    $p = $cand[0]; $kind = $cand[1]
    if (-not $p) { continue }
    if (-not (Test-Path -LiteralPath $p)) { continue }
    $ver = & $p -c 'echo ${BASH_VERSINFO[0]}' 2>$null
    if ($LASTEXITCODE -eq 0 -and $ver) {
        $major = 0
        [void][int]::TryParse(("$ver").Trim(), [ref]$major)
        if ($major -ge 4) {
            $script:BashPath = $p
            $script:BashKind = $kind
            Write-Ok ("bash $major via $kind -- $p")
            break
        } else {
            Write-Warn ("found bash $major at $p; Ratchet needs bash 4+. Still looking.")
        }
    }
}

if ($script:BashPath -and $script:BashKind -like 'WSL*') {
    Write-Warn 'The only bash found is WSL, and WSL sees a DIFFERENT FILESYSTEM.'
    Write-Cont 'A WSL bash resolves /mnt/c/... , not C:\... , so a hook handed a Windows'
    Write-Cont 'path will report that a file which plainly exists does not. Ratchet works'
    Write-Cont 'under WSL when the whole workflow lives inside WSL -- clone the repo into'
    Write-Cont 'the WSL filesystem and run Claude Code from there -- but mixing a Windows'
    Write-Cont 'checkout with a WSL shell is the configuration that produces the most'
    Write-Cont 'confusing failures, because every error message names a real file.'
    Write-Cont 'Strong recommendation: install Git for Windows and use Git-Bash instead.'
    Write-Cont '    winget install Git.Git'
}

if (-not $script:BashPath) {
    Write-Fail 'No usable bash found. Every Ratchet hook is a bash script.'
    Write-Cont 'Without one, the harness installs and then every single gate errors'
    Write-Cont 'out on the first tool call -- which looks like Claude Code being'
    Write-Cont 'broken rather than like a missing dependency, so we refuse here.'
    Write-Cont ''
    Write-Cont 'Fix, in order of preference:'
    Write-Cont '  1. Install Git for Windows. It ships Git-Bash, which is what the'
    Write-Cont '     overwhelming majority of Windows Claude Code setups already use:'
    Write-Cont '         winget install Git.Git'
    Write-Cont '     (or https://git-scm.com/download/win)'
    Write-Cont '  2. Or enable WSL:   wsl --install'
    Write-Cont ''
    Write-Cont 'Then re-open your terminal and re-run this script.'
    $script:HostFatal = $true
}

# --- jq (HARD requirement) -------------------------------------------------
$jqPath = Test-Command 'jq'
if (-not $jqPath -and $script:BashPath) {
    # jq may exist inside the Git-Bash tree without being on the Windows PATH.
    $probe = & $script:BashPath -lc 'command -v jq' 2>$null
    if ($LASTEXITCODE -eq 0 -and $probe) { $jqPath = ("$probe").Trim() }
}
if ($jqPath) {
    Write-Ok ("jq found: $jqPath")
} else {
    Write-Fail 'jq not found. This is a HARD requirement, not a nicety.'
    Write-Cont 'Every Ratchet hook parses its payload as JSON. A security decision'
    Write-Cont 'made without a real JSON parser is a guess, so the guards fail'
    Write-Cont 'CLOSED when jq is absent -- meaning every Bash tool call is blocked.'
    Write-Cont 'Installing without jq produces a repo the agent cannot work in.'
    Write-Cont ''
    Write-Cont 'Fix:  winget install jqlang.jq        (or: choco install jq)'
    Write-Cont '      Then confirm the hooks can see it:'
    Write-Cont '          bash -lc "command -v jq"'
    Write-Cont '      If winget put it somewhere Git-Bash cannot see, the blunt fix is'
    Write-Cont '      to copy jq.exe into "C:\Program Files\Git\usr\bin".'
    $script:HostFatal = $true
}

# --- python3, with the Store stub handled explicitly -----------------------
function Get-WorkingPython {
    $cands = @()
    if ($env:RATCHET_PYTHON) { $cands += $env:RATCHET_PYTHON }
    $cands += @('python3', 'python', 'py -3')
    foreach ($c in $cands) {
        $exe = $c; $pre = @()
        if ($c -like '* *') {
            $parts = $c -split ' '
            $exe = $parts[0]; $pre = $parts[1..($parts.Length - 1)]
        }
        if (-not (Test-Command $exe)) { continue }
        # THE STORE STUB TEST. The stub is a real file on PATH named python3.exe
        # that launches the Microsoft Store and exits. It answers "yes" to
        # Get-Command and "no" to actually being Python. Only running it tells
        # you the truth.
        $out = $null
        try {
            $out = & $exe @pre '-c' 'import sys;print(sys.version_info[0])' 2>$null
        } catch { $out = $null }
        if ($LASTEXITCODE -eq 0 -and ("$out").Trim() -eq '3') { return $c }
    }
    return $null
}
$script:Py = Get-WorkingPython
if ($script:Py) {
    $pv = & ($script:Py -split ' ')[0] '-c' 'import sys;print(sys.version.split()[0])' 2>$null
    Write-Ok ("python3 via '$($script:Py)' ($pv)")
} else {
    Write-Fail 'No working Python 3 found (probed $env:RATCHET_PYTHON, python3, python, py -3).'
    Write-Cont 'Four of Ratchet''s gates are Python: check_done.py, check_narrative.py,'
    Write-Cont 'proof_map.py, run_metrics.py. Without an interpreter the ship gate'
    Write-Cont 'cannot evaluate the definition of done, and it fails closed.'
    Write-Cont ''
    Write-Cont 'IF "python3" APPEARED TO EXIST: that was the Microsoft Store stub -- a'
    Write-Cont 'placeholder that opens the Store and exits. It is on the default'
    Write-Cont 'Windows 11 PATH and it fools every check except actually running it.'
    Write-Cont 'Fix either way:'
    Write-Cont '    winget install Python.Python.3.12'
    Write-Cont 'and then turn the stubs off so they stop shadowing the real thing:'
    Write-Cont '    Settings > Apps > Advanced app settings > App execution aliases'
    Write-Cont '    -> switch OFF "python.exe" and "python3.exe"'
    $script:HostFatal = $true
}

# --- gh (warn only) --------------------------------------------------------
if (Test-Command 'gh') {
    & gh auth status *> $null
    if ($LASTEXITCODE -eq 0) { Write-Ok 'gh (authenticated)' }
    else {
        Write-Warn 'gh is installed but not authenticated. The ship flow will fail at the'
        Write-Cont 'last step of your first run. Fix now:  gh auth login'
    }
} else {
    Write-Warn 'gh (GitHub CLI) not found. Everything up to the Ship Prompt works without'
    Write-Cont 'it, but the run ends by opening a PR and merging it, and both are gh.'
    Write-Cont 'Fix:  winget install GitHub.cli    then: gh auth login'
}

# ===========================================================================
# SECTION 2 -- TARGET VALIDATION
# ===========================================================================
Write-Head 'Target'

$SrcDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$HarnessDir = Join-Path $SrcDir 'harness'

if (-not (Test-Path -LiteralPath $Target)) { Stop-Install "target directory does not exist: $Target" }
$TargetPath = (Resolve-Path -LiteralPath $Target).Path

if ($TargetPath -eq $SrcDir) {
    Stop-Install @"
the target is the Ratchet source tree itself ($SrcDir).
  Ratchet installs INTO a project. Point -Target at the repo you want gated:
      .\install.ps1 -Target ..\my-repo
"@
}
if ($TargetPath.StartsWith($HarnessDir, [System.StringComparison]::OrdinalIgnoreCase)) {
    Stop-Install "the target is inside the harness source tree ($HarnessDir)."
}
Write-Ok "target: $TargetPath"

# --- git repo --------------------------------------------------------------
& git -C $TargetPath rev-parse --git-dir *> $null
if ($LASTEXITCODE -ne 0) {
    Stop-Install @"
$TargetPath is not a git repository.
  Ratchet's gates are defined in terms of branches, diffs and a protected base
  branch; there is nothing coherent to install into a non-repo. Fix:
      git -C "$TargetPath" init
      git -C "$TargetPath" commit --allow-empty -m "init"
"@
}
$top = (& git -C $TargetPath rev-parse --show-toplevel 2>$null)
if ($top) {
    $top = (Resolve-Path -LiteralPath ("$top".Trim())).Path
    if ($top -ne $TargetPath) {
        Write-Warn "you pointed at a subdirectory; installing at the repo root instead: $top"
        $TargetPath = $top
    }
}
Write-Ok 'git repository confirmed'

# --- CRLF posture ----------------------------------------------------------
# We always WRITE LF. The remaining risk is that a later `git checkout` hands
# the files back with CRLF, which breaks the shebang line and produces the
# famous "bad interpreter" error naming a file that visibly exists.
$autocrlf = (& git -C $TargetPath config --get core.autocrlf 2>$null)
if ($autocrlf) { $autocrlf = "$autocrlf".Trim() } else { $autocrlf = '(unset)' }
if ($autocrlf -eq 'true') {
    Write-Warn "core.autocrlf is 'true' in this repo."
    Write-Cont 'Every hook file this script writes is LF, which is correct. But with'
    Write-Cont 'autocrlf=true, a future `git checkout` will convert them to CRLF, and a'
    Write-Cont 'CRLF shebang makes the shell look for an interpreter named "bash\r".'
    Write-Cont 'The error it prints ("bad interpreter: no such file or directory") names'
    Write-Cont 'a file that plainly exists, which is why this is worth pre-empting.'
    Write-Cont 'The installer writes a .gitattributes rule to pin the hooks to LF.'
} else {
    Write-Ok "core.autocrlf: $autocrlf"
}

# --- dirty tracked files ---------------------------------------------------
$porcelain = @(& git -C $TargetPath status --porcelain 2>$null)
$dirtyTracked   = @($porcelain | Where-Object { $_ -notmatch '^\?\?' })
$dirtyUntracked = @($porcelain | Where-Object { $_ -match '^\?\?' }).Count
if ($dirtyTracked.Count -gt 0) {
    if ($Force -or $WhatIfPreference -or $SubstituteOnly -or $Uninstall) {
        Write-Warn 'tracked files are modified; continuing (-Force/-WhatIf/-SubstituteOnly/-Uninstall).'
    } else {
        Write-Host ''
        Write-Host 'install refused: the target has modified or staged tracked files.' -ForegroundColor Red
        Write-Host ''
        $dirtyTracked | Select-Object -First 20 | ForEach-Object { Write-Host ('    ' + $_) }
        Write-Host ''
        Write-Host '  This matters more than usual here. The installer writes into .claude\,'
        Write-Host '  .context\ and .gitignore, and merges your settings.json. If any of that'
        Write-Host '  is wrong you will want "git checkout ." to be a complete undo -- and it'
        Write-Host '  only is if nothing tracked was already modified.'
        Write-Host ''
        Write-Host '  Commit or stash, then re-run. Or -Force if you know what you are doing.'
        Write-Host ''
        exit 2
    }
} elseif ($dirtyUntracked -gt 0) {
    Write-Info "worktree has $dirtyUntracked untracked path(s); no tracked file is modified, so"
    Write-Info "  'git checkout .' is still a complete undo of anything this installer changes."
} else {
    Write-Ok 'worktree clean'
}

# --- base branch -----------------------------------------------------------
if (-not $BaseBranch) {
    $bb = (& git -C $TargetPath symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>$null)
    if ($bb) { $BaseBranch = ("$bb".Trim() -replace '^origin/', '') }
    if (-not $BaseBranch) {
        $bb = (& git -C $TargetPath rev-parse --abbrev-ref HEAD 2>$null)
        if ($bb) { $BaseBranch = "$bb".Trim() }
    }
    if (-not $BaseBranch -or $BaseBranch -eq 'HEAD') { $BaseBranch = 'main' }
}
Write-Ok "base branch: $BaseBranch  (this is the branch that must be protected)"

# --- project name / stack --------------------------------------------------
if (-not $ProjectName) { $ProjectName = Split-Path -Leaf $TargetPath }
if (-not $Stack) {
    if ((Test-Path (Join-Path $TargetPath 'pyproject.toml')) -or
        (Test-Path (Join-Path $TargetPath 'setup.py'))       -or
        (Test-Path (Join-Path $TargetPath 'pytest.ini'))     -or
        (Test-Path (Join-Path $TargetPath 'requirements.txt'))) { $Stack = 'python-pytest' }
    elseif (Test-Path (Join-Path $TargetPath 'package.json')) { $Stack = 'node-jest' }
    else { $Stack = 'generic' }
    Write-Ok "stack auto-detected: $Stack"
} else {
    Write-Ok "stack: $Stack"
}
$stackTools = @{ 'python-pytest' = @('python3','pytest'); 'node-jest' = @('node','npm'); 'generic' = @() }
foreach ($t in $stackTools[$Stack]) {
    if (Test-Command $t) { Write-Ok "stack tool: $t" }
    else {
        Write-Warn "stack tool '$t' not found. The $Stack pack's commands will fail when a"
        Write-Cont "gate runs them. Gates that need a command they cannot run SKIP with a"
        Write-Cont "loud notice -- they do not silently pass -- so this is safe but noisy."
    }
}

if ($script:HostFatal) {
    Write-Host ''
    Write-Host 'install refused: one or more required host tools are missing.' -ForegroundColor Red
    Write-Host '  Nothing was written. Fix the FAIL lines above and re-run.'
    Write-Host '  Every one of them is a tool a SECURITY GATE needs, which is why this is'
    Write-Host '  a refusal and not a warning: a gate that cannot run has not passed.'
    Write-Host ''
    exit 2
}

# ===========================================================================
# SECTION 3 -- ACTION PRIMITIVES (all honour -WhatIf)
# ===========================================================================
$ManifestPath = Join-Path $TargetPath '.claude\.ratchet-install-manifest'
$StatePath    = Join-Path $TargetPath '.claude\.ratchet-install.json'
$script:ManifestLines = New-Object System.Collections.Generic.List[string]

function Add-ManifestLine { param([string]$Line) if (-not $WhatIfPreference) { $script:ManifestLines.Add($Line) } }

function Get-RelPath {
    param([string]$Full)
    $r = $Full.Substring($TargetPath.Length).TrimStart('\', '/')
    return ($r -replace '\\', '/')
}

function New-TargetDirectory {
    param([string]$Rel)
    $full = Join-Path $TargetPath ($Rel -replace '/', '\')
    if (Test-Path -LiteralPath $full) { return }
    if ((Confirm-Change $Rel 'create directory')) {
        New-Item -ItemType Directory -Path $full -Force | Out-Null
        Add-ManifestLine "D $Rel"
    }
}

# Write text as UTF-8 WITHOUT a BOM and with LF endings.
# Both halves matter. A BOM at the top of a .sh file becomes three bytes before
# the "#!" and the shebang stops being a shebang. Set-Content -Encoding UTF8 on
# PowerShell 5.1 writes a BOM, which is why this uses .NET directly rather than
# the obvious cmdlet.
# NOTE on ConvertTo-Json in PowerShell 5.1: a one-element array serialises as a
# bare scalar rather than an array. Every permission class we write has dozens
# of entries so it does not bite here, but if you ever trim these lists to one
# entry, wrap the value as @(,$x) before serialising.
function Write-TextLf {
    param([string]$Path, [string]$Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $lf = $Content -replace "`r`n", "`n" -replace "`r", "`n"
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $lf, $enc)
}

function Copy-HarnessFile {
    param(
        [string]$SourcePath,
        [string]$Rel,
        [ValidateSet('replace','if-absent')] [string]$Mode = 'replace'
    )
    if (-not (Test-Path -LiteralPath $SourcePath)) {
        $script:MissingFiles.Add($Rel) | Out-Null
        return $false
    }
    $dest = Join-Path $TargetPath ($Rel -replace '/', '\')
    if ((Test-Path -LiteralPath $dest) -and $Mode -eq 'if-absent') {
        Write-Info "kept existing $Rel (yours; not overwritten)"
        return $true
    }
    if ((Confirm-Change $Rel 'write file')) {
        # Sniff for NUL bytes to tell text from binary. Guard the empty file:
        # 0..(0-1) in PowerShell is the sequence 0,-1, not an empty range, and
        # the -1 index would read the last byte of an array that has none.
        $bytes = [System.IO.File]::ReadAllBytes($SourcePath)
        $isText = $true
        $scan = [Math]::Min(1024, $bytes.Length)
        for ($i = 0; $i -lt $scan; $i++) { if ($bytes[$i] -eq 0) { $isText = $false; break } }
        if ($isText) {
            $text = [System.IO.File]::ReadAllText($SourcePath)
            Write-TextLf -Path $dest -Content $text
        } else {
            $d = Split-Path -Parent $dest
            if ($d -and -not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
            Copy-Item -LiteralPath $SourcePath -Destination $dest -Force
        }
        Add-ManifestLine "F $Rel"
    }
    return $true
}

function Copy-HarnessTree {
    param([string]$Rel, [string]$Mode = 'replace')
    $src = Join-Path $HarnessDir ($Rel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $src)) {
        $script:MissingFiles.Add("$Rel/ (whole directory)") | Out-Null
        return
    }
    $n = 0
    foreach ($f in (Get-ChildItem -LiteralPath $src -File)) {
        $fmode = $Mode
        # domain.config.sh is the one file under .claude\ that a HUMAN owns: it
        # is the interview's output and it holds this project's walls.
        # Replacing it on upgrade would silently reset every wall configured,
        # and the failure would be invisible until the day a guard did not
        # refuse something it used to refuse.
        if ($f.Name -eq 'domain.config.sh') { $fmode = 'if-absent' }
        if (Copy-HarnessFile -SourcePath $f.FullName -Rel "$Rel/$($f.Name)" -Mode $fmode) { $n++ }
    }
    if ($n -gt 0) { Write-Ok "$Rel ($n files)" }
}

# ===========================================================================
# SECTION 4 -- UNINSTALL
# ===========================================================================
if ($Uninstall) {
    Write-Head 'Uninstall'
    if (-not (Test-Path -LiteralPath $ManifestPath)) {
        Stop-Install @"
no install manifest at .claude\.ratchet-install-manifest.
  Either Ratchet was never installed here, or it was installed by hand. This
  script will not guess which files are yours -- deleting a project's .claude\
  on a guess is exactly the damage it exists to avoid. Remove by hand:
      .claude\hooks\  .claude\agents\  .claude\settings.json
  and restore any .claude\settings.json.bak-* you find.
"@
    }
    $lines = @(Get-Content -LiteralPath $ManifestPath)
    $restored = @{}

    # ONE RESTORE PER ORIGINAL, AND IT IS THE OLDEST BACKUP. Every install
    # takes a backup, so after three upgrades there are three .bak files -- and
    # two of them are Ratchet-merged documents, not the user's original.
    # Restoring in manifest order would "uninstall" the harness by handing back
    # a file that still contains the harness.
    foreach ($l in ($lines | Where-Object { $_ -like 'B *' } | Sort-Object)) {
        $parts = $l -split ' '
        $bak = $parts[1]; $orig = $parts[2]
        if ($restored.ContainsKey($orig)) { continue }
        if ($bak -eq '-') {
            # There was no such file before Ratchet. Removing it IS the restore.
            # Without this branch an uninstall after two installs restores the
            # first backup it finds -- which, when the project never had a
            # settings.json, is a Ratchet-generated document from install #1.
            $origFull = Join-Path $TargetPath ($orig -replace '/', '\')
            if (Test-Path -LiteralPath $origFull) {
                if ((Confirm-Change $orig 'remove (did not exist before install)')) {
                    Remove-Item -LiteralPath $origFull -Force
                }
            }
            Write-Ok "removed $orig (this project had none before Ratchet)"
            $restored[$orig] = $true
            continue
        }
        $bakFull = Join-Path $TargetPath ($bak -replace '/', '\')
        if (Test-Path -LiteralPath $bakFull) {
            if ((Confirm-Change $orig "restore from $bak")) {
                Copy-Item -LiteralPath $bakFull -Destination (Join-Path $TargetPath ($orig -replace '/', '\')) -Force
                Write-Ok "restored $orig from $bak (the pre-Ratchet original)"
            }
            $restored[$orig] = $true
        } else {
            Write-Warn "backup $bak is gone; cannot restore $orig"
        }
    }
    foreach ($l in ($lines | Where-Object { $_ -like 'F *' })) {
        $rel = $l.Substring(2)
        if ($restored.ContainsKey($rel)) { continue }
        $full = Join-Path $TargetPath ($rel -replace '/', '\')
        if (Test-Path -LiteralPath $full) {
            if ((Confirm-Change $rel 'remove')) { Remove-Item -LiteralPath $full -Force }
        }
    }
    foreach ($d in @('.claude\hooks\stack', '.claude\hooks', '.claude\agents', '.claude')) {
        $full = Join-Path $TargetPath $d
        if (Test-Path -LiteralPath $full) {
            if (@(Get-ChildItem -LiteralPath $full -Force).Count -eq 0) {
                if ((Confirm-Change $d 'remove empty directory')) {
                    Remove-Item -LiteralPath $full -Force
                    Write-Ok "removed empty $d"
                }
            }
        }
    }
    foreach ($f in @($ManifestPath, $StatePath)) {
        if (Test-Path -LiteralPath $f) {
            if ((Confirm-Change (Get-RelPath $f) 'remove')) { Remove-Item -LiteralPath $f -Force }
        }
    }

    Write-Head 'Uninstall complete'
    Write-Host '  LEFT IN PLACE, deliberately -- this is your project''s work, not the harness:'
    Write-Host '    .context\                        your SPEC, MILESTONES, DECISIONS, archive'
    Write-Host '    .agent-development\              run retros, lessons, pending actions'
    Write-Host '    .pipeline\                       findings ledger, checkpoints, scratch'
    Write-Host '    docs\evidence\                   WIN-row proof and probe transcripts'
    Write-Host '    secrets\                         the escalation signing key'
    Write-Host '    .claude\hooks\domain.config.sh   your domain pack: the walls you configured'
    Write-Host '    .claude\settings.json.bak-*      every backup this installer ever took'
    Write-Host ''
    Write-Host '  Delete any of those by hand if you want them gone. The installer will not,'
    Write-Host '  because none of it was written by the installer.'
    exit 0
}

# ===========================================================================
# SECTION 5 -- INSTALL
# ===========================================================================
Write-Head 'Installing'

if (-not (Test-Path -LiteralPath $HarnessDir)) {
    Stop-Install @"
harness source tree not found at $HarnessDir.
  install.ps1 expects to sit next to a 'harness' directory containing
  .claude, .context and the rest. Are you running it from an incomplete
  checkout?
"@
}

# Carry forward B records from a previous install so an upgrade -> uninstall
# still restores the ORIGINAL settings.json.
if ((Test-Path -LiteralPath $ManifestPath) -and -not $WhatIfPreference) {
    foreach ($l in (Get-Content -LiteralPath $ManifestPath)) {
        if ($l -like 'B *') { $script:ManifestLines.Add($l) }
    }
}

$Ts = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmss') + 'Z'

Write-Head 'Scaffolding the four-directory partition'
foreach ($d in @(
    '.claude/hooks/stack', '.claude/agents',
    '.context/archive/decisions',
    '.pipeline/checkpoints', '.pipeline/escalations', '.pipeline/dispatch', '.pipeline/archive',
    '.agent-development/runs', '.agent-development/consolidated',
    '.agent-development/metrics', '.agent-development/proposals',
    'docs/evidence', 'secrets')) { New-TargetDirectory -Rel $d }
Write-Ok '.claude\ (control layer, agent-unwritable)'
Write-Ok '.context\ (human contracts, never agent-edited)'
Write-Ok '.pipeline\ (run scratch, mostly gitignored)'
Write-Ok '.agent-development\ (learning loop, tracked, never pruned)'
Write-Ok 'docs\evidence\, secrets\'

Write-Head 'Copying the harness'
Copy-HarnessTree '.claude/hooks'       'replace'
Copy-HarnessTree '.claude/hooks/stack' 'replace'
Copy-HarnessTree '.claude/agents'      'replace'

Write-Head 'Human-owned contracts (.context\)'
$ctxSrc = Join-Path $HarnessDir '.context'
if (Test-Path -LiteralPath $ctxSrc) {
    foreach ($f in (Get-ChildItem -LiteralPath $ctxSrc -File)) {
        if ($f.Name -eq 'CLAUDE.md') { continue }
        $rel = ".context/$($f.Name)"
        if (Test-Path -LiteralPath (Join-Path $TargetPath ($rel -replace '/', '\'))) {
            Write-Info "kept existing $rel (yours; not overwritten)"
        } else {
            if (Copy-HarnessFile -SourcePath $f.FullName -Rel $rel -Mode 'if-absent') { Write-Ok "$rel (new)" }
        }
    }
}

# --- CLAUDE.md: never clobber ---------------------------------------------
$harnessClaude = Join-Path $ctxSrc 'CLAUDE.md'
if (Test-Path -LiteralPath $harnessClaude) {
    $ctxClaude  = Join-Path $TargetPath '.context\CLAUDE.md'
    $rootClaude = Join-Path $TargetPath 'CLAUDE.md'
    if (Test-Path -LiteralPath $ctxClaude) {
        Write-Info 'kept existing .context\CLAUDE.md (yours; not overwritten)'
    } else {
        if (Copy-HarnessFile -SourcePath $harnessClaude -Rel '.context/CLAUDE.md' -Mode 'if-absent') {
            Write-Ok '.context\CLAUDE.md (orchestrator operating manual)'
        }
    }
    if (Test-Path -LiteralPath $rootClaude) {
        [void](Copy-HarnessFile -SourcePath $harnessClaude -Rel 'CLAUDE.ratchet.md' -Mode 'replace')
        Write-Warn 'you already have a root CLAUDE.md. It was NOT touched.'
        Write-Cont "Ratchet's operating manual was written to CLAUDE.ratchet.md instead."
        Write-Cont 'Claude Code reads root CLAUDE.md automatically and does NOT read'
        Write-Cont 'CLAUDE.ratchet.md, so until you act, the harness''s doctrine is'
        Write-Cont 'installed but not loaded. Do ONE of these:'
        Write-Cont '  (a) add this line to your CLAUDE.md:   @.context/CLAUDE.md'
        Write-Cont '  (b) merge CLAUDE.ratchet.md into your CLAUDE.md by hand'
        Write-Cont '(a) is what we recommend: it keeps the two files separately'
        Write-Cont 'upgradeable, and .context\CLAUDE.md is the file Ratchet updates.'
    } else {
        if ((Confirm-Change 'CLAUDE.md' 'write import stub')) {
            Write-TextLf -Path $rootClaude -Content "@.context/CLAUDE.md`n"
            Add-ManifestLine 'F CLAUDE.md'
            Write-Ok 'CLAUDE.md -> @.context/CLAUDE.md (one-line import; edit freely, it is yours)'
        }
    }
}

Write-Head 'Learning loop (.agent-development\)'
$devSrc = Join-Path $HarnessDir '.agent-development'
if (Test-Path -LiteralPath $devSrc) {
    foreach ($f in (Get-ChildItem -LiteralPath $devSrc -File)) {
        [void](Copy-HarnessFile -SourcePath $f.FullName -Rel ".agent-development/$($f.Name)" -Mode 'if-absent')
    }
}
Write-Ok '.agent-development\ seeded (existing files kept)'

# ===========================================================================
# SECTION 6 -- settings.json: MERGE, never overwrite
# ===========================================================================
Write-Head 'Permission surface (.claude\settings.json)'

function Get-ShellVar {
    # Read one variable out of a bash config file by SOURCING it in bash.
    # Parsing shell with a regex would break on heredocs, which is exactly how
    # the domain pack stores its lists.
    param([string]$File, [string]$Name)
    if (-not (Test-Path -LiteralPath $File)) { return '' }
    if (-not $script:BashPath) { return '' }
    $posix = ($File -replace '\\', '/')
    $out = & $script:BashPath -c ". '$posix' >/dev/null 2>&1; printf '%s' `"`${$Name:-}`"" 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    return ("$out")
}

$StackAllowTable = @{
    'python-pytest' = @(
        'Bash(make:*)','Bash(uv sync:*)','Bash(uv lock:*)','Bash(uv add:*)','Bash(uv remove:*)',
        'Bash(uv export:*)','Bash(uv run pytest:*)','Bash(uv run mypy:*)','Bash(uv run ruff:*)',
        'Bash(uv run pip-audit:*)','Bash(uv run pre-commit:*)','Bash(pytest:*)',
        'Bash(python -m pytest:*)','Bash(python3 -m pytest:*)','Bash(ruff:*)','Bash(mypy:*)',
        'Bash(pip-audit:*)','Bash(pre-commit install)','Bash(pre-commit run:*)',
        'Edit(./pyproject.toml)','Edit(./uv.lock)','Edit(./requirements.txt)',
        'Edit(./.github/workflows/**)','Write(./.github/workflows/**)')
    'node-jest' = @(
        'Bash(make:*)','Bash(npm ci)','Bash(npm install:*)','Bash(npm run:*)','Bash(npm test:*)',
        'Bash(npx jest:*)','Bash(npx tsc:*)','Bash(npx eslint:*)','Bash(npx prettier:*)',
        'Bash(pnpm install:*)','Bash(pnpm run:*)','Bash(yarn install:*)','Bash(yarn run:*)',
        'Bash(node --test:*)','Edit(./package.json)','Edit(./tsconfig.json)',
        'Edit(./.github/workflows/**)','Write(./.github/workflows/**)')
    'generic' = @('Bash(make:*)','Edit(./.github/workflows/**)','Write(./.github/workflows/**)')
}

function Expand-PathList {
    param([string]$List, [string[]]$Verbs)
    $out = @()
    foreach ($raw in ($List -split "`n")) {
        $p = $raw.Trim()
        if (-not $p -or $p.StartsWith('#')) { continue }
        if ($p.StartsWith('./')) { $p = $p.Substring(2) }
        foreach ($v in $Verbs) {
            if ($p.StartsWith('/') -or $p.StartsWith('*')) { $out += "$v($p)" }
            else { $out += "$v(./$p)" }
        }
    }
    return $out
}

$TemplatePath = Join-Path $HarnessDir '.claude\settings.template.json'
$SettingsPath = Join-Path $TargetPath '.claude\settings.json'
if (-not (Test-Path -LiteralPath $TemplatePath)) {
    $script:MissingFiles.Add('.claude/settings.template.json') | Out-Null
    Write-Fail 'settings.template.json is missing from the harness source. Skipping the'
    Write-Cont 'permission surface entirely. The hooks are installed but NOTHING IS'
    Write-Cont 'WIRED: no guard runs, no gate fires. This install is not usable.'
} else {
    $domainSh = Join-Path $TargetPath '.claude\hooks\domain.config.sh'
    $domName  = Get-ShellVar $domainSh 'DOMAIN_NAME'; if (-not $domName) { $domName = 'none' }

    $tpl = [System.IO.File]::ReadAllText($TemplatePath)
    $scalar = @{
        '{{RATCHET_VERSION}}'              = $RtInstallerVersion
        '{{RATCHET_PROJECT_NAME}}'         = $ProjectName
        '{{PROJECT_NAME}}'                 = $ProjectName
        '{{RATCHET_PROJECT_DIR}}'          = ($TargetPath -replace '\\', '/')
        '{{RATCHET_STACK_NAME}}'           = $Stack
        '{{RATCHET_DOMAIN_NAME}}'          = $domName
        '{{RATCHET_BASE_BRANCH}}'          = $BaseBranch
        '{{BASE_BRANCH}}'                  = $BaseBranch
        '{{RATCHET_AGENT_BRANCH_PREFIX}}'  = 'agent/'
        '{{RATCHET_ESCALATION_MODE}}'      = $EscalationMode
        '{{RATCHET_SECRETS_DIR}}'          = 'secrets'
        '{{RATCHET_ESCALATION_KEY}}'       = 'secrets/escalation.key'
        '{{RATCHET_GENERATED_AT}}'         = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
    foreach ($k in $scalar.Keys) { $tpl = $tpl.Replace($k, $scalar[$k]) }

    $newObj = $null
    try { $newObj = $tpl | ConvertFrom-Json } catch { $newObj = $null }
    if (-not $newObj) {
        Write-Fail 'the expanded settings template is not valid JSON. Not touching settings.json.'
        Write-Cont 'This is a harness bug, not a you bug.'
    } else {
        # Expand the LIST placeholders: one string element becomes zero or more.
        # Keeping them as string elements is what makes settings.template.json
        # valid JSON on its own, and therefore lintable in CI before anyone
        # runs an installer.
        $stackAllow = $StackAllowTable[$Stack]
        $domDeny    = Expand-PathList (Get-ShellVar $domainSh 'FORBIDDEN_ARTIFACTS') @('Edit','Write')
        $banDeny    = Expand-PathList (Get-ShellVar $domainSh 'BANNED_READ_FILES')   @('Read','Edit','Write')
        $corpDeny   = Expand-PathList (Get-ShellVar $domainSh 'GOVERNING_CORPUS')    @('Edit','Write')
        $corpDeny  += Expand-PathList (Get-ShellVar $domainSh 'SECRET_PATTERNS')     @('Read','Edit','Write')

        function Expand-Marker {
            param($Arr, [string]$Marker, [string[]]$Repl)
            $out = @()
            foreach ($e in $Arr) { if ($e -eq $Marker) { $out += $Repl } else { $out += $e } }
            return $out
        }
        $allow = Expand-Marker $newObj.permissions.allow '{{RATCHET_STACK_ALLOW}}'      $stackAllow
        $ask   = Expand-Marker $newObj.permissions.ask   '{{RATCHET_DOMAIN_ASK}}'       @()
        $deny  = Expand-Marker $newObj.permissions.deny  '{{RATCHET_DOMAIN_DENY}}'      $domDeny
        $deny  = Expand-Marker $deny                     '{{RATCHET_BANNED_READ_DENY}}' $banDeny
        $deny  = Expand-Marker $deny                     '{{RATCHET_CORPUS_DENY}}'      $corpDeny

        $newObj.permissions.allow = @($allow | Sort-Object -Unique)
        $newObj.permissions.ask   = @($ask   | Sort-Object -Unique)
        $newObj.permissions.deny  = @($deny  | Sort-Object -Unique)

        if (Test-Path -LiteralPath $SettingsPath) {
            $bakRel = ".claude/settings.json.bak-$Ts"
            $bakFull = Join-Path $TargetPath ($bakRel -replace '/', '\')
            if ((Confirm-Change $bakRel 'back up settings.json')) {
                Copy-Item -LiteralPath $SettingsPath -Destination $bakFull -Force
                Add-ManifestLine "B $bakRel .claude/settings.json"
                Write-Ok "backed up your settings.json to $bakRel"
            }
            $old = $null
            try { $old = (Get-Content -LiteralPath $SettingsPath -Raw) | ConvertFrom-Json } catch { $old = $null }
            if (-not $old) {
                Write-Warn 'your existing .claude\settings.json is not valid JSON. It was backed up and'
                Write-Cont 'REPLACED rather than merged, because merging into a file we cannot parse'
                Write-Cont 'would mean guessing at your intent.'
                if ((Confirm-Change '.claude/settings.json' 'install')) {
                    Write-TextLf -Path $SettingsPath -Content ($newObj | ConvertTo-Json -Depth 32)
                    Add-ManifestLine 'F .claude/settings.json'
                }
            } else {
                # THE MERGE. Union permissions; append only hooks we do not
                # already have. Your entries survive; ours are added. The one
                # asymmetry is deliberate: OUR deny wins over YOUR allow,
                # because deny is the class that cannot be lifted at runtime,
                # and a permissive entry surviving a merge would silently
                # reopen a wall.
                if (-not ($old.PSObject.Properties.Name -contains 'permissions')) {
                    $old | Add-Member -NotePropertyName permissions -NotePropertyValue ([PSCustomObject]@{}) -Force
                }
                foreach ($cls in @('allow','ask','deny')) {
                    if (-not ($old.permissions.PSObject.Properties.Name -contains $cls)) {
                        $old.permissions | Add-Member -NotePropertyName $cls -NotePropertyValue @() -Force
                    }
                }
                $mAllow = @(@($old.permissions.allow) + @($newObj.permissions.allow) | Sort-Object -Unique)
                $mAsk   = @(@($old.permissions.ask)   + @($newObj.permissions.ask)   | Sort-Object -Unique)
                $mDeny  = @(@($old.permissions.deny)  + @($newObj.permissions.deny)  | Sort-Object -Unique)
                $mAllow = @($mAllow | Where-Object { $newObj.permissions.deny -notcontains $_ })
                $mAsk   = @($mAsk   | Where-Object { $newObj.permissions.deny -notcontains $_ })

                $old.permissions | Add-Member -NotePropertyName allow -NotePropertyValue $mAllow -Force
                $old.permissions | Add-Member -NotePropertyName ask   -NotePropertyValue $mAsk   -Force
                $old.permissions | Add-Member -NotePropertyName deny  -NotePropertyValue $mDeny  -Force
                $old.permissions | Add-Member -NotePropertyName defaultMode -NotePropertyValue $newObj.permissions.defaultMode -Force

                if (-not ($old.PSObject.Properties.Name -contains 'hooks')) {
                    $old | Add-Member -NotePropertyName hooks -NotePropertyValue ([PSCustomObject]@{}) -Force
                }
                foreach ($evt in $newObj.hooks.PSObject.Properties.Name) {
                    $existing = @()
                    if ($old.hooks.PSObject.Properties.Name -contains $evt) { $existing = @($old.hooks.$evt) }
                    $haveCmds = @()
                    foreach ($grp in $existing) {
                        if ($grp -and $grp.PSObject.Properties.Name -contains 'hooks') {
                            foreach ($h in @($grp.hooks)) { if ($h.command) { $haveCmds += $h.command } }
                        }
                    }
                    $add = @()
                    foreach ($grp in @($newObj.hooks.$evt)) {
                        $cmds = @()
                        foreach ($h in @($grp.hooks)) { if ($h.command) { $cmds += $h.command } }
                        $novel = @($cmds | Where-Object { $haveCmds -notcontains $_ })
                        if ($novel.Count -gt 0) { $add += $grp }
                    }
                    $old.hooks | Add-Member -NotePropertyName $evt -NotePropertyValue (@($existing) + @($add)) -Force
                }
                foreach ($meta in @('_ratchet','_ratchet_permission_doctrine','_ratchet_deny_partition','_ratchet_note_decisions')) {
                    if ($newObj.PSObject.Properties.Name -contains $meta) {
                        $old | Add-Member -NotePropertyName $meta -NotePropertyValue $newObj.$meta -Force
                    }
                }
                if ((Confirm-Change '.claude/settings.json' 'merge')) {
                    Write-TextLf -Path $SettingsPath -Content ($old | ConvertTo-Json -Depth 32)
                    Add-ManifestLine 'F .claude/settings.json'
                    Write-Ok "merged: allow $(@($old.permissions.allow).Count) entries; your entries kept, our deny wins ties"
                }
            }
        } else {
            if ((Confirm-Change '.claude/settings.json' 'install')) {
                Write-TextLf -Path $SettingsPath -Content ($newObj | ConvertTo-Json -Depth 32)
                Add-ManifestLine 'F .claude/settings.json'
                Write-Ok 'wrote .claude\settings.json'
            }
        }
    }
}

# ===========================================================================
# SECTION 7 -- executability and the bash record
# ===========================================================================
Write-Head 'Hook executability and the bash record'

# There is no chmod on NTFS, and there does not need to be: Git-Bash and WSL
# both run a .sh file handed to bash regardless of an execute bit, and Claude
# Code invokes the hooks through a shell. What DOES matter is that git records
# the execute bit for anyone who later clones this repo on Linux or macOS, so
# we set it in the index rather than on the filesystem.
if (-not $WhatIfPreference) {
    $hookFiles = @()
    foreach ($pat in @('.claude\hooks\*.sh', '.claude\hooks\*.py', '.claude\hooks\stack\*.sh')) {
        $hookFiles += @(Get-ChildItem -Path (Join-Path $TargetPath $pat) -File -ErrorAction SilentlyContinue)
    }
    $n = 0
    foreach ($f in $hookFiles) {
        $rel = Get-RelPath $f.FullName
        & git -C $TargetPath update-index --add --chmod=+x -- $rel *> $null
        if ($LASTEXITCODE -eq 0) { $n++ }
    }
    Write-Ok "recorded the execute bit in git for $n of $($hookFiles.Count) hook files"
    if ($n -lt $hookFiles.Count) {
        Write-Info 'Files not yet added to git will get their execute bit on your first commit'
        Write-Info '  if you run:  git add --chmod=+x .claude/hooks'
    }
    Write-Ok 'approve.sh installed (human-only: denied to the agent at three layers)'

    # Record which bash the gates will actually run under. When something
    # misbehaves six weeks from now, "which shell is this even" is the first
    # question and this file answers it without anyone having to guess.
    $bashRecord = @"
# Written by install.ps1 $RtInstallerVersion on $((Get-Date).ToUniversalTime().ToString('u')).
# The shell Ratchet's hooks were verified to run under on this host.
# This is a RECORD, not a setting: Claude Code chooses the shell itself. If the
# hooks start failing with "bad interpreter" or "command not found", compare
# what is here with what `bash --version` says now.
RATCHET_BASH_PATH=$($script:BashPath)
RATCHET_BASH_KIND=$($script:BashKind)
RATCHET_INSTALLED_ON=Windows $([System.Environment]::OSVersion.Version)
RATCHET_PYTHON_PROBED=$($script:Py)
"@
    Write-TextLf -Path (Join-Path $TargetPath '.claude\hooks\.ratchet-bash') -Content $bashRecord
    Add-ManifestLine 'F .claude/hooks/.ratchet-bash'
    Write-Ok "recorded the hook shell: $($script:BashKind) ($($script:BashPath))"
}

# --- .gitattributes: pin the hooks to LF forever --------------------------
$gaPath = Join-Path $TargetPath '.gitattributes'
$gaMark = '# --- Ratchet: hooks are bash; CRLF breaks the shebang line ---'
$gaHave = $false
if (Test-Path -LiteralPath $gaPath) {
    $gaHave = @(Get-Content -LiteralPath $gaPath) -contains $gaMark
}
if (-not $gaHave) {
    if ((Confirm-Change '.gitattributes' 'pin hook line endings to LF')) {
        $block = "`n$gaMark`n" +
                 "# A CRLF shebang makes the shell look for an interpreter named `"bash\r`",`n" +
                 "# and the error names a file that visibly exists. Pin these, always.`n" +
                 ".claude/hooks/** text eol=lf`n" +
                 "*.sh            text eol=lf`n"
        $existing = ''
        if (Test-Path -LiteralPath $gaPath) { $existing = [System.IO.File]::ReadAllText($gaPath) }
        Write-TextLf -Path $gaPath -Content ($existing + $block)
        if (-not (Test-Path -LiteralPath $gaPath)) { Add-ManifestLine 'F .gitattributes' }
        Write-Ok '.gitattributes pins .claude/hooks/** and *.sh to LF'
    }
} else {
    Write-Ok '.gitattributes already pins the hooks to LF'
}

# ===========================================================================
# SECTION 8 -- secrets, ACLs, and a VERIFIED gitignore
# ===========================================================================
Write-Head 'Escalation key and gitignore'

$GitIgnorePath = Join-Path $TargetPath '.gitignore'
function Add-IgnoreLine {
    param([string]$Pattern, [string]$Comment = '')
    $have = $false
    if (Test-Path -LiteralPath $GitIgnorePath) {
        $have = @(Get-Content -LiteralPath $GitIgnorePath) -contains $Pattern
    }
    if ($have) { return }
    if ((Confirm-Change '.gitignore' "add '$Pattern'")) {
        $cur = ''
        if (Test-Path -LiteralPath $GitIgnorePath) { $cur = [System.IO.File]::ReadAllText($GitIgnorePath) }
        if ($cur -and -not $cur.EndsWith("`n")) { $cur += "`n" }
        if ($Comment) { $cur += "$Comment`n" }
        $cur += "$Pattern`n"
        Write-TextLf -Path $GitIgnorePath -Content $cur
    }
}

Add-IgnoreLine 'secrets/' '# --- Ratchet: the escalation signing key lives here. Never commit it. ---'
Add-IgnoreLine '.env'
Add-IgnoreLine '.env.local'

# THE .pipeline\ IGNORE/TRACK PARTITION.
# .pipeline is not uniformly disposable and treating it as such is a real bug
# in both directions. Per-host runtime files differ per machine and would
# conflict on every merge. But findings.md, the manifest, the checkpoint
# verdicts and ship-consent.json are the RECORD of a run -- the evidence anyone
# would use later to check that a merge was consented to and a finding was
# adjudicated. Those are tracked.
$pipeMark = '# --- Ratchet: .pipeline/ runtime (per-host; never committed) ---'
$pipeHave = $false
if (Test-Path -LiteralPath $GitIgnorePath) { $pipeHave = @(Get-Content -LiteralPath $GitIgnorePath) -contains $pipeMark }
if (-not $pipeHave) {
    if ((Confirm-Change '.gitignore' 'write the .pipeline ignore/track partition')) {
        $cur = ''
        if (Test-Path -LiteralPath $GitIgnorePath) { $cur = [System.IO.File]::ReadAllText($GitIgnorePath) }
        $cur += "`n$pipeMark`n"
        foreach ($p in @('.pipeline/stop-retries*','.pipeline/subagent-retries*','.pipeline/run-events.jsonl',
                         '.pipeline/run-metrics.json','.pipeline/verify-last.json','.pipeline/run-start',
                         '.pipeline/run-idle','.pipeline/run-last-seen','.pipeline/run-active',
                         '.pipeline/ready-to-ship','.pipeline/.last-paged','.pipeline/cmd-log',
                         '.pipeline/notifications.log','.pipeline/dispatch/','.pipeline/.py-interp',
                         '.pipeline/red-baseline.txt','.pipeline/escalations/')) { $cur += "$p`n" }
        $cur += "`n# --- Ratchet: .pipeline/ durable record (TRACKED on purpose) ---`n"
        $cur += "# These negations are assertions, not fixes: .pipeline/ itself is NOT ignored,`n"
        $cur += "# so these files are already tracked. They are written down because the`n"
        $cur += "# tempting simplification -- one '.pipeline/' line -- would silently drop the`n"
        $cur += "# findings ledger, the checkpoint verdicts and ship-consent.json, which are`n"
        $cur += "# the only durable evidence that a merge was consented to and a finding was`n"
        $cur += "# adjudicated. Anyone who reaches for that simplification reads this first.`n"
        foreach ($p in @('!.pipeline/findings.md','!.pipeline/plan-files.txt','!.pipeline/manifest-amendments.txt',
                         '!.pipeline/checkpoints/','!.pipeline/ship-consent.json','!.pipeline/recap.md',
                         '!.pipeline/run-journal.md')) { $cur += "$p`n" }
        Write-TextLf -Path $GitIgnorePath -Content $cur
        Write-Ok '.pipeline\ ignore/track partition written to .gitignore'
    }
} else {
    Write-Ok '.pipeline\ partition already present in .gitignore'
}

# --- VERIFY, do not assume, that secrets\ is ignored ----------------------
# "We appended a line to .gitignore" is not the same claim as "git will not
# commit this file". A parent .gitignore, a global core.excludesFile, a later
# negation, or an ALREADY-TRACKED path all break it -- and the last one breaks
# it silently, because git ignores .gitignore for files already in the index.
if (-not $WhatIfPreference) {
    $secretsDir = Join-Path $TargetPath 'secrets'
    if (-not (Test-Path -LiteralPath $secretsDir)) { New-Item -ItemType Directory -Path $secretsDir -Force | Out-Null }
    $probe = Join-Path $secretsDir '.ratchet-ignore-probe'
    Set-Content -LiteralPath $probe -Value '' -NoNewline
    & git -C $TargetPath check-ignore -q 'secrets/.ratchet-ignore-probe' *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Ok 'verified: git will not commit anything under secrets\'
    } else {
        Write-Fail 'secrets\ is NOT ignored by git, even after writing the .gitignore entry.'
        Write-Cont 'The escalation signing key is about to be created there. If it is'
        Write-Cont 'committed, every approval in this repo''s history becomes forgeable by'
        Write-Cont 'anyone who can read the repo -- and rotating it will not undo that.'
        Write-Cont ''
        Write-Cont 'Most likely causes, in the order worth checking:'
        Write-Cont '  1. secrets\ is already TRACKED. git ignores .gitignore for files'
        Write-Cont "     already in the index. Fix:  git -C `"$TargetPath`" rm -r --cached secrets"
        Write-Cont '  2. a later negation in .gitignore re-includes it:'
        Write-Cont '     git check-ignore -v secrets/escalation.key'
        Write-Cont '  3. a global core.excludesFile or a parent .gitignore disagrees.'
        $script:Warnings++
    }
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
}

# --- ACLs on secrets\ (the closest Windows gets to 0700) ------------------
if (-not $WhatIfPreference) {
    try {
        $secretsDir = Join-Path $TargetPath 'secrets'
        $acl = Get-Acl -LiteralPath $secretsDir
        $acl.SetAccessRuleProtection($true, $false)   # break inheritance, drop inherited rules
        foreach ($r in @($acl.Access)) { [void]$acl.RemoveAccessRule($r) }
        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $me, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
        Set-Acl -LiteralPath $secretsDir -AclObject $acl
        Write-Ok "secrets\ ACL: inheritance broken, access granted to $me only"
        Write-Info 'Be clear-eyed about what that is worth: it stops another standard user'
        Write-Info '  account reading the escalation key. It does not stop an administrator,'
        Write-Info '  and it does nothing at all if this folder is inside OneDrive or on a'
        Write-Info '  network share. The control that actually matters is the gitignore'
        Write-Info '  check above -- a key in a commit is public forever; a key readable by'
        Write-Info '  an admin on your own machine is a much smaller problem.'
    } catch {
        Write-Warn "could not set ACLs on secrets\ ($($_.Exception.Message))."
        Write-Cont 'The key will still be created. On Windows this is a hardening step, not'
        Write-Cont 'a control -- the control is that secrets\ is gitignored, verified above.'
    }
}

# --- generate the key ------------------------------------------------------
$KeyFile = Join-Path $TargetPath 'secrets\escalation.key'
if ($WhatIfPreference) {
    Write-Info 'WhatIf: would generate secrets\escalation.key via approve.sh --init-key'
} elseif (Test-Path -LiteralPath $KeyFile) {
    Write-Ok 'escalation key already present (not regenerated -- that is deliberate)'
} else {
    $approve = Join-Path $TargetPath '.claude\hooks\approve.sh'
    $made = $false
    if ((Test-Path -LiteralPath $approve) -and $script:BashPath) {
        Push-Location $TargetPath
        & $script:BashPath -c './.claude/hooks/approve.sh --init-key' *> $null
        Pop-Location
        $made = Test-Path -LiteralPath $KeyFile
    }
    if (-not $made) {
        # .NET RNG. Do not use Get-Random here: it is seeded and not
        # cryptographic, and this key is the only thing standing between an
        # agent and forging its own approvals.
        $bytes = New-Object byte[] 32
        $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        $rng.GetBytes($bytes)
        $hex = -join ($bytes | ForEach-Object { $_.ToString('x2') })
        Write-TextLf -Path $KeyFile -Content $hex
        $made = Test-Path -LiteralPath $KeyFile
    }
    if ($made) {
        Add-ManifestLine 'F secrets/escalation.key'
        Write-Ok 'generated secrets\escalation.key'
    } else {
        Write-Warn 'could not generate an escalation key.'
        Write-Cont 'Without it, every escalatable refusal becomes a hard wall: the guard'
        Write-Cont 'refuses and no human approval can lift it. Run:'
        Write-Cont '    bash .claude/hooks/approve.sh --init-key'
    }
}

# ===========================================================================
# SECTION 9 -- the domain interview
# ===========================================================================
if ($Domain -eq 'interactive' -and -not $WhatIfPreference) {
    Write-Head 'Domain pack interview'
    $iv = Join-Path $TargetPath '.claude\hooks\interview.sh'
    if ((Test-Path -LiteralPath $iv) -and $script:BashPath) {
        Push-Location $TargetPath
        & $script:BashPath -c "PROJECT_NAME='$ProjectName' ./.claude/hooks/interview.sh"
        Pop-Location
    } else {
        Write-Warn 'interview.sh not installed (or no bash); skipping. Run it later:'
        Write-Cont '    bash .claude/hooks/interview.sh'
    }
}

# ===========================================================================
# SECTION 10 -- brace-marker substitution
# ===========================================================================
Write-Head 'Substituting doctrine markers'

$domainSh = Join-Path $TargetPath '.claude\hooks\domain.config.sh'
$stackSh  = Join-Path $TargetPath ".claude\hooks\stack\$Stack.sh"

$verifyCmd  = Get-ShellVar $stackSh  'VERIFY_CMD'
$fastCmd    = Get-ShellVar $stackSh  'FAST_TEST_CMD'
$scopedCmd  = Get-ShellVar $stackSh  'SCOPED_TEST_CMD'
$stackNameV = Get-ShellVar $stackSh  'STACK_NAME'; if (-not $stackNameV) { $stackNameV = $Stack }
$arbiter    = Get-ShellVar $domainSh 'ARBITER_LABEL'; if (-not $arbiter) { $arbiter = 'Escalate to a higher-tier model' }
$domName    = Get-ShellVar $domainSh 'DOMAIN_NAME';  if (-not $domName) { $domName = 'none' }
$domDesc    = Get-ShellVar $domainSh 'DOMAIN_DESCRIPTION'
if (-not $domDesc) { $domDesc = 'a software project with no declared domain pack' }
$domLaws    = Get-ShellVar $domainSh 'DOMAIN_LAWS'
$domLens    = Get-ShellVar $domainSh 'DOMAIN_REVIEW_LENS'
$domPass    = Get-ShellVar $domainSh 'DOMAIN_SECURITY_PASS'
$domMat     = Get-ShellVar $domainSh 'DOMAIN_MATERIALITY'
if (-not $domMat) { $domMat = 'it changes a rule that later milestones will inherit rather than re-derive' }
$domHard    = Get-ShellVar $domainSh 'DOMAIN_HARD_STOPS'
if (-not $domHard) { $domHard = 'This domain declared no additional irreversible action; the harness-fixed list above is the whole wall.' }

# BOTH SPELLINGS of every marker are emitted. The prefixed form
# ({{RATCHET_BASE_BRANCH}}) and the bare form ({{BASE_BRANCH}}) are both in
# active use across the harness's documents, and an installer that filled only
# one spelling would leave literal braces sitting inside an agent's system
# prompt, where they read as instructions to nobody.
$Subs = @{
    'PROJECT_NAME' = $ProjectName;                  'RATCHET_PROJECT_NAME' = $ProjectName
    'PROJECT_DIR'  = ($TargetPath -replace '\\','/'); 'RATCHET_PROJECT_DIR' = ($TargetPath -replace '\\','/')
    'RT_VERSION'   = $RtInstallerVersion;           'RATCHET_VERSION' = $RtInstallerVersion
    'STACK_NAME'   = $stackNameV;                   'RATCHET_STACK_NAME' = $stackNameV
    'BASE_BRANCH'  = $BaseBranch;                   'RATCHET_BASE_BRANCH' = $BaseBranch
    'AGENT_BRANCH_PREFIX' = 'agent/';               'RATCHET_AGENT_BRANCH_PREFIX' = 'agent/'
    'ESCALATION_MODE' = $EscalationMode;            'RATCHET_ESCALATION_MODE' = $EscalationMode
    'FORGE' = 'github';                             'RATCHET_FORGE' = 'github'
    'SECRETS_DIR' = 'secrets';                      'RATCHET_SECRETS_DIR' = 'secrets'
    'ESCALATION_KEY' = 'secrets/escalation.key';    'RATCHET_ESCALATION_KEY' = 'secrets/escalation.key'
    'VERIFY_CMD' = $verifyCmd;                      'RATCHET_VERIFY_CMD' = $verifyCmd
    'FAST_TEST_CMD' = $fastCmd;                     'SCOPED_TEST_CMD' = $scopedCmd
    'ARBITER_LABEL' = $arbiter;                     'RATCHET_ARBITER_LABEL' = $arbiter
    'DOMAIN_NAME' = $domName;                       'RATCHET_DOMAIN_NAME' = $domName
    'DOMAIN_DESCRIPTION' = $domDesc;                'DOMAIN_LAWS' = $domLaws
    'DOMAIN_REVIEW_LENS' = $domLens;                'DOMAIN_SECURITY_PASS' = $domPass
    'DOMAIN_MATERIALITY' = $domMat;                 'DOMAIN_HARD_STOPS' = $domHard
}

if ($WhatIfPreference) {
    Write-Info "WhatIf: would substitute $($Subs.Count) markers across .claude\, .context\, docs\"
} else {
    $roots = @('.claude\agents', '.claude\hooks', '.context', '.agent-development', 'docs')
    $extra = @('.claude\settings.json', 'CLAUDE.md', 'CLAUDE.ratchet.md')
    $skipExt  = @('.pyc','.png','.jpg','.gif','.zip','.gz','.key','.pem')
    $skipName = @('domain.config.sh')
    $files = New-Object System.Collections.Generic.List[string]
    foreach ($e in $extra) {
        $p = Join-Path $TargetPath $e
        if (Test-Path -LiteralPath $p) { $files.Add($p) }
    }
    foreach ($r in $roots) {
        $p = Join-Path $TargetPath $r
        if (-not (Test-Path -LiteralPath $p)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $p -Recurse -File -ErrorAction SilentlyContinue)) {
            if ($skipName -contains $f.Name) { continue }
            if ($skipExt -contains $f.Extension.ToLower()) { continue }
            if ($f.FullName -like '*__pycache__*') { continue }
            $files.Add($f.FullName)
        }
    }
    $changed = 0
    $unresolved = @{}
    # Deliberately NOT [regex]::Replace with a ScriptBlock evaluator. That needs
    # a ScriptBlock-to-MatchEvaluator delegate conversion, which is reliable on
    # PowerShell 7 and is exactly the kind of thing that fails on 5.1 with an
    # error nobody can read. Two passes of plain string work is boring, fast
    # enough for a few hundred small files, and behaves identically on both.
    $rx = New-Object System.Text.RegularExpressions.Regex('\{\{([A-Z0-9_]+)\}\}')
    foreach ($fp in $files) {
        $text = $null
        try { $text = [System.IO.File]::ReadAllText($fp) } catch { continue }
        if (-not $text) { continue }
        if ($text.IndexOf('{{') -lt 0) { continue }
        $orig = $text
        $names = @()
        foreach ($m in $rx.Matches($text)) { $names += $m.Groups[1].Value }
        foreach ($k in ($names | Select-Object -Unique)) {
            if ($Subs.ContainsKey($k)) {
                $text = $text.Replace(('{{' + $k + '}}'), [string]$Subs[$k])
            } else {
                if (-not $unresolved.ContainsKey($k)) { $unresolved[$k] = @() }
                $unresolved[$k] += (Get-RelPath $fp)
            }
        }
        if ($text -ne $orig) {
            Write-TextLf -Path $fp -Content $text
            $changed++
        }
    }
    Write-Ok "substituted markers in $changed files"
    if ($unresolved.Count -gt 0) {
        Write-Warn 'some brace markers had no value and were LEFT IN PLACE:'
        foreach ($k in ($unresolved.Keys | Sort-Object)) {
            Write-Cont ("  {{$k}}  in  " + (($unresolved[$k] | Select-Object -Unique -First 4) -join ', '))
        }
        Write-Cont 'A surviving marker is not cosmetic. In an agent definition it becomes'
        Write-Cont 'literal text in a system prompt, and the model reads the braces as a'
        Write-Cont 'string rather than as your test command. Fix the domain pack and re-run:'
        Write-Cont '    .\install.ps1 -Target . -SubstituteOnly'
    }
}

if (-not $WhatIfPreference) {
    $state = [PSCustomObject]@{
        project_name = $ProjectName; stack = $Stack; base_branch = $BaseBranch
        escalation_mode = $EscalationMode; domain_mode = $Domain
        installer_version = $RtInstallerVersion
        installed_at = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        installed_by = 'install.ps1'
        bash_path = $script:BashPath; bash_kind = $script:BashKind; python = $script:Py
    }
    Write-TextLf -Path $StatePath -Content ($state | ConvertTo-Json -Depth 8)
    Add-ManifestLine 'F .claude/.ratchet-install.json'
}

if ($SubstituteOnly) {
    Write-Head 'Substitution-only run complete'
    Write-Host '  Nothing else was touched.'
    exit 0
}

# ===========================================================================
# SECTION 11 -- PENDING-HUMAN-ACTIONS
# ===========================================================================
Write-Head 'Pre-filing the three human actions'
$phaRel  = '.agent-development/PENDING-HUMAN-ACTIONS.md'
$phaPath = Join-Path $TargetPath ($phaRel -replace '/', '\')
$phaHave = $false
if (Test-Path -LiteralPath $phaPath) {
    $phaHave = (Select-String -LiteralPath $phaPath -Pattern 'ratchet-install-human-actions' -Quiet)
}
if ($phaHave) {
    Write-Ok "$phaRel already carries the install actions"
} elseif ((Confirm-Change $phaRel 'file three human actions')) {
    $d = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
    $cur = ''
    if (Test-Path -LiteralPath $phaPath) { $cur = [System.IO.File]::ReadAllText($phaPath) }
    if (-not $cur) {
        $cur = @"
# PENDING HUMAN ACTIONS

This register exists so that "someone must do X" stops being filed as a
decision. A to-do recorded as a decision is both a bloated decision log and a
task nobody tracks.

Agents APPEND here. Humans close rows by editing the Status column to DONE and
saying what they did. Nothing here is ever deleted; a closed row is evidence.

| name | opened | who | action | status |
|---|---|---|---|---|

"@
        Add-ManifestLine "F $phaRel"
    }
    $cur += "| webhook-url-unset | $d | human | Set ``RATCHET_WEBHOOK_URL`` to an https endpoint (Slack/Discord/ntfy) so ``notify.sh`` can page you when a run stops for a Decision Card. Unset, the harness still works, but an unattended run that stops is a run you find out about by looking. <!-- ratchet-install-human-actions --> | OPEN |`n"
    $cur += "| base-branch-unprotected | $d | human | Enable branch protection on ``$BaseBranch`` (require a PR, block force push). This is the ONLY server-side control in the ship flow. ``ship-consent.json`` is a record, not a control; the permission prompt is a per-command approval. Branch protection is what actually stops an unreviewed merge. | OPEN |`n"
    $cur += "| spec-and-milestones-empty | $d | human | Fill ``.context/SPEC.md`` (frozen requirement ids) and ``.context/MILESTONES.md`` (WIN rows, each with a script-decidable verify command). Until both exist the run has no definition of done, and every gate that reads them will refuse rather than guess. | OPEN |`n"
    Write-TextLf -Path $phaPath -Content $cur
    Write-Ok "filed 3 open actions in $phaRel"
}

# ===========================================================================
# SECTION 12 -- VERIFICATION
# ===========================================================================
$verifyRc = 0
$verifyState = 'not run'
if (-not $SkipVerify -and -not $WhatIfPreference) {
    Write-Head 'Install verification (test_hooks.py)'
    $th = Join-Path $TargetPath '.claude\hooks\test_hooks.py'
    if (Test-Path -LiteralPath $th) {
        Push-Location $TargetPath
        $pyParts = $script:Py -split ' '
        $pyExe = $pyParts[0]
        $pyPre = @()
        if ($pyParts.Length -gt 1) { $pyPre = $pyParts[1..($pyParts.Length - 1)] }
        $out = & $pyExe @pyPre '.claude/hooks/test_hooks.py' 2>&1
        $verifyRc = $LASTEXITCODE
        Pop-Location
        if ($verifyRc -eq 0) {
            $verifyState = 'PASS'
            Write-Host '  PASS  the hook suite is green on this host.' -ForegroundColor Green
            $out | Select-Object -Last 5 | ForEach-Object { Write-Host ('          ' + $_) }
        } else {
            $verifyState = 'FAIL'
            Write-Host ''
            Write-Host '  ================ INSTALL VERIFICATION FAILED ================' -ForegroundColor Red
            Write-Host "  test_hooks.py exited $verifyRc. The harness is installed but at least"
            Write-Host '  one gate does not behave the way its own tests say it should.'
            Write-Host ''
            $out | Select-Object -Last 30 | ForEach-Object { Write-Host ('    ' + $_) }
            Write-Host ''
            Write-Host '  Do not start a milestone on a red suite. A gate whose test fails is a'
            Write-Host '  gate you cannot reason about, and the whole value of this harness is'
            Write-Host '  that a refusal means something. Re-run the suite yourself:'
            Write-Host "      cd $TargetPath ; $($script:Py) .claude\hooks\test_hooks.py"
            Write-Host '  ============================================================' -ForegroundColor Red
            Write-Host ''
        }
    } else {
        $script:MissingFiles.Add('.claude/hooks/test_hooks.py') | Out-Null
        $verifyState = 'SKIPPED (test_hooks.py not installed)'
        Write-Warn 'test_hooks.py is not present, so the install was NOT verified.'
        Write-Cont 'An unverified control layer is the one thing this harness cannot check'
        Write-Cont 'for you. Run the suite as soon as the file exists.'
    }

    # R-005-03: an approved .claude\ write is judged on whether it made the hook
    # suite WORSE, not on whether the suite is perfect. On a host with
    # pre-existing failures and no baseline, every failure counts as new and the
    # postcondition can never clear -- turning an approvable write into a
    # permanent wall for reasons unrelated to the write. Record the floor now.
    $approve = Join-Path $TargetPath '.claude\hooks\approve.sh'
    if ((Test-Path -LiteralPath $approve) -and $script:BashPath) {
        Push-Location $TargetPath
        & $script:BashPath -c './.claude/hooks/approve.sh --postcondition-baseline' *> $null
        $rc = $LASTEXITCODE
        Pop-Location
        if ($rc -eq 0) { Write-Ok 'recorded the control-layer postcondition baseline' }
        else {
            Write-Warn 'could not record the postcondition baseline automatically. Run it yourself:'
            Write-Cont '    bash .claude/hooks/approve.sh --postcondition-baseline'
            Write-Cont 'Skipping it is only harmless on a host where the suite is fully green.'
        }
    }
}

# ===========================================================================
# SECTION 13 -- finalise the manifest
# ===========================================================================
if (-not $WhatIfPreference) {
    $lines = @($script:ManifestLines | Sort-Object -Unique)
    $hdr = @(
        "# Ratchet install manifest -- written by install.ps1 $RtInstallerVersion at $((Get-Date).ToUniversalTime().ToString('u'))",
        '# Read by: install.ps1 -Uninstall. Lines: "F <rel>" file, "D <rel>" dir,',
        '# "B <backup-rel> <original-rel>" a backup that uninstall restores.'
    )
    Write-TextLf -Path $ManifestPath -Content ((($hdr + $lines) -join "`n") + "`n")
}

# ===========================================================================
# SECTION 14 -- REPORT
# ===========================================================================
Write-Head '======================================================================'
if ($WhatIfPreference) {
    Write-Host '  WHATIF COMPLETE. Nothing above was written.'
    Write-Host '  Re-run without -WhatIf to apply.'
    Write-Head '======================================================================'
    exit 0
}

Write-Host "  Ratchet $RtInstallerVersion installed into: $TargetPath"
Write-Host "    project name    $ProjectName"
Write-Host "    stack pack      $Stack"
Write-Host "    domain pack     $Domain"
Write-Host "    base branch     $BaseBranch"
Write-Host "    escalation      $EscalationMode"
Write-Host "    hook shell      $($script:BashKind) -- $($script:BashPath)"
Write-Host "    python          $($script:Py)"
Write-Host "    verification    $verifyState"
Write-Host "    warnings        $($script:Warnings)"

if ($script:MissingFiles.Count -gt 0) {
    Write-Head 'Files the harness source did not contain'
    foreach ($m in ($script:MissingFiles | Sort-Object -Unique)) { Write-Host "    missing: $m" }
    Write-Host ''
    Write-Host '  Each of those is a component that is now NOT installed. If this is a'
    Write-Host '  development checkout that is expected; if it is a release, the release is'
    Write-Host '  incomplete and you should not run a milestone against it.'
}

Write-Head 'THREE THINGS ONLY A HUMAN CAN DO'
Write-Host ''
Write-Host '  1. PAGER. Set the webhook so a stopped run reaches you.'
Write-Host '         setx RATCHET_WEBHOOK_URL "https://hooks.slack.com/services/..."'
Write-Host '     (setx persists it for new terminals; the current one needs a restart.)'
Write-Host '     Without it the harness still works; you just find out it stopped by'
Write-Host '     going and looking.'
Write-Host ''
Write-Host "  2. BRANCH PROTECTION on '$BaseBranch'. Require a pull request, block force"
Write-Host '     pushes. Do this even though the harness already gates merges, because'
Write-Host '     the harness''s gate is a record and a prompt, and this is a server-side'
Write-Host '     rule. It is the only one of the three an agent cannot route around.'
Write-Host '     Settings > Branches > Add rule, or:'
Write-Host "         gh api -X PUT repos/{owner}/{repo}/branches/$BaseBranch/protection ..."
Write-Host ''
Write-Host '  3. FILL THE TWO CONTRACTS. Nothing runs without them:'
Write-Host '         .context\SPEC.md         requirement ids, frozen, cited by every test'
Write-Host '         .context\MILESTONES.md   WIN rows, each with a verify command that'
Write-Host '                                  exits 0 for pass. A WIN row without one is a'
Write-Host '                                  setup defect, and the harness will say so'
Write-Host '                                  rather than quietly judge it by vibes.'
Write-Host ''
Write-Host '  All three are already filed in .agent-development\PENDING-HUMAN-ACTIONS.md.'

Write-Head 'YOUR FIRST COMMAND TO CLAUDE CODE'
Write-Host ''
Write-Host "  cd $TargetPath"
Write-Host '  claude'
Write-Host ''
Write-Host '  Then paste exactly this:'
Write-Host ''
Write-Host '      Read .context/CLAUDE.md, .context/SPEC.md and .context/MILESTONES.md.'
Write-Host '      Confirm you understand the four-directory ownership partition and the'
Write-Host '      two human stop points, then run milestone M0.'
Write-Host ''
Write-Host '  If M0 does not exist yet, say "propose an M0 with two WIN rows and stop"'
Write-Host '  instead -- it will write the milestone and wait for you, which is the'
Write-Host '  cheapest way to see the gates work before you spend a real run on them.'
Write-Head '======================================================================'

if ($verifyState -eq 'FAIL') { exit 1 }
exit 0
