<#
.SYNOPSIS
  AI Platform Kit installer (Windows / PowerShell).

.DESCRIPTION
  Installs the Databricks Platform Kit skills for the coding agent(s) you pick, into
  the current project or globally. Run interactively:

    irm https://raw.githubusercontent.com/databricks-solutions/ai-platform-kit/main/install.ps1 | iex

  Or non-interactively (arguments pass straight through to skills-sync.py):

    ./install.ps1 --agent codex --scope project
    ./install.ps1 --agents claude,cursor --scope global

  All real logic lives in scripts/skills-sync.py (Python 3, stdlib only). This wrapper
  just finds or fetches the repo, checks for Python, and delegates.
#>

$ErrorActionPreference = 'Stop'
$TarballUrl = 'https://codeload.github.com/databricks-solutions/ai-platform-kit/tar.gz/refs/heads/main'

function Die($msg) { Write-Error "error: $msg"; exit 1 }

# --- locate python --------------------------------------------------------------------
$python = $null
foreach ($cand in @('python', 'python3')) {
  if (Get-Command $cand -ErrorAction SilentlyContinue) { $python = $cand; break }
}
if (-not $python) { Die 'Python 3 is required but was not found on PATH.' }

# --- locate the repo (running from a clone?) or fetch a tarball -----------------------
$repoDir = $null
if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot 'scripts/skills-sync.py'))) {
  $repoDir = $PSScriptRoot
}

$cleanupDir = $null
if (-not $repoDir) {
  $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("aipk-" + [System.Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmp | Out-Null
  $cleanupDir = $tmp
  Write-Host 'Fetching AI Platform Kit...'
  $tarPath = Join-Path $tmp 'aipk.tar.gz'
  Invoke-WebRequest -Uri $TarballUrl -OutFile $tarPath
  tar -xz -f $tarPath -C $tmp
  $repoDir = (Get-ChildItem -Path $tmp -Directory -Filter 'ai-platform-kit-*' | Select-Object -First 1).FullName
  if (-not $repoDir) { Die 'could not unpack the kit tarball.' }
}

try {
  & $python (Join-Path $repoDir 'scripts/skills-sync.py') @args
  exit $LASTEXITCODE
}
finally {
  if ($cleanupDir -and (Test-Path $cleanupDir)) { Remove-Item -Recurse -Force $cleanupDir }
}
