# LocalCaption

LocalCaption is a native Apple Silicon macOS app for live transcription of app playback and microphone speech. It presents each audio source in its own lane, saves finalized captions in SQLite, and can translate English and Russian in either direction. A floating subtitles panel can follow either lane.

## Install and update

Download `LocalCaption.dmg` from GitHub Releases, open it, and drag LocalCaption into **Applications**. Eject the disk image and launch the installed copy. For the first install from an existing pre-Sparkle build, quit LocalCaption and replace the app in Applications. Your settings, transcripts, and models are stored separately.

Choose **LocalCaption → Check for Updates…** or open **Settings → General → Application Updates** to check for a signed update. The same section shows the version, build, last check, and optional daily automatic checks. Sparkle asks before installing. If a session is running, finish the session and use **View Update…** to install. Capture and inference work offline. [GitHub Releases](https://github.com/VladKir96/speech_transcription/releases) · [Signing and troubleshooting](RELEASE.md)

## Requirements

- Apple Silicon Mac with macOS 14 or later.
- Xcode 16 or later, or compatible Apple Command Line Tools with Swift 6, for building.
- CMake 3.20 or later. The bootstrap script can download a pinned portable CMake.
- About 1.5 GB for both Whisper Q8 models, Silero 6.3, and both MarianMT directions. Optional NLLB-200 installation uses another 651 MB.

The app uses SwiftUI, ScreenCaptureKit, Core Audio, Accelerate, Metal, and the system SQLite library. It bundles whisper.cpp, SentencePiece, ONNX Runtime, and CTranslate2 for arm64. The finished app runs without Python, Docker, a package manager, or a server. See [model and runtime licenses](MODEL-LICENSES.md).

## Build and launch

```sh
./Scripts/bootstrap.sh
./Scripts/build-app.sh
open dist/LocalCaption.app
```

Bootstrap verifies pinned dependency archives and uses the macOS 14 deployment target. Once the archives are cached, later builds can run offline. The packaging script creates and verifies an ad hoc signed application bundle. Open `Package.swift` in Xcode after bootstrapping to browse and build the Swift package. Use the packaged app for recording permissions.

On Command Line Tools with the macOS 27 SDK and no SwiftUI macro plugin, the scripts select the installed macOS 26 SDK. Set `SDKROOT` to select another suitable SDK. Builds in a sandbox that already prevents subprocess sandboxing can set `LOCALCAPTION_SWIFTPM_NO_SANDBOX=1`.

Release maintainers can run `./Scripts/release.sh 1.5.0 --build-only` to create a signed update ZIP, DMG, appcast, and checksums under `dist/release-candidates/v1.5.0`. This needs the persistent Sparkle signing key. [Release workflow](RELEASE.md)

## First run

1. Open **Settings → Models** and download **Whisper Small (Q8)** or **Whisper Large-v3 Turbo (Q8)**. Small is the default. If you download Turbo only, select it in Models or Recognition.
2. Download **Silero VAD 6.3** in **Settings → Models** for neural speech detection. New capture streams prefer the signed-release 6.3 ONNX model when installed. The existing **Silero VAD 6.2** installation remains available as a fallback. An audio-level detector handles sessions without a usable Silero model.
3. In **Settings → Audio**, enable the desired sources and choose a microphone or **System Default**. For System Audio, **Automatic** uses Core Audio and the **System Audio Recording Only** grant on macOS 14.2 and later. **ScreenCaptureKit** uses the primary display and the **Screen & System Audio Recording** grant. **macOS display picker** lets you select a display through Apple’s sharing UI. Automatic uses ScreenCaptureKit display discovery on macOS 14.0 and 14.1.
4. Open **Live**, choose a profile, and click **Start Session**. Each lane shows capture status and input level. Use **Pause**, **Resume**, and **Stop** from the toolbar.

Model downloads begin after you click **Download**. Canceling discards the incomplete installation. The installer checks file size and SHA-256 before making a model available. Once your models are installed, you can disconnect from the network and start new sessions. LocalCaption creates no raw audio files and sends no audio, transcript, analytics, or inference requests over the network.

## Upgrading Whisper from Q5

Download the Q8 variant for your saved model choice under **Settings → Models**. The next session uses the verified Q8 file. Existing compatibility files are preserved on disk and can still serve as a fallback if a current file is unavailable.

To use an installed Q5 model, finish the session, quit LocalCaption, and launch it from the workspace with the rollback option.

```sh
open -n -a "$PWD/dist/LocalCaption.app" --env LOCALCAPTION_WHISPER_QUANTIZATION=q5
```

Relaunch normally to return to Q8. If the Q5 file was removed, restore the pinned file to its original Models subfolder before using the override. The model choice and saved history remain available with either version. [Artifacts, checksums, and Q5/Q8 comparison](VERIFICATION.md#localcaption-130-whisper-q8_0)

## Microphone control

Use **Mic On** or **Mic Off** in the recording toolbar to change microphone capture during a session. Space toggles the microphone by default when the LocalCaption window is focused and a text field is inactive. Change the key, modifiers, and mode in **Settings → Audio → Microphone control**. You can also choose a different input device during a session.

**Push-to-Talk** starts with the microphone off. Hold the focused shortcut to speak. Releasing the key or leaving the window stops microphone capture and finalizes speech already received. **Use shortcut in other apps** is available in **Toggle** mode with modifiers such as Control + Option + M. macOS can reserve a shortcut for another app. LocalCaption reports a registration conflict and uses the focused shortcut.

## Translation and floating subtitles

Download the corresponding **Marian English → Russian** or **Marian Russian → English** model in Settings. Enable **Translation** in Live and set the target language. Choose **Auto Detect**, **English**, or **Russian** under Recognition. Set both directions up if you routinely change target language.

**Settings → Translation → Translation Engine** defaults to **MarianMT (Fast)**. To use **NLLB-200 (Multilingual)**, open **Settings → Models**, select **Install from Folder…**, and choose the [prepared model folder](DISTRIBUTION.md#preparing-the-optional-nllb-model). Both engines support English ↔ Russian. A change takes effect for subsequently finalized phrases, including during recording. Each queued phrase keeps its engine, and each completed translation is saved with that engine. Use **Retry Translation** on a failed caption to choose the selected engine or explicitly retry with an installed MarianMT model.

Meta's NLLB-200 Distilled 600M checkpoint is licensed under **CC BY-NC 4.0** for noncommercial use. It is distributed separately from LocalCaption. The model card describes it as a research model for general-domain translation. [Meta model card](https://huggingface.co/facebook/nllb-200-distilled-600M) · [CC BY-NC 4.0](https://creativecommons.org/licenses/by-nc/4.0/)

The live panels show recognized text while LocalCaption completes each phrase for translation. In **Settings → Recognition → Speech Segmentation**, **Phrase Completion Pause** ranges from 0.5 to 4.0 seconds. Select **Fast** (0.9 s), **Balanced** (1.8 s), or **Context-Aware** (2.8 s) to set a starting point. Each source assembles its own phrases, and long phrases split at about 15 seconds. Pause and Stop flush speech already captured.

Use **Subtitles** in the toolbar or **⇧⌘L** in LocalCaption to show the floating panel. Set its sources, display mode, font size, opacity, and maximum lines in **Settings → Subtitles**. Drag the header to move it or an edge to resize it.

## Speaker Diarization

Diarization is off by default and applies to System Audio. Download **Pyannote Speaker Segmentation** and **WeSpeaker ResNet34-LM** in **Settings → Models**, then use **Speakers** in the System Audio header. You can turn it on or off during a recording. Existing speaker labels stay on their captions.

**Settings → Speakers** controls the default state, detection mode, speaker count limit, similarity threshold, colors, and subtitle names. **Real-Time** uses rolling windows up to four seconds and updates about once a second. **High Accuracy** uses up to ten seconds and updates about every two seconds. A fixed speaker count caps the number of profiles. The default similarity threshold is 0.55.

Click a speaker name in Live or History to rename it. **Rename Speaker…** is also available from the caption’s context menu. The name applies to all captions for that speaker in the session. TXT and JSON include available speaker data, and SRT offers **Include speaker names**. For a short or uncertain utterance, the app can show **Unknown Speaker**. A Whisper segment that crosses a turn or contains simultaneous speech can show **Mixed Speakers** or **Overlapping Speakers** with its original text intact.

Speaker analysis runs in its own bounded worker with the bundled ONNX Runtime. The database stores speaker labels and caption assignments. Audio windows and embeddings stay in memory for the active session. [Model licenses](MODEL-LICENSES.md) · [Speaker verification and benchmarks](VERIFICATION.md#localcaption-140-speaker-diarization)

## History and export

Finalized captions are saved incrementally. Live and saved transcripts show the newest captions first. While reading earlier captions in Live, choose **Back to Latest** to return to the current speech. **Load earlier captions** pages older text from the database.

**History** supports reopening, searching, renaming, and exporting sessions. **Delete All History** opens a confirmation dialog and removes saved transcripts and translations from the database, excluding the active session. You can also export from Live. **Settings → Storage** shows the data folder and supports automatic export to a selected folder.

TXT, JSON, and SRT use UTF-8. SRT offers original, translated, or combined subtitles. When captions overlap across sources, it splits the timeline into non-overlapping cues containing the active source-labeled text.

JSON export schema version 1 uses the top-level keys `schemaVersion`, `session`, and `segments`. The session contains a UUID, title, UTC ISO-8601 creation and start dates, optional end date, duration in seconds, status, and selected options. Each segment contains UUIDs for the segment and session, `source` (`system` or `microphone`), `start` and `end` in seconds from session start, `original`, `language` (Whisper language code), `finalized`, `createdAt`, and `translationStatus`. The optional `translation` and `translationError` fields are present when available. Time offsets include elapsed pauses.

The default data folder is `~/Library/Application Support/LocalCaption`. Previous commits survive interrupted sessions. If a transcript write fails while recording, LocalCaption pauses capture, shows the failure, and retains affected segments in memory so you can retry saving or export them.

## Implementation

- On macOS 14.2 and later, Automatic uses a native Core Audio process tap that captures playback from other apps. ScreenCaptureKit attaches only an audio output to its display filter. A separate Core Audio HAL unit captures the selected microphone.
- Both sources normalize to 16 kHz mono PCM on a shared monotonic timeline. Each has independent VAD, speech windows, partial captions, and bounded audio queues. A shared Whisper actor serializes native inference. On overload the capture queue reports skipped input, and completed caption batches are saved independently.
- Silero 6.3 uses the existing ONNX Runtime CPU library. Per-source 32 ms windows carry acoustic context and recurrent state through each stream. The capture pipeline retains its 100 ms segmentation cadence and the existing Phrase Completion Pause.
- Whisper Small and Large-v3 Turbo use Q8_0 weights and Metal where available. Low Latency asks for a partial after roughly one second of buffered speech. High Accuracy uses a longer window, a longer pause threshold, and beam search for final results.
- Marian OPUS-MT runs in ONNX Runtime's CPU execution provider. NLLB-200 Distilled 600M runs in CTranslate2 with int8 weights and two CPU threads. Both use SentencePiece. The translation worker loads only the engine needed by the next request and keeps it warm across consecutive requests. SQLite holds up to 64 pending translations per session. When the queue is full or a request exceeds the stop deadline, the original remains saved and the translation can be retried.
- The live UI keeps the latest 240 finalized captions per lane. Earlier captions can be loaded from SQLite. History pages results.

## Tests and performance

```sh
./Scripts/test.sh
LOCALCAPTION_TEST_MODELS="$HOME/Library/Application Support/LocalCaption/Models" ./Scripts/test.sh
LOCALCAPTION_TEST_MODELS="$HOME/Library/Application Support/LocalCaption/Models" \
  LOCALCAPTION_TEST_NLLB="/path/to/LocalCaption-NLLB-200-600M" ./Scripts/test.sh
```

Install both Whisper Q8 models, Silero and Marian models before the second command. It uses actual arm64 inference with English and Russian fixtures. Set `LOCALCAPTION_TEST_Q5` to a directory containing both legacy Whisper files to exercise migration. To verify the Q8 downloads separately, run `LOCALCAPTION_TEST_Q8_DOWNLOAD=1 ./Scripts/test.sh --filter publishedWhisperDownloads`. The Silero download check uses `LOCALCAPTION_TEST_DOWNLOAD=1 ./Scripts/test.sh --filter publishedSileroDownload`. [Benchmark and regression results](VERIFICATION.md)

To use the Silero rollback option, keep the pinned 6.2 file in its original Models subfolder. Finish the current session, quit LocalCaption, and launch it from the workspace.

```sh
open -n -a "$PWD/dist/LocalCaption.app" --env LOCALCAPTION_VAD_VERSION=6.2
```

Relaunch normally to use the preferred installed model again.

## Limitations and troubleshooting

- Protected playback can omit audio from capture. Confirm the playback app is producing audible output. ScreenCaptureKit display discovery also requires an active display.
- When using speakers, room audio can appear in both lanes. Headphones reduce duplication. Multichannel microphone devices use their first input channel.
- A disconnected input automatically retries when the configured device returns while another source keeps the session active. For a stopped system audio stream, use **Pause → Resume** to reconnect.
- If Metal cannot initialize, Whisper can use CPU inference. With sustained backlog, try Low Latency or benchmark the other model on your workload.
- The initial translation catalog supports English and Russian. Whisper may misidentify short or mixed-language phrases. Manually select a source language when it is known.
- macOS checks the signed code identity when applying a recording grant. An entry can display an enabled toggle for a previously signed LocalCaption build. Keep one regular app copy at a stable path, or use the same Apple Development signing identity for successive local builds. See [signing and recording grants](DISTRIBUTION.md).
- To measure capture before transcription, quit LocalCaption and launch the diagnostic from the same bundle:

  ```sh
  open -n -a "$PWD/dist/LocalCaption.app" --args --diagnose-system-audio
  ```

  Choose the capture source, click **Start Capture**, play speech in a browser, and click **Stop**. The window reports the signed build identity, native frame count, normalized frame count, and peak and RMS energy. The capture log is available with `log show --last 10m --info --predicate 'subsystem == "local.caption" AND category == "capture"'`. [Apple Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps) · [Apple recording settings](https://support.apple.com/guide/mac-help/mchld6aa7d23/mac)

See [distribution instructions](DISTRIBUTION.md) for DMG creation, signing, and notarization.
# speech_transcription
