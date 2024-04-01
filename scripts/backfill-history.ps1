# // git pull origin main --allow-unrelated-histories

#Requires -Version 5.1
<#
.SYNOPSIS
  Replay uncommitted project files as dated commits between Jan and Feb 2024.

.DESCRIPTION
  - Splits work into small, meaningful commits (crate bootstrap through tests).
  - Assigns each commit a random timestamp on a random day (0-5 commits/day).
  - Sets GIT_AUTHOR_DATE and GIT_COMMITTER_DATE for realistic history.

.PARAMETER StartDate
  First calendar day to consider (yyyy-MM-dd).

.PARAMETER EndDate
  Last calendar day to consider (yyyy-MM-dd).

.PARAMETER Seed
  RNG seed for reproducible day/time distribution.

.PARAMETER TzOffset
  Git date offset suffix, e.g. "-0300".

.PARAMETER DryRun
  Print planned commits without running git commit.

.PARAMETER AmendRoot
  Re-date the current root commit (usually the clone README) to StartDate morning.

.EXAMPLE
  cd e:\Work\local\rust_github\colored-rss
  .\scripts\backfill-history.ps1 -DryRun
  .\scripts\backfill-history.ps1
#>
[CmdletBinding()]
param(
    [string]$StartDate = "2024-02-01",
    [string]$EndDate   = "2024-03-31",
    [int]$Seed         = 80,
    [string]$TzOffset  = "-0300",
    [switch]$DryRun,
    [switch]$AmendRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Set-Location $RepoRoot

if (-not (Test-Path ".git")) {
    throw "Not a git repository: $RepoRoot"
}

function Remove-NestedGitRepos {
    Get-ChildItem -Path $RepoRoot -Directory -Recurse -Force -Filter ".git" |
        Where-Object { $_.FullName -ne (Join-Path $RepoRoot ".git") } |
        ForEach-Object {
            if ($DryRun) {
                Write-Host "Found nested repo (would remove): $($_.FullName)"
            }
            else {
                Write-Host "Removing nested repo: $($_.FullName)"
                Remove-Item -LiteralPath $_.FullName -Recurse -Force
            }
        }
}

function Get-RandomTime {
    param([datetime]$Day, [System.Random]$Rng)
    $h = $Rng.Next(9, 23)
    $m = $Rng.Next(0, 60)
    $s = $Rng.Next(0, 60)
    return $Day.AddHours($h).AddMinutes($m).AddSeconds($s)
}

function Build-Schedule {
    param(
        [array]$CommitQueue,
        [datetime]$Start,
        [datetime]$End,
        [int]$Seed
    )
    $rng = [System.Random]::new($Seed)

    # Spread commits across the full range so history uses Jan–Feb, not only early days.
    $count = $CommitQueue.Count
    $spanDays = [math]::Max(1, ($End - $Start).Days)
    $plan = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $count; $i++) {
        $baseDay = $Start.AddDays([int][math]::Round($i * $spanDays / [math]::Max(1, $count - 1)))
        $jitter = $rng.Next(-1, 2)
        $day = $baseDay.AddDays($jitter)
        if ($day -lt $Start) { $day = $Start }
        if ($day -gt $End) { $day = $End }
        $when = Get-RandomTime -Day $day -Rng $rng
        $plan.Add([pscustomobject]@{
                Message = $CommitQueue[$i].Message
                Paths   = $CommitQueue[$i].Paths
                When    = $when
            })
    }

    # Cap commits per calendar day at 5; push overflow to the next day.
    $byDay = @{}
    foreach ($item in ($plan | Sort-Object When)) {
        $key = $item.When.ToString("yyyy-MM-dd")
        if (-not $byDay.ContainsKey($key)) { $byDay[$key] = 0 }
        while ($byDay[$key] -ge 5) {
            $next = $item.When.AddDays(1)
            if ($next.Date -gt $End.Date) { break }
            $item.When = $next
            $key = $item.When.ToString("yyyy-MM-dd")
            if (-not $byDay.ContainsKey($key)) { $byDay[$key] = 0 }
        }
        $byDay[$key]++
    }
    return $plan | Sort-Object When
}

function Test-GitStaged {
    $names = git diff --cached --name-only 2>$null
    return [bool]($names | Where-Object { $_ })
}

function Invoke-DatedCommit {
    param(
        [string]$Message,
        [string[]]$Paths,
        [datetime]$When,
        [string]$TzOffset
    )

    $existing = @($Paths | Where-Object { Test-Path $_ })
    $missing = @($Paths | Where-Object { -not (Test-Path $_) })
    foreach ($m in $missing) {
        Write-Warning "Path not found (skipped): $m"
    }
    if (-not $existing) {
        Write-Warning "No paths to add for: $Message"
        return $false
    }

    $dateStr = "{0:yyyy-MM-dd HH:mm:ss} {1}" -f $When, $TzOffset

    if ($DryRun) {
        Write-Host "[dry-run] $dateStr  $Message"
        Write-Host "          paths: $($existing -join ', ')"
        return $true
    }

    git add --ignore-errors -- @existing
    if (-not (Test-GitStaged)) {
        Write-Warning "Nothing staged for: $Message"
        return $false
    }

    $env:GIT_AUTHOR_DATE = $dateStr
    $env:GIT_COMMITTER_DATE = $dateStr
    try {
        git commit -m $Message --date=$dateStr | Out-Host
        Write-Host "Committed: $dateStr  $Message" -ForegroundColor Green
        return $true
    }
    finally {
        Remove-Item Env:\GIT_AUTHOR_DATE -ErrorAction SilentlyContinue
        Remove-Item Env:\GIT_COMMITTER_DATE -ErrorAction SilentlyContinue
    }
}

# Ordered commits: small logical steps, foundation before dependents.
$CommitQueue = @(
    @{
        Message = "chore: ignore Rust build artifacts"
        Paths   = @(".gitignore")
    }
    @{
        Message = "docs: add colored-rs README"
        Paths   = @("README.md")
        SkipIf  = "tracked:README.md"
    }
    @{
        Message = "chore: add MPL-2.0 license"
        Paths   = @("LICENSE")
    }
    @{
        Message = "chore: add crate manifest"
        Paths   = @("Cargo.toml")
    }

    @{
        Message = "feat: add ANSI color enum and escape sequences"
        Paths   = @("src/color.rs")
    }
    @{
        Message = "feat: add Style bitmask and builder helpers"
        Paths   = @("src/style.rs")
    }
    @{
        Message = "feat: add CLICOLOR, NO_COLOR, and Windows VT control"
        Paths   = @("src/control.rs")
    }
    @{
        Message = "feat: add CustomColor and truecolor tuple support"
        Paths   = @("src/customcolors.rs")
    }
    @{
        Message = "feat: add no-color formatting trait"
        Paths   = @("src/formatters.rs")
    }
    @{
        Message = "feat: add ColoredString and Colorize trait"
        Paths   = @("src/lib.rs")
    }
    @{
        Message = "feat: implement ColoredString as std::error::Error"
        Paths   = @("src/error.rs")
    }
    @{
        Message = "test: add insta snapshot fixtures"
        Paths   = @("src/snapshots")
    }

    @{
        Message = "example: add minimal Colorize demo"
        Paths   = @("examples/most_simple.rs")
    }
    @{
        Message = "example: add custom and dynamic color demos"
        Paths   = @("examples/custom_colors.rs", "examples/dynamic_colors.rs")
    }
    @{
        Message = "example: add nested styling demo"
        Paths   = @("examples/nested_colors.rs")
    }
    @{
        Message = "example: add terminal control demo"
        Paths   = @("examples/control.rs")
    }
    @{
        Message = "example: add ColoredString as Error demo"
        Paths   = @("examples/as_error.rs")
    }

    @{
        Message = "test: add ansi_term compatibility suite"
        Paths   = @("tests")
    }
    @{
        Message = "docs: add changelog"
        Paths   = @("CHANGELOG.md")
    }
    @{
        Message = "ci: add Dockerfile for reproducible builds"
        Paths   = @("Dockerfile")
    }
    @{
        Message = "chore: add gitattributes and blame-ignore revs"
        Paths   = @(".gitattributes", ".git-blame-ignore-revs")
    }
    @{
        Message = "chore: add Cargo.lock for dev dependency pinning"
        Paths   = @("Cargo.lock")
    }
    @{
        Message = "chore: add backfill history script"
        Paths   = @("scripts/backfill-history.ps1")
    }
)

function Test-ShouldSkipCommit {
    param($Entry)
    if (-not ($Entry.ContainsKey("SkipIf") -and $Entry.SkipIf)) { return $false }
    if ($Entry.SkipIf -eq "tracked:README.md") {
        $tracked = git ls-files --error-unmatch README.md 2>$null
        return $LASTEXITCODE -eq 0
    }
    return $false
}

# --- main ---
Write-Host "Repository: $RepoRoot"
Remove-NestedGitRepos

$start = [datetime]::ParseExact($StartDate, "yyyy-MM-dd", $null)
$end   = [datetime]::ParseExact($EndDate, "yyyy-MM-dd", $null)

$activeQueue = [System.Collections.Generic.List[object]]::new()
foreach ($c in $CommitQueue) {
    if (Test-ShouldSkipCommit $c) {
        Write-Host "Skipping (already present): $($c.Message)"
        continue
    }
    $activeQueue.Add($c)
}

$plan = Build-Schedule -CommitQueue $activeQueue.ToArray() -Start $start -End $end -Seed $Seed

Write-Host ""
Write-Host "Plan: $($plan.Count) commits from $($plan[0].When.ToString('yyyy-MM-dd')) to $($plan[-1].When.ToString('yyyy-MM-dd')) (seed=$Seed)"
Write-Host ""

if ($AmendRoot) {
    $rootDate = "{0:yyyy-MM-dd 09:00:00} {1}" -f $start, $TzOffset
    if ($DryRun) {
        Write-Host "[dry-run] amend root commit date -> $rootDate"
    }
    else {
        $env:GIT_AUTHOR_DATE = $rootDate
        $env:GIT_COMMITTER_DATE = $rootDate
        try {
            git commit --amend --no-edit --date=$rootDate | Out-Host
        }
        finally {
            Remove-Item Env:\GIT_AUTHOR_DATE, Env:\GIT_COMMITTER_DATE -ErrorAction SilentlyContinue
        }
    }
}

$ok = 0
$skip = 0
foreach ($item in $plan) {
    $done = Invoke-DatedCommit -Message $item.Message -Paths $item.Paths -When $item.When -TzOffset $TzOffset
    if ($done) { $ok++ } else { $skip++ }
}

Write-Host ""
Write-Host "Finished: $ok committed, $skip skipped."
if (-not $DryRun) {
    Write-Host "Inspect: git log --oneline --date=short --format='%h %ad %s'"
    Write-Host "Per-day:   git log --format=%ad --date=short | Group-Object | Sort-Object Name"
}
