# Automated upstream release mirror

The fork's `Mirror upstream release` workflow checks `LiteLDev/LeviLauncher` every six hours. A scheduled run uses the newest non-draft release only after both upstream Windows assets are present. It exits before allocating a Windows builder if the fork already has that tag with both mirrored asset names.

For each unmirrored release it:

1. mirrors upstream `main` to the fork's dedicated `upstream-main` source-snapshot branch without overwriting LeviVanced's automation branch (upstream workflow files are omitted because GitHub forbids its Actions token from rewriting workflows);
2. checks out the exact upstream release tag in detached mode;
3. applies the reviewed `allowtrialinstall` policy patch and pinned legacy Preview extractor overlay with exact-match/collision guards;
4. builds and tests `LeviLauncher.exe`;
5. packages that exact executable as `LeviLauncher-amd64-installer.exe` using the upstream Inno Setup project and as updater ZIPs for in-app updates (`LeviLauncher.zip` for release v1.1.0+ and the compatibility `LeviLauncher_windows_amd64.zip` for builds installed from earlier LeviVanced releases);
6. copies the upstream release name and changelog;
7. copies the selected upstream release tag only after its assets exist, then publishes a `LeviVanced` release with the same tag and prerelease status; stable releases become the fork's latest release; and
8. uploads the portable and installer assets under the same names used upstream, plus the updater ZIP.

Manual runs accept an optional upstream tag and a force-rebuild switch. Force rebuild replaces all three assets and refreshes release metadata. Rebuilding the same upstream tag does not increase the app version; users already on that version must download/reinstall it manually to obtain a custom-only change.

Builds made with `allowtrialinstall` query `IncrediblePie/LeviVanced` for updates. Preview builds automatically accept mirrored preview updates; stable builds retain the normal stable-only default. On upstream v1.1.0+ the fork only retargets upstream's own updater (API base URL and asset URL) and additionally fails closed: it requires `LeviLauncher.zip` to carry a `sha256:` digest in the release metadata and verifies the downloaded file against it (cached updater files are re-verified), otherwise the update aborts before installation. The `LeviLauncher_windows_amd64.zip` asset is still published only so already-installed v1.0.x LeviVanced builds keep working — new builds use `LeviLauncher.zip`. The installer metadata also points to the fork's Releases page. Ordinary builds without the custom patch continue using the upstream update source unchanged.

The release note identifies the binaries as unsigned custom builds and includes their SHA-256 values. Native Release installation retains Microsoft entitlement responses, device binding, key-wrap authentication, package integrity checks, and KeyID matching. Custom Preview MSIXVC installation uses upstream v0.3.13's closed-source extractor instead; the wrapper verifies the exact DLL hash, preserves current loader preparation, and stages output before committing it. The DLL's internal key and integrity behavior is unaudited. See [legacy Preview extractor](legacy-preview-extractor.md).

GitHub only evaluates scheduled workflows from a repository's default branch. As with all public GitHub repositories, GitHub may disable schedules after a prolonged period without repository activity; a manual workflow run re-enables/checks the mirror immediately.

The encrypted `LEVIVANCED_WORKFLOW_TOKEN` repository secret is used only while copying the exact annotated upstream release tag. GitHub's built-in Actions token cannot introduce commits containing workflow changes. The workflow clears this token before checking out or executing any upstream release code.

## Upstream layout compatibility

Release mirroring is only supported for upstream releases whose source layout matches the patcher's reviewed guards (currently the v1.1.x series). The v1.1.0 series removed `internal/lip` (the LIP mirror test fixture in earlier releases is therefore no longer patched), pinned `go 1.27.3`, made `LeviLauncher.zip` the self-update asset, and removed the old self-update internals this fork used to rewrite. The release patcher now makes exactly two source-level changes to `internal/update/update.go` (the GitHub API base URL and the asset URL), injects a `Digest` field plus fail-closed verification helpers, and otherwise leaves upstream's updater untouched. Any upstream release whose files do not match the expected guards fails closed and stops the build; it is never published.

Three upstream tests (`TestModSearchAndShow`, `TestSharedDetails`, `TestMigration_V11_AccountsDACL`) fail identically in upstream's own CI, which masks them by ignoring the `go test` exit code. The builder skips exactly those three with a documented `-skip` pattern and keeps everything else strict: the complete tagged Go test suite and vet must pass, and every failed command stops the builder before publication.
