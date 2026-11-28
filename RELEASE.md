# Releasing LocalCaption

## Initial setup

Build from an Apple Silicon Mac with macOS 14 or later, Xcode 16 or compatible Swift 6 Command Line Tools, and Python 3.9 or later for the release script. The app bundles its native libraries and Sparkle. A Mac installing the app only needs macOS and the desired downloaded models.

```sh
./Scripts/bootstrap.sh
./Scripts/test.sh
./Scripts/build-app.sh
```

`AppResources/Info.plist` is the source of truth for the marketing version and build number. The release script requires a greater stable version and increments the build. It derives the feed URL from the GitHub origin. The bundled feed is `https://github.com/OWNER/REPO/releases/latest/download/appcast.xml`. Its signed enclosure points to that version’s `LocalCaption.zip` so the feed and download stay paired even when a newer release takes over the latest URL.

### Sparkle signing

Sparkle uses EdDSA to authenticate the feed and update ZIP. Apple code signing identifies the app and its embedded code to macOS. Notarization is Apple’s separate distribution check.

The distribution public key is in `AppResources/Info.plist` under `SUPublicEDKey`. Sparkle’s official tools look up the corresponding private key under the Keychain account `local.caption.macos`. The script compares the public key in Keychain with the app’s pin before building or publishing. Use the same key for each release. [Sparkle signing and publishing](https://sparkle-project.org/documentation/publishing/)

```sh
bash Scripts/bootstrap-sparkle.sh
.deps/sparkle/bin/generate_keys --account local.caption.macos -p
```

On first use, Keychain may ask you to authorize `generate_appcast` and `sign_update` from the pinned Sparkle distribution. Approve the intended tools in the macOS dialog. Enter any Keychain password there.

To initialize a new, independent distribution before shipping its first build, run `generate_keys --account local.caption.macos` and pin the returned public key in its Info.plist. For the existing LocalCaption distribution, import its saved key if your Keychain lacks it.

Back up the key to a file **on an encrypted volume outside the checkout**. Unmount the volume or lock your encrypted backup after use. Limit access to trusted release maintainers. Keep a second secure copy and confirm the recovery procedure while the original Keychain is still available.

```sh
umask 077
.deps/sparkle/bin/generate_keys --account local.caption.macos -x /Volumes/EncryptedBackup/LocalCaption.ed25519
# On a release Mac restoring the existing distribution identity
.deps/sparkle/bin/generate_keys --account local.caption.macos -f /Volumes/EncryptedBackup/LocalCaption.ed25519
.deps/sparkle/bin/generate_keys --account local.caption.macos -p
```

Compare the recovered public key with `SUPublicEDKey` before preparing a release. Keep private keys, certificate exports, passwords, and tokens out of the repository, notes, and release assets. Losing the existing signing key can require users to install a fresh app manually.

### GitHub authentication

Install the GitHub CLI and authenticate once with an account that can push to the public repository.

```sh
gh auth login --hostname github.com
gh auth status --hostname github.com
gh auth setup-git
```

For an SSH origin, configure GitHub SSH authentication as well. The release script checks the authenticated account’s push access and the remote’s default branch. A valid existing login works without another sign-in.

### Personal distribution

The default `--signing personal` applies an ad hoc signature with the existing `local.caption.macos` bundle identifier and audio-input entitlement. It needs the Sparkle private key for update signing. If a consistent local Apple Development signing identity is available, supply its exact name through `LOCALCAPTION_SIGN_IDENTITY`. Use the same profile and identity across a series of updates where possible.

An ad hoc app distributed over the internet can be blocked by Gatekeeper depending on macOS and organizational policy. If macOS offers **Open Anyway**, use it only after verifying the download and trusting its publisher. Developer ID signing and notarization are intended for public installation with Gatekeeper. Do not change system security settings to launch a personal build. [Apple’s guidance on opening downloaded apps](https://support.apple.com/en-us/102445)

An updated ad hoc build may receive a new designated code requirement. macOS can ask for System Audio or Microphone consent again. Grant access to the installed copy in **System Settings → Privacy & Security** and follow any relaunch prompt. The ad hoc update path should be tested on each supported macOS version you intend to distribute to. [Recording permissions](DISTRIBUTION.md#development-signing-and-recording-grants)

### Developer ID distribution

With a paid Apple Developer membership, install a valid **Developer ID Application** certificate and its private key in Keychain. Configure a notarytool Keychain profile using an App Store Connect API key or an Apple ID with an app-specific password. Run the setup interactively so secrets stay out of command history.

```sh
security find-identity -v -p codesigning
xcrun notarytool store-credentials LocalCaption-notary
export LOCALCAPTION_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export LOCALCAPTION_NOTARY_PROFILE=LocalCaption-notary
./Scripts/release.sh 1.5.0 --signing developer-id --build-only
```

The script signs nested code and the app with Hardened Runtime and timestamps. It notarizes a ZIP of the app, staples the app before creating the update ZIP and DMG, then signs, notarizes, staples, and checks the DMG. Keep the bundle ID and signing team consistent. Developer ID credentials are optional for development and personal builds. [Apple distribution signing](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac) · [Apple notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

## Build, verify, and publish

```sh
./Scripts/release.sh 1.5.0 --build-only
```

Build-only mode stages the requested version and next build in the app bundle without committing or changing the source plist. It permits work in progress, validates local tags, and produces `LocalCaption.app`, `LocalCaption.dmg`, `LocalCaption.zip`, `appcast.xml`, `SHA256SUMS`, and the notes under `dist/release-candidates/v1.5.0`. The script tests the app, mounts and checks the DMG, unpacks the update ZIP, checks native dependencies and Apple signatures, and verifies both Sparkle signatures. The pinned dependencies and build recipe make the release reproducible with the same toolchain. Artifact timestamps and code signing can change the checksums across builds.

Review the notes under `ReleaseNotes/<version>.md`, or supply `--notes path/to/notes.md`. The fallback uses user-facing conventional commit subjects beginning with `feat:`, `fix:`, or `perf:`. Review generated notes before publishing. Sparkle embeds the same Markdown used on GitHub.

Install the candidate from its DMG on a test Mac. Before publication, also exercise an in-place update from an older Sparkle-enabled build under the intended signing profile. Use a separate bundle ID, key, and data directory for isolated testing. Check the version and build after relaunch, transcript history, model installations, audio permissions, and the behavior when an update arrives during a session. Test a broken download and rejection of a modified ZIP.

After authorization to publish, commit the release implementation and notes and start from a clean checkout of the default branch. GitHub must accept pushes from the release account on that branch.

```sh
./Scripts/release.sh 1.5.0 --publish
```

Use `--signing developer-id` with the environment above to publish notarized artifacts. Publication builds from the clean source and saves artifacts under `dist/releases/v1.5.0`. The script commits the two version fields, tags the release commit, and pushes the branch and tag atomically. It creates a draft, uploads the four release assets, downloads and verifies them against the local bytes, then publishes as Latest. It confirms unauthenticated HTTPS access to the latest appcast and versioned ZIP before printing the release URL. Older releases keep their original assets and URLs.

### Resume and manual publication

If the upload or public download verification fails, retain `dist/releases/v1.5.0` and retry with the saved assets.

```sh
./Scripts/release.sh 1.5.0 --publish --resume
```

An already uploaded matching asset is reused. If a draft has an incomplete or changed asset, inspect the error and remove only that asset from the draft in GitHub before retrying. Keep the release tag and the release version commit intact. The resume command can verify a release already published by a previous attempt.

For a manual publication, use the verified `dist/releases/v1.5.0` assets from the release workflow and confirm the version commit and tag are present on GitHub. Use a draft and the Markdown file alongside the artifacts.

```sh
gh release create v1.5.0 --verify-tag --draft --title "LocalCaption v1.5.0" \
  --notes-file dist/releases/v1.5.0/LocalCaption.md
gh release upload v1.5.0 dist/releases/v1.5.0/{LocalCaption.dmg,LocalCaption.zip,appcast.xml,SHA256SUMS}
verified_dir="$(mktemp -d)"
gh release download v1.5.0 --dir "$verified_dir" \
  --pattern LocalCaption.dmg --pattern LocalCaption.zip --pattern appcast.xml --pattern SHA256SUMS
cmp dist/releases/v1.5.0/SHA256SUMS "$verified_dir/SHA256SUMS"
(cd "$verified_dir" && shasum -a 256 -c SHA256SUMS)
```

After each verified download matches, publish the draft with `gh release edit v1.5.0 --verify-tag --draft=false --latest`. Run the resume command above to confirm the public downloads. Use a new version to replace a bad published release. Editing a signed appcast requires generating and signing it again.

## Installation and update troubleshooting

1. On the release page, download `LocalCaption.dmg` and `SHA256SUMS`. Run `shasum -a 256 LocalCaption.dmg` and compare the result with the DMG line in the checksum file.
2. Open the DMG, drag LocalCaption to Applications, eject the image, and launch from Applications. For a build that predates Sparkle, quit it and replace the bundle on the first install.
3. Check the installed build in **About LocalCaption** or **Settings → General → Application Updates**.
4. Use **LocalCaption → Check for Updates…** to check immediately. Automatic checks are off by default and run about daily when enabled. Sparkle asks for approval before installing.
5. If a session is running, click **Stop** and let LocalCaption finish saving the transcript. Resolve any save error before clicking **View Update…**. If a transfer fails, check connectivity and try again. If Sparkle rejects a signature, get a fresh copy only from the trusted release page and report the failure.
6. For update errors, use Console to inspect Sparkle messages and confirm the installed copy can be updated at its location. For a missing feed, confirm GitHub has a published Latest release with all four assets. LocalCaption’s speech pipeline runs offline.

Settings are in the app’s macOS preferences domain. The SQLite library and **Models** folder remain under `~/Library/Application Support/LocalCaption`. This keeps Whisper, Silero, MarianMT, NLLB, and speaker models available across app replacements. The installer and Sparkle replace the app bundle only.
