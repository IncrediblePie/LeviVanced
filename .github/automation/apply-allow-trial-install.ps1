[CmdletBinding()]
param(
    [string]$RepoRoot = (Get-Location).Path,
    [bool]$Prerelease = $false,
    [string]$OverlayRoot = (Join-Path $PSScriptRoot "overlay")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
$utf8 = [Text.UTF8Encoding]::new($false)
$OverlayRoot = [IO.Path]::GetFullPath($OverlayRoot)
$legacyDLL = Join-Path $OverlayRoot "internal\legacyextractor\launcher_core.dll"
$legacyHash = "f557c21c08cd89c58bb6d47dd87d27402d4043ad8741b30fc5df91f796ff89aa"
if (-not (Test-Path $legacyDLL -PathType Leaf) -or
    (Get-FileHash $legacyDLL -Algorithm SHA256).Hash.ToLowerInvariant() -ne $legacyHash) {
    throw "Reviewed v0.3.13 legacy extractor overlay is missing or has an unexpected SHA-256."
}

function Update-ExactlyOnce {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Before,
        [Parameter(Mandatory)][string]$After
    )

    $path = Join-Path $RepoRoot $RelativePath
    if (-not (Test-Path $path -PathType Leaf)) {
        throw "Required upstream file is missing: $RelativePath"
    }
    $content = [IO.File]::ReadAllText($path)
    $lineEnding = if ($content.Contains("`r`n")) { "`r`n" } else { "`n" }
    $normalizedContent = $content.Replace("`r", "")
    $normalizedBefore = $Before.Replace("`r", "")
    $normalizedAfter = $After.Replace("`r", "")
    $count = [regex]::Matches($normalizedContent, [regex]::Escape($normalizedBefore)).Count
    $afterCount = [regex]::Matches($normalizedContent, [regex]::Escape($normalizedAfter)).Count
    if ($afterCount -eq 1 -and ($count -eq 0 -or ($count -eq 1 -and $normalizedAfter.Contains($normalizedBefore)))) {
        Write-Host "Already patched: $RelativePath"
        return
    }
    if ($afterCount -ne 0) {
        throw "Mixed or duplicated patch state in $RelativePath; review before building."
    }
    if ($count -ne 1) {
        throw "Expected exactly one patch location in ${RelativePath}; found $count. Review the new upstream release before building."
    }
    $updated = $normalizedContent.Replace($normalizedBefore, $normalizedAfter)
    if ($lineEnding -eq "`r`n") {
        $updated = $updated.Replace("`n", "`r`n")
    }
    [IO.File]::WriteAllText($path, $updated, $utf8)
    Write-Host "Patched: $RelativePath"
}

function Write-PolicyFile {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][string]$Content
    )

    $path = Join-Path $RepoRoot $RelativePath
    New-Item -ItemType Directory -Path (Split-Path $path -Parent) -Force | Out-Null
    [IO.File]::WriteAllText($path, $Content.Replace("`n", [Environment]::NewLine), $utf8)
    Write-Host "Wrote: $RelativePath"
}

# Upstream v1.1.0 removed the internal/lip package (now internal/lipcore).
# No compatibility fixture is needed there anymore; older refactored files
# are left untouched.

Update-ExactlyOnce `
    -RelativePath "internal\mcservice\installer.go" `
    -Before 'RequireFullLicense: true,' `
    -After 'RequireFullLicense: nativeinstall.DefaultRequireFullLicense,'

Update-ExactlyOnce `
    -RelativePath "cmd\msixvc-native\main_windows.go" `
    -Before 'flag.Bool("require-full", true, "Reject trial licenses")' `
    -After 'flag.Bool("require-full", nativeinstall.DefaultRequireFullLicense, "Reject trial licenses")'

$innoVersion = @'
#ifndef AppVersion
  #define AppVersion GetVersionNumbersString(AppBinaryPath)
#endif
'@.TrimEnd().Replace("`n", [Environment]::NewLine)
Update-ExactlyOnce `
    -RelativePath "build\windows\inno\project.iss" `
    -Before '#define AppVersion GetVersionNumbersString(AppBinaryPath)' `
    -After $innoVersion

Update-ExactlyOnce `
    -RelativePath "build\windows\inno\project.iss" `
    -Before '#define AppUrl "https://github.com/LiteLDev/LeviLauncher"' `
    -After '#define AppUrl "https://github.com/IncrediblePie/LeviVanced"'

$configPath = Join-Path $RepoRoot "build\config.yml"
$configText = [IO.File]::ReadAllText($configPath)
$betaPattern = '(?m)^(\s*beta:\s*)"(?:true|false)"'
$betaMatches = [regex]::Matches($configText, $betaPattern)
if ($betaMatches.Count -ne 1) {
    throw "Expected exactly one beta setting in build/config.yml; found $($betaMatches.Count)."
}
$betaValue = $Prerelease.ToString().ToLowerInvariant()
$configText = [regex]::Replace($configText, $betaPattern, { param($m) $m.Groups[1].Value + '"' + $betaValue + '"' })
$versionMatches = [regex]::Matches($configText, '(?m)^\s*version:\s*"([0-9][^"]*)"') | ForEach-Object { $_.Groups[1].Value }
$appVersion = $versionMatches | Select-Object -Last 1
if ([string]::IsNullOrWhiteSpace($appVersion)) {
    throw 'Cannot determine application version from build/config.yml.'
}
[IO.File]::WriteAllText($configPath, $configText, $utf8)
Write-Host "Set build/config.yml beta to $betaValue (version: $appVersion)."

# The upstream v1.1.x tree no longer ships the PE resource files. Regenerate
# them so this build embeds metadata matching the mirrored release tag.
# Windows PE file_version must be four numeric components. Pre-release
# segments are stripped; product strings keep the raw version.
$numericParts = $appVersion.Trim() -split '[-._]+' | Where-Object { $_ -match '^\d+$' } | Select-Object -First 4
$core = @($numericParts)
while ($core.Count -lt 4) { $core += '0' }
$fileVersion = ($core -join '.')
$manifest = @"
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1" xmlns:asmv3="urn:schemas-microsoft-com:asm.v3">
    <assemblyIdentity type="win32" name="org.levimc.launcher" version="$fileVersion" processorArchitecture="*"/>
    <dependency>
        <dependentAssembly>
            <assemblyIdentity type="win32" name="Microsoft.Windows.Common-Controls" version="6.0.0.0" processorArchitecture="*" publicKeyToken="6595b64144ccf1df" language="*"/>
        </dependentAssembly>
    </dependency>
    <asmv3:application>
        <asmv3:windowsSettings>
            <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true/pm</dpiAware> <!-- fallback for Windows 7 and 8 -->
            <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">permonitorv2,permonitor</dpiAwareness> <!-- falls back to per-monitor if per-monitor v2 is not supported -->
        </asmv3:windowsSettings>
    </asmv3:application>
    <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
        <security>
            <requestedPrivileges>
                <requestedExecutionLevel level="asInvoker" uiAccess="false"/>
            </requestedPrivileges>
        </security>
    </trustInfo>
</assembly>
"@
[IO.File]::WriteAllText((Join-Path $RepoRoot 'build\windows\wails.exe.manifest'), $manifest, $utf8)
Write-Host "Wrote: build\\windows\\wails.exe.manifest (version $fileVersion)"
$info = @{
    fixed = @{ file_version = $fileVersion }
    info  = @{
        '0409' = @{
            ProductVersion = $appVersion.Trim()
            CompanyName    = 'LeviMC'
            FileDescription = 'A Minecraft Launcher'
            LegalCopyright = '(c) 2024-2026, LeviMC'
            ProductName    = 'LeviLauncher'
            Comments       = 'Some Product Comments'
        }
    }
} | ConvertTo-Json -Depth 6
[IO.File]::WriteAllText((Join-Path $RepoRoot 'build\windows\info.json'), $info + "`n", $utf8)
Write-Host "Wrote: build\\windows\\info.json (ProductVersion $appVersion)"

# v1.1.0+ self-update retarget: keep upstream's own update logic and point it at
# the fork. The updater ZIP must match upstream's canonical name (LeviLauncher.zip)
# and is verified against the GitHub release asset SHA-256 digest before install.
$releaseStruct = @'
type githubReleaseAsset struct {
	Name               string `json:"name"`
	BrowserDownloadURL string `json:"browser_download_url"`
	Size               int64  `json:"size"`
}
'@.TrimEnd().Replace("`r`n", "`n")
$releaseStructPatched = @'
type githubReleaseAsset struct {
	Name               string `json:"name"`
	BrowserDownloadURL string `json:"browser_download_url"`
	Size               int64  `json:"size"`
	Digest             string `json:"digest"`
}

// findForkReleaseAsset returns the asset with the given name, if present.
func findForkReleaseAsset(release githubRelease, name string) *githubReleaseAsset {
	for i := range release.Assets {
		if strings.EqualFold(release.Assets[i].Name, name) {
			return &release.Assets[i]
		}
	}
	return nil
}

// verifyForkReleaseAssetDigest requires a sha256 digest on the named asset and
// verifies the file against it. It fails closed when digest metadata is missing,
// so a compromised or accidental proxy response cannot be installed silently.
func verifyForkReleaseAssetDigest(release githubRelease, zipPath string) error {
	const assetName = "LeviLauncher.zip"
	asset := findForkReleaseAsset(release, assetName)
	if asset == nil {
		return fmt.Errorf("release asset %q not found", assetName)
	}
	digest := strings.ToLower(strings.TrimSpace(asset.Digest))
	if !strings.HasPrefix(digest, "sha256:") || len(digest) != len("sha256:")+64 {
		return fmt.Errorf("release asset %q has no SHA-256 digest", assetName)
	}
	if err := verifyFileSHA256(zipPath, strings.TrimSpace(digest[len("sha256:"):])); err != nil {
		return err
	}
	return nil
}
'@.TrimEnd().Replace("`r`n", "`n")
Update-ExactlyOnce -RelativePath "internal\update\update.go" -Before $releaseStruct -After $releaseStructPatched

Update-ExactlyOnce `
    -RelativePath "internal\update\update.go" `
    -Before 'const oriUrl = "https://api.github.com/repos/LiteLDev/LeviLauncher/releases"' `
    -After 'const oriUrl = "https://api.github.com/repos/IncrediblePie/LeviVanced/releases"'

Update-ExactlyOnce `
    -RelativePath "internal\update\update.go" `
    -Before '"https://github.com/LiteLDev/LeviLauncher/releases/download/" + ver + "/LeviLauncher.zip"' `
    -After '"https://github.com/IncrediblePie/LeviVanced/releases/download/" + ver + "/LeviLauncher.zip"'

$oldZrestrictedDownload = @'
	if fi, statErr := os.Stat(zipPath); statErr == nil && fi.Size() > 0 {
		sink.Emit(EventAppUpdateStatus, "downloaded")
		sink.Emit(EventAppUpdateProgress, AppUpdateProgress{Phase: "download", Downloaded: fi.Size(), Total: fi.Size()})
	} else {
		if err := downloadUpdateAsset(ctx, buildSelfUpdateCandidateURLs(ver), zipPath); err != nil {
			return res, emitUpdateErrorTo(ctx, "ERR_UPDATE_DOWNLOAD_FAILED", err)
		}
	}
'@.TrimEnd().Replace("`r`n", "`n")
$verifiedDownload = @'
	fi, statErr := os.Stat(zipPath)
	cachedValid := statErr == nil && fi.Size() > 0 && verifyForkReleaseAssetDigest(release, zipPath) == nil
	if cachedValid {
		sink.Emit(EventAppUpdateStatus, "downloaded")
		sink.Emit(EventAppUpdateProgress, AppUpdateProgress{Phase: "download", Downloaded: fi.Size(), Total: fi.Size()})
	} else {
		_ = os.Remove(zipPath)
		if err := downloadUpdateAsset(ctx, buildSelfUpdateCandidateURLs(ver), zipPath); err != nil {
			return res, emitUpdateErrorTo(ctx, "ERR_UPDATE_DOWNLOAD_FAILED", err)
		}
		if err := verifyForkReleaseAssetDigest(release, zipPath); err != nil {
			_ = os.Remove(zipPath)
			return res, emitUpdateErrorTo(ctx, "ERR_UPDATE_DOWNLOAD_FAILED", err)
		}
	}
'@.TrimEnd().Replace("`r`n", "`n")
Update-ExactlyOnce -RelativePath "internal\update\update.go" -Before $oldZrestrictedDownload -After $verifiedDownload

Write-PolicyFile "internal\nativeinstall\install_policy_default_windows.go" @'
//go:build windows && !allowtrialinstall

// SPDX-License-Identifier: GPL-3.0-only
package nativeinstall

// DefaultRequireFullLicense is the install policy used by the launcher UI and
// diagnostic CLI. Official builds accept only Full content licenses.
const DefaultRequireFullLicense = true
'@

Write-PolicyFile "internal\nativeinstall\install_policy_allow_trial_windows.go" @'
//go:build windows && allowtrialinstall

// SPDX-License-Identifier: GPL-3.0-only
package nativeinstall

// DefaultRequireFullLicense relaxes the launcher's Full-only policy for builds
// made with -tags allowtrialinstall. The package must still have a valid,
// device-bound content key returned by Microsoft.
const DefaultRequireFullLicense = false
'@

Write-PolicyFile "internal\nativeinstall\install_policy_default_windows_test.go" @'
//go:build windows && !allowtrialinstall

package nativeinstall

import "testing"

func TestDefaultInstallPolicyRequiresFullLicense(t *testing.T) {
	if !DefaultRequireFullLicense {
		t.Fatal("official build unexpectedly permits trial installation")
	}
}
'@

Write-PolicyFile "internal\nativeinstall\install_policy_allow_trial_windows_test.go" @'
//go:build windows && allowtrialinstall

package nativeinstall

import "testing"

func TestAllowTrialInstallBuildPolicy(t *testing.T) {
	if DefaultRequireFullLicense {
		t.Fatal("allowtrialinstall build still requires a Full license")
	}
}
'@

Update-ExactlyOnce `
    -RelativePath "internal\mcservice\installer.go" `
    -Before 'func InstallExtractMsixvc(ctx context.Context, name string, folderName string, isPreview bool) string {' `
    -After 'func installExtractMsixvcNative(ctx context.Context, name string, folderName string, isPreview bool) string {'

$modPath = Join-Path $RepoRoot "go.mod"
$modText = [IO.File]::ReadAllText($modPath)
$winioMatch = [regex]::Match($modText, '(?m)^\s*(?:require\s+)?github\.com/Microsoft/go-winio\s+(\S+)')
if ($winioMatch.Success -and $winioMatch.Groups[1].Value -ne "v0.6.2") {
    throw "Upstream already requires a different go-winio version; review before building."
}
if (-not $winioMatch.Success) {
    [IO.File]::WriteAllText($modPath, $modText.TrimEnd() + "`n`nrequire github.com/Microsoft/go-winio v0.6.2`n", $utf8)
}
$sumPath = Join-Path $RepoRoot "go.sum"
$sumText = [IO.File]::ReadAllText($sumPath)
foreach ($line in @(
    "github.com/Microsoft/go-winio v0.6.2 h1:F2VQgta7ecxGYO8k3ZZz3RS8fVIXVxONVUPlNERoyfY=",
    "github.com/Microsoft/go-winio v0.6.2/go.mod h1:yd8OoFMLzJbo9gZq8j5qaps8bJ9aShtEA8Ipt1oGCvU="
)) {
    if (-not $sumText.Contains($line)) { $sumText = $sumText.TrimEnd() + "`n" + $line + "`n" }
}
[IO.File]::WriteAllText($sumPath, $sumText, $utf8)

# Copy only reviewed additions. Never overwrite an upstream file with different
# contents: a future upstream collision must fail closed for a fresh review.
foreach ($source in Get-ChildItem $OverlayRoot -Recurse -File) {
    $relative = $source.FullName.Substring($OverlayRoot.Length).TrimStart([char[]]"\/")
    $target = Join-Path $RepoRoot $relative
    if (Test-Path $target) {
        if (-not (Test-Path $target -PathType Leaf) -or
            (Get-FileHash $source.FullName -Algorithm SHA256).Hash -ne (Get-FileHash $target -Algorithm SHA256).Hash) {
            throw "Reviewed overlay would overwrite different upstream content: $relative"
        }
        Write-Host "Already copied: $relative"
    } else {
        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
        Copy-Item -LiteralPath $source.FullName -Destination $target
        Write-Host "Copied: $relative"
    }
}

$noticePath = Join-Path $RepoRoot "THIRD_PARTY_NOTICES"
$notices = [IO.File]::ReadAllText($noticePath)
$noticeMarker = "== Restored legacy Preview extractor (LeviVanced custom build) =="
if (-not $notices.Contains($noticeMarker)) {
    $legacyNotice = [IO.File]::ReadAllText((Join-Path $RepoRoot "internal\legacyextractor\NOTICE.txt"))
    [IO.File]::WriteAllText($noticePath, $notices.TrimEnd() + "`n`n$noticeMarker`n`n$legacyNotice", $utf8)
}

Write-Host "Custom policy and legacy Preview extractor patch applied successfully." -ForegroundColor Green

