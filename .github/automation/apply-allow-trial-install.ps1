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

# Upstream v1.0.7 intentionally switched to npmmirror but retained the old
# Tencent success fixture. Repair only that reviewed fixture, never the
# production allowlist, and leave older/already-fixed upstream tests alone.
$lipSourcePath = Join-Path $RepoRoot "internal\lip\install.go"
$lipTestPath = Join-Path $RepoRoot "internal\lip\install_test.go"
$lipSource = [IO.File]::ReadAllText($lipSourcePath)
$lipTests = [IO.File]::ReadAllText($lipTestPath)
$npmmirrorHost = '(?m)^\s*lipMirrorTarballHost\s*=\s*"registry\.npmmirror\.com"\s*$'
if ([regex]::IsMatch($lipSource, $npmmirrorHost) -and
    $lipTests.Contains('name: "tencent mirror source",') -and
    $lipTests.Contains('expectedTarball: "https://mirrors.cloud.tencent.com/npm/@levimc/lip/-/')) {
    $oldMirrorFixture = @'
			name: "tencent mirror source",
			source: lipPackageSource{
				MetadataURL:       lipMirrorMetadataAPI,
				TarballHost:       lipMirrorTarballHost,
				TarballPathPrefix: lipMirrorTarballPathPrefix,
			},
			expectedTarball: "https://mirrors.cloud.tencent.com/npm/@levimc/lip/-/lip-0.34.4.tgz",
'@.TrimEnd()
    $newMirrorFixture = $oldMirrorFixture.Replace('"tencent mirror source"', '"npmmirror mirror source"').Replace(
        'https://mirrors.cloud.tencent.com/npm/@levimc/lip/-/lip-0.34.4.tgz',
        'https://registry.npmmirror.com/@levimc/lip/-/lip-0.34.4.tgz'
    )
    Update-ExactlyOnce -RelativePath "internal\lip\install_test.go" -Before $oldMirrorFixture -After $newMirrorFixture
} else {
    Write-Host "LIP mirror fixture compatibility correction is not needed."
}

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
[IO.File]::WriteAllText($configPath, $configText, $utf8)
Write-Host "Set build/config.yml beta to $betaValue."

$releaseAPIFunction = @'
func getReleaseAPIURLs() []string {
	api := "https://api.github.com/repos/" + updateRepository + "/releases"
	return []string{
		api,
		"https://cdn.gh-proxy.org/" + api,
		"https://edgeone.gh-proxy.org/" + api,
		"https://gh-proxy.org/" + api,
		"https://hk.gh-proxy.org/" + api,
		"https://ghproxy.vip/" + api,
	}
}
'@.TrimEnd().Replace("`n", [Environment]::NewLine)
$oldReleaseAPIFunction = @'
func getReleaseAPIURLs() []string {
	return []string{
		"https://api.github.com/repos/LiteLDev/LeviLauncher/releases",
		"https://cdn.gh-proxy.org/https://api.github.com/repos/LiteLDev/LeviLauncher/releases",
		"https://edgeone.gh-proxy.org/https://api.github.com/repos/LiteLDev/LeviLauncher/releases",
		"https://gh-proxy.org/https://api.github.com/repos/LiteLDev/LeviLauncher/releases",
		"https://hk.gh-proxy.org/https://api.github.com/repos/LiteLDev/LeviLauncher/releases",
		"https://ghproxy.vip/https://api.github.com/repos/LiteLDev/LeviLauncher/releases",
	}
}
'@.TrimEnd().Replace("`n", [Environment]::NewLine)
Update-ExactlyOnce -RelativePath "internal\update\update.go" -Before $oldReleaseAPIFunction -After $releaseAPIFunction

$assetFields = @'
Size               int64  `json:"size"`
	Digest             string `json:"digest"`
'@.TrimEnd().Replace("`n", [Environment]::NewLine)
Update-ExactlyOnce `
    -RelativePath "internal\update\update.go" `
    -Before 'Size               int64  `json:"size"`' `
    -After $assetFields

$oldUpdateCandidates = @'
func buildSelfUpdateCandidateURLs(ver string) []string {
	return []string{
		"https://goproxy.io/github.com/dreamguxiang/!levi!launcher/@v/" + ver + ".zip",
		"https://mirrors.aliyun.com/goproxy/github.com/dreamguxiang/levilauncher/@v/" + ver + ".zip",
	}
}
'@.TrimEnd().Replace("`n", [Environment]::NewLine)
$newUpdateCandidates = @'
func buildSelfUpdateCandidateURLs(release githubRelease, ver string) ([]string, string, error) {
	if useReleaseUpdateAsset {
		asset := findAssetByName(release, expectedZipAssetName())
		if asset == nil || strings.TrimSpace(asset.BrowserDownloadURL) == "" {
			return nil, "", fmt.Errorf("release is missing %s", expectedZipAssetName())
		}
		digest := strings.TrimSpace(asset.Digest)
		if !strings.HasPrefix(strings.ToLower(digest), "sha256:") {
			return nil, "", fmt.Errorf("release asset has no SHA-256 digest")
		}
		hash, err := parseSHA256Checksum(strings.TrimSpace(digest[len("sha256:"):]))
		if err != nil {
			return nil, "", fmt.Errorf("invalid release asset digest: %w", err)
		}
		return buildAssetCandidateURLs(asset.BrowserDownloadURL), hash, nil
	}
	return []string{
		"https://goproxy.io/github.com/dreamguxiang/!levi!launcher/@v/" + ver + ".zip",
		"https://mirrors.aliyun.com/goproxy/github.com/dreamguxiang/levilauncher/@v/" + ver + ".zip",
	}, "", nil
}
'@.TrimEnd().Replace("`n", [Environment]::NewLine)
Update-ExactlyOnce -RelativePath "internal\update\update.go" -Before $oldUpdateCandidates -After $newUpdateCandidates

$oldDownloadBlock = @'
	if fi, statErr := os.Stat(zipPath); statErr == nil && fi.Size() > 0 {
		application.Get().Event.Emit(EventAppUpdateStatus, "downloaded")
		application.Get().Event.Emit(EventAppUpdateProgress, AppUpdateProgress{Phase: "download", Downloaded: fi.Size(), Total: fi.Size()})
	} else {
		if err := downloadUpdateAsset(ctx, buildSelfUpdateCandidateURLs(ver), zipPath); err != nil {
			return emitUpdateError("ERR_UPDATE_DOWNLOAD_FAILED", err)
		}
	}
'@.TrimEnd().Replace("`n", [Environment]::NewLine)
$newDownloadBlock = @'
	updateURLs, expectedHash, err := buildSelfUpdateCandidateURLs(release, ver)
	if err != nil {
		return emitUpdateError("ERR_UPDATE_RELEASE_UNAVAILABLE", err)
	}
	cacheValid := false
	if fi, statErr := os.Stat(zipPath); statErr == nil && fi.Size() > 0 {
		cacheValid = expectedHash == "" || verifyFileSHA256(zipPath, expectedHash) == nil
		if cacheValid {
			application.Get().Event.Emit(EventAppUpdateStatus, "downloaded")
			application.Get().Event.Emit(EventAppUpdateProgress, AppUpdateProgress{Phase: "download", Downloaded: fi.Size(), Total: fi.Size()})
		} else {
			_ = os.Remove(zipPath)
		}
	}
	if !cacheValid {
		if err := downloadUpdateAsset(ctx, updateURLs, zipPath); err != nil {
			return emitUpdateError("ERR_UPDATE_DOWNLOAD_FAILED", err)
		}
		if expectedHash != "" {
			if err := verifyFileSHA256(zipPath, expectedHash); err != nil {
				_ = os.Remove(zipPath)
				return emitUpdateError("ERR_UPDATE_DOWNLOAD_FAILED", err)
			}
		}
	}
'@.TrimEnd().Replace("`n", [Environment]::NewLine)
Update-ExactlyOnce -RelativePath "internal\update\update.go" -Before $oldDownloadBlock -After $newDownloadBlock

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

Write-PolicyFile "internal\update\source_default.go" @'
//go:build !allowtrialinstall

package update

const (
	updateRepository     = "LiteLDev/LeviLauncher"
	useReleaseUpdateAsset = false
)
'@

Write-PolicyFile "internal\update\source_allow_trial.go" @'
//go:build allowtrialinstall

package update

const (
	updateRepository     = "IncrediblePie/LeviVanced"
	useReleaseUpdateAsset = true
)
'@

Write-PolicyFile "internal\update\source_default_test.go" @'
//go:build !allowtrialinstall

package update

import "testing"

func TestDefaultUpdateSource(t *testing.T) {
	if updateRepository != "LiteLDev/LeviLauncher" || useReleaseUpdateAsset {
		t.Fatal("official build update source changed unexpectedly")
	}
	urls, hash, err := buildSelfUpdateCandidateURLs(githubRelease{}, "v1.2.3")
	if err != nil || hash != "" || len(urls) != 2 {
		t.Fatalf("unexpected official update candidates: urls=%v hash=%q err=%v", urls, hash, err)
	}
}
'@

Write-PolicyFile "internal\update\source_allow_trial_test.go" @'
//go:build allowtrialinstall

package update

import (
	"strings"
	"testing"
)

func TestAllowTrialUpdateSource(t *testing.T) {
	if updateRepository != "IncrediblePie/LeviVanced" || !useReleaseUpdateAsset {
		t.Fatal("allowtrialinstall build is not using the fork release source")
	}
	digest := strings.Repeat("a", 64)
	target := "https://github.com/IncrediblePie/LeviVanced/releases/download/v1.2.3/LeviLauncher_windows_amd64.zip"
	release := githubRelease{Assets: []githubReleaseAsset{{
		Name: expectedZipAssetName(), BrowserDownloadURL: target, Digest: "sha256:" + digest,
	}}}
	urls, hash, err := buildSelfUpdateCandidateURLs(release, "v1.2.3")
	if err != nil || hash != digest {
		t.Fatalf("unexpected custom update candidate: hash=%q err=%v", hash, err)
	}
	found := false
	for _, candidate := range urls {
		found = found || candidate == target
	}
	if !found {
		t.Fatalf("fork release URL missing from candidates: %v", urls)
	}
	if _, _, err := buildSelfUpdateCandidateURLs(githubRelease{}, "v1.2.3"); err == nil {
		t.Fatal("custom updater accepted a release without its update ZIP")
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
