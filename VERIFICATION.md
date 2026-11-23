# Verification

## LocalCaption 1.2.0 offline translation engines

The arm64 build uses the official CTranslate2 4.6.3 CPU dylib for NLLB-200 Distilled 600M and the existing ONNX Runtime backend for MarianMT. The native wrapper uses SentencePiece and forces the requested NLLB target token. The prepared folder was reproduced from the pinned Meta safetensors revision and matched all eight release checksums. Its installed file size is 650,705,113 bytes. [Meta model card](https://huggingface.co/facebook/nllb-200-distilled-600M) · [CTranslate2 Transformers conversion](https://opennmt.net/CTranslate2/guides/transformers.html)

### Offline checks

- The packaged app, native benchmark, and automated suite each ran with networking denied. The app rejected an unrelated folder, then imported the verified NLLB folder through Settings and reported it installed.
- During one packaged recording, a paced English fixture produced an NLLB translation from both System Audio and the built-in microphone. Switching to MarianMT during that same recording routed subsequent archival speech on System Audio to MarianMT. The database kept both engine identifiers in that session. A second System Audio session translated a paced Russian fixture to English with NLLB.
- A draft row could remain visibly pending in Live after SQLite saved its translation. The final build uses separate view identities for drafts and finalized rows. The signed QA variant displayed the finished translation while the session was still recording.
- The QA database migrated from schema 1 to 2 with all 19 existing caption rows intact. New rows recorded the engine and, for NLLB, the checkpoint and conversion version. The automated tests checked JSON metadata, TXT and SRT text, preference restoration, corruption and reimport, explicit retry with MarianMT, removal, queue saturation, and stale completion. The suite reported 52 tests with an optional model download skipped.
- During window selection, an earlier QA copy reopened against the regular library. The import, recording, and provenance checks used the isolated QA library. A distinct QA bundle identifier allowed the final rendering check to target that library reliably.

### Comparison with identical inputs

| Input | MarianMT | NLLB-200 |
| --- | --- | --- |
| Hello, how are you doing today? | Привет, как дела? | Привет, как дела сегодня? |
| We need to optimize the inference pipeline to reduce latency. | Нам нужно оптимизировать трубопровод для того, чтобы уменьшить запоздание. | Нам нужно оптимизировать трубопровод выводов, чтобы уменьшить задержку. |
| Although the current implementation works correctly, we should consider improving its performance before deploying it. | Хотя нынешнее осуществление работает правильно, мы должны рассмотреть вопрос об улучшении его работы до его развертывания. | Хотя текущая реализация работает правильно, мы должны рассмотреть возможность улучшения ее эффективности до ее внедрения. |
| I think we should discuss this tomorrow. | Думаю, мы должны обсудить это завтра. | Думаю, мы должны обсудить это завтра. |
| Давайте обсудим архитектуру системы и возможные способы оптимизации. | Let's discuss the architecture of the system and possible ways to optimize it. | Let's talk about the system architecture and the possible ways to optimize it. |

NLLB preserved “today” and used the more natural «задержку». Its rendering of “inference pipeline” was literal. MarianMT used the more direct “discuss” in the Russian-to-English example. Both gave the same translation for the completed phrase assembled from the slow-speech fragments.

### Performance on this Mac

Measured on an Apple M5 Pro with 48 GiB memory and macOS 27.2.1. The native NLLB test used int8 CPU execution with two threads and one concurrent inference. It measured a 0.210 s first load, 0.352 s mean over 25 warm translations, 0.180 s for the short conversational sample, and about 0.54 s for the longest sample. Thirty translations plus load and shutdown took 11.82 s. Peak RSS was 1.26 GB, and average process CPU use was about 184% of one core. MarianMT warm calls in the same five-input comparison suite ranged from 0.055 to 0.138 s. These measurements describe the test Mac. Live throughput can vary with hardware, phrase length, and simultaneous recognition.

NLLB accepts up to 256 input tokens and generates up to 256 output tokens with greedy decoding. Its 15-second inference deadline and cancellation take effect at decoder token boundaries. Model loading and encoder execution run before those callbacks. Live hardware testing covered the M5 Pro and built-in microphone.

Files changed for this release

- `Native/NLLB.cpp`, `Native/CMakeLists.txt`, `Sources/CInference/inference.h`, and the build scripts add the standalone CTranslate2 runtime and native bridge.
- `Scripts/prepare-nllb.py`, `Sources/CaptionCore/Resources/Models.json`, and `ModelStore.swift` prepare, verify, and import the optional assets.
- `Sources/CaptionCore/Inference.swift`, `Domain.swift`, `Repository.swift`, and `TranslationQueue.swift` route requests, preserve provenance, and update the existing database.
- `Sources/LocalCaption/AppModel.swift`, `PreferencesView.swift`, `TranscriptView.swift`, and `HistoryView.swift` add selection, installation, live status, and retry.
- `Tests/CaptionCoreTests/TranslationEngineTests.swift`, `Tests/LocalCaptionTests/SessionStartupTests.swift`, `AppResources/Info.plist`, `README.md`, `DISTRIBUTION.md`, and `MODEL-LICENSES.md` cover the new release and its offline workflow.

## LocalCaption 1.1.0 history, microphone control, and phrase segmentation

The arm64 release built and passed strict signature verification on macOS 27.2.1. The packaged QA copy had the same executable and designated requirement as `dist/LocalCaption.app`. Live checks used an isolated database and cached local models.

| Check | Result |
| --- | --- |
| History confirmation and active-session exclusion | Cancel preserved both seeded sessions. Confirming during recording removed both sessions and their 277 associated captions and translations. The active session continued. SQLite reported no orphaned rows. The deleted sessions stayed gone after restart. An empty database showed a disabled Delete All History button. |
| Transcript ordering and scrolling | Saved captions 275, 274, and 273 appeared in descending order with their translations. In the live System Audio lane, new partials appeared above finalized rows. Scrolling to older text held the visible position during continued playback. Back to Latest returned to the newest partial. |
| Native microphone control | The toolbar and Space stopped and restarted the built-in microphone during playback. Space entered the focused History search field while the microphone stayed off. Holding Space in Push-to-Talk started the native input, and the toolbar showed Off after release. Muting survived Pause and Resume. |
| System Audio playback | The packaged app captured and translated the archival Kennedy clip with the microphone off. The System Audio tap stayed active during microphone toggles. |
| Configurable phrase completion and local translation | Balanced displayed 1.8 s, Context-Aware selected 2.8 s, and a custom 3.0 s reached the active session. Two synthetic speech fixtures played through Core Audio produced a single translated row per paused sentence in English → Russian and Russian → English. |

The offline test run reported 48 tests with the optional Silero network download skipped. It covers transactional deletion and restart, timestamp tie-breaking, old settings and new settings round-trips, microphone device switching and repeated toggles, recognition and translation for both languages, pause boundaries from 0.5 to 3 seconds, lengthy retained phrases, and Stop flushing. Live testing used the built-in microphone. Global Toggle registered in Settings, while physical key delivery with another app focused was unverified. Push-to-Talk uses AppKit events from the focused LocalCaption window. [Apple AppKit local event monitor](https://developer.apple.com/documentation/appkit/nsevent/addlocalmonitorforevents%28matching%3Ahandler%3A%29)

Files changed for this release

- `Sources/CaptionCore/Domain.swift`, `PhraseAggregation.swift`, `Repository.swift`, and `Streaming.swift` handle phrase settings, recognition boundaries, and database operations.
- `Sources/LocalCaption/AppModel.swift`, `MicrophoneShortcut.swift`, `LocalCaptionApp.swift`, `PreferencesView.swift`, and `WorkspaceView.swift` handle the microphone lifecycle, shortcut registration, and UI controls.
- `Sources/LocalCaption/HistoryView.swift`, `TranscriptView.swift`, and `SubtitleWindow.swift` update transcript order and history.
- `Tests/CaptionCoreTests/CoreTests.swift`, `InferenceTests.swift`, `PhraseTests.swift`, and `Tests/LocalCaptionTests/SessionStartupTests.swift` cover the new behavior. `AppResources/Info.plist`, `README.md`, and this report describe the release and usage.

## LocalCaption 1.0.2 system audio capture

The failing retry at 15:39:38 on November 23, 2026 ran version 1.0.1, build 2, from `.deps/system-audio-check/LocalCaption.app/Contents/MacOS/LocalCaption` (PID 2208). macOS 27.2.1 rejected its ad hoc code requirement for `kTCCServiceScreenCapture`. The running CDHash was `3ecd65d55e5842c8907d3c6623195925c8383f37`; the recorded screen grant required `29cd9c9a76331498c14e9f3673920b7c782c9747`. The then-current `dist` bundle also had a different hash, `28d0aa69f05df49096fce1ec4bb1decd474911fb`. The first failing API was `SCShareableContent.current`. It returned `com.apple.ScreenCaptureKit.SCStreamErrorDomain` code `-3801` (`userDeclined`) before the app reached filter creation, audio output registration, or `SCStream.startCapture()`.

The tested arm64 release was version 1.0.2, build 3, at `dist/LocalCaption.app`. Its bundle and signing identifier were both `local.caption.macos`, with no signing team and CDHash `398364fb0f1b338e4174f1602d7eed66d307bd9a`. Strict signature verification passed. macOS initially found that the separate `kTCCServiceAudioCapture` requirement also referred to an earlier hash (`51bdce4f`). After the macOS prompt was approved, the log showed the new hash matched and reported `Allowed (User Consent)` for audio capture. The screen capture requirement continued to mismatch in the same log. No privacy entries were reset or edited by the app. [Apple recording settings](https://support.apple.com/guide/mac-help/mchld6aa7d23/mac) · [Apple code requirements](https://developer.apple.com/documentation/security/applying-code-requirements)

Automatic now uses a Core Audio process tap on macOS 14.2 and later. The diagnostic loads just the selected capture backend and PCM conversion. The tap delivered native 48 kHz stereo audio, and the shared converter delivered 16 kHz mono PCM. The ScreenCaptureKit route and macOS display picker remain available. ScreenCaptureKit uses a display filter, sets `capturesAudio` and `excludesCurrentProcessAudio`, adds an `.audio` output, and retains the output and stream delegate through shutdown. [Apple Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)

| Live test on the packaged app | Result |
| --- | --- |
| Audio-only capture diagnostic with archival speech played by a separate process | 12,160 buffers, 6,225,920 native frames, 2,075,306 normalized frames, peak 0.780783, RMS 0.041972 |
| Audio-only diagnostic with Chrome playing a YouTube clip after relaunch | 1,753 buffers, 897,536 native frames, 299,178 normalized frames, peak 0.388334, RMS 0.046896 |
| System Audio only, Chrome playing YouTube | Six finalized System Audio segments saved, including the Kennedy speech. The microphone lane was off. |
| Microphone only | Five finalized microphone segments saved. The System Audio lane was off. |
| Both sources, playback and live speech | Seven System Audio and 23 microphone segments saved to the same session. |
| Stop, Start, and application relaunch after consent | The tap released on Stop and captured again after Start and after quitting and relaunching the same signed app. A quiet diagnostic restart received frames with zero peak and RMS. |

Session tests cover backend selection, denial and retry, independent sources, and repeated Start/Stop. The offline test run reported 38 tests, with the optional Silero network download skipped. A deliberate revocation of the new audio-only grant, a restart-required prompt, and authorized ScreenCaptureKit playback were outside the live checks. The capture APIs tested provided no distinct restart-required error. If macOS requests a restart, use its Quit & Reopen prompt. [Kennedy Library Foundation YouTube clip](https://www.youtube.com/watch?v=L8l11q_MNRY)

Files changed for this release

- `CoreAudioTapCapture.swift`, `AudioCapture.swift`, and `Domain.swift` implement audio-only capture and backend selection.
- `CaptureDiagnostics.swift` and `ScreenCaptureAuthorization.swift` report bundle identity and capture stages.
- `SystemAudioDiagnostic.swift` and `LocalCaptionApp.swift` provide diagnostic launch and native buffer measurements.
- `PreferencesView.swift` and `AppResources/Info.plist` expose the capture modes and declare system audio usage.
- `SessionStartupTests.swift` checks diagnostic measurements and explicit ScreenCaptureKit selection.
- `README.md`, `DISTRIBUTION.md`, and this report document capture, reauthorization, and verification.

## System Audio authorization regression

On macOS 27.2.1, System Settings displayed LocalCaption as enabled in both recording lists. During the failing Automatic attempt, macOS logged `Failed to match existing code requirement` for `kTCCServiceScreenCapture`. The stored requirement's code hash matched an older workspace copy (prefix `29cd9c9a`). The executable at `dist/LocalCaption.app` was signed with a different hash (prefix `51bdce4f`). ScreenCaptureKit returned `SCStreamErrorDomain -3801` during display discovery. The previous code also treated a false CoreGraphics screen preflight as permission denial for every discovery error.

- `AudioCapture.swift` now uses ScreenCaptureKit discovery and startup directly, or the macOS display picker when selected. It subscribes to audio buffers and logs the first sample and the first normalized chunk sent to transcription.
- `ScreenCaptureAuthorization.swift` classifies authorization declines, unavailable sources, invalid configurations, stream errors, and picker cancellation. Settings shows the result of the last capture attempt. App identity diagnostics include the bundle identifier, build, code hash, and macOS version.
- An isolated signed build reproduced the declined grant with the microphone off, showed the specific authorization error, and left Start available. A later attempt opened the macOS display picker. Stop canceled the pending selection and returned to a retryable state. A display was not authorized during the test, so no native System Audio buffers arrived and live System Audio transcription could not be tested.
- The arm64 release passed strict signature verification. The offline suite passed 35 tests with the optional model download skipped. It covers denial and retry, unrelated ScreenCaptureKit errors, explicit picker selection and cancellation, and the existing microphone and inference regressions.

## Start Session regression

Eleven reports on November 23, 2026, including `LocalCaption-2026-11-23-143735.ips`, showed `EXC_BREAKPOINT / SIGTRAP` in the Core Audio HAL I/O thread. The frames ran from `HALC_ProxyIOContext::IOWorkLoop` into the closure created by `MicrophoneCapture.start`, then into Swift's executor check and `dispatch_assert_queue`. Console reported that the closure expected the main thread. A minimal Swift 6 Debug reproducer using the old callback pattern trapped with the same stack. The issue affected microphone-enabled sessions when the input unit delivered its first buffer.

`AudioCapture.swift` now registers a nonisolated C callback and retains its Swift context through native disposal. The MainActor still owns the audio unit and session state. The first live retest exposed a separate `EXC_CRASH / SIGABRT` on Stop in `AppModel.closeSession`. The function read the observable session while updating its end date, which violated Swift's exclusive access rule. It now updates a local copy and assigns it back. A separate release retest exposed a Quit-time assertion in `ggml_metal_rsets_free` while the cached Whisper context still owned Metal residency sets. The app delegate now waits for session shutdown and explicit inference-context release before replying to macOS termination.

Startup validates the speech model against its pinned digest before handing the path to whisper.cpp. The session controller serializes preparation and shutdown, cancels preparation when Stop or window close is requested, and rolls back partially initialized sources. A working source can continue when the other fails. The `local.caption` Console subsystem reports startup stages, transitions, and native error codes. Model paths and audio-device identifiers are marked private. The app omits audio and transcript content from these diagnostics.

- Debug and arm64 Release builds succeeded. The release bundle passed strict signature verification.
- 31 automated tests passed with networking denied. The optional model-download test was skipped. Coverage includes the native callback on a foreign queue, invalid and same-size corrupted speech models, denied permissions, partial rollback, cancellation, retry, and repeated lifecycle operations for each source configuration.
- In the final signed Release app, Stop followed by Quit and Quit during active microphone recording both saved completed sessions, released the Metal context, and exited without a crash report.
- In the signed Debug app, a real microphone session transcribed a local synthetic speech fixture. Pause, Resume, and Stop succeeded. Ten consecutive microphone-only Start and Stop cycles completed. Removing the test copy's model link produced a recoverable error, and restoring it allowed a successful retry.
- With Screen & System Audio Recording denied, microphone capture continued in a dual-source session. A system-only session showed the permission error and returned to a retryable state. Successful system-only and simultaneous capture with permission enabled remain pending.

## Environment and results

The arm64 app was built and ad hoc signed on a MacBook Pro with an Apple M5 Pro and 48 GB of unified memory. The build uses the macOS 14 deployment target. A relocated copy of the signed app launched and initialized its SQLite schema with network access denied. The verification host ran a newer macOS release.

The automated suite passed 18 tests with network access denied. A separate online test downloaded and validated the pinned Silero model, replaced a truncated installation, and removed the test copy. Tests exercised real Whisper Small and Large-v3 Turbo on English and Russian speech, Silero VAD, bidirectional native Marian translation, concurrent source pipelines, paced partial output, long speech, repeated phrases, silence, and finalized transcript storage. Additional coverage includes stereo-to-mono conversion, session transitions, crash recovery, database rollback, timestamp reconciliation, model integrity checks, and TXT, JSON, and SRT export formatting.

In the launched signed app, the Live workspace displayed both source lanes. Settings recognized all five models in an isolated test directory. History reopened an isolated saved session with mixed sources and languages. Its TXT export went through the native save panel and included the expected labels, timestamps, and translated text. The main window reported showing and hiding the subtitle panel when toggled.

## Measured inference

| Model | First partial from paced fixture | Inference for a 1.6 s window | Final inference for 5.8–6.2 s of audio |
| --- | ---: | ---: | ---: |
| Whisper Small Q5_1 | 1.30 s | 0.18 s | 0.22–0.25 s |
| Whisper Large-v3 Turbo Q5_0 | 1.95 s | 0.83–0.84 s | 0.86–0.88 s |

The paced tests fed 100 ms blocks to the same pipeline used for live audio and timed the first partial from the beginning of the fixture. The other timings cover warm Metal inference calls. They exclude physical audio capture, rendering, cold shader compilation, competing workloads, and translation. The benchmark uses one English and one Russian synthetic utterance and does not establish a general accuracy ranking.

For one sentence in each direction, Marian took 0.32–0.34 s with model loading and 0.05 s on a second request. The tests produced “Микрофон записывает звук.” and “The microphone is recording sound.” in the corresponding directions.

## Live acceptance procedure

Live simultaneous microphone and system capture, browser playback, physical device reconnection, the two-hour endurance run, and testing on macOS 14 hardware remain pending. Use the following procedure for full live acceptance.

1. Grant Microphone and Screen & System Audio Recording access. Start with both sources enabled. Play a video in a browser and speak into the selected microphone while using headphones. Confirm both source indicators are active and each lane receives its own speech.
2. Test English → Russian and Russian → English in separate sessions. Confirm partial revisions, finalized originals, and delayed translations.
3. Show the subtitle panel above a browser window. Confirm its source filters, display modes, position, and resize behavior.
4. Pause, wait, and resume. Confirm time offsets include the gap. Stop and confirm that the session is saved and appears in History.
5. Export TXT, JSON, and each SRT display mode. Confirm both source labels and chronological timestamps appear.
6. Disconnect the network with models installed and repeat a capture and translation. The automated inference suite already ran with network access denied.
7. Run both sources for at least two hours while inspecting memory and input backlog. Navigate earlier captions and history while the session is active.
8. Disconnect an external microphone while system playback continues. Confirm the microphone status changes independently and the selected input reconnects when it returns.
9. Deny System Audio access and confirm the microphone still works and System Audio displays its error.
10. Repeat Start and Stop, try both profiles, and force-quit a test session. Relaunch and confirm that committed captions remain visible and the session is marked Interrupted.
