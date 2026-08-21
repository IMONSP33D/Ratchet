<#
.SYNOPSIS
    Mid-project updater for the Ratchet harness (Windows). Parity with ratchet-update.sh.

.DESCRIPTION
    You installed Ratchet 1.0.0. You worked for six weeks. A newer scaffold
    ships. You want the new control layer and you want to keep everything you
    built: your domain pack, your SPEC and MILESTONES, your findings ledger,
    your retro corpus, your decisions. Doing that by hand is a batched
    multi-file edit to the control layer, which is exactly the operation the
    source pipeline measured as self-harming.

    THE PROMISE
      1. Every file is classified before anything is written, and the
         classification is EXHAUSTIVE: a path this script does not recognise is
         USER, and USER is never touched.
      2. HARNESS files you (or an agent) edited locally are DETECTED, listed,
         and preserved as "<file>.local-<timestamp>" -- never silently
         clobbered. The point of a control layer is that changes to it are
         deliberate.
      3. The whole .claude\ tree is backed up before a single byte is written,
         and rollback is ONE command, printed on every path including success.
      4. It refuses to run mid-run. Swapping the gates halfway means the run's
         second half is judged by different rules than its first.
      5. The file writing is done BY install.ps1, not by a second
         implementation. This script decides; install.ps1 writes. There is
         exactly one settings.json merge in this codebase and it lives there.

    WINDOWS SPECIFICS
      - Written for Windows PowerShell 5.1. No ternary operator, no null
        coalescing, no PS 6+ cmdlet parameters. It runs on a stock Windows 10
        or 11 box with nothing installed but Git and jq.
      - Every file it writes is written LF with no BOM. A hook file saved CRLF
        has a shebang reading "#!/usr/bin/env bash`r" and the kernel then looks
        for an interpreter literally named "bash`r".
      - Paths are compared and recorded in repo-relative POSIX form ("/"), so a
        manifest written on Windows is readable by the bash updater and the
        other way round.

.PARAMETER Check
    Report what WOULD change and write nothing. This is the default.

.PARAMETER Apply
    Perform the update.

.PARAMETER From
    Bundle directory or .zip. Default: the directory holding this script.

.PARAMETER Target
    Repository to update. Default: the current directory.

.PARAMETER Yes
    Do not prompt for confirmation.

.PARAMETER Force
    Update even though a run is active. Read the refusal text first.

.PARAMETER ForceOverwriteModified
    Overwrite locally-modified HARNESS files with no .local-* copy kept. The
    full backup still holds them.

.PARAMETER AllowDowngrade
    Permit installing an OLDER version than the one installed.

.PARAMETER AdoptBaseline
    Write .claude\.ratchet-manifest from the CURRENT on-disk state and exit.
    Use once, right after an install by an installer that predates manifests.

.PARAMETER SkipVerify
    Skip the post-apply hook suite. Not recommended.

.EXAMPLE
    .\ratchet-update.ps1 -Check -Target . -From C:\src\ratchet-1.1.0

.EXAMPLE
    .\ratchet-update.ps1 -Apply -Target . -From .\ratchet-1.1.0.zip -Yes

.EXAMPLE
    .\ratchet-update.ps1 -Apply -WhatIf -Target . -From C:\src\ratchet-1.1.0

.NOTES
    Exit codes:
      0  up to date / check complete / applied cleanly
      1  APPLIED but verification failed, or the settings merge failed. The
         update is on disk. The rollback command is printed.
      2  REFUSED before changing anything.

    STATE FILES OWNED BY THIS SCRIPT (CONTRACT 0.7: reader and writer together)

    <target>\.claude\.ratchet-version
        One line: the harness semver currently installed, e.g. "1.0.0".
        Written after a successful -Apply and by -AdoptBaseline. If absent the
        version is recovered from .claude\.ratchet-install.json, then from
        RT_VERSION in .claude\hooks\ratchet.config.sh.

    <target>\.claude\.ratchet-manifest
        Checksums of every HARNESS-class file AS THIS SCRIPT WROTE IT. This is
        the baseline that makes "you edited a harness file" a decidable
        question instead of a guess.
            # comment lines begin with '#'
            <sha256>  <repo-relative-path>
        Two spaces between fields, so the file is sha256sum -c compatible and
        byte-identical in form to the one ratchet-update.sh writes.
        ABSENT is a legal state. It degrades to UNVERIFIED, which is reported,
        never assumed-clean.

    <target>\.claude\.backup-<version>-<timestamp>\
        claude\      a copy of the whole .claude\ tree minus other .backup-*
        context\     the doctrine docs this update would rewrite
        root\        CLAUDE.ratchet.md, if present
        install.log  the delegated install.ps1 transcript
        restore.ps1  the one-command rollback

    Files this script APPENDS to, never rewrites:
        .agent-development\PENDING-HUMAN-ACTIONS.md
        .pipeline\run-events.jsonl  (via .claude\hooks\pipeline-event.sh)
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [switch] $Check,
    [switch] $Apply,
    [string] $From                   = '',
    [string] $Target                 = '.',
    [switch] $Yes,
    [switch] $Force,
    [switch] $ForceOverwriteModified,
    [switch] $AllowDowngrade,
    [switch] $AdoptBaseline,
    [switch] $SkipVerify,
    [switch] $NoColor
)

Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Continue'

$RtuVersion = '1.0.0'
$script:Warnings = 0

# ---------------------------------------------------------------- output ----
function Write-Head { param([string] $Text) Write-Host ''; Write-Host $Text -ForegroundColor Cyan }
function Write-Say  { param([string] $Text) Write-Host $Text }
function Write-Ok   { param([string] $Text) Write-Host ('  ok    ' + $Text) -ForegroundColor Green }
function Write-Info { param([string] $Text) Write-Host ('  ..    ' + $Text) }
function Write-Warn {
    param([string] $Text)
    Write-Host ('  WARN  ' + $Text) -ForegroundColor Yellow
    $script:Warnings = $script:Warnings + 1
}
function Write-Err  { param([string] $Text) Write-Host ('  FAIL  ' + $Text) -ForegroundColor Red }
function Stop-Refused {
    param([string] $Text)
    Write-Host ''
    Write-Host ('update refused: ' + $Text) -ForegroundColor Red
    Write-Host ''
    exit 2
}

# ------------------------------------------------------------- primitives ---
function Get-Sha256 {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return '' }
    $h = Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction SilentlyContinue
    if ($null -eq $h) { return '' }
    return $h.Hash.ToLower()
}

function Write-LfFile {
    param([string] $Path, [string] $Content)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $lf = $Content -replace "`r`n", "`n"
    $enc = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $lf, $enc)
}

function Copy-LfFile {
    param([string] $Source, [string] $Destination)
    $bytes = [System.IO.File]::ReadAllBytes($Source)
    $text  = [System.Text.Encoding]::UTF8.GetString($bytes)
    Write-LfFile -Path $Destination -Content $text
}

function Get-RepoRelative {
    param([string] $Root, [string] $Full)
    $r = $Root.TrimEnd('\', '/')
    $f = $Full
    if ($f.StartsWith($r, [System.StringComparison]::OrdinalIgnoreCase)) {
        $f = $f.Substring($r.Length)
    }
    $f = $f -replace '\\', '/'
    return $f.TrimStart('/')
}

# Compare-Semver A B -> -1 (A<B), 0 (A==B), 1 (A>B).
# An ABSENT pre-release suffix sorts HIGHER than a present one (1.1.0 > 1.1.0-rc1).
function Compare-Semver {
    param([string] $A, [string] $B)
    $a = $A.TrimStart('v')
    $b = $B.TrimStart('v')
    $ap = ''
    $bp = ''
    if ($a.Contains('-')) { $ap = $a.Substring($a.IndexOf('-') + 1); $a = $a.Substring(0, $a.IndexOf('-')) }
    if ($b.Contains('-')) { $bp = $b.Substring($b.IndexOf('-') + 1); $b = $b.Substring(0, $b.IndexOf('-')) }
    $pa = $a.Split('.')
    $pb = $b.Split('.')
    for ($i = 0; $i -lt 3; $i++) {
        $x = 0
        $y = 0
        if ($i -lt $pa.Length) { [int]::TryParse($pa[$i], [ref] $x) | Out-Null }
        if ($i -lt $pb.Length) { [int]::TryParse($pb[$i], [ref] $y) | Out-Null }
        if ($x -lt $y) { return -1 }
        if ($x -gt $y) { return 1 }
    }
    if ($ap -eq '' -and $bp -ne '') { return 1 }
    if ($ap -ne '' -and $bp -eq '') { return -1 }
    $c = [string]::CompareOrdinal($ap, $bp)
    if ($c -lt 0) { return -1 }
    if ($c -gt 0) { return 1 }
    return 0
}

# ============================================================================
# THE CLASSIFICATION. Exhaustive by construction.
# ============================================================================
# Get-RtClass <repo-relative-path> -> 'HARNESS' | 'USER' | 'MERGED'
#
# Read this function as the specification. Three classes, and the DEFAULT is
# USER -- so a path nobody thought about is a path nobody overwrites. That is
# the only default it is safe to be wrong about.
#
#   HARNESS  ours. Replaced wholesale. Local edits detected and preserved.
#   MERGED   settings.json only. Union of permissions, re-wired hooks, your
#            additions preserved, backed up first. Merged by install.ps1.
#   USER     yours. NEVER touched. Includes anything unrecognised.
#
# The one sanctioned exception to "USER is never touched" is an APPEND to
# .agent-development/PENDING-HUMAN-ACTIONS.md, an append-only register that
# exists to be appended to. It is called out in the report.
# ============================================================================
function Get-RtClass {
    param([string] $RelPath)
    $p = $RelPath -replace '\\', '/'

    if ($p -eq '.claude/settings.json') { return 'MERGED' }

    # USER carve-outs INSIDE harness territory. domain.config.sh lives in a
    # harness directory but is not harness-owned: it is the interview's output
    # and it holds this project's walls.
    if ($p -eq '.claude/hooks/domain.config.sh') { return 'USER' }
    if ($p -like '.claude/settings.json.bak-*')  { return 'USER' }
    if ($p -like '.claude/.backup-*')            { return 'USER' }
    if ($p -like '*.local-*')                    { return 'USER' }

    # HARNESS.
    if ($p -like '.claude/hooks/stack/*.sh') { return 'HARNESS' }
    if ($p -like '.claude/hooks/*.sh')       { return 'HARNESS' }
    if ($p -like '.claude/hooks/*.py')       { return 'HARNESS' }
    if ($p -like '.claude/agents/*.md')      { return 'HARNESS' }
    # Doctrine docs. They ship from the harness, carry no project content of
    # their own, and are the only channel by which a doctrine change reaches an
    # existing project. install.ps1 writes them if-absent, which is right for an
    # install and wrong for an update.
    if ($p -eq '.context/CLAUDE.md')      { return 'HARNESS' }
    if ($p -eq '.context/PIPELINE.md')    { return 'HARNESS' }
    if ($p -eq '.context/TEMPLATE.md')    { return 'HARNESS' }
    if ($p -eq '.context/UPGRADING.md')   { return 'HARNESS' }
    if ($p -eq 'CLAUDE.ratchet.md')       { return 'HARNESS' }

    # USER: the project's own work.
    if ($p -eq '.context/SPEC.md')       { return 'USER' }
    if ($p -eq '.context/MILESTONES.md') { return 'USER' }
    if ($p -eq '.context/DECISIONS.md')  { return 'USER' }
    if ($p -like '.context/archive/*')       { return 'USER' }
    if ($p -like '.agent-development/*')     { return 'USER' }
    if ($p -like '.pipeline/*')              { return 'USER' }
    if ($p -like 'secrets/*')                { return 'USER' }
    if ($p -like 'docs/evidence/*')          { return 'USER' }
    if ($p -eq 'CLAUDE.md')                  { return 'USER' }

    # DEFAULT. Everything else in the repository is the project's.
    return 'USER'
}

$DoctrineDocs = @('.context/CLAUDE.md', '.context/PIPELINE.md', '.context/TEMPLATE.md', '.context/UPGRADING.md')

# The never-escalatable control set (CONTRACT 5.6). Drift here is reported at a
# higher volume than drift anywhere else, because nothing lifts these rules and
# a local edit to one of them is a silently disabled wall.
$ControlSet = @('settings.json', 'guard.sh', 'scope-guard.sh', 'hooklib.sh',
                'escalation-lib.sh', 'approve.sh', 'ratchet.config.sh')
function Test-InControlSet {
    param([string] $RelPath)
    $base = Split-Path -Leaf ($RelPath -replace '/', '\')
    return ($ControlSet -contains $base)
}

# Markers make a raw byte compare lie: doctrine docs and agent definitions ship
# with {{MARKERS}} that install.ps1 substitutes at write time. Comparing raw
# bundle bytes against the substituted installed file would report every one of
# them as changed forever. So a line of the BUNDLE file containing a marker is
# skipped. Local-modification detection is unaffected: that compares the
# installed file against the recorded checksum of the installed file, which is
# a different question and must stay one.
function Test-HarnessDiffers {
    param([string] $Installed, [string] $Bundle)
    if (-not (Test-Path -LiteralPath $Installed -PathType Leaf)) { return $true }
    if (-not (Test-Path -LiteralPath $Bundle    -PathType Leaf)) { return $false }
    $ai = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($Installed))
    $ab = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($Bundle))
    $li = ($ai -replace "`r`n", "`n").Split("`n")
    $lb = ($ab -replace "`r`n", "`n").Split("`n")
    if ($li.Length -ne $lb.Length) { return $true }
    for ($i = 0; $i -lt $lb.Length; $i++) {
        if ($lb[$i] -match '\{\{[A-Z0-9_]+\}\}') { continue }
        if ($li[$i] -ne $lb[$i]) { return $true }
    }
    return $false
}

# ============================================================================
# SECTION 1 -- mode, bundle, target
# ============================================================================
Write-Head ("Ratchet updater " + $RtuVersion + " (PowerShell)")

$Mode = 'check'
if ($Apply) { $Mode = 'apply' }
$DryRun = $false
if ($WhatIfPreference) { $DryRun = $true; $Mode = 'apply' }
if ($Check -and -not $Apply) { $Mode = 'check' }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ($From -eq '') { $From = $ScriptDir }

$BundleTmp = ''
$Bundle    = ''
if (Test-Path -LiteralPath $From -PathType Container) {
    $Bundle = (Resolve-Path -LiteralPath $From).Path
}
elseif (Test-Path -LiteralPath $From -PathType Leaf) {
    if ($From.ToLower().EndsWith('.zip')) {
        $BundleTmp = Join-Path ([System.IO.Path]::GetTempPath()) ('rtu-' + [System.Guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $BundleTmp -Force | Out-Null
        try {
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
            [System.IO.Compression.ZipFile]::ExtractToDirectory((Resolve-Path -LiteralPath $From).Path, $BundleTmp)
        }
        catch {
            Stop-Refused ("could not extract " + $From + ": " + $_.Exception.Message)
        }
        if ((Test-Path (Join-Path $BundleTmp 'harness')) -and (Test-Path (Join-Path $BundleTmp 'install.ps1'))) {
            $Bundle = $BundleTmp
        }
        else {
            $cand = Get-ChildItem -LiteralPath $BundleTmp -Directory -Recurse -Depth 2 -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -eq 'harness' } | Select-Object -First 1
            if ($null -ne $cand) { $Bundle = $cand.Parent.FullName }
        }
        if ($Bundle -eq '') {
            Stop-Refused "that zip does not look like a Ratchet bundle: no directory inside it contains both install.ps1 and harness\."
        }
    }
    else {
        Stop-Refused ("-From must be a directory or a .zip (got a file: " + $From + ")")
    }
}
else {
    Stop-Refused ("-From path does not exist: " + $From)
}

$HarnessSrc = Join-Path $Bundle 'harness'
if (-not (Test-Path -LiteralPath $HarnessSrc -PathType Container)) {
    Stop-Refused ($Bundle + " has no harness\ directory. That is not a Ratchet bundle.")
}
$InstallPs1 = Join-Path $Bundle 'install.ps1'
if (-not (Test-Path -LiteralPath $InstallPs1 -PathType Leaf)) {
    Stop-Refused ($Bundle + " has no install.ps1. This updater deliberately does NOT contain a second copy of the install logic -- it decides, install.ps1 writes. Without install.ps1 there is nothing to delegate to.")
}

$BundleVersion = ''
$vf = Join-Path $Bundle 'VERSION'
if (Test-Path -LiteralPath $vf -PathType Leaf) {
    $BundleVersion = ((Get-Content -LiteralPath $vf -TotalCount 1) + '').Trim()
}
if ($BundleVersion -eq '') {
    $cfg = Join-Path $HarnessSrc '.claude/hooks/ratchet.config.sh'
    if (Test-Path -LiteralPath $cfg -PathType Leaf) {
        $m = Select-String -LiteralPath $cfg -Pattern '^RT_VERSION="\$\{RT_VERSION:-([^}]*)\}"' | Select-Object -First 1
        if ($null -ne $m) { $BundleVersion = $m.Matches[0].Groups[1].Value }
    }
}
if ($BundleVersion -eq '') {
    Stop-Refused "cannot determine the bundle's version: no VERSION file and no RT_VERSION default in harness\.claude\hooks\ratchet.config.sh."
}
Write-Ok ("bundle:  " + $Bundle + "  (version " + $BundleVersion + ")")

if (-not (Test-Path -LiteralPath $Target -PathType Container)) {
    Stop-Refused ("-Target does not exist: " + $Target)
}
$Tgt = (Resolve-Path -LiteralPath $Target).Path
$gitTop = & git -C $Tgt rev-parse --show-toplevel 2>$null
if ($LASTEXITCODE -eq 0 -and $gitTop) {
    $gitTop = ($gitTop | Select-Object -First 1).Trim() -replace '/', '\'
    if ($gitTop -and (Test-Path -LiteralPath $gitTop) -and ($gitTop -ne $Tgt)) {
        Write-Info ("you pointed at a subdirectory; using the repo root: " + $gitTop)
        $Tgt = (Resolve-Path -LiteralPath $gitTop).Path
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $Tgt '.claude\hooks') -PathType Container)) {
    Stop-Refused ($Tgt + " does not have a Ratchet install (.claude\hooks\ is absent). An update needs something to update. To install for the first time:`n      & '" + $InstallPs1 + "' -Target '" + $Tgt + "'")
}

$InstallState = Join-Path $Tgt '.claude\.ratchet-install.json'
$VersionFile  = Join-Path $Tgt '.claude\.ratchet-version'
$ManifestFile = Join-Path $Tgt '.claude\.ratchet-manifest'
$RunActive    = Join-Path $Tgt '.pipeline\run-active'

$InstalledVersion = ''
$VersionSource    = ''
if (Test-Path -LiteralPath $VersionFile -PathType Leaf) {
    $InstalledVersion = ((Get-Content -LiteralPath $VersionFile -TotalCount 1) + '').Trim()
    $VersionSource = '.claude\.ratchet-version'
}
$StateObj = $null
if (Test-Path -LiteralPath $InstallState -PathType Leaf) {
    try { $StateObj = (Get-Content -LiteralPath $InstallState -Raw) | ConvertFrom-Json } catch { $StateObj = $null }
}
if ($InstalledVersion -eq '' -and $null -ne $StateObj) {
    if ($StateObj.PSObject.Properties.Name -contains 'installer_version') {
        $InstalledVersion = ($StateObj.installer_version + '').Trim()
        $VersionSource = '.claude\.ratchet-install.json'
    }
}
if ($InstalledVersion -eq '') {
    $tcfg = Join-Path $Tgt '.claude\hooks\ratchet.config.sh'
    if (Test-Path -LiteralPath $tcfg -PathType Leaf) {
        $m = Select-String -LiteralPath $tcfg -Pattern '^RT_VERSION="\$\{RT_VERSION:-([^}]*)\}"' | Select-Object -First 1
        if ($null -ne $m) {
            $InstalledVersion = $m.Matches[0].Groups[1].Value
            $VersionSource = 'RT_VERSION in ratchet.config.sh'
        }
    }
}
if ($InstalledVersion -eq '') {
    $InstalledVersion = '0.0.0'
    $VersionSource = 'UNKNOWN (assumed 0.0.0)'
    Write-Warn "cannot determine the installed version. Treating it as 0.0.0, so every harness file will be considered changed."
}
Write-Ok ("target:  " + $Tgt + "  (version " + $InstalledVersion + ", from " + $VersionSource + ")")

$VCmp = Compare-Semver $InstalledVersion $BundleVersion
$Verb = ''
if ($VCmp -lt 0) { $Verb = 'update  ' + $InstalledVersion + ' -> ' + $BundleVersion }
if ($VCmp -eq 0) { $Verb = 're-apply ' + $BundleVersion + ' (same version)' }
if ($VCmp -gt 0) { $Verb = 'DOWNGRADE ' + $InstalledVersion + ' -> ' + $BundleVersion }

$IProject = ''
$IStack   = ''
$IBase    = ''
$IEsc     = ''
if ($null -ne $StateObj) {
    $names = $StateObj.PSObject.Properties.Name
    if ($names -contains 'project_name')    { $IProject = $StateObj.project_name }
    if ($names -contains 'stack')           { $IStack   = $StateObj.stack }
    if ($names -contains 'base_branch')     { $IBase    = $StateObj.base_branch }
    if ($names -contains 'escalation_mode') { $IEsc     = $StateObj.escalation_mode }
}

# ============================================================================
# SECTION 2 -- harness path enumeration and the checksum manifest
# ============================================================================
function Get-TargetHarnessPaths {
    $out = New-Object System.Collections.ArrayList
    foreach ($d in @('.claude\hooks', '.claude\hooks\stack', '.claude\agents')) {
        $full = Join-Path $Tgt $d
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $full -File -ErrorAction SilentlyContinue)) {
            $rel = Get-RepoRelative -Root $Tgt -Full $f.FullName
            if ((Get-RtClass $rel) -ne 'HARNESS') { continue }
            [void] $out.Add($rel)
        }
    }
    foreach ($rel in ($DoctrineDocs + @('CLAUDE.ratchet.md'))) {
        if (Test-Path -LiteralPath (Join-Path $Tgt ($rel -replace '/', '\')) -PathType Leaf) { [void] $out.Add($rel) }
    }
    return ($out | Sort-Object -Unique)
}

function Get-BundleHarnessPaths {
    $out = New-Object System.Collections.ArrayList
    foreach ($d in @('.claude\hooks', '.claude\hooks\stack', '.claude\agents')) {
        $full = Join-Path $HarnessSrc $d
        if (-not (Test-Path -LiteralPath $full -PathType Container)) { continue }
        foreach ($f in (Get-ChildItem -LiteralPath $full -File -ErrorAction SilentlyContinue)) {
            $rel = Get-RepoRelative -Root $HarnessSrc -Full $f.FullName
            if ((Get-RtClass $rel) -ne 'HARNESS') { continue }
            [void] $out.Add($rel)
        }
    }
    foreach ($doc in $DoctrineDocs) {
        if (Test-Path -LiteralPath (Join-Path $HarnessSrc ($doc -replace '/', '\')) -PathType Leaf) { [void] $out.Add($doc) }
    }
    if ((Test-Path -LiteralPath (Join-Path $Tgt 'CLAUDE.ratchet.md') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $HarnessSrc '.context\CLAUDE.md') -PathType Leaf)) {
        [void] $out.Add('CLAUDE.ratchet.md')
    }
    return ($out | Sort-Object -Unique)
}

function Write-RtManifest {
    param([string] $RecordVersion)
    $sb = New-Object System.Text.StringBuilder
    [void] $sb.AppendLine('# Ratchet harness manifest -- checksums of HARNESS-class files as written.')
    [void] $sb.AppendLine('# Written by: ratchet-update.ps1 ' + $RtuVersion + ' at ' +
        (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') + ' (harness ' + $RecordVersion + ')')
    [void] $sb.AppendLine('# Read by:    ratchet-update.ps1 / ratchet-update.sh -Check/-Apply, to decide')
    [void] $sb.AppendLine('#             whether a harness file was edited LOCALLY before it is overwritten.')
    [void] $sb.AppendLine('# Format:     "<sha256>  <repo-relative-path>"  (sha256sum -c compatible)')
    [void] $sb.AppendLine('# Deleting this file does not break anything: every harness file then reports')
    [void] $sb.AppendLine('# as UNVERIFIED, which is louder, not quieter.')
    foreach ($rel in (Get-TargetHarnessPaths)) {
        $sum = Get-Sha256 (Join-Path $Tgt ($rel -replace '/', '\'))
        if ($sum -ne '') { [void] $sb.AppendLine($sum + '  ' + $rel) }
    }
    Write-LfFile -Path $ManifestFile -Content $sb.ToString()
}

function Get-BaselineSum {
    param([string] $RelPath, [hashtable] $Baseline)
    if ($null -eq $Baseline) { return '' }
    if ($Baseline.ContainsKey($RelPath)) { return $Baseline[$RelPath] }
    return ''
}

if ($AdoptBaseline) {
    Write-Head 'Adopting the current tree as the checksum baseline'
    Write-Say '  This records what is on disk RIGHT NOW as pristine. Run it only when you'
    Write-Say '  know the harness has not been hand-edited since it was installed --'
    Write-Say '  typically immediately after an install by an installer that predates'
    Write-Say '  .ratchet-manifest. Anything already modified becomes invisible to every'
    Write-Say '  future update, which is the one way this file can hurt you.'
    if ($DryRun) {
        Write-Info 'DRY: would write .claude\.ratchet-manifest and .claude\.ratchet-version'
        exit 0
    }
    Write-RtManifest -RecordVersion $InstalledVersion
    $n = (Get-TargetHarnessPaths).Count
    Write-Ok ('wrote .claude\.ratchet-manifest (' + $n + ' harness files)')
    Write-LfFile -Path $VersionFile -Content ($InstalledVersion + "`n")
    Write-Ok ('wrote .claude\.ratchet-version (' + $InstalledVersion + ')')
    exit 0
}

# ============================================================================
# SECTION 3 -- REFUSALS. All of them fire before anything is written.
# ============================================================================
if ((Test-Path -LiteralPath $RunActive -PathType Leaf) -and ($Mode -eq 'apply') -and (-not $DryRun)) {
    $runMilestone = ((Get-Content -LiteralPath $RunActive -TotalCount 1) + '').Trim()
    if (-not $Force) {
        Write-Host ''
        Write-Host ('update refused: a run is active (' + $runMilestone + ').') -ForegroundColor Red
        Write-Host ''
        Write-Say "  Swapping the gates mid-run means the run's second half is judged by"
        Write-Say '  different rules than its first. The scope check, the definition-of-done'
        Write-Say '  check and the escalation partition would all change underneath a run that'
        Write-Say '  has already made decisions under the old ones, and nothing in the record'
        Write-Say '  would say which half of the evidence was collected under which rules.'
        Write-Say ''
        Write-Say '  Finish or archive the run first:'
        Write-Say ('      cd "' + $Tgt + '"; bash .claude/hooks/gc-prune.sh archive ' + $runMilestone)
        Write-Say ''
        if (-not (Test-Path -LiteralPath (Join-Path $Tgt '.pipeline\run-start') -PathType Leaf)) {
            Write-Say '  NOTE: there is no .pipeline\run-start beside it, so this may be a leftover'
            Write-Say '  rather than a live run -- test_hooks.py arms a run as a fixture and does'
            Write-Say '  not always clear it. Archive it and re-run; do not reach for -Force just'
            Write-Say '  because you cannot remember starting a run.'
            Write-Say ''
        }
        Write-Say '  -Force overrides this. If you use it, say so in DECISIONS.md, because the'
        Write-Say "  run's retro will otherwise be read as one coherent measurement."
        Write-Say ''
        exit 2
    }
    Write-Warn ('a run is active (' + $runMilestone + ') and -Force was given.')
    Write-Say '        The second half of this run will be judged by different rules than its'
    Write-Say '        first. File a DECISIONS.md entry saying so, or its retro is not a'
    Write-Say '        measurement of anything.'
}

# In -Check this is a warning, not a refusal: -Check writes nothing, and refusing
# to even LOOK at a downgrade would hide the one report that tells you which
# gates it removes. The refusal fires when something is about to be written.
if (($VCmp -gt 0) -and (-not $AllowDowngrade) -and ($Mode -ne 'apply')) {
    Write-Warn ('that bundle is OLDER than what is installed (' + $BundleVersion + ' < ' + $InstalledVersion + ').')
    Write-Say  '        Reporting it anyway, because -Check writes nothing. -Apply would refuse'
    Write-Say  '        without -AllowDowngrade. Read the never-escalatable delta below: on a'
    Write-Say  '        downgrade it lists the walls this would REMOVE.'
}
if (($VCmp -gt 0) -and (-not $AllowDowngrade) -and ($Mode -eq 'apply')) {
    Stop-Refused ("that bundle is OLDER than what is installed (" + $BundleVersion + " < " + $InstalledVersion + ").`n  A downgrade is a legitimate operation -- rolling back a bad scaffold is exactly`n  what you want sometimes -- but it is never what you MEANT when you typed`n  'update', and an accidental one silently removes gates you are relying on.`n  If you mean it:  -AllowDowngrade")
}

# Fatal for -Apply only. -Check never merges anything, so it degrades to a
# warning there rather than refusing to tell you what an update would do.
$jq = Get-Command jq -ErrorAction SilentlyContinue
if (($null -eq $jq) -and ($Mode -ne 'apply')) {
    Write-Warn 'jq is not on PATH. -Check still works, but -Apply will refuse: the'
    Write-Say  '        settings.json merge is the permission surface and it is not guessable.'
}
if (($null -eq $jq) -and ($Mode -eq 'apply')) {
    Stop-Refused "jq is not on PATH.`n  settings.json is the permission surface: the deny list is the class of rule`n  that cannot be lifted at runtime. Merging it without a JSON tool would mean`n  guessing, and a permissive entry that survives a bad guess silently reopens a`n  wall. CONTRACT 0.3 -- a gate that cannot determine safety BLOCKS.`n      winget install jqlang.jq"
}

# ============================================================================
# SECTION 4 -- CLASSIFY AND DIFF EVERY FILE
# ============================================================================
$Baseline = $null
$BaselinePresent = $false
if (Test-Path -LiteralPath $ManifestFile -PathType Leaf) {
    $BaselinePresent = $true
    $Baseline = @{}
    foreach ($line in (Get-Content -LiteralPath $ManifestFile)) {
        $l = ($line + '').TrimEnd("`r")
        if ($l.StartsWith('#')) { continue }
        if ($l.Trim() -eq '') { continue }
        $idx = $l.IndexOf('  ')
        if ($idx -lt 1) { continue }
        $Baseline[$l.Substring($idx + 2)] = $l.Substring(0, $idx)
    }
}

$Rows         = New-Object System.Collections.ArrayList
$ModifiedList = New-Object System.Collections.ArrayList
$DoctrineTouch = New-Object System.Collections.ArrayList
$nNew = 0; $nUpdate = 0; $nSame = 0; $nModified = 0; $nUnverified = 0; $nOrphan = 0

$BundlePaths = Get-BundleHarnessPaths
foreach ($rel in $BundlePaths) {
    $srcRel = $rel
    if ($rel -eq 'CLAUDE.ratchet.md') { $srcRel = '.context/CLAUDE.md' }
    $src = Join-Path $HarnessSrc ($srcRel -replace '/', '\')
    $dst = Join-Path $Tgt ($rel -replace '/', '\')

    if (-not (Test-Path -LiteralPath $dst -PathType Leaf)) {
        [void] $Rows.Add(@('NEW', 'HARNESS', $rel, 'not installed here yet'))
        $nNew = $nNew + 1
        if ($rel.StartsWith('.context/') -or $rel -eq 'CLAUDE.ratchet.md') { [void] $DoctrineTouch.Add($rel) }
        continue
    }

    # Local modification is decided against the RECORDED checksum, never against
    # the bundle. Those are different questions and conflating them is how an
    # upstream change gets reported as your edit.
    $baseSum = Get-BaselineSum -RelPath $rel -Baseline $Baseline
    $curSum  = Get-Sha256 $dst
    $localState = 0
    if ($BaselinePresent -and $baseSum -ne '') {
        if ($baseSum -ne $curSum) { $localState = 1 }
    }
    else {
        $localState = 2
    }

    $differs = Test-HarnessDiffers -Installed $dst -Bundle $src
    if (-not $differs) {
        if ($localState -eq 1) {
            [void] $Rows.Add(@('SAME', 'HARNESS', $rel, 'locally edited, but identical to the new version'))
        }
        else {
            [void] $Rows.Add(@('SAME', 'HARNESS', $rel, '-'))
        }
        $nSame = $nSame + 1
        continue
    }

    if ($localState -eq 1) {
        $note = 'LOCAL EDIT -> saved as .local-<ts>'
        if ($ForceOverwriteModified) { $note = 'LOCAL EDIT -> DISCARDED (-ForceOverwriteModified)' }
        if (Test-InControlSet $rel) { $note = 'CONTROL SET. ' + $note }
        [void] $Rows.Add(@('MODIFIED', 'HARNESS', $rel, $note))
        [void] $ModifiedList.Add($rel)
        $nModified = $nModified + 1
    }
    elseif ($localState -eq 2) {
        [void] $Rows.Add(@('UNVERIFIED', 'HARNESS', $rel, 'differs, and there is no baseline to say whose change it is'))
        [void] $ModifiedList.Add($rel)
        $nUnverified = $nUnverified + 1
    }
    else {
        [void] $Rows.Add(@('UPDATE', 'HARNESS', $rel, '-'))
        $nUpdate = $nUpdate + 1
    }
    if ($rel.StartsWith('.context/') -or $rel -eq 'CLAUDE.ratchet.md') { [void] $DoctrineTouch.Add($rel) }
}

# ORPHANS: harness files we installed that the new bundle no longer ships.
if ($BaselinePresent) {
    foreach ($rel in $Baseline.Keys) {
        if ($BundlePaths -contains $rel) { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $Tgt ($rel -replace '/', '\')) -PathType Leaf)) { continue }
        [void] $Rows.Add(@('ORPHAN', 'HARNESS', $rel, 'the new bundle no longer ships this; left in place'))
        $nOrphan = $nOrphan + 1
    }
}

$settingsNote = 'merge: union permissions, re-wire hooks, keep your entries; backed up first'
if (-not (Test-Path -LiteralPath (Join-Path $Tgt '.claude\settings.json') -PathType Leaf)) {
    $settingsNote = 'absent; a fresh one will be generated'
}
[void] $Rows.Add(@('MERGE', 'MERGED', '.claude/settings.json', $settingsNote))

# The USER partition, stated as rules, not as 400 unchanged file rows.
$UserRows = New-Object System.Collections.ArrayList
function Add-UserRow {
    param([string] $Path, [string] $What)
    $present = 'absent'
    $probe = Join-Path $Tgt ($Path -replace '/', '\')
    if ($Path.Contains('*')) {
        $hit = Get-ChildItem -Path $probe -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $hit) { $present = 'present' }
    }
    elseif (Test-Path -LiteralPath $probe) { $present = 'present' }
    [void] $UserRows.Add(@('KEEP', 'USER', $Path, ($What + ' (' + $present + ')')))
}
Add-UserRow '.claude/hooks/domain.config.sh' 'your domain pack: every wall you configured'
Add-UserRow '.context/SPEC.md'               'your requirement ids'
Add-UserRow '.context/MILESTONES.md'         'your WIN rows'
Add-UserRow '.context/DECISIONS.md'          'your decision log'
Add-UserRow '.context/archive/'              'archived decisions'
Add-UserRow '.agent-development/'            'learning loop: retros, lessons, proposals, metrics'
Add-UserRow '.pipeline/'                     'run scratch, findings ledger, checkpoints, events'
Add-UserRow 'secrets/'                       'the escalation signing key (never regenerated)'
Add-UserRow 'docs/evidence/'                 'WIN-row proof and probe transcripts'
Add-UserRow 'CLAUDE.md'                      'your root CLAUDE.md'
Add-UserRow '.claude/settings.json.bak-*'    'every backup any installer took'

# ============================================================================
# SECTION 5 -- SEMANTIC DELTAS THAT NEED A HUMAN
# ============================================================================
function Get-NeverEscalatable {
    param([string] $EscLib)
    $out = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $EscLib -PathType Leaf)) { return $out }
    $inBlock = $false
    foreach ($raw in (Get-Content -LiteralPath $EscLib)) {
        $l = ($raw + '').TrimEnd("`r")
        if (($l -match '^ESC_NEVER_CORE=''(.*)$') -or ($l -match '^ESC_STRICT_NEVER=''(.*)$')) {
            $inBlock = $true
            $first = $Matches[1]
            if ($first.EndsWith("'")) { $inBlock = $false; $first = $first.Substring(0, $first.Length - 1) }
            if ($first.Trim() -ne '') { [void] $out.Add($first.Trim()) }
            continue
        }
        if ($inBlock) {
            if ($l.EndsWith("'")) {
                $inBlock = $false
                $l = $l.Substring(0, $l.Length - 1)
            }
            if ($l.Trim() -ne '') { [void] $out.Add($l.Trim()) }
        }
    }
    return ($out | Sort-Object -Unique)
}

$neverOld    = Get-NeverEscalatable (Join-Path $Tgt        '.claude\hooks\escalation-lib.sh')
$neverBundle = Get-NeverEscalatable (Join-Path $HarnessSrc '.claude\hooks\escalation-lib.sh')
$neverNew  = @($neverBundle | Where-Object { $neverOld -notcontains $_ })
$neverGone = @($neverOld    | Where-Object { $neverBundle -notcontains $_ })

function Get-ConfigDefaults {
    param([string] $Cfg)
    $h = @{}
    if (-not (Test-Path -LiteralPath $Cfg -PathType Leaf)) { return $h }
    foreach ($raw in (Get-Content -LiteralPath $Cfg)) {
        $l = ($raw + '').TrimEnd("`r")
        if ($l -match '^([A-Z_][A-Z0-9_]*)="\$\{\1:-(.*)\}"') {
            $h[$Matches[1]] = $Matches[2]
        }
    }
    return $h
}

$cfgOld = Get-ConfigDefaults (Join-Path $Tgt        '.claude\hooks\ratchet.config.sh')
$cfgNew = Get-ConfigDefaults (Join-Path $HarnessSrc '.claude\hooks\ratchet.config.sh')
$CfgChanged = New-Object System.Collections.ArrayList
$decFile = Join-Path $Tgt '.context\DECISIONS.md'
$domFile = Join-Path $Tgt '.claude\hooks\domain.config.sh'
$setFile = Join-Path $Tgt '.claude\settings.json'
$setEnvNames = @()
if (Test-Path -LiteralPath $setFile -PathType Leaf) {
    try {
        $so = (Get-Content -LiteralPath $setFile -Raw) | ConvertFrom-Json
        if ($so.PSObject.Properties.Name -contains 'env' -and $null -ne $so.env) {
            $setEnvNames = $so.env.PSObject.Properties.Name
        }
    }
    catch { $setEnvNames = @() }
}
foreach ($k in ($cfgNew.Keys | Sort-Object)) {
    if (-not $cfgOld.ContainsKey($k)) { continue }
    if ($cfgOld[$k] -eq $cfgNew[$k]) { continue }
    $reliance = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $decFile -PathType Leaf) {
        $hit = Select-String -LiteralPath $decFile -Pattern ('Default/config.*' + [regex]::Escape($k)) -ErrorAction SilentlyContinue
        if ($null -ne $hit) { [void] $reliance.Add('named in DECISIONS.md') }
    }
    if (Test-Path -LiteralPath $domFile -PathType Leaf) {
        $hit = Select-String -LiteralPath $domFile -Pattern ('^\s*(export\s+)?' + [regex]::Escape($k) + '=') -ErrorAction SilentlyContinue
        if ($null -ne $hit) { [void] $reliance.Add('set in domain.config.sh') }
    }
    if ($setEnvNames -contains $k) { [void] $reliance.Add('set in settings.json .env') }
    [void] $CfgChanged.Add(@($k, $cfgOld[$k], $cfgNew[$k], ($reliance -join '; ')))
}
$CfgOverridden = @($CfgChanged | Where-Object { $_[3] -ne '' }).Count

$ControlDrift = @($ModifiedList | Where-Object { Test-InControlSet $_ })

# ============================================================================
# SECTION 6 -- THE REPORT
# ============================================================================
Write-Head ('Plan: ' + $Verb)
Write-Host ''
Write-Host ('  {0,-10} {1,-8} {2,-42} {3}' -f 'STATUS', 'CLASS', 'PATH', 'NOTE')
Write-Host ('  ' + ('-' * 94))
foreach ($r in ($Rows | Sort-Object @{ Expression = { $_[1] } }, @{ Expression = { $_[0] } }, @{ Expression = { $_[2] } })) {
    Write-Host ('  {0,-10} {1,-8} {2,-42} {3}' -f $r[0], $r[1], $r[2], $r[3])
}
foreach ($r in $UserRows) {
    Write-Host ('  {0,-10} {1,-8} {2,-42} {3}' -f $r[0], $r[1], $r[2], $r[3])
}
Write-Host ('  ' + ('-' * 94))
Write-Host ('  HARNESS  ' + $nNew + ' new  ' + $nUpdate + ' updated  ' + $nSame + ' unchanged  ' +
            $nModified + ' locally-modified  ' + $nUnverified + ' unverified  ' + $nOrphan + ' orphaned')
Write-Host '  MERGED   1 (.claude/settings.json)'
Write-Host '  USER     everything else in this repository, including every path not listed above.'
Write-Host "           The classifier's default is USER, so an unrecognised path is never touched."

if (-not $BaselinePresent) {
    Write-Head 'No checksum baseline'
    Write-Warn "there is no .claude\.ratchet-manifest, so 'did someone edit this harness"
    Write-Say  "        file?' cannot be answered for this install. Every harness file that"
    Write-Say  '        differs from the bundle is reported UNVERIFIED and will be PRESERVED as'
    Write-Say  '        a .local-<ts> copy rather than assumed clean.'
    Write-Say  '        This is the expected state exactly once: the install that predates the'
    Write-Say  '        updater. From this update onward the question is decidable.'
}

if ($ModifiedList.Count -gt 0) {
    Write-Head 'Harness files changed on this machine'
    Write-Say '  These are control-layer files that do not match what was installed. The'
    Write-Say "  harness's whole claim is that changes to the control layer are DELIBERATE,"
    Write-Say '  so they are listed rather than absorbed:'
    Write-Say ''
    foreach ($m in $ModifiedList) { Write-Say ('      ' + $m) }
    Write-Say ''
    if ($ForceOverwriteModified) {
        Write-Warn '-ForceOverwriteModified: no .local-* copies will be kept.'
        Write-Say  '        The full backup still holds them; see the rollback command below.'
    }
    else {
        Write-Say '  Each will be copied to <file>.local-<timestamp> beside itself before the'
        Write-Say '  new version lands. A .local-* file matches no hook glob (*.sh, *.py) and is'
        Write-Say '  wired into nothing, so it is inert: it is a diff waiting for you, not a'
        Write-Say '  second control layer.'
        Write-Say '  Pass -ForceOverwriteModified to skip the copies.'
    }
}

if ($ControlDrift.Count -gt 0) {
    Write-Head 'CONTROL-SET DRIFT'
    Write-Host '  These are never-escalatable files (CONTRACT 5.6). Nothing lifts a rule in' -ForegroundColor Yellow
    Write-Host '  them: not an approval, not a card, not a domain pack. A local edit to one' -ForegroundColor Yellow
    Write-Host '  is a wall that may have been quietly moved:' -ForegroundColor Yellow
    Write-Say ''
    foreach ($m in $ControlDrift) { Write-Say ('      ' + $m) }
    Write-Say ''
    Write-Say '  This is a WARNING, not a refusal, and deliberately so: refusing here would'
    Write-Say '  block the very update that restores the control layer to a known state. It'
    Write-Say '  is filed in PENDING-HUMAN-ACTIONS.md so it cannot be scrolled past.'
}

if ($neverNew.Count -gt 0) {
    Write-Head 'New never-escalatable rules'
    Write-Say '  The new scaffold adds rules that NO approval can lift. Work that used to be'
    Write-Say '  possible with a human confirmation may now be a hard wall:'
    Write-Say ''
    foreach ($r in $neverNew) { Write-Say ('      ' + $r) }
}
if ($neverGone.Count -gt 0) {
    Write-Head 'Rules no longer in the never-escalatable set'
    Write-Say '  These were walls and are not any more. Read them as a loosening:'
    Write-Say ''
    foreach ($r in $neverGone) { Write-Say ('      ' + $r) }
}

if ($CfgChanged.Count -gt 0) {
    Write-Head 'Changed configuration defaults'
    Write-Host ('  {0,-28} {1,-22} {2,-22} {3}' -f 'KEY', 'WAS', 'NOW', 'THIS PROJECT')
    foreach ($c in $CfgChanged) {
        $who = $c[3]
        if ($who -eq '') { $who = '-' }
        Write-Host ('  {0,-28} {1,-22} {2,-22} {3}' -f $c[0], $c[1], $c[2], $who)
    }
    if ($CfgOverridden -gt 0) {
        Write-Say ''
        Write-Warn ($CfgOverridden.ToString() + ' of those are values this project has an opinion about.')
        Write-Say  '        A default that moves under a project that overrides it is the quiet'
        Write-Say  '        kind of breakage: nothing fails, the number is just different now.'
    }
}

if ($Mode -eq 'check') {
    Write-Head 'Check complete -- nothing was written'
    if (($nUpdate -eq 0) -and ($nNew -eq 0) -and ($nModified -eq 0) -and ($nUnverified -eq 0)) {
        Write-Ok 'no harness file would change.'
    }
    else {
        Write-Say '  To apply:'
        Write-Say ("      & '" + $MyInvocation.MyCommand.Path + "' -Apply -Target '" + $Tgt + "' -From '" + $From + "'")
        Write-Say ''
        Write-Say '  To rehearse it first (writes nothing, runs install.ps1 -WhatIf):'
        Write-Say '      ... -Apply -WhatIf'
    }
    if ($BundleTmp -ne '') { Remove-Item -LiteralPath $BundleTmp -Recurse -Force -ErrorAction SilentlyContinue }
    exit 0
}

# ============================================================================
# SECTION 7 -- CONFIRM
# ============================================================================
if ((-not $DryRun) -and (-not $Yes)) {
    $dirty = @(& git -C $Tgt status --porcelain 2>$null | Where-Object { -not $_.StartsWith('??') } | Select-Object -First 10)
    if ($dirty.Count -gt 0) {
        Write-Head 'Modified tracked files in the target'
        foreach ($d in $dirty) { Write-Say ('      ' + $d) }
        Write-Say ''
        Write-Say '  Not a refusal: this updater takes its own full backup of .claude\ and'
        Write-Say "  gives you a one-command rollback, which is stronger than 'git checkout .'."
        Write-Say '  It is shown so you know what else is in flight.'
    }
    Write-Host ''
    $ans = Read-Host ('  Proceed with: ' + $Verb + '  [y/N]')
    if (($ans -ne 'y') -and ($ans -ne 'Y') -and ($ans -ne 'yes') -and ($ans -ne 'YES')) {
        Write-Say ''
        Write-Say '  Aborted. Nothing was written.'
        if ($BundleTmp -ne '') { Remove-Item -LiteralPath $BundleTmp -Recurse -Force -ErrorAction SilentlyContinue }
        exit 0
    }
}

# ============================================================================
# SECTION 8 -- BACKUP. Before one byte is written.
# ============================================================================
$Ts        = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
$BkRel     = '.claude/.backup-' + $InstalledVersion + '-' + $Ts
$Bk        = Join-Path $Tgt ($BkRel -replace '/', '\')
$Rollback  = 'powershell -ExecutionPolicy Bypass -File ' + ($BkRel -replace '/', '\') + '\restore.ps1'
$InstallLog = ''

if ($DryRun) {
    Write-Head 'Backup (dry run)'
    Write-Info ('DRY: would copy .claude\ (minus other .backup-*) to ' + $BkRel + '/claude/')
    Write-Info ('DRY: would copy the doctrine docs it rewrites to ' + $BkRel + '/context/')
    Write-Info ('DRY: would generate ' + $BkRel + '/restore.ps1')
    $InstallLog = Join-Path ([System.IO.Path]::GetTempPath()) ('rtu-install-' + $Ts + '.log')
}
else {
    Write-Head 'Backup'
    New-Item -ItemType Directory -Path (Join-Path $Bk 'claude') -Force -ErrorAction SilentlyContinue | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $Bk 'claude') -PathType Container)) {
        Stop-Refused ("cannot create the backup directory " + $BkRel + ".`n  Nothing has been written. An update without a backup is not an update, it is`n  a hope, so this is a refusal and not a warning.")
    }
    $bkOk = $true
    foreach ($e in (Get-ChildItem -LiteralPath (Join-Path $Tgt '.claude') -Force -ErrorAction SilentlyContinue)) {
        if ($e.Name -like '.backup-*') { continue }
        try { Copy-Item -LiteralPath $e.FullName -Destination (Join-Path $Bk 'claude') -Recurse -Force -ErrorAction Stop }
        catch { Write-Err ('could not back up .claude\' + $e.Name); $bkOk = $false }
    }
    if (-not $bkOk) { Stop-Refused 'the backup is incomplete. Nothing else was written.' }
    $bkN = (Get-ChildItem -LiteralPath (Join-Path $Bk 'claude') -Recurse -File -Force -ErrorAction SilentlyContinue).Count
    Write-Ok ('backed up .claude\ -> ' + $BkRel + '/claude/ (' + $bkN + ' files)')

    if ($DoctrineTouch.Count -gt 0) {
        New-Item -ItemType Directory -Path (Join-Path $Bk 'context') -Force -ErrorAction SilentlyContinue | Out-Null
        foreach ($rel in $DoctrineTouch) {
            $srcp = Join-Path $Tgt ($rel -replace '/', '\')
            if (-not (Test-Path -LiteralPath $srcp -PathType Leaf)) { continue }
            if ($rel -eq 'CLAUDE.ratchet.md') {
                New-Item -ItemType Directory -Path (Join-Path $Bk 'root') -Force -ErrorAction SilentlyContinue | Out-Null
                Copy-Item -LiteralPath $srcp -Destination (Join-Path $Bk 'root') -Force -ErrorAction SilentlyContinue
            }
            else {
                Copy-Item -LiteralPath $srcp -Destination (Join-Path $Bk 'context') -Force -ErrorAction SilentlyContinue
            }
        }
        Write-Ok 'backed up the doctrine docs this update rewrites'
    }

    # The rollback script. Generated per backup and explicit about every path it
    # touches. It restores the control layer and NOTHING else: .pipeline\,
    # .agent-development\, SPEC, MILESTONES, DECISIONS and secrets\ were never
    # modified, so putting them back would be a change, not a rollback.
    $restoreTemplate = @'
# Ratchet rollback -- generated by ratchet-update.ps1 @@RTUVER@@ at @@TS@@.
# Restores the control layer to harness @@OLDVER@@, exactly as it was
# immediately before the update to @@NEWVER@@.
#
# It restores:   .claude\hooks\  .claude\agents\  .claude\settings.json
#                the .claude\ dotfiles, and the doctrine docs under .context\
# It does NOT touch: .pipeline\  .agent-development\  secrets\  docs\evidence\
#                .context\SPEC.md  MILESTONES.md  DECISIONS.md  your CLAUDE.md
# Nothing in that second list was modified by the update, so restoring it would
# be a change rather than a rollback. The one row appended to
# PENDING-HUMAN-ACTIONS.md is left in place on purpose: it is the record that
# this happened.
Set-StrictMode -Version 1.0
$Bk = Split-Path -Parent $MyInvocation.MyCommand.Path
$R  = (Resolve-Path (Join-Path $Bk '..\..')).Path
if (-not (Test-Path (Join-Path $Bk 'claude'))) {
    Write-Host 'rollback: backup payload missing' -ForegroundColor Red
    exit 2
}
Write-Host ('Rolling ' + $R + ' back to Ratchet @@OLDVER@@ ...')
foreach ($d in @('hooks', 'agents')) {
    $p = Join-Path $R ('.claude\' + $d)
    if (Test-Path $p) { Remove-Item -LiteralPath $p -Recurse -Force }
}
foreach ($f in @('settings.json', '.ratchet-version', '.ratchet-manifest',
                 '.ratchet-install-manifest', '.ratchet-install.json')) {
    $p = Join-Path $R ('.claude\' + $f)
    if (Test-Path $p) { Remove-Item -LiteralPath $p -Force }
}
Copy-Item -Path (Join-Path $Bk 'claude\*') -Destination (Join-Path $R '.claude') -Recurse -Force
if (Test-Path (Join-Path $Bk 'context')) {
    Copy-Item -Path (Join-Path $Bk 'context\*') -Destination (Join-Path $R '.context') -Force
}
if (Test-Path (Join-Path $Bk 'root')) {
    Copy-Item -Path (Join-Path $Bk 'root\*') -Destination $R -Force
}
Write-Host 'Rolled back. Now re-run the suite, because a rollback is a change too:'
Write-Host ('    cd "' + $R + '"; python .claude/hooks/test_hooks.py')
Write-Host 'The .local-* copies this update left behind (if any) are still on disk.'
exit 0
'@
    $restore = $restoreTemplate.Replace('@@RTUVER@@', $RtuVersion).Replace('@@TS@@', $Ts)
    $restore = $restore.Replace('@@OLDVER@@', $InstalledVersion).Replace('@@NEWVER@@', $BundleVersion)
    Write-LfFile -Path (Join-Path $Bk 'restore.ps1') -Content $restore
    Write-Ok ('rollback script: ' + $BkRel + '/restore.ps1')
    Write-Host ''
    Write-Host ('  ROLLBACK, any time:  cd ' + $Tgt + '; ' + $Rollback) -ForegroundColor Cyan
    Write-Host ''
    $InstallLog = Join-Path $Bk 'install.log'
}

# ============================================================================
# SECTION 9 -- APPLY
# ============================================================================
Write-Head 'Applying'

# 9.1 doctrine docs. install.ps1 writes .context\ if-absent, which is right for
# an install and wrong for an update, so the updater places these itself and
# lets install.ps1's substitution pass fill the {{MARKERS}} afterwards.
foreach ($rel in $DoctrineTouch) {
    $srcRel = $rel
    if ($rel -eq 'CLAUDE.ratchet.md') { $srcRel = '.context/CLAUDE.md' }
    $src = Join-Path $HarnessSrc ($srcRel -replace '/', '\')
    if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }
    if ($DryRun) {
        Write-Info ('DRY: write ' + $rel + ' (doctrine doc)')
        continue
    }
    Copy-LfFile -Source $src -Destination (Join-Path $Tgt ($rel -replace '/', '\'))
    Write-Ok ('doctrine doc: ' + $rel)
}

# 9.2 delegate to install.ps1. This is the whole point. install.ps1 already
# knows how to replace the harness, keep user files, merge settings.json,
# substitute markers, fix line endings and not regenerate the escalation key. A
# second implementation of any of that is a second thing to get wrong. -Force is
# passed because THIS script has already taken a backup that is stronger than
# the dirty-worktree check install.ps1 would otherwise apply; -SkipVerify
# because the suite is run below, where the report can put the rollback command
# next to a failure.
$iArgs = @('-Target', $Tgt, '-Domain', 'none', '-SkipVerify', '-Force', '-NoColor')
if ($IStack   -ne '') { $iArgs += @('-Stack', $IStack) }
if ($IProject -ne '') { $iArgs += @('-ProjectName', $IProject) }
if ($IBase    -ne '') { $iArgs += @('-BaseBranch', $IBase) }
if ($IEsc     -ne '') { $iArgs += @('-EscalationMode', $IEsc) }
if ($DryRun)          { $iArgs += @('-WhatIf') }

if ($IStack -eq '') {
    Write-Warn 'no .claude\.ratchet-install.json, so the stack pack and project name are'
    Write-Say  '        being re-detected rather than remembered. Check the report below; if the'
    Write-Say  '        stack is wrong, re-run install.ps1 once with the right -Stack.'
}

Write-Info ('delegating the file writes to install.ps1 ' + $BundleVersion + ' ...')
$installOut = & powershell -NoProfile -ExecutionPolicy Bypass -File $InstallPs1 @iArgs 2>&1
$installRc = $LASTEXITCODE
Write-LfFile -Path $InstallLog -Content (($installOut | Out-String))
if ($installRc -eq 0) {
    if ($DryRun) { Write-Ok 'install.ps1 -WhatIf completed (it wrote nothing either)' }
    else { Write-Ok ('install.ps1 completed (transcript: ' + $BkRel + '/install.log)') }
}
else {
    Write-Err ('install.ps1 exited ' + $installRc + '. Last 25 lines:')
    foreach ($l in (($installOut | Out-String) -split "`n" | Select-Object -Last 25)) { Write-Say ('      ' + $l.TrimEnd()) }
}
$SettingsFailed = $false
if (($installOut | Out-String) -match 'merge produced invalid JSON') { $SettingsFailed = $true }

# 9.2b What the merge took away from YOU. The merge is a union with one
# deliberate asymmetry: our deny beats your allow and your ask, because deny is
# the class that cannot be lifted at runtime and a permissive entry that
# survived a merge would silently reopen a wall. That is correct, and it is also
# the one thing in the merge a human would want told to them by name rather than
# discovered later by being blocked.
if ((-not $DryRun) -and (Test-Path -LiteralPath (Join-Path $Bk 'claude\settings.json') -PathType Leaf)) {
    try {
        $oldS = (Get-Content -LiteralPath (Join-Path $Bk 'claude\settings.json') -Raw) | ConvertFrom-Json
        $newS = (Get-Content -LiteralPath (Join-Path $Tgt '.claude\settings.json') -Raw) | ConvertFrom-Json
        $keep = @()
        if ($newS.permissions.PSObject.Properties.Name -contains 'allow') { $keep += $newS.permissions.allow }
        if ($newS.permissions.PSObject.Properties.Name -contains 'ask')   { $keep += $newS.permissions.ask }
        $had = @()
        if ($oldS.permissions.PSObject.Properties.Name -contains 'allow') { $had += $oldS.permissions.allow }
        if ($oldS.permissions.PSObject.Properties.Name -contains 'ask')   { $had += $oldS.permissions.ask }
        $dropped = @($had | Where-Object { $keep -notcontains $_ } | Sort-Object -Unique)
        if ($dropped.Count -gt 0) {
            Write-Warn ('permission entries you had are gone, because harness ' + $BundleVersion + ' denies them:')
            foreach ($d in $dropped) { Write-Say ('          ' + $d) }
            Write-Say '        Our deny beats your allow and your ask. If one of these is load-bearing'
            Write-Say '        for this project, it does not go back in settings.json by hand: it is a'
            Write-Say '        domain-pack question (SECRET_EXEMPTIONS, FORBIDDEN_EXEC_TOKENS) or a'
            Write-Say '        named local patch. See .context\UPGRADING.md section 5.'
        }
    }
    catch { Write-Warn 'could not compare the pre-merge and post-merge permission surfaces.' }
}

# install.ps1's first run writes a root CLAUDE.md containing the one-line import
# "@.context/CLAUDE.md". Every run after that sees a root CLAUDE.md, concludes
# the project had its own, and writes CLAUDE.ratchet.md plus a warning saying
# the doctrine is "installed but not loaded" -- which is false when the import
# is already there. Say so, once, rather than let the warning stand.
if ((-not $DryRun) -and (Test-Path -LiteralPath (Join-Path $Tgt 'CLAUDE.ratchet.md') -PathType Leaf)) {
    $rootClaude = Join-Path $Tgt 'CLAUDE.md'
    if (Test-Path -LiteralPath $rootClaude -PathType Leaf) {
        $hit = Select-String -LiteralPath $rootClaude -Pattern '@\.context/CLAUDE\.md' -ErrorAction SilentlyContinue
        if ($null -ne $hit) {
            Write-Info 'CLAUDE.ratchet.md was (re)written by install.ps1, but your root CLAUDE.md'
            Write-Info '  already imports @.context/CLAUDE.md, so the doctrine IS loaded and that'
            Write-Info '  file is a redundant copy. Deleting it is safe and this updater will not'
            Write-Info '  put it back unless install.ps1 does.'
        }
    }
}

# 9.3 preserve the local edits. The byte-exact pre-update copy is in the backup,
# which is why the .local file is written from THERE and not from the live tree:
# by now the live tree has been rewritten and marker-substituted.
$LocalSaved = New-Object System.Collections.ArrayList
if (($ModifiedList.Count -gt 0) -and (-not $ForceOverwriteModified)) {
    Write-Head 'Preserving your harness edits'
    foreach ($rel in $ModifiedList) {
        if ($DryRun) {
            Write-Info ('DRY: save ' + $rel + ' -> ' + $rel + '.local-' + $Ts)
            continue
        }
        $srcBk = ''
        if ($rel -eq 'CLAUDE.ratchet.md') { $srcBk = Join-Path $Bk 'root\CLAUDE.ratchet.md' }
        elseif ($rel.StartsWith('.context/')) { $srcBk = Join-Path $Bk ('context\' + (Split-Path -Leaf ($rel -replace '/', '\'))) }
        elseif ($rel.StartsWith('.claude/')) { $srcBk = Join-Path $Bk ('claude\' + ($rel.Substring(8) -replace '/', '\')) }
        if (($srcBk -ne '') -and (Test-Path -LiteralPath $srcBk -PathType Leaf)) {
            $dstLocal = (Join-Path $Tgt ($rel -replace '/', '\')) + '.local-' + $Ts
            Copy-Item -LiteralPath $srcBk -Destination $dstLocal -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $dstLocal -PathType Leaf) {
                Write-Ok ($rel + '.local-' + $Ts)
                [void] $LocalSaved.Add($rel + '.local-' + $Ts)
            }
            else { Write-Err ('could not preserve ' + $rel) }
        }
        else { Write-Err ('no backup copy of ' + $rel + ' to preserve') }
    }
    if ($LocalSaved.Count -gt 0) {
        Write-Say ''
        Write-Say '  Diff each one against what just landed, decide, then delete it. If the edit'
        Write-Say '  is still wanted, it does not go back in by hand: it goes upstream, or it'
        Write-Say '  becomes a named local patch. See .context\UPGRADING.md.'
    }
}

# 9.4 version + manifest
if (-not $DryRun) {
    Write-LfFile -Path $VersionFile -Content ($BundleVersion + "`n")
    Write-Ok ('recorded .claude\.ratchet-version = ' + $BundleVersion)
    Write-RtManifest -RecordVersion $BundleVersion
    Write-Ok ('recorded .claude\.ratchet-manifest (' + (Get-TargetHarnessPaths).Count + ' harness checksums)')
    Write-Say "      From here, 'did someone edit a harness file?' is a decidable question."
}
else {
    Write-Info 'DRY: would record .ratchet-version and .ratchet-manifest'
}

# ============================================================================
# SECTION 10 -- HUMAN FOLLOW-UP
# ============================================================================
$Pha = Join-Path $Tgt '.agent-development\PENDING-HUMAN-ACTIONS.md'
$PhaText = ''
if (Test-Path -LiteralPath $Pha -PathType Leaf) { $PhaText = (Get-Content -LiteralPath $Pha -Raw) }

# Names are permanent and never reused (CONTRACT 6), so a repeated condition
# gets a step counter rather than the same name twice.
function Get-PhaName {
    param([string] $Base)
    $n = 1
    while ($PhaText.Contains('| ' + $Base + '-' + $n + ' |')) { $n = $n + 1 }
    return ($Base + '-' + $n)
}
$PhaRows = New-Object System.Collections.ArrayList
$Today = (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd')
function Add-PhaRow {
    param([string] $Base, [string] $Action)
    $nm = Get-PhaName $Base
    [void] $PhaRows.Add(@($nm, ('| ' + $nm + ' | ' + $Today + ' | human | ' + $Action + ' | OPEN |')))
    $script:PhaText = $script:PhaText + "`n| " + $nm + ' |'
}

if ($neverNew.Count -gt 0) {
    Add-PhaRow 'new-never-escalatable-rules' ('Harness ' + $InstalledVersion + ' -> ' + $BundleVersion +
        ' added never-escalatable rule ids: `' + ($neverNew -join ' ') + '`. Nothing lifts these -- not `approve.sh`, not a Decision Card, not the domain pack. Re-read `.claude/hooks/escalation-lib.sh` and confirm no standing workflow in this project depends on one of them being confirmable. If one does, that workflow now needs redesigning, not approving.')
}
if ($CfgOverridden -gt 0) {
    $keys = @($CfgChanged | Where-Object { $_[3] -ne '' } | ForEach-Object { $_[0] })
    Add-PhaRow 'config-default-changed-under-override' ('Harness ' + $InstalledVersion + ' -> ' + $BundleVersion +
        ' changed the default of: `' + ($keys -join ' ') + '` -- and this project has a recorded opinion about each of them. Nothing failed; the number is just different now. Confirm the value you want is set somewhere the update cannot move it (DECISIONS.md plus an explicit export), not inherited from a default.')
}
if ($ControlDrift.Count -gt 0) {
    Add-PhaRow 'control-set-drift-detected' ('Before this update, these never-escalatable control-set files did not match what was installed: `' +
        ($ControlDrift -join ' ') + '`. They have been replaced with harness ' + $BundleVersion + ' and the previous contents kept as `.local-' + $Ts +
        '`. Read the diff and decide whether the edit was a deliberate local patch (record it in DECISIONS.md and see `.context/UPGRADING.md`), or drift that should stay gone.')
}
elseif ($ModifiedList.Count -gt 0) {
    Add-PhaRow 'harness-files-locally-modified' ('These harness files did not match what was installed and were replaced by harness ' +
        $BundleVersion + ', with the previous contents kept as `.local-' + $Ts + '`: `' + ($ModifiedList -join ' ') +
        '`. Diff each, then either propose the change upstream or record it as a named local patch in DECISIONS.md. Deleting the `.local-*` file is how you close this row.')
}

if (($PhaRows.Count -gt 0) -and (-not $DryRun)) {
    Write-Head 'Filed for a human'
    if (-not (Test-Path -LiteralPath $Pha -PathType Leaf)) {
        $hdr = "# PENDING HUMAN ACTIONS`n`nAgents APPEND here. Humans close rows by editing the Status column to DONE.`n`n| name | opened | who | action | status |`n|---|---|---|---|---|`n"
        Write-LfFile -Path $Pha -Content $hdr
    }
    $existing = [System.IO.File]::ReadAllText($Pha)
    $add = ''
    foreach ($r in $PhaRows) { $add = $add + $r[1] + "`n" }
    Write-LfFile -Path $Pha -Content ($existing + $add)
    foreach ($r in $PhaRows) { Write-Say ('      ' + $r[0]) }
    Write-Say ''
    Write-Say '  Appending to PENDING-HUMAN-ACTIONS.md is the one sanctioned write into the'
    Write-Say '  USER partition: it is an append-only register that exists to be appended to.'
}
elseif ($PhaRows.Count -gt 0) {
    Write-Head 'Would file for a human'
    foreach ($r in $PhaRows) { Write-Say ('      DRY: ' + $r[0]) }
}

# The event. pipeline-event.sh is a bash hook; on Windows it runs under the same
# Git-Bash the gates run under, which install.ps1 recorded in .ratchet-bash.
if (-not $DryRun) {
    $bashExe = 'bash'
    $bashRec = Join-Path $Tgt '.claude\hooks\.ratchet-bash'
    if (Test-Path -LiteralPath $bashRec -PathType Leaf) {
        $b = ((Get-Content -LiteralPath $bashRec -TotalCount 1) + '').Trim()
        if ($b -ne '') { $bashExe = $b }
    }
    $forcedRun = '0'
    if ($Force) { $forcedRun = '1' }
    $evArgs = @('.claude/hooks/pipeline-event.sh', 'harness_updated',
        ('from=' + $InstalledVersion), ('to=' + $BundleVersion),
        ('updated=' + $nUpdate), ('new=' + $nNew), ('modified_preserved=' + $nModified),
        ('unverified=' + $nUnverified), ('orphaned=' + $nOrphan),
        ('backup=' + $BkRel), ('forced_over_active_run=' + $forcedRun))
    Push-Location $Tgt
    & $bashExe @evArgs 2>&1 | Out-Null
    $evRc = $LASTEXITCODE
    Pop-Location
    if ($evRc -eq 0) { Write-Ok 'emitted harness_updated to .pipeline/run-events.jsonl' }
    else { Write-Warn 'could not emit the pipeline event (the update itself is unaffected)' }
}

# ============================================================================
# SECTION 11 -- VERIFY. And do NOT auto-roll-back on failure.
# ============================================================================
$VerifyState = 'not run'
$RunActiveBefore = $true    # 'true' means: do not warn unless the suite armed it
$py = ''
foreach ($cand in @('python3', 'python', 'py')) {
    $c = Get-Command $cand -ErrorAction SilentlyContinue
    if ($null -eq $c) { continue }
    $v = & $cand -c 'import sys;print(sys.version_info[0])' 2>$null
    if ("$v".Trim() -eq '3') { $py = $cand; break }
}

if ($DryRun) {
    $VerifyState = 'skipped (dry run)'
}
elseif ($SkipVerify) {
    $VerifyState = 'SKIPPED (-SkipVerify)'
    Write-Warn 'the hook suite was not run. An unverified control layer is the one thing'
    Write-Say  '        this harness cannot check for you.'
}
elseif ((Test-Path -LiteralPath (Join-Path $Tgt '.claude\hooks\test_hooks.py') -PathType Leaf) -and ($py -ne '')) {
    Write-Head 'Verification (test_hooks.py)'
    $script:RunActiveBefore = Test-Path -LiteralPath $RunActive -PathType Leaf
    Push-Location $Tgt
    $vout = & $py '.claude/hooks/test_hooks.py' 2>&1
    $vrc = $LASTEXITCODE
    Pop-Location
    if ($vrc -eq 0) {
        $VerifyState = 'PASS'
        Write-Ok ('hook suite green on harness ' + $BundleVersion)
    }
    else {
        $VerifyState = 'FAIL'
        Write-Err ('hook suite FAILED after the update (exit ' + $vrc + ')')
        foreach ($l in (($vout | Out-String) -split "`n" | Select-Object -Last 30)) { Write-Say ('      ' + $l.TrimEnd()) }
    }
}
else {
    $VerifyState = 'SKIPPED (no test_hooks.py or no python3)'
    Write-Warn $VerifyState
}

# The control-layer postcondition is judged against a recorded floor of what this
# host already fails. The update changed the suite, so the old floor describes a
# different program. Re-record it -- but ONLY from a green run: a floor taken
# from a red suite bakes today's breakage in as normal and the postcondition then
# passes while the control layer is genuinely broken.
if ((-not $DryRun) -and ($VerifyState -eq 'PASS')) {
    $approve = Join-Path $Tgt '.claude\hooks\approve.sh'
    if (Test-Path -LiteralPath $approve -PathType Leaf) {
        $bashExe = 'bash'
        $bashRec = Join-Path $Tgt '.claude\hooks\.ratchet-bash'
        if (Test-Path -LiteralPath $bashRec -PathType Leaf) {
            $b = ((Get-Content -LiteralPath $bashRec -TotalCount 1) + '').Trim()
            if ($b -ne '') { $bashExe = $b }
        }
        Write-Info 're-recording the control-layer postcondition baseline...'
        Push-Location $Tgt
        & $bashExe '.claude/hooks/approve.sh' '--postcondition-baseline' 2>&1 | Out-Null
        $prc = $LASTEXITCODE
        Pop-Location
        if ($prc -eq 0) { Write-Ok ('postcondition baseline re-recorded against harness ' + $BundleVersion) }
        else {
            Write-Warn 'could not re-record the postcondition baseline. Run it yourself:'
            Write-Say  ('            cd "' + $Tgt + '"; bash .claude/hooks/approve.sh --postcondition-baseline')
            Write-Say  '        A baseline from the OLD suite describes a different program.'
        }
    }
}
elseif ((-not $DryRun) -and ($VerifyState -ne 'PASS')) {
    Write-Warn 'NOT re-recording the postcondition baseline: the suite is not green.'
    Write-Say  "        A floor taken from a red suite records today's breakage as normal."
}

# The suite (and the postcondition baseline, which re-runs it) arms a run as a
# fixture and does not always clear it. This script must not clear it either:
# gc-prune.sh owns every run-lifecycle transition (CONTRACT 5.1) and a second
# writer to RUN_ACTIVE is exactly the kind of split ownership that makes a state
# file untrustworthy. So: say so, and check AFTER the last thing that runs the
# suite, not after the first.
if ((-not $DryRun) -and ($RunActiveBefore -eq $false) -and (Test-Path -LiteralPath $RunActive -PathType Leaf)) {
    $ra = ((Get-Content -LiteralPath $RunActive -TotalCount 1) + '').Trim()
    Write-Warn ('the hook suite left a run armed (.pipeline\run-active = ' + $ra + ').')
    Write-Say  '        Nothing is wrong with your repo, but until it is cleared the scope'
    Write-Say  "        checks and the Stop gate's definition-of-done checks are LIVE, and the"
    Write-Say  '        next update will refuse. gc-prune.sh owns that file, so clear it there:'
    Write-Say  ('            cd "' + $Tgt + '"; bash .claude/hooks/gc-prune.sh archive ' + $ra)
}

# ============================================================================
# SECTION 12 -- REPORT
# ============================================================================
Write-Head ('=' * 70)
if ($DryRun) {
    Write-Say '  DRY RUN COMPLETE. Nothing above was written.'
    Write-Say '  Re-run without -WhatIf to apply.'
    Write-Head ('=' * 70)
    if ($BundleTmp -ne '') { Remove-Item -LiteralPath $BundleTmp -Recurse -Force -ErrorAction SilentlyContinue }
    exit 0
}

$settingsLine = 'merged (yours kept, our deny wins ties)'
if ($SettingsFailed) { $settingsLine = 'MERGE FAILED -- not modified' }

Write-Say ('  Ratchet ' + $InstalledVersion + ' -> ' + $BundleVersion + ' in: ' + $Tgt)
Write-Say ('    harness files   ' + $nUpdate + ' updated, ' + $nNew + ' new, ' + $nSame + ' unchanged, ' + $nOrphan + ' orphaned')
Write-Say ('    preserved       ' + $nModified + ' locally-modified, ' + $nUnverified + ' unverified')
Write-Say ('    settings.json   ' + $settingsLine)
Write-Say ('    verification    ' + $VerifyState)
Write-Say ('    warnings        ' + $script:Warnings)
Write-Say  '    untouched       .context\SPEC.md .context\MILESTONES.md .context\DECISIONS.md'
Write-Say  '                    .claude\hooks\domain.config.sh  .agent-development\  .pipeline\'
Write-Say  '                    secrets\  docs\evidence\  and every path not listed above'

if ($LocalSaved.Count -gt 0) {
    Write-Say ''
    Write-Say '  Your harness edits are on disk, beside the files they came from:'
    foreach ($l in $LocalSaved) { Write-Say ('      ' + $l) }
}

Write-Say ''
Write-Host '  ROLLBACK (one command, works any time):' -ForegroundColor Cyan
Write-Say ('      cd ' + $Tgt + '; ' + $Rollback)

if ($VerifyState -eq 'FAIL') {
    Write-Host ''
    Write-Host ('  ' + ('=' * 68)) -ForegroundColor Red
    Write-Host '  THE HOOK SUITE IS RED ON THE NEW HARNESS.' -ForegroundColor Red
    Write-Host ''
    Write-Say '  This update was NOT rolled back automatically, and that is deliberate: an'
    Write-Say '  automatic rollback would leave you with a working harness and no record'
    Write-Say '  that the new one is broken, which is how a broken release ships twice.'
    Write-Say ''
    Write-Say '  Roll back now:'
    Write-Say ('      cd ' + $Tgt + '; ' + $Rollback)
    Write-Say ''
    Write-Say ('  Or investigate first -- the old tree is intact in ' + $BkRel + ':')
    Write-Say ('      cd ' + $Tgt + '; python .claude/hooks/test_hooks.py')
    Write-Host ('  ' + ('=' * 68)) -ForegroundColor Red
    Write-Host ''
}

Write-Head 'FIRST SESSION AFTER AN UPDATE'
Write-Say ''
Write-Say '  Read .context\UPGRADING.md -- it is the doctrine for this, and the update'
Write-Say '  may have just rewritten it. The short version:'
Write-Say '    1. Re-read .agent-development\ACTIVE-LESSONS.md; a lesson can be obsoleted'
Write-Say '       by a scaffold change and a stale lesson costs tokens every run.'
Write-Say "    2. Run the project's own suite, not just the hook suite."
Write-Say '    3. Read the new never-escalatable rules above. Something that used to be'
Write-Say '       approvable may now be a wall.'
Write-Say '    4. Close the rows this update filed in PENDING-HUMAN-ACTIONS.md.'
Write-Head ('=' * 70)

if ($BundleTmp -ne '') { Remove-Item -LiteralPath $BundleTmp -Recurse -Force -ErrorAction SilentlyContinue }

if (($VerifyState -eq 'FAIL') -or $SettingsFailed) { exit 1 }
exit 0
