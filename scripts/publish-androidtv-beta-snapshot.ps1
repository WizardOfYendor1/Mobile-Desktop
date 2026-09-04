[CmdletBinding()]
param(
  [string]$SourceRoot = (Get-Location).Path,
  [string]$BaseRef = 'HEAD',
  [string]$Targets = 'androidtv',
  [string]$SnapshotBranch = 'beta/androidtv-snapshot',
  [string]$AutomationWorktree = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'

function Invoke-SourceGit {
  param([string[]]$GitArguments)

  $result = & git -C $script:sourceRoot @GitArguments
  if ($LASTEXITCODE -ne 0) {
    throw "git $($GitArguments -join ' ') failed with exit code $LASTEXITCODE"
  }

  return $result
}

$sourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
$automationWorktree = (Resolve-Path -LiteralPath $AutomationWorktree).Path
if ($Targets -notmatch '^(all|android|androidtv|ios|macos|windows|windows_arm64|linux|tvos)(,(all|android|androidtv|ios|macos|windows|windows_arm64|linux|tvos))*$') {
  throw 'Targets must be comma-separated android,androidtv,ios,macos,windows,windows_arm64,linux,all, or tvos.'
}
$baseSha = (Invoke-SourceGit -GitArguments @('rev-parse', '--verify', "$BaseRef^{commit}")).Trim()
$branchName = (Invoke-SourceGit -GitArguments @('branch', '--show-current')).Trim()
if ([string]::IsNullOrWhiteSpace($branchName)) {
  $branchName = '(detached HEAD)'
}

# A throwaway index lets git add --all capture staged, unstaged, and untracked
# non-ignored files without changing the source worktree's real index. Seed it
# from HEAD rather than copying the real index: a copy carries skip-worktree
# bits, which silently omit those paths (the tester TV banner) from snapshots.
$temporaryIndex = [IO.Path]::GetTempFileName()
Remove-Item -LiteralPath $temporaryIndex -Force
$previousIndex = $env:GIT_INDEX_FILE
try {
  $env:GIT_INDEX_FILE = $temporaryIndex
  Invoke-SourceGit -GitArguments @('read-tree', 'HEAD')
  Invoke-SourceGit -GitArguments @('add', '--all')
  $tree = (Invoke-SourceGit -GitArguments @('write-tree')).Trim()
  $message = "Amulet Android TV beta snapshot`n`nBase: $baseSha`nSource ref: $BaseRef`nSource branch: $branchName"
  $snapshotSha = (Invoke-SourceGit -GitArguments @('commit-tree', $tree, '-p', $baseSha, '-m', $message)).Trim()
}
finally {
  if ($null -eq $previousIndex) {
    Remove-Item Env:GIT_INDEX_FILE -ErrorAction SilentlyContinue
  }
  else {
    $env:GIT_INDEX_FILE = $previousIndex
  }
  Remove-Item -LiteralPath $temporaryIndex -Force -ErrorAction SilentlyContinue
}

$destination = "$snapshotSha`:refs/heads/$SnapshotBranch"
& git -C $sourceRoot push origin $destination "--force-with-lease=refs/heads/$SnapshotBranch"
if ($LASTEXITCODE -ne 0) {
  throw "Could not update origin/$SnapshotBranch"
}

& git -C $automationWorktree commit --allow-empty -m "beta-snapshot | $Targets"
if ($LASTEXITCODE -ne 0) {
  throw 'Could not create the automation trigger commit.'
}
& git -C $automationWorktree push origin automation/androidtv-beta
if ($LASTEXITCODE -ne 0) {
  throw 'Could not push the automation trigger commit.'
}

Write-Host "Published snapshot $snapshotSha from $branchName and triggered the Amulet Android TV beta build."
