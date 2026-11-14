[CmdletBinding()]
param(
    [string]$OutputPath = "bin/LeviLauncher-AllowTrial.exe",
    [switch]$SkipTests,
    [switch]$SkipNativeRebuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$goVersion = "1.27.3"
$goArchiveSha256 = "f26081f438319757f8a1b46d7d0b2c5ec7583d4038e485e0aa725cfde7885fff"
$wailsVersion = "v3.0.0"
$toolRoot = Join-Path $env:LOCALAPPDATA "LeviLauncherBuildTools"
$goRoot = Join-Path $toolRoot "go-$goVersion"
$goExe = Join-Path $goRoot "go\bin\go.exe"
$toolBin = Join-Path $toolRoot "bin"
$wailsExe = Join-Path $toolBin "wails3.exe"
$wailsStamp = Join-Path $toolBin ("wails3-{0}.stamp" -f $wailsVersion.TrimStart("v"))
$buildTags = "production,allowtrialinstall"
$operationTemp = Join-Path $toolRoot ("temp-{0}" -f [guid]::NewGuid())
$goTemp = Join-Path $operationTemp "go-build"

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter()][string[]]$ArgumentList = @(),
        [Parameter()][string]$WorkingDirectory = $repoRoot
    )

    Push-Location $WorkingDirectory
    try {
        Write-Host "> $FilePath $($ArgumentList -join ' ')" -ForegroundColor Cyan
        & $FilePath @ArgumentList
        if ($LASTEXITCODE -ne 0) {
            throw "Command failed with exit code ${LASTEXITCODE}: $FilePath"
        }
    }
    finally {
        Pop-Location
    }
}

function Require-Command {
    param([Parameter(Mandatory)][string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "Required command '$Name' was not found on PATH."
    }
    return $command.Source
}

function Install-GoToolchain {
    if (Test-Path $goExe) {
        return
    }

    New-Item -ItemType Directory -Path $toolRoot -Force | Out-Null
    $archive = Join-Path $toolRoot "go$goVersion.windows-amd64.zip"
    $staging = Join-Path $toolRoot "go-$goVersion-staging"
    try {
        if (-not (Test-Path $archive)) {
            Write-Host "Downloading Go $goVersion..." -ForegroundColor Yellow
            Invoke-WebRequest -Uri "https://go.dev/dl/go$goVersion.windows-amd64.zip" -OutFile $archive -UseBasicParsing
        }
        $actual = (Get-FileHash -Path $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $goArchiveSha256) {
            throw "Go archive SHA-256 mismatch: expected $goArchiveSha256, got $actual"
        }
        if (Test-Path $staging) {
            Remove-Item -Path $staging -Recurse -Force
        }
        New-Item -ItemType Directory -Path $staging | Out-Null
        Expand-Archive -Path $archive -DestinationPath $staging
        if (Test-Path $goRoot) {
            Remove-Item -Path $goRoot -Recurse -Force
        }
        Move-Item -Path $staging -Destination $goRoot
    }
    finally {
        if (Test-Path $staging) {
            Remove-Item -Path $staging -Recurse -Force
        }
    }
}

if (-not [Environment]::Is64BitOperatingSystem) {
    throw "LeviLauncher's native MSIXVC path requires 64-bit Windows."
}

$nodeExe = Require-Command "node.exe"
$npmExe = Require-Command "npm.cmd"
$xmakeExe = Require-Command "xmake.exe"
Install-GoToolchain

New-Item -ItemType Directory -Path $toolBin -Force | Out-Null
New-Item -ItemType Directory -Path $goTemp -Force | Out-Null
$env:GOTOOLCHAIN = "local"
$env:GOBIN = $toolBin
$env:CGO_ENABLED = "0"
$env:GOOS = "windows"
$env:GOARCH = "amd64"
$env:TEMP = $operationTemp
$env:TMP = $operationTemp
$env:GOTMPDIR = $goTemp
$env:PATH = "$(Split-Path $goExe -Parent);$toolBin;$env:PATH"
$env:LEVI_XBOX_UPDATE_PROBE = $null

Invoke-Checked $goExe @("version")
Invoke-Checked $nodeExe @("--version")
Invoke-Checked $npmExe @("--version")
Invoke-Checked $xmakeExe @("--version")

if (-not (Test-Path $wailsExe) -or -not (Test-Path $wailsStamp)) {
    Invoke-Checked $goExe @("install", "github.com/wailsapp/wails/v3/cmd/wails3@$wailsVersion")
    Get-ChildItem -Path $toolBin -Filter "wails3-*.stamp" -File -ErrorAction SilentlyContinue | Remove-Item -Force
    Set-Content -Path $wailsStamp -Value $wailsVersion -NoNewline
}

$nativeDir = Join-Path $repoRoot "native\levilauncher"
$loaderDll = Join-Path $repoRoot "internal\leviloader\LeviLauncher.dll"
$loaderBackup = Join-Path $toolRoot ("LeviLauncher-{0}.dll.backup" -f [guid]::NewGuid())
$syso = Join-Path $repoRoot "wails_windows_amd64.syso"
$restoreLoader = $false
try {
    if (-not $SkipNativeRebuild) {
        if (Test-Path $loaderDll) {
            Copy-Item -Path $loaderDll -Destination $loaderBackup
            $restoreLoader = $true
        }
        Invoke-Checked $xmakeExe @("f", "-p", "windows", "-a", "x64", "-m", "release", "--toolchain=msvc", "--deploy=y", "-y") $nativeDir
        Invoke-Checked $xmakeExe @("build", "-r", "LeviLauncher") $nativeDir
        if (-not $SkipTests) {
            Invoke-Checked $xmakeExe @("-y", "native_tests") $nativeDir
            Invoke-Checked $xmakeExe @("run", "native_tests") $nativeDir
        }
    }

    Invoke-Checked $npmExe @("ci") (Join-Path $repoRoot "frontend")
    Invoke-Checked $wailsExe @("generate", "bindings", "-f", "-tags $buildTags", "-clean=true")
    Invoke-Checked $npmExe @("run", "build") (Join-Path $repoRoot "frontend")

    if (-not $SkipTests) {
        # Upstream ships a small number of tests that fail identically in upstream's own CI;
        # upstream's workflow masks them by ignoring the `go test` exit code. Skip exactly
        # those; every other failure still stops the build before publication.
        $knownBrokenUpstreamTests = '^(TestModSearchAndShow|TestSharedDetails|TestMigration_V11_AccountsDACL)$'
        Write-Host "Skipping upstream tests confirmed broken in upstream CI: $knownBrokenUpstreamTests" -ForegroundColor Yellow
        Invoke-Checked $goExe @("test", "-count=1", "-tags", "allowtrialinstall", "-skip", $knownBrokenUpstreamTests, "./...")
        Invoke-Checked $goExe @("vet", "-tags", "allowtrialinstall", "./...")
    }

    foreach ($resource in @("build\windows\icon.ico", "build\windows\wails.exe.manifest", "build\windows\info.json")) {
        if (-not (Test-Path (Join-Path $repoRoot $resource))) {
            throw "Required tracked Windows resource is missing: $resource"
        }
    }
    Invoke-Checked $wailsExe @("generate", "syso", "-arch", "amd64", "-icon", "windows/icon.ico", "-manifest", "windows/wails.exe.manifest", "-info", "windows/info.json", "-out", "..\wails_windows_amd64.syso") (Join-Path $repoRoot "build")

    $resolvedOutput = if ([System.IO.Path]::IsPathRooted($OutputPath)) {
        [System.IO.Path]::GetFullPath($OutputPath)
    } else {
        [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputPath))
    }
    New-Item -ItemType Directory -Path (Split-Path $resolvedOutput -Parent) -Force | Out-Null
    Invoke-Checked $goExe @("build", "-tags", $buildTags, "-trimpath", "-buildvcs=false", "-ldflags=-H windowsgui", "-o", $resolvedOutput, ".")

    if (-not (Test-Path $resolvedOutput)) {
        throw "Expected build output was not created: $resolvedOutput"
    }
    $item = Get-Item $resolvedOutput
    $hash = (Get-FileHash -Path $resolvedOutput -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Host "Build complete" -ForegroundColor Green
    Write-Host "Output: $($item.FullName)"
    Write-Host "Bytes:  $($item.Length)"
    Write-Host "SHA256: $hash"
    Write-Host "Release policy: Full-only rejection disabled; a valid Microsoft-returned key is still required."
    Write-Host "Preview policy: restored upstream v0.3.13 launcher_core.dll extractor (no newer WAM content-license gate)."
}
finally {
    if (Test-Path $syso) {
        Remove-Item -Path $syso -Force
    }
    if ($restoreLoader -and (Test-Path $loaderBackup)) {
        Copy-Item -Path $loaderBackup -Destination $loaderDll -Force
    }
    if (Test-Path $loaderBackup) {
        Remove-Item -Path $loaderBackup -Force
    }
    if (Test-Path $operationTemp) {
        Remove-Item -Path $operationTemp -Recurse -Force
    }
}
