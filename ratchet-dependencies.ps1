<#
.SYNOPSIS
    Install what Ratchet's host check requires (Windows).

.DESCRIPTION
    Run this BEFORE install.ps1 (or install.sh under Git-Bash) when the host
    check refuses. It works out what is missing, shows you the exact command it
    wants to run, asks before running it, and -- when it cannot install
    something itself -- prints the precise command or download URL instead of
    guessing.

    It is safe to run repeatedly. It only ever acts on what is actually
    missing, so a second run on a fixed host installs nothing and exits 0.

    WHAT IT MANAGES (exactly what install.ps1's host check tests for):
      FATAL   bash 4+   every Ratchet hook is a bash script. On Windows that
                        means Git-Bash, which arrives with Git for Windows.
      FATAL   git       the gates read the worktree on every hook firing
      FATAL   jq        hooks parse a JSON payload; without jq the security
                        guards fail CLOSED, so the agent can run nothing at all
      FATAL   python3   four gates are Python; the ship gate needs them
      WARN    gh        needed only by the ship flow (open PR, merge)
      OFFER   pytest ruff       stack pack: python-pytest
      OFFER   node npm          stack pack: node-jest

    THREE WINDOWS FACTS THIS SCRIPT IS BUILT AROUND:

    1. THE MICROSOFT STORE PYTHON STUB. A default Windows 11 PATH contains
       python.exe and python3.exe in ...\WindowsApps\. They are placeholders
       that open the Store and exit. They answer Get-Command perfectly. Only
       RUNNING them tells the truth, so this script runs them, and if it finds
       a stub it says so by name and tells you how to switch it off.

    2. WINGET'S PYTHON IS THE PYTHON.ORG BUILD, NOT THE STORE ONE. That is why
       Python.Python.3.12 is the id used below and why we never send you to
       the Store: the Store build sandboxes its file access and installs into a
       per-user location that Git-Bash frequently cannot see.

    3. GIT-BASH HAS ITS OWN PATH. A tool that PowerShell can see is not
       necessarily a tool your hooks can see. After installing, this script
       asks Git-Bash itself whether it can find jq, because Git-Bash's answer
       is the one that matters.

    WHAT IT WILL NOT DO, ON PURPOSE:
      - It never installs anything without showing the command and asking,
        unless you pass -Yes.
      - It never elevates itself. Chocolatey needs an Administrator shell; this
        script prints the command and tells you where to run it.
      - It never installs Python packages into a system interpreter.
      - It never installs an optional stack tool without a separate yes.

.PARAMETER Target
    The repo you intend to install Ratchet into. Used to pick the stack and to
    print the exact next command. Default: the current directory.

.PARAMETER Stack
    python-pytest | node-jest | generic | none. Default: auto-detected.

.PARAMETER Check
    Report status and exit. Install nothing.

.PARAMETER DryRun
    Print every command that would run; change nothing. Same as -WhatIf.

.PARAMETER Yes
    Assume yes at every prompt, including the optional stack tools.

.PARAMETER NoOptional
    Do not even offer the stack pack tools.

.EXAMPLE
    .\ratchet-dependencies.ps1 -Check

.EXAMPLE
    .\ratchet-dependencies.ps1 -Target ..\my-repo -Stack python-pytest

.NOTES
    PowerShell 5.1 and PowerShell 7 compatible. No modules required.
    Exit codes:
      0  every FATAL dependency is present
      1  a FATAL dependency is still missing after this run
      2  refused before doing anything (bad arguments)
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string] $Target = '.',
    [ValidateSet('python-pytest', 'node-jest', 'generic', 'none', '')]
    [string] $Stack = '',
    [switch] $Check,
    [switch] $DryRun,
    [switch] $Yes,
    [switch] $NoOptional
)

# StrictMode 1.0 for the same reason install.ps1 uses it: it catches the typo'd
# variable that silently evaluates to $null and turns a refusal into a no-op,
# without throwing on every defensive property read.
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Continue'

$RtDepsVersion = '1.0.0'

# $LASTEXITCODE does not exist until a native command has run, and StrictMode
# 1.0 prohibits reading an uninitialised variable. Seed it so the first probe
# that checks it cannot throw.
$global:LASTEXITCODE = 0

$script:DryRun = $false
if ($DryRun) { $script:DryRun = $true }
if ($WhatIfPreference) { $script:DryRun = $true }

# ---------------------------------------------------------------- output ----
# Same shapes as install.ps1 and install.sh: ok / .. / WARN / FAIL / continuation.
# Colour degrades when NO_COLOR is set or when the host cannot colour.
$script:UseColor = $true
if ($env:NO_COLOR) { $script:UseColor = $false }

function Write-C {
    param([string] $Text, [string] $Color)
    if ($script:UseColor -and $Color) {
        Write-Host $Text -ForegroundColor $Color
    } else {
        Write-Host $Text
    }
}

$script:Warnings = 0

function Write-Head { param([string] $Text) Write-Host ''; Write-C $Text 'White' }
function Write-Ok   { param([string] $Text) Write-C ('  ok    ' + $Text) 'Green' }
function Write-Info { param([string] $Text) Write-Host ('  ..    ' + $Text) }
function Write-Warn {
    param([string] $Text)
    Write-C ('  WARN  ' + $Text) 'Yellow'
    $script:Warnings = $script:Warnings + 1
}
function Write-Fail { param([string] $Text) Write-C ('  FAIL  ' + $Text) 'Red' }
function Write-Cont {
    param([string] $Text)
    if ([string]::IsNullOrEmpty($Text)) { Write-Host '' } else { Write-Host ('        ' + $Text) }
}
function Write-Cmd  { param([string] $Text) Write-Host ('      ' + $Text) }

function Stop-Deps {
    param([string] $Reason)
    Write-Host ''
    Write-C ('ratchet-dependencies refused: ' + $Reason) 'Red'
    Write-Host ''
    exit 2
}

function Test-Command {
    param([string] $Name)
    $c = Get-Command $Name -ErrorAction SilentlyContinue
    if ($c) { return $c.Source } else { return $null }
}

function Confirm-Run {
    param([string] $Prompt)
    if ($Yes) {
        Write-Host ''
        Write-Info '-Yes given; proceeding without asking.'
        return $true
    }
    if (-not [Environment]::UserInteractive) {
        Write-Host ''
        Write-Warn 'this session is not interactive and -Yes was not given, so nothing will be run.'
        Write-Cont 'Copy the commands above, or re-run with -Yes.'
        return $false
    }
    Write-Host ''
    $answer = Read-Host ('  ' + $Prompt + ' [y/N]')
    if ($answer -match '^(y|Y|yes|YES|Yes)$') { return $true }
    return $false
}

function Invoke-Step {
    # Prints the command, then runs it -- unless this is a dry run, in which
    # case it prints and returns. Nothing in this script runs a command that
    # was not printed first.
    param([string] $Exe, [string[]] $Arguments)
    $line = $Exe + ' ' + ($Arguments -join ' ')
    if ($script:DryRun) {
        Write-C ('  DRY   ' + $line) 'Yellow'
        return $true
    }
    Write-C ('  run   ' + $line) 'White'
    # Out-Host, not a bare call: anything a native command writes to the
    # success stream would otherwise be appended to this function's return
    # value, and the caller's $true would arrive as an array.
    & $Exe @Arguments 2>&1 | Out-Host
    if ($LASTEXITCODE -eq 0) { return $true }
    return $false
}

function Update-SessionPath {
    # winget and choco write to the machine/user PATH in the registry. The
    # already-running shell keeps its stale copy, so a freshly installed tool
    # looks missing and the status table would lie. Re-read both scopes.
    try {
        $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $user    = [Environment]::GetEnvironmentVariable('Path', 'User')
        $joined  = @()
        if ($machine) { $joined += $machine }
        if ($user)    { $joined += $user }
        if ($joined.Count -gt 0) { $env:Path = ($joined -join ';') }
    } catch {
        Write-Info 'could not refresh PATH from the registry; open a new terminal to see new tools.'
    }
}

# ============================================================================
# SECTION 1 -- PLATFORM
# ============================================================================
Write-Head ("Ratchet dependency installer $RtDepsVersion -- platform (Windows)")

Write-Ok ("PowerShell $($PSVersionTable.PSVersion)")
if ($PSVersionTable.PSVersion.Major -lt 5) {
    Write-Fail 'PowerShell 5.1 or newer is required to run this script.'
    Write-Cont 'Windows 10 and 11 ship 5.1. If you are on something older, upgrade'
    Write-Cont 'Windows Management Framework first.'
    exit 2
}

# This is the Windows-side script. If it is somehow running on Linux or macOS
# (PowerShell 7 is cross-platform), say so and point at the shell script, which
# is the correct tool there and knows about apt/dnf/pacman/apk/brew.
$script:OnWindows = $true
try {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        if (-not $IsWindows) { $script:OnWindows = $false }
    }
} catch {
    $script:OnWindows = $true
}
if (-not $script:OnWindows) {
    Write-Warn 'this is the Windows script and you are not on Windows.'
    Write-Cont 'Use the shell script instead; it knows your package manager:'
    Write-Cont '    ./ratchet-dependencies.sh --check'
    Write-Host ''
    exit 2
}

# --- package manager -------------------------------------------------------
$script:Pm    = ''
$script:PmExe = ''
$wingetExe = Test-Command 'winget'
$chocoExe  = Test-Command 'choco'
if ($wingetExe) {
    $script:Pm = 'winget'; $script:PmExe = 'winget'
} elseif ($chocoExe) {
    $script:Pm = 'choco';  $script:PmExe = 'choco'
}

if ($script:Pm -eq 'winget') {
    Write-Ok 'package manager: winget'
} elseif ($script:Pm -eq 'choco') {
    Write-Ok 'package manager: chocolatey'
    Write-Cont 'winget was not found. choco works, but it needs an Administrator shell,'
    Write-Cont 'so its commands are printed for you to run there rather than run here.'
} else {
    Write-Warn 'neither winget nor choco was found.'
    Write-Cont 'winget ships with Windows 11 and with recent Windows 10 (it comes from'
    Write-Cont 'the App Installer package). Nothing will be installed automatically;'
    Write-Cont 'you will get exact download links instead.'
}

# --- elevation -------------------------------------------------------------
# We never elevate ourselves. We report whether we are elevated so the advice
# about choco is correct, and winget raises its own UAC prompt when it needs to.
$script:IsAdmin = $false
try {
    $wid = [Security.Principal.WindowsIdentity]::GetCurrent()
    $wpr = New-Object Security.Principal.WindowsPrincipal($wid)
    $script:IsAdmin = $wpr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {
    $script:IsAdmin = $false
}
if ($script:IsAdmin) {
    Write-Ok 'this shell is elevated (Administrator)'
} else {
    Write-Info 'this shell is NOT elevated. winget will raise its own UAC prompt when it needs one.'
}

# --- target ----------------------------------------------------------------
$script:TargetPath = $null
try {
    $script:TargetPath = (Resolve-Path -LiteralPath $Target -ErrorAction Stop).Path
} catch {
    $script:TargetPath = $null
}
if ($script:TargetPath) {
    Write-Ok ('target repo: ' + $script:TargetPath)
} else {
    Write-Warn ("target '$Target' does not exist yet; stack detection will fall back to 'generic'.")
}

# ============================================================================
# SECTION 1b -- THE WSL / WINDOWS SPLIT
# The single most expensive misconfiguration this harness can be handed, so it
# gets a section rather than a line.
# ============================================================================
$script:TargetInWsl = $false
if ($script:TargetPath) {
    if ($script:TargetPath -like '\\wsl$\*' -or $script:TargetPath -like '\\wsl.localhost\*') {
        $script:TargetInWsl = $true
    }
}

$script:WslPresent = $false
if (Test-Path -LiteralPath ($env:SystemRoot + '\System32\wsl.exe')) { $script:WslPresent = $true }

if ($script:TargetInWsl) {
    Write-Head 'Your repo is inside WSL and you are on the Windows side -- read this'
    Write-Host '  Everything has to live in ONE world. WSL and Windows do not share a'
    Write-Host '  filesystem: WSL sees /home/you/repo, Windows sees C:\Users\you\repo, and'
    Write-Host '  no single path satisfies both. A Windows Python driving a WSL bash (or'
    Write-Host '  the reverse) hands the hooks paths that do not exist on the other side,'
    Write-Host '  and every error message then names a file that plainly does exist.'
    Write-Host ''
    Write-Warn ('the target is a WSL path: ' + $script:TargetPath)
    Write-Cont 'Installing Windows packages from here will NOT help that repo. Do this'
    Write-Cont 'instead -- open a WSL shell and run the shell script there:'
    Write-Cont '    wsl'
    Write-Cont '    cd ~/your-repo'
    Write-Cont '    ./ratchet-dependencies.sh --check'
    Write-Cont ''
    Write-Cont 'Or move the project onto the Windows filesystem and stay here.'
} elseif ($script:WslPresent) {
    Write-Head 'WSL is present on this machine -- one rule'
    Write-Host '  You are on the Windows side, which is fine, and this script will set up'
    Write-Host '  the Windows side. Just do not mix: if the project lives under C:\ , use'
    Write-Host '  Git-Bash and a python.org Python. If it lives under \\wsl$\ , do all of'
    Write-Host '  it inside WSL with ratchet-dependencies.sh. A WSL shell driving a'
    Write-Host '  Windows Python cannot work; the two filesystems do not line up.'
}

# ============================================================================
# SECTION 2 -- THE DEPENDENCY TABLE
# One record per dependency: tier, live status, and the identifier each package
# manager knows it by. Everything downstream reads this table; nothing hardcodes
# a package name twice.
# ============================================================================
function New-Dep {
    param(
        [string] $Name, [string] $Tier,
        [string] $WingetId, [string] $ChocoId, [string] $Url
    )
    $o = New-Object psobject
    Add-Member -InputObject $o -MemberType NoteProperty -Name Name     -Value $Name
    Add-Member -InputObject $o -MemberType NoteProperty -Name Tier     -Value $Tier
    Add-Member -InputObject $o -MemberType NoteProperty -Name Status   -Value 'unknown'
    Add-Member -InputObject $o -MemberType NoteProperty -Name Detail   -Value ''
    Add-Member -InputObject $o -MemberType NoteProperty -Name WingetId -Value $WingetId
    Add-Member -InputObject $o -MemberType NoteProperty -Name ChocoId  -Value $ChocoId
    Add-Member -InputObject $o -MemberType NoteProperty -Name Url      -Value $Url
    return $o
}

$script:Deps = @{}
# bash and git are ONE package on Windows: Git for Windows ships Git-Bash.
# The table says so twice on purpose, and the plan de-duplicates by id.
$script:Deps['bash']    = New-Dep 'bash'    'FATAL' 'Git.Git'            'git'       'https://git-scm.com/download/win'
$script:Deps['git']     = New-Dep 'git'     'FATAL' 'Git.Git'            'git'       'https://git-scm.com/download/win'
$script:Deps['jq']      = New-Dep 'jq'      'FATAL' 'jqlang.jq'          'jq'        'https://jqlang.github.io/jq/download/'
$script:Deps['python3'] = New-Dep 'python3' 'FATAL' 'Python.Python.3.12' 'python'    'https://www.python.org/downloads/windows/'
$script:Deps['gh']      = New-Dep 'gh'      'warn'  'GitHub.cli'         'gh'        'https://cli.github.com'
$script:Deps['pytest']  = New-Dep 'pytest'  'opt'   ''                   ''          'python -m pip install --user pytest'
$script:Deps['ruff']    = New-Dep 'ruff'    'opt'   ''                   ''          'python -m pip install --user ruff'
$script:Deps['node']    = New-Dep 'node'    'opt'   'OpenJS.NodeJS.LTS'  'nodejs-lts' 'https://nodejs.org/en/download'
$script:Deps['npm']     = New-Dep 'npm'     'opt'   'OpenJS.NodeJS.LTS'  'nodejs-lts' 'https://nodejs.org/en/download'

function Set-DepStatus {
    param([string] $Name, [string] $Status, [string] $Detail)
    if ($script:Deps.ContainsKey($Name)) {
        $script:Deps[$Name].Status = $Status
        $script:Deps[$Name].Detail = $Detail
    }
}
function Get-DepStatus {
    param([string] $Name)
    if ($script:Deps.ContainsKey($Name)) { return $script:Deps[$Name].Status }
    return 'unknown'
}

# ============================================================================
# SECTION 3 -- PROBES. Test by RUNNING things, never by their presence on PATH.
# ============================================================================
Write-Head 'Dependencies'

function Find-Bash {
    # Returns a two-element array: path, kind. Kind matters: a WSL bash is a
    # different filesystem, not just a different binary.
    $cands = @()
    $onPath = Test-Command 'bash'
    if ($onPath) { $cands += ,@($onPath, 'PATH') }
    $cands += ,@(($env:ProgramFiles + '\Git\bin\bash.exe'), 'Git-Bash')
    $cands += ,@((${env:ProgramFiles(x86)} + '\Git\bin\bash.exe'), 'Git-Bash (x86)')
    $cands += ,@(($env:LOCALAPPDATA + '\Programs\Git\bin\bash.exe'), 'Git-Bash (user)')
    $cands += ,@(($env:SystemRoot + '\System32\bash.exe'), 'WSL')

    foreach ($cand in $cands) {
        $p = $cand[0]
        $kind = $cand[1]
        if (-not $p) { continue }
        if (-not (Test-Path -LiteralPath $p)) { continue }
        $ver = & $p -c 'echo ${BASH_VERSINFO[0]}' 2>$null
        if ($LASTEXITCODE -eq 0 -and $ver) {
            $major = 0
            [void][int]::TryParse(("$ver").Trim(), [ref] $major)
            if ($major -ge 4) { return ,@($p, $kind, $major) }
        }
    }
    return $null
}

$script:BashPath = $null
$script:BashKind = ''
$found = Find-Bash
if ($found) {
    $script:BashPath = $found[0]
    $script:BashKind = $found[1]
    Set-DepStatus 'bash' 'ok' ("$($found[2]).x via $($found[1])")
    Write-Ok ("bash $($found[2]) via $($found[1]) -- $($found[0])")
    if ($script:BashKind -like 'WSL*') {
        Write-Warn 'the only bash found is the WSL relay, and WSL sees a DIFFERENT FILESYSTEM.'
        Write-Cont 'A WSL bash resolves /mnt/c/... , not C:\... , so a hook handed a Windows'
        Write-Cont 'path reports that a file which plainly exists does not. Ratchet works'
        Write-Cont 'under WSL when the WHOLE workflow lives inside WSL. Mixing a Windows'
        Write-Cont 'checkout with a WSL shell is the configuration that produces the most'
        Write-Cont 'confusing failures this harness has.'
        Write-Cont 'Strongly preferred on the Windows side: install Git for Windows and'
        Write-Cont 'use its Git-Bash. This script offers exactly that below.'
        # Do not accept the WSL relay as the answer: keep bash in the plan so
        # Git for Windows is offered.
        Set-DepStatus 'bash' 'wrong-world' 'only the WSL relay was found'
    } else {
        # Hand the answer down, exactly as install.ps1 does, so the Python side
        # of the harness does not independently resolve the System32 relay.
        $env:RATCHET_BASH = $script:BashPath
    }
} else {
    Set-DepStatus 'bash' 'missing' 'no bash 4+ found'
    Write-Fail 'no usable bash found. Every Ratchet hook is a bash script.'
    Write-Cont 'Without one the harness installs and then every gate errors out on the'
    Write-Cont 'first tool call, which reads as Claude Code being broken rather than as'
    Write-Cont 'a missing dependency. On Windows, bash comes from Git for Windows.'
}

# --- git -------------------------------------------------------------------
if (Test-Command 'git') {
    $gv = ''
    try { $gv = ((& git --version) -split ' ')[2] } catch { $gv = '' }
    Set-DepStatus 'git' 'ok' $gv
    Write-Ok ('git ' + $gv)
} else {
    Set-DepStatus 'git' 'missing' 'not on PATH'
    Write-Fail 'git not found. Ratchet''s gates read the worktree on every hook firing.'
}

# --- jq (FATAL, and not negotiable) ----------------------------------------
$jqPath = Test-Command 'jq'
$script:JqSeenByBash = $false
if ($script:BashPath) {
    # The answer that matters is Git-Bash's, not PowerShell's: the hooks run
    # under Git-Bash and inherit its PATH, not this one.
    $probe = & $script:BashPath -lc 'command -v jq' 2>$null
    if ($LASTEXITCODE -eq 0 -and $probe) {
        $script:JqSeenByBash = $true
        if (-not $jqPath) { $jqPath = ("$probe").Trim() }
    }
}
if ($jqPath) {
    Set-DepStatus 'jq' 'ok' $jqPath
    Write-Ok ('jq found: ' + $jqPath)
    if ($script:BashPath -and -not $script:JqSeenByBash) {
        Write-Warn 'PowerShell can see jq but Git-Bash cannot, and Git-Bash is what runs the hooks.'
        Write-Cont 'The blunt, reliable fix is to put jq.exe where Git-Bash always looks:'
        Write-Cont '    copy jq.exe into "C:\Program Files\Git\usr\bin"'
        Write-Cont 'Confirm with:  bash -lc "command -v jq"'
    }
} else {
    Set-DepStatus 'jq' 'missing' 'not on PATH'
    Write-Fail 'jq not found. This is a HARD requirement, not a nicety.'
    Write-Cont 'Every Ratchet hook parses its payload as JSON. A security decision made'
    Write-Cont 'without a real JSON parser is a guess, so the guards fail CLOSED when jq'
    Write-Cont 'is absent -- meaning every Bash tool call the agent makes is blocked.'
    Write-Cont 'A Ratchet install without jq is a repo the agent cannot work in at all.'
}

# --- python3, with the Store stub handled by name --------------------------
function Get-WorkingPython {
    $cands = @()
    if ($env:RATCHET_PYTHON) { $cands += $env:RATCHET_PYTHON }
    $cands += @('python3', 'python', 'py -3')
    foreach ($c in $cands) {
        $exe = $c
        $pre = @()
        if ($c -like '* *') {
            $parts = $c -split ' '
            $exe = $parts[0]
            $pre = $parts[1..($parts.Length - 1)]
        }
        if (-not (Test-Command $exe)) { continue }
        # THE STORE STUB TEST. The stub is a real file on PATH named
        # python3.exe that launches the Microsoft Store and exits. It answers
        # "yes" to Get-Command and "no" to actually being Python. Only running
        # it tells you which one you have.
        $out = $null
        try {
            $out = & $exe @pre '-c' 'import sys;print(sys.version_info[0])' 2>$null
        } catch {
            $out = $null
        }
        if ($LASTEXITCODE -eq 0 -and ("$out").Trim() -eq '3') { return $c }
    }
    return $null
}

function Find-StoreStub {
    # Returns the path of a WindowsApps python alias if one is shadowing PATH.
    foreach ($n in @('python3', 'python')) {
        $src = Test-Command $n
        if ($src -and ($src -like '*\WindowsApps\*')) { return $src }
    }
    return $null
}

$script:Py = Get-WorkingPython
$stub = Find-StoreStub
if ($script:Py) {
    $pv = ''
    try { $pv = & ($script:Py -split ' ')[0] '-c' 'import sys;print(sys.version.split()[0])' 2>$null } catch { $pv = '' }
    Set-DepStatus 'python3' 'ok' ("$pv (via '$($script:Py)')")
    Write-Ok ("python3 via '$($script:Py)' ($pv)")
    if ($stub) {
        Write-Warn ('a Microsoft Store python alias is also on PATH: ' + $stub)
        Write-Cont 'A real Python won this time, but PATH order is not stable across'
        Write-Cont 'terminals and installs. Switch the aliases off so it cannot win later:'
        Write-Cont '    Settings > Apps > Advanced app settings > App execution aliases'
        Write-Cont '    -> switch OFF python.exe and python3.exe'
    }
} else {
    if ($stub) {
        Set-DepStatus 'python3' 'stub' ('Microsoft Store stub at ' + $stub)
        Write-Fail 'the only "python" on PATH is the Microsoft Store stub.'
        Write-Cont ('Found at: ' + $stub)
        Write-Cont 'That file is a placeholder that opens the Store and exits. It is on the'
        Write-Cont 'default Windows 11 PATH and it fools every check except running it,'
        Write-Cont 'which is what this script just did.'
    } else {
        Set-DepStatus 'python3' 'missing' 'no working interpreter'
        Write-Fail 'no working Python 3 found (probed $env:RATCHET_PYTHON, python3, python, py -3).'
    }
    Write-Cont 'Four of Ratchet''s gates are Python: check_done.py, check_narrative.py,'
    Write-Cont 'proof_map.py, run_metrics.py. Without an interpreter the ship gate cannot'
    Write-Cont 'evaluate the definition of done, and it fails closed.'
    Write-Cont ''
    Write-Cont 'Install the python.org build -- NOT the Store one. The Store build'
    Write-Cont 'sandboxes file access and installs per-user in a place Git-Bash often'
    Write-Cont 'cannot see, and its stub aliases are what you are fighting here.'
    Write-Cont 'Then switch the aliases off:'
    Write-Cont '    Settings > Apps > Advanced app settings > App execution aliases'
    Write-Cont '    -> switch OFF python.exe and python3.exe'
}

# --- gh (warn only: the ship flow, and nothing before it) ------------------
if (Test-Command 'gh') {
    & gh auth status *> $null
    if ($LASTEXITCODE -eq 0) {
        Set-DepStatus 'gh' 'ok' 'authenticated'
        Write-Ok 'gh (authenticated)'
    } else {
        Set-DepStatus 'gh' 'unauth' 'installed, not logged in -- run: gh auth login'
        Write-Warn 'gh is installed but not authenticated. The ship flow (open PR, merge)'
        Write-Cont 'will fail at the last step of your first run. Fix now:  gh auth login'
    }
} else {
    Set-DepStatus 'gh' 'missing' 'ship flow only'
    Write-Warn 'gh (GitHub CLI) not found. Everything up to the Ship Prompt works without'
    Write-Cont 'it, but the run ends by opening a PR and merging it, and both are gh.'
}

# ============================================================================
# SECTION 4 -- OPTIONAL STACK TOOLS. Never required. A gate that cannot run its
# command SKIPS with a loud notice; it does not silently pass.
# ============================================================================
function Get-DetectedStack {
    param([string] $Path)
    if (-not $Path) { return 'generic' }
    foreach ($f in @('pyproject.toml', 'setup.py', 'pytest.ini', 'tox.ini', 'requirements.txt')) {
        if (Test-Path -LiteralPath (Join-Path $Path $f)) { return 'python-pytest' }
    }
    if (Test-Path -LiteralPath (Join-Path $Path 'package.json')) { return 'node-jest' }
    return 'generic'
}

$script:StackName = $Stack
$stackSource = 'you asked for it'
if ([string]::IsNullOrEmpty($script:StackName)) {
    $script:StackName = Get-DetectedStack $script:TargetPath
    $stackSource = 'auto-detected'
}

$script:OptionalDeps = @()
if (-not $NoOptional) {
    if ($script:StackName -eq 'python-pytest') { $script:OptionalDeps = @('pytest', 'ruff') }
    if ($script:StackName -eq 'node-jest')     { $script:OptionalDeps = @('node', 'npm') }
}

Write-Head ("Stack pack: $($script:StackName) ($stackSource)")
if ($script:OptionalDeps.Count -eq 0) {
    if ($NoOptional) {
        Write-Info 'optional tools suppressed by -NoOptional'
    } else {
        Write-Info ("the '$($script:StackName)' pack has no extra tools; every stack command is a")
        Write-Cont 'no-op and gates that need one SKIP with a loud notice rather than passing.'
    }
} else {
    foreach ($d in $script:OptionalDeps) {
        $src = Test-Command $d
        if ($src) {
            Set-DepStatus $d 'ok' $src
            Write-Ok ("$d found: $src")
        } else {
            Set-DepStatus $d 'missing' 'optional'
            Write-Info ("$d not found (optional -- the $($script:StackName) gates will SKIP loudly, not pass)")
        }
    }
}

# ============================================================================
# SECTION 5 -- PLAN
# ============================================================================
$script:PlanReq    = New-Object System.Collections.Generic.List[string]
$script:PlanOpt    = New-Object System.Collections.Generic.List[string]
$script:Manual     = New-Object System.Collections.Generic.List[string]
$script:NeedAny    = $false

function Add-Unique {
    param($ListObject, [string] $Value)
    if ([string]::IsNullOrEmpty($Value)) { return }
    if (-not $ListObject.Contains($Value)) { [void]$ListObject.Add($Value) }
}

function Add-ManualLine {
    param([string] $Name, [string] $Text)
    [void]$script:Manual.Add(('  ' + $Name.PadRight(9) + $Text))
}

function Add-ToPlan {
    param([string] $Name, [string] $Group)
    $dep = $script:Deps[$Name]
    if ($dep.Status -eq 'ok') { return }
    $script:NeedAny = $true

    # An installed-but-unauthenticated gh is a login, not an install.
    if ($Name -eq 'gh' -and $dep.Status -eq 'unauth') {
        Add-ManualLine 'gh' 'gh auth login'
        return
    }

    $id = ''
    if ($script:Pm -eq 'winget') { $id = $dep.WingetId }
    if ($script:Pm -eq 'choco')  { $id = $dep.ChocoId }

    if ($id) {
        if ($Group -eq 'opt') { Add-Unique $script:PlanOpt $id } else { Add-Unique $script:PlanReq $id }
    } else {
        Add-ManualLine $Name $dep.Url
    }
}

foreach ($d in @('bash', 'git', 'jq', 'python3', 'gh')) { Add-ToPlan $d 'req' }
foreach ($d in $script:OptionalDeps) { Add-ToPlan $d 'opt' }

function Show-Plan {
    param($ListObject, [string] $Label)
    if ($ListObject.Count -eq 0) { return }
    Write-Host ''
    Write-Host ('  ' + $Label)
    Write-Host ''
    if ($script:Pm -eq 'winget') {
        foreach ($id in $ListObject) {
            Write-Cmd ("winget install --id $id --exact --source winget --accept-package-agreements --accept-source-agreements")
        }
    } elseif ($script:Pm -eq 'choco') {
        Write-Cmd ('choco install -y ' + ($ListObject -join ' ') + '      (from an ELEVATED PowerShell)')
    }
}

Write-Head 'Plan'
if (-not $script:NeedAny) {
    Write-Ok 'nothing to do -- every dependency Ratchet needs is already here.'
} elseif ($script:PlanReq.Count -eq 0 -and $script:PlanOpt.Count -eq 0 -and $script:Manual.Count -eq 0) {
    Write-Ok 'nothing to install -- what is wrong here is fixed by the command in "Next".'
} else {
    Show-Plan $script:PlanReq 'Required (fatal to the harness, or needed by the ship flow):'
    Show-Plan $script:PlanOpt ("Optional ($($script:StackName) stack tools -- Ratchet works without them):")

    if ($script:PlanReq.Contains('Git.Git') -or $script:PlanReq.Contains('git')) {
        Write-Host ''
        Write-Info 'Git for Windows is what gives you bash. One package, two dependencies.'
        Write-Cont 'After it installs, OPEN A NEW TERMINAL before running install.ps1 --'
        Write-Cont 'the installer needs Git-Bash on PATH and this shell has a stale copy.'
    }
    if ($script:PlanReq.Contains('Python.Python.3.12') -or $script:PlanReq.Contains('python')) {
        Write-Host ''
        Write-Info 'That Python id is the python.org build, deliberately, not the Store one.'
        Write-Cont 'The Store build sandboxes file access and installs per-user where'
        Write-Cont 'Git-Bash frequently cannot reach it, and its aliases are the stub.'
    }
    if ($script:Manual.Count -gt 0) {
        Write-Host ''
        Write-Host '  Cannot be installed from here. Do these by hand:'
        foreach ($line in $script:Manual) { Write-Host $line }
    }
    if ($script:Pm -eq 'choco' -and -not $script:IsAdmin) {
        Write-Host ''
        Write-Warn 'chocolatey needs an Administrator shell and this one is not elevated.'
        Write-Cont 'This script will not elevate itself. Copy the line above into an'
        Write-Cont 'Administrator PowerShell and run it there, then re-run this script.'
    }
}

# ============================================================================
# SECTION 6 -- ACT
# ============================================================================
$script:DidInstall = $false

function Invoke-Install {
    param($ListObject)
    $allOk = $true
    if ($script:Pm -eq 'winget') {
        foreach ($id in $ListObject) {
            # NOT $args: that is an automatic variable and assigning to it is a
            # quiet way to break a function's own argument handling.
            $wgArgs = @('install', '--id', $id, '--exact', '--source', 'winget',
                        '--accept-package-agreements', '--accept-source-agreements')
            $r = Invoke-Step 'winget' $wgArgs
            if (-not $r) { $allOk = $false }
        }
    } elseif ($script:Pm -eq 'choco') {
        if (-not $script:IsAdmin) { return $false }
        $chArgs = @('install', '-y') + @($ListObject)
        $r = Invoke-Step 'choco' $chArgs
        if (-not $r) { $allOk = $false }
    } else {
        return $false
    }
    if (-not $script:DryRun) { $script:DidInstall = $true }
    return $allOk
}

if ($Check) {
    if ($script:NeedAny) {
        Write-Host ''
        Write-Info '-Check given: nothing was installed.'
    }
} elseif ($script:NeedAny) {
    if ($script:PlanReq.Count -gt 0) {
        if (Confirm-Run 'Run the REQUIRED commands above?') {
            Write-Head 'Installing (required)'
            $r = Invoke-Install $script:PlanReq
            if (-not $r) {
                Write-Warn 'at least one command did not report success. The status table below is the truth.'
            }
        } else {
            Write-Info 'skipped. Nothing was installed.'
        }
    }
    if ($script:PlanOpt.Count -gt 0) {
        if (Confirm-Run ("Also install the OPTIONAL $($script:StackName) tools?")) {
            Write-Head 'Installing (optional)'
            $r = Invoke-Install $script:PlanOpt
            if (-not $r) {
                Write-Warn 'at least one optional command did not report success. This is not fatal to Ratchet.'
            }
        } else {
            Write-Info 'skipped the optional tools. Ratchet does not need them.'
        }
    }
}

# ============================================================================
# SECTION 7 -- RE-PROBE AND REPORT. Report what is on the box now, never what
# we intended to put there.
# ============================================================================
if ($script:DidInstall) {
    Write-Head 'Re-checking'
    Update-SessionPath

    $found2 = Find-Bash
    if ($found2) {
        if ($found2[1] -like 'WSL*') {
            Set-DepStatus 'bash' 'wrong-world' 'only the WSL relay was found'
        } else {
            Set-DepStatus 'bash' 'ok' ("$($found2[2]).x via $($found2[1])")
            $script:BashPath = $found2[0]
            $env:RATCHET_BASH = $found2[0]
        }
    }
    if (Test-Command 'git') {
        $gv2 = ''
        try { $gv2 = ((& git --version) -split ' ')[2] } catch { $gv2 = '' }
        Set-DepStatus 'git' 'ok' $gv2
    }
    $jq2 = Test-Command 'jq'
    if (-not $jq2 -and $script:BashPath) {
        $probe2 = & $script:BashPath -lc 'command -v jq' 2>$null
        if ($LASTEXITCODE -eq 0 -and $probe2) { $jq2 = ("$probe2").Trim() }
    }
    if ($jq2) { Set-DepStatus 'jq' 'ok' $jq2 }

    $script:Py = Get-WorkingPython
    if ($script:Py) {
        $pv2 = ''
        try { $pv2 = & ($script:Py -split ' ')[0] '-c' 'import sys;print(sys.version.split()[0])' 2>$null } catch { $pv2 = '' }
        Set-DepStatus 'python3' 'ok' ("$pv2 (via '$($script:Py)')")
    }
    if (Test-Command 'gh') {
        & gh auth status *> $null
        if ($LASTEXITCODE -eq 0) {
            Set-DepStatus 'gh' 'ok' 'authenticated'
        } else {
            Set-DepStatus 'gh' 'unauth' 'installed, not logged in -- run: gh auth login'
        }
    }
    foreach ($d in $script:OptionalDeps) {
        $s2 = Test-Command $d
        if ($s2) { Set-DepStatus $d 'ok' $s2 }
    }
    Write-Info 'PATH refreshed from the registry. If something still reads as missing,'
    Write-Cont 'open a NEW terminal and re-run this script -- some installers only'
    Write-Cont 'publish their PATH entry to sessions started after they finish.'
}

Write-Head 'Status'
Write-Host ('  ' + 'DEPENDENCY'.PadRight(11) + 'TIER'.PadRight(7) + 'STATUS'.PadRight(9) + 'DETAIL')
Write-Host ('  ' + '----------'.PadRight(11) + '----'.PadRight(7) + '------'.PadRight(9) + '------')

$script:FatalMissing = $false
$rowOrder = @('bash', 'git', 'jq', 'python3', 'gh') + $script:OptionalDeps
foreach ($name in $rowOrder) {
    $dep = $script:Deps[$name]
    $colour = 'Yellow'
    if ($dep.Status -eq 'ok') {
        $colour = 'Green'
    } elseif ($dep.Tier -eq 'FATAL') {
        $colour = 'Red'
    }
    if ($dep.Tier -eq 'FATAL' -and $dep.Status -ne 'ok') { $script:FatalMissing = $true }
    $line = '  ' + $dep.Name.PadRight(11) + $dep.Tier.PadRight(7) + $dep.Status.PadRight(9) + $dep.Detail
    Write-C $line $colour
}

# ============================================================================
# SECTION 8 -- WHAT TO DO NEXT
# ============================================================================
Write-Head 'Next'

if ($script:DryRun) {
    Write-Host '  Dry run: nothing was changed. Re-run without -DryRun/-WhatIf to install.'
}

$nextStack = $script:StackName
if ($nextStack -eq 'none') { $nextStack = 'generic' }

if ($script:FatalMissing) {
    Write-Host '  One or more FATAL dependencies are still missing. install.ps1 will refuse,'
    Write-Host '  and that refusal is correct: a gate that cannot run has not passed.'
    Write-Host '  Fix the red rows above, then run this script again to confirm.'
    if ((Get-DepStatus 'bash') -eq 'wrong-world') {
        Write-Host ''
        Write-Host '  The bash row says wrong-world: the only bash here is the WSL relay,'
        Write-Host '  which resolves a different filesystem than your Windows checkout.'
        Write-Host '  Install Git for Windows, or move the whole workflow into WSL and use'
        Write-Host '  ratchet-dependencies.sh there. Do not mix the two.'
    }
    if ($script:PlanReq.Count -gt 0 -and -not $script:DidInstall) {
        Write-Host ''
        Write-Host '  The commands are printed above under "Plan". Nothing was run.'
    }
    Write-Host ''
    exit 1
}

Write-Host '  Every FATAL dependency is present. Now run:'
Write-Host ''
Write-Host ("      .\install.ps1 -Target $Target -Stack $nextStack")
Write-Host ''
Write-Host ('  (or, from Git-Bash:  ./install.sh --target ' + $Target + ' --stack ' + $nextStack + ')')

if ((Get-DepStatus 'gh') -ne 'ok') {
    Write-Host ''
    Write-Host '  Reminder: gh is not ready. Everything up to the Ship Prompt works, and'
    Write-Host '  then the run stops at the PR. Fix it before your first ship:  gh auth login'
}

Write-Host ''
exit 0
