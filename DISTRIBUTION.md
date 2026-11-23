# Distribution

The default local build is ad hoc signed. Keep the native libraries in `Contents/Frameworks` when moving the app. Model files belong in the per-user application data folder.

## Development signing and recording grants

macOS uses a designated code requirement to match recording permissions to a signed app. With ad hoc signing that requirement can contain the individual build's code hash. The bundle identifier stays `local.caption.macos`, so System Settings can show LocalCaption as enabled even when the recorded requirement belongs to an older build.

When you have an Apple Development certificate, set `LOCALCAPTION_SIGN_IDENTITY` to the same certificate or compatible signing identity for Debug and Release builds. Keep the installed app at a consistent location. You can inspect the signed requirement and bundle path using `codesign -dv -r- dist/LocalCaption.app`. A transition from ad hoc signing to a certificate, or to an incompatible signing identity, can require granting access to the new build and relaunching. [Apple code requirements](https://developer.apple.com/documentation/security/applying-code-requirements) · [Apple distribution signing](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac)

For workspace testing, launch `dist/LocalCaption.app` directly. Older copies in `.deps`, builds opened from Xcode, and a second installation in `/Applications` can have distinct signatures behind the same displayed name.

If macOS asks for access again:

1. Quit any open LocalCaption copies. Open `dist/LocalCaption.app`, select **Automatic** in **Settings → Audio**, and start a session. Approve **System Audio Recording Only** if macOS prompts for it.
2. If an old entry prevents the grant from applying, open **System Settings → Privacy & Security → Screen & System Audio Recording**. In the **System Audio Recording Only** list, select the stale LocalCaption entry, remove it with **–**, then use **+** to add the exact `dist/LocalCaption.app`. Use **⌘⇧G** in the file picker to navigate to its containing folder. For the ScreenCaptureKit display-discovery mode, apply the same steps in the **Screen & System Audio Recording** list.
3. Follow any **Quit & Reopen** prompt and start another session in the same application bundle. [Apple recording settings](https://support.apple.com/guide/mac-help/mchld6aa7d23/mac)

## Disk image

To create a local disk image from a built app:

```sh
hdiutil create -volname LocalCaption -srcfolder dist/LocalCaption.app \
  -format UDZO dist/LocalCaption.dmg
```

For public distribution, build with a Developer ID Application identity and hardened runtime:

```sh
LOCALCAPTION_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./Scripts/build-app.sh
hdiutil create -volname LocalCaption -srcfolder dist/LocalCaption.app \
  -format UDZO dist/LocalCaption.dmg
codesign --sign "Developer ID Application: Your Name (TEAMID)" --timestamp dist/LocalCaption.dmg
xcrun notarytool submit dist/LocalCaption.dmg --keychain-profile YOUR_PROFILE --wait
xcrun stapler staple dist/LocalCaption.dmg
```

Developer ID signing and notarization require the full Xcode tools and a configured Apple developer account. The scripts apply the audio-input entitlement and verify nested code signatures.

## Preparing the optional NLLB model

The operator who prepares the model needs Python 3.13 on Apple Silicon, internet access for the initial dependency and checkpoint downloads, and disk space for the 2.46 GB source checkpoint and 651 MB conversion. An end user can install the prepared folder from **Settings → Models → NLLB-200 Distilled 600M → Install from Folder…**. LocalCaption validates each file against the app's pinned SHA-256 manifest and copies the validated folder to `~/Library/Application Support/LocalCaption/Models/nllb-200-600m/`.

```sh
python3.13 -m venv .deps/nllb-convert
.deps/nllb-convert/bin/python -m pip install \
  ctranslate2==4.6.3 torch==2.9.1 transformers==4.57.6 \
  tokenizers==0.22.2 sentencepiece==0.2.1 huggingface-hub==0.36.2 \
  safetensors==0.8.0 numpy==2.5.5
.deps/nllb-convert/bin/python Scripts/prepare-nllb.py \
  .deps/nllb-source .deps/LocalCaption-NLLB-200-600M --download
```

The preparation script checks Meta's safetensors checkpoint and tokenizer files before loading them. It runs the conversion offline and checks the output against the release manifest. You can omit `--download` if you already have the verified source files. The app links the CTranslate2 C++ runtime and uses the SentencePiece tokenizer with the model's source prefix, EOS, and forced target language token. The runtime needs only the installed assets. [CTranslate2 Transformers conversion](https://opennmt.net/CTranslate2/guides/transformers.html)

The app package includes the MIT-licensed CTranslate2 library. NLLB weights and tokenizer assets remain separate. Follow Meta's CC BY-NC 4.0 terms for preparation, use, or sharing. [Model license and attribution](MODEL-LICENSES.md)
