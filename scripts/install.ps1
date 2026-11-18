[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$RepoUrl = "https://github.com/HugehardJiang/open-computer-use-win-patch"

$nodeCmd = Get-Command node -ErrorAction SilentlyContinue
if (-not $nodeCmd) {
    throw "Node.js (>=18) is required. Install Node.js first, then re-run this installer."
}

$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("ocu-win-patch-" + [System.Guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null

try {
    $gitCmd = Get-Command git -ErrorAction SilentlyContinue
    $repoDir = Join-Path $tmpDir "repo"
    if ($gitCmd) {
        & git clone --depth 1 "$RepoUrl.git" $repoDir
        if ($LASTEXITCODE -ne 0) {
            throw "git clone failed with exit code $LASTEXITCODE"
        }
    } else {
        $zipPath = Join-Path $tmpDir "repo.zip"
        Invoke-WebRequest -Uri "$RepoUrl/archive/refs/heads/main.zip" -OutFile $zipPath -UseBasicParsing
        Expand-Archive -Path $zipPath -DestinationPath $tmpDir -Force
        $repoDir = Join-Path $tmpDir "open-computer-use-win-patch-main"
    }

    $installer = Join-Path $repoDir "scripts\install.mjs"
    & $nodeCmd.Source $installer @args
    if ($LASTEXITCODE -ne 0) {
        throw "install.mjs exited with code $LASTEXITCODE"
    }
} finally {
    Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
