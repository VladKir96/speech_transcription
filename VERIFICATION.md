# Verification

## LocalCaption 1.4.0 Speaker Diarization

### Runtime and models

The app uses the existing arm64 ONNX Runtime 1.24.4 CPU backend. The sherpa-onnx API reviewed for this feature exposes offline diarization. LocalCaption runs a bounded rolling window and maintains its own session-scoped speaker registry. Both artifacts were downloaded, matched the publisher’s pinned byte count and SHA-256, and ran natively on the Apple Silicon test Mac. [Sherpa diarization documentation](https://k2-fsa.github.io/sherpa/onnx/speaker-diarization/index.html)

| Model | Source | Bytes | SHA-256 | License |
| --- | --- | ---: | --- | --- |
| Pyannote Speaker Segmentation 3.0, FP32 | [Pinned ONNX Community conversion](https://huggingface.co/onnx-community/pyannote-segmentation-3.0/tree/733a93b6473d019a773298e08cefa686894b1854) | 5,986,908 | `057ee564753071c0b09b5b611648b50ac188d50846bff5f01e9f7bbf1591ea25` | MIT |
| WeSpeaker ResNet34-LM | [Pinned publisher artifact](https://huggingface.co/Wespeaker/wespeaker-resnet34-LM/tree/f0c48c298fd835726c27956a5d617bad7115627e) | 26,530,309 | `7bb2f06e9df17cdf1ef14ee8a15ab08ed28e8d0ef5054ee135741560df2ec068` | CC BY 4.0 |

The native compatibility probe passed a 16 kHz mono tensor to Pyannote and got 234 by 7 scores for four seconds and 589 by 7 for ten seconds. The seven classes represent silence, three local voice slots, and three pairs of simultaneous speakers. The bridge passes WeSpeaker 80-bin log-Mel features with the publisher's windowing and mean normalization. Both 70- and 160-frame inputs returned 256-value embeddings. LocalCaption normalizes the vectors before cosine clustering. [Pyannote class specification](https://huggingface.co/pyannote/segmentation-3.0) · [WeSpeaker reference preprocessing](https://github.com/wenet-e2e/wespeaker/blob/master/wespeaker/bin/infer_onnx.py)

### Processing and data lifetime

Only System Audio has a diarization input. The speaker worker receives normalized PCM through a 24-chunk FIFO buffer that drops the oldest pending chunk when full. It handles gaps on the capture clock, retains at most four or ten seconds of audio, and runs each model at single-threaded CPU settings. The modes analyze about once every one or two seconds, respectively. Exclusive speech supplies the embeddings. An observed overlap can mark a caption without updating a speaker profile.

The tracker uses cosine similarity, a 0.55 default verified against the local fixture, a margin for ambiguous matches, and an evidence requirement for new profiles. It can hold up to ten confirmed profiles and eight candidates. The fixed-count setting caps profiles. The display name can change independently of the speaker ID. The app keeps profiles and recent timeline metadata in memory during a session, including across a pause or temporary deactivation.

Disabling immediately closes the input and cancels the worker. Any synchronous native call finishes safely before the worker releases both model sessions. Re-enabling waits for that shutdown before loading a replacement pair. The disabled path allocates no audio buffer, starts no worker, and performs no speaker inference. Activation starts at the analysis input's first eligible audio chunk. A caption crossing that boundary keeps its text without a speaker label.

Caption alignment uses Whisper segment times and the rolling speaker timeline. Confirmed speaker changes separate pending translation phrases. A dedicated phrase queue displays original text while waiting up to about 1.35 seconds in Real-Time and 2.6 seconds in High Accuracy when an attribution is pending. Known mixed or overlapping captions keep the original Whisper segment intact. Recent Unknown Speaker assignments can be patched by caption ID. A completed translation stays in place when its speaker label changes.

SQLite migrates from schema 2 to 3 with a session-scoped speaker table and nullable caption fields. The migration left all six existing test sessions and 111 existing caption rows identical on their original fields. The database stores names, colors and caption assignments. Audio and embedding vectors stay in memory.

### Paced pipeline benchmark

Each row is a separate offline process on the Apple M5 Pro. All runs replayed the same 14 seconds of audio at wall-clock speed through the existing System Audio streaming code. The harness used Whisper Small Q8 with Metal, Silero 6.3, and warm MarianMT. CPU is average process use as a percentage of one core. Peak RSS includes recognition, translation, and the test process. Mean call latency covers 17 Whisper and four MarianMT calls in each run. The first timeline time is relative to playback start. Speaker RTF is time in native speaker analysis divided by 14 seconds of input.

| Mode | CPU | Peak RSS | Whisper mean | MarianMT mean | First timeline | Native speaker RTF |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Off | 9.5% | 1.39 GiB | 126 ms | 136 ms | — | 0 |
| Real-Time | 24.3% | 1.80 GiB | 123 ms | 141 ms | 2.12 s | 0.150 |
| High Accuracy | 16.7% | 1.58 GiB | 123 ms | 133 ms | 5.22 s | 0.100 |

The Off run performed zero speaker calls and created zero speaker drafts. The two enabled runs assigned speakers to three of four final captions. Metal remained in use for Whisper. GPU utilization was unmeasured. These single-run timings describe this Mac and workload.

### Quality and release checks

The 63-second fixture used four locally synthesized voices in English and Russian. It covers alternating speakers, two similar English voices, a short response, a paused sentence, added noise, music, quiet intervals, a return after quiet, and an intentional overlap. The reference uses each rendered utterance's known position in the mono mix. The reported exclusive-speaker error rate used 200 ms frames, a 250 ms collar at each turn boundary, one-to-one best matching of predicted IDs to reference identities, and excluded overlap from scoring. The fixture produced 145 scored speech frames, or 29.0 seconds.

| Mode | Missed speech | False alarm | Confusion | Exclusive-speaker error | Estimated speakers |
| --- | ---: | ---: | ---: | ---: | ---: |
| Real-Time | 2.8 s | 0.0 s | 0.2 s | 10.3% | 4 of 4 |
| High Accuracy | 0.6 s | 0.0 s | 2.4 s | 10.3% | 5 for 4 |

Both modes marked the deliberate overlap and retained the first voice’s label on its return. Verification and native loading took 47 ms and 72 ms respectively for the two runs in the final suite. The restart check retained that speaker ID after advancing the same session’s fixture clock by over five minutes. A separate accelerated run analyzed 378 audio seconds in 377 windows, kept the same first-speaker ID across six repeats, and reported no queue lag. This yielded 42.47 seconds of native speaker analysis in 44.13 seconds elapsed.

The signed Apple Silicon package passed strict signature checks. The offline suite reported 72 tests across five suites. The three opt-in checks ran separately for downloads, paced performance and extended analysis. The native and regression checks covered Whisper Q8, both translation backends, missing and corrupt speaker files, dual capture lifecycle, phrase boundaries, migration, rename, export and history deletion.

The offline live QA recording completed at **3:56**. System Audio kept transcribing and translating during activation, deactivation, reactivation, Pause and Resume. Four IDs were stored, and no microphone caption received a speaker label. Replaying the same phrase while disabled produced a translation without a speaker. The returning voice after reactivation kept Speaker 1. History reopened the recording, displayed the renamed **Interviewer** label on four captions, and saved that label in the SRT. The floating panel opened while analysis was on.

This corpus is too small to characterize general conversational accuracy. Short replies and closely matched voices can remain unknown, be grouped together, or get an additional profile. The app preserves whole Whisper segments at uncertain boundaries. Live QA used the Core Audio process tap. Long analysis used accelerated fixture playback, and quality on spontaneous multi-person recordings remains unmeasured.

### Reproducing the checks

```sh
python3 Scripts/prepare-diarization-fixture.py .deps/diarization/fixtures
export LOCALCAPTION_TEST_SPEAKER_MODELS=/path/to/Models
export LOCALCAPTION_TEST_SPEAKER_FIXTURE="$PWD/.deps/diarization/fixtures"
./Scripts/test.sh --filter RealDiarizationTests
LOCALCAPTION_SPEAKER_STRESS=1 ./Scripts/test.sh --filter speakerProfilesRemainStableInExtendedStream
LOCALCAPTION_TEST_MODELS=/path/to/Models \
LOCALCAPTION_TEST_VAD63=/path/to/Models/silero-6.3/silero_vad.onnx \
LOCALCAPTION_SPEAKER_BENCHMARK=realTime ./Scripts/test.sh --filter pacedSpeakerPipelineBenchmark
```

The last command also accepts `off` or `highAccuracy`. Python and local speech voices are used only to prepare the QA fixture.

### Files changed

- `Native/Inference.mm` and `Sources/CInference/inference.h` add native segmentation, feature extraction and embedding calls.
- `Sources/CaptionCore/Diarization.swift`, `DiarizationSession.swift`, `Streaming.swift`, and `PhraseAggregation.swift` implement bounded inference, tracking, alignment and phrase boundaries.
- `Sources/CaptionCore/Domain.swift`, `Repository.swift`, `Export.swift`, `ModelStore.swift`, and `Resources/Models.json` add model pins, speaker metadata, migration and exports.
- `Sources/LocalCaption/AppModel.swift`, `PreferencesView.swift`, `TranscriptView.swift`, `HistoryView.swift`, `WorkspaceView.swift`, and `SubtitleWindow.swift` connect capture lifecycle, speaker controls, labels, renaming and export options.
- `Tests/CaptionCoreTests/DiarizationTests.swift`, `InferenceTests.swift`, `Tests/LocalCaptionTests/SessionStartupTests.swift`, and `Scripts/prepare-diarization-fixture.py` cover tests and fixture preparation. `AppResources/Info.plist`, `README.md` and `MODEL-LICENSES.md` record the release and its offline setup.

## LocalCaption 1.3.0 Whisper Q8_0

The app uses the multilingual Whisper Small and Large-v3 Turbo Q8_0 files published by whisper.cpp at revision `5359861c739e955e79d9a303bcbc70fb988958b1`. The downloaded bytes matched the repository's LFS SHA-256 and file sizes. The two GGML headers encode Q8_0 as `ftype=2007`, which whisper.cpp reads as quantization version 2 and type 7. LocalCaption uses the upstream conversions directly. The original models are MIT licensed. [Whisper.cpp model repository](https://huggingface.co/ggerganov/whisper.cpp/tree/5359861c739e955e79d9a303bcbc70fb988958b1) · [OpenAI Whisper license](https://github.com/openai/whisper/blob/main/LICENSE)

| Artifact | Directory under Models | Bytes | SHA-256 |
| --- | --- | ---: | --- |
| [`ggml-small-q8_0.bin`](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small-q8_0.bin) | `small-q8` | 264,464,607 | `49c8fb02b65e6049d5fa6c04f81f53b867b5ec9540406812c643f177317f779f` |
| [`ggml-large-v3-turbo-q8_0.bin`](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q8_0.bin) | `turbo-q8` | 874,188,075 | `317eb69c11673c9de1e1f0d459b253999804ec71ac4c23c17ecf5fbe24e259a1` |
| [`ggml-small-q5_1.bin`](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-small-q5_1.bin) | `small` | 190,085,487 | `ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb` |
| [`ggml-large-v3-turbo-q5_0.bin`](https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin) | `turbo` | 574,041,195 | `394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2` |

The native probe used the bundled whisper.cpp v1.8.3 Metal backend on an Apple M5 Pro with 48 GiB of memory and macOS 27.2.1. The Small variants both reported 12 encoder and 12 decoder layers, 80 mel bands, and a vocabulary of 51,865. Both Turbo variants reported 32 encoder and four decoder layers, 128 mel bands, and a vocabulary of 51,866. All four reported multilingual support, initialized the Metal backend, and correctly autodetected and transcribed the English and Russian regression samples. The app retries on CPU and shows its existing acceleration notice if Metal initialization fails. [whisper.cpp v1.8.3](https://github.com/ggml-org/whisper.cpp/tree/v1.8.3)

Settings still encodes the architecture as `small` or `turbo`. The selected architecture resolves to the checksum-verified Q8 file at session start. With a missing or invalid Q8 file, the app can use verified compatibility weights for that architecture and prompts the user to install or repair the current model. The installer stages each download and verifies it before publication. A shared Whisper actor retains one native recognition context for both sources and releases the previous context before loading a different model. Audio capture, VAD and phrase-completion parameters continue to use their existing values.

### Matched benchmark

All runs used the app's native bridge, Metal, four threads, automatic language detection, and the High Accuracy final decoder with beam size four. Each model ran in its own process with networking denied. The fixture set contains 62.11 seconds across ten clips, with 144 reference words and 727 normalized reference characters. The latency statistics cover 30 warm calls per variant, three per clip. Load time includes the Metal probe and native context initialization. RTF is total decode time divided by input audio time. Peak RSS is whole-process resident memory as reported by macOS. Native model buffers alone used 189.49 MB and 263.87 MB for Small Q5 and Q8, and 573.40 MB and 873.55 MB for Turbo Q5 and Q8.

WER and CER use Levenshtein distance after Unicode case folding and punctuation removal. CER also removes spaces. Accuracy scores use the first warm result from each clip. The Irish-accent, quiet, fast, conversational, and technical fixtures use local macOS speech voices. The noisy microphone fixture uses public Speech Commands microphone recordings with reproducibly added noise. The video fixture is the public archival speech in whisper.cpp's `jfk.wav`. [Speech Commands source](https://www.tensorflow.org/tutorials/audio/simple_audio)

| Variant | WER | CER | RTF | Mean | P95 | Peak RSS | Load |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Small Q5_1 | 2.78% | 0.55% | 0.0355 | 0.220 s | 0.260 s | 489.8 MiB | 0.199 s |
| Small Q8_0 | 2.78% | 0.55% | 0.0346 | 0.215 s | 0.257 s | 575.2 MiB | 0.226 s |
| Large-v3 Turbo Q5_0 | 0.00% | 0.00% | 0.1403 | 0.871 s | 0.900 s | 819.0 MiB | 0.279 s |
| Large-v3 Turbo Q8_0 | 0.00% | 0.00% | 0.1335 | 0.829 s | 0.858 s | 1,131.1 MiB | 0.359 s |

Each cell below shows mean latency in seconds and word edits. All variants detected the correct language on each fixture.

| Fixture | Small Q5_1 | Small Q8_0 | Turbo Q5_0 | Turbo Q8_0 |
| --- | ---: | ---: | ---: | ---: |
| English conversation | 0.211 / 0 | 0.205 / 0 | 0.862 / 0 | 0.822 / 0 |
| Russian conversation | 0.250 / 0 | 0.242 / 0 | 0.889 / 0 | 0.847 / 0 |
| English technical | 0.224 / 0 | 0.217 / 0 | 0.875 / 0 | 0.833 / 0 |
| Russian technical | 0.260 / 4 | 0.257 / 4 | 0.900 / 0 | 0.859 / 0 |
| Fast English | 0.220 / 0 | 0.214 / 0 | 0.868 / 0 | 0.829 / 0 |
| Irish-accented English | 0.210 / 0 | 0.203 / 0 | 0.863 / 0 | 0.823 / 0 |
| Slow English with pauses | 0.184 / 0 | 0.180 / 0 | 0.849 / 0 | 0.812 / 0 |
| Quiet English | 0.210 / 0 | 0.204 / 0 | 0.862 / 0 | 0.825 / 0 |
| Noisy microphone | 0.203 / 0 | 0.197 / 0 | 0.868 / 0 | 0.817 / 0 |
| Archival video audio | 0.232 / 0 | 0.227 / 0 | 0.878 / 0 | 0.830 / 0 |

The benchmark found no accuracy gain for Q8 on this corpus. Both Q8 versions had comparable warm inference times and used more resident memory. The corpus is small and primarily synthesized, so these figures describe the checked fixtures and test Mac.

To reproduce, build the native dependencies, obtain the four pinned artifacts above, and extract the three microphone files listed under [Silero matched fixtures](#matched-fixtures). Prepare the clips once and run the second command in a fresh process for each file. Python is a development-only benchmark dependency.

```sh
python3 Scripts/benchmark-whisper.py .deps/whisper-q8/fixtures --prepare .deps/vad63/speech-commands
python3 Scripts/benchmark-whisper.py .deps/whisper-q8/fixtures \
  --model /path/to/ggml-model.bin --beam 4 --repeats 3
```

### Regression checks

The final offline arm64 suite reported 64 tests across four suites. It exercised both verified Q8 models, automatic English and Russian detection, independent dual-source segmentation, live-style partials, actual MarianMT and NLLB inference, session lifecycle, and invalid files. The migration tests cover a missing Q8 file, same-size corruption, fallback, preference restoration, and explicit rollback. Separate online tests exercised download and integrity verification for both Q8 models and the Silero pins.

The final signed build showed exactly three recognition models in Settings, even with the older files present in its isolated model folder. The Whisper picker offered Small Q8 and Large-v3 Turbo Q8. All three current entries changed from download offers to installed status once the verified files were added. Translation model management remained visible. Both Q8 files were verified in the normal model library, which already held Silero 6.3. Existing preferences and transcript data were preserved.

The signed capture QA copy ran with networking denied and its own model and transcript folders. A machine with only the old Whisper weights could still start capture. After both Q8 variants were added, Small Q8 loaded on Metal for the same architecture selection. A paced English fixture played through the Mac speakers produced a complete MarianMT translation on both System Audio and the built-in microphone. Space muted the microphone while System Audio continued. Switching to NLLB during the same recording saved three subsequent translations with NLLB provenance.

The Turbo Q8 System Audio-only run lasted **5:43** and saved 69 NLLB translations of repeated archival playback. During recording, Settings disabled model switching and removal. The app ended the recording through its normal Stop path, released the system audio tap, and saved the session. Sampled process RSS peaked at 3.75 GiB and stayed near 3.53 GiB during the later playback intervals. These process figures include capture, Whisper, VAD, translation, and the UI. Fixture playback stopped when the completed session was observed.

Live QA showed the floating subtitle control and newest-first captions. It reopened the prior QA history and exported a TXT containing both source labels and the paced original and translation. All three prior sessions and 35 prior caption rows in the seeded history stayed intact. Automated lifecycle tests exercised microphone-only setup, Push-to-Talk, Pause and Resume, and repeated starts and stops. Live timing covers the host's Core Audio process tap and built-in microphone. A longer hardware run, microphone-only Push-to-Talk with live hardware, the ScreenCaptureKit display path, and earlier macOS releases were outside this run.

### Files changed

- `Sources/CaptionCore/Resources/Models.json`, `RollbackModels.json`, `ModelStore.swift`, and `Domain.swift` define and verify the variants while preserving architecture preferences. `Scripts/build-app.sh` packages both manifests.
- `Sources/LocalCaption/SessionDependencies.swift`, `AppModel.swift`, `PreferencesView.swift`, and `WorkspaceView.swift` implement migration, model selection and compatibility status. `Native/Inference.mm` reports an internal Metal initialization failure through the existing CPU fallback path.
- `Tests/CaptionCoreTests/InferenceTests.swift`, `VADTests.swift`, `Tests/LocalCaptionTests/SessionStartupTests.swift`, and `Scripts/benchmark-whisper.py` exercise and compare the model variants.
- `AppResources/Info.plist`, `README.md`, `MODEL-LICENSES.md`, and `VERIFICATION.md` record the release, attributions, results, and [rollback procedure](README.md#upgrading-whisper-from-q5).

## LocalCaption 1.2.1 Silero VAD 6.3

Silero published v6.3 on November 23, 2026, at 09:19 UTC. GitHub verified the signature of release commit `63d4a2a7bfce8cd9bb39ed8fa0afcb5236d73e01`. The release describes changes to short speech and pauses, improved long-context retention, earlier end detection, and fewer false positives. It reports slightly stricter scoring at the same threshold. The inspected multi-rate ONNX graph contains 163 nodes and one conditional across its subgraphs, compared with 689 nodes and 25 conditionals in the official 6.2 ONNX graph. Both declare ONNX opset 16 and IR version 8. [Silero v6.3 release](https://github.com/snakers4/silero-vad/releases/tag/v6.3)

| Asset | Installed path under Models | SHA-256 |
| --- | --- | --- |
| [Official 6.3 multi-rate ONNX](https://raw.githubusercontent.com/snakers4/silero-vad/63d4a2a7bfce8cd9bb39ed8fa0afcb5236d73e01/src/silero_vad/data/silero_vad.onnx) | `silero-6.3/silero_vad.onnx` | `f6f4407b41e05e277e7f5cfd9b9ae957b1dfe763c6076a934734c0b448e09b31` |
| [6.2 GGML rollback](https://huggingface.co/ggml-org/whisper-vad/blob/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v6.2.0.bin) | `silero/ggml-silero-v6.2.0.bin` | `2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987` |

The 6.3 asset is 2,204,103 bytes. LocalCaption checks the pinned size and SHA-256 before installation and when the file identity, size, or timestamp changes. New streams prefer installed 6.3, use verified 6.2 if 6.3 is unavailable or fails, and fall back to audio-level detection when neither model can run. The same launch can use separate model instances for each source. Downloads remain explicit in Settings → Models. [Model catalog](Sources/CaptionCore/Resources/Models.json) · [6.2 rollback instructions](README.md)

### Native interface and streaming

The standalone arm64 probe loaded both official ONNX graphs with the bundled ONNX Runtime 1.24.4 CPU library and ran 40 sequential windows with batches of one and two at 8 and 16 kHz. No runtime upgrade was required. The names and element types are the same for both versions. The 6.3 graph declares more of the recurrent output shape. The 6.2 graph declares all three dimensions of `stateN` dynamic and returned the same concrete shape in the probe. [Official Silero streaming wrapper](https://github.com/snakers4/silero-vad/blob/v6.3/src/silero_vad/utils_vad.py)

| Port | Type | Shape for 6.3 |
| --- | --- | --- |
| `input` | float32 | `[batch, samples]` |
| `state` | float32 | `[2, batch, 128]` |
| `sr` | int64 | scalar |
| `output` | float32 | `[batch, 1]` |
| `stateN` | float32 | `[2, batch, 128]` |

The native bridge validates the ports and runs a warm-up before giving the handle to a stream. Each source has its own CPU session, zero-initialized recurrent state, and audio context. It processes 512 new samples plus 64 previous samples at 16 kHz. The bridge also supports 256 plus 32 at 8 kHz. The app normalizes Core Audio input to mono 16 kHz and uses batch size one. The Swift wrapper retains fewer than 512 residual samples between 100 ms caption frames. Stream startup, source reconnection, and a marked input discontinuity reset the state. Stream shutdown releases the handle after queued recognition finishes.

The previous app ran 6.2 via whisper.cpp's GGML VAD. It rescored a sliding context and used the maximum of the recent native scores. The new path uses the maximum over the new 32 ms windows available in each 100 ms input block. Both use the existing 0.38 onset and 0.30 continuation thresholds, audio-level gate, up to 320 ms of preroll, and minimum of two voiced frames for a finalized recognition window. The two profiles retain their existing end-silence and maximum-window limits. Whisper recognition consumes those windows, while translation combines compatible text using the separate Phrase Completion Pause.

### Matched fixtures

Each detector received the same 16 kHz mono samples, with the same silence padding, RMS gate of 0.00025, 0.38/0.30 thresholds, and measurement at 100 ms resolution. Regions below have at least two voiced frames and are separated by at least 600 ms. The two ONNX models use identical windowing. The 6.2 GGML column measures the implementation that previously shipped in LocalCaption. The table reports **regions / milliseconds of the fixture envelope left unvoiced** for speech fixtures and **regions / false-positive milliseconds** for pure music, noise, and silence. The speech envelope includes natural and inserted silences. These clips lack frame-level speech annotations, so the envelope gaps describe detector output and cannot establish missed speech, precision, recall, or F1.

| Fixture | 6.2 GGML | 6.2 ONNX | 6.3 ONNX |
| --- | ---: | ---: | ---: |
| English | 1 / 317 | 1 / 317 | 1 / 317 |
| Russian | 1 / 272 | 1 / 272 | 1 / 372 |
| Slow English | 2 / 1,067 | 2 / 1,067 | 2 / 1,067 |
| Slow Russian | 2 / 1,122 | 2 / 1,122 | 2 / 1,122 |
| Short English | 1 / 0 | 1 / 0 | 1 / 0 |
| Quiet English | 1 / 517 | 1 / 417 | 1 / 417 |
| Continuous English and Russian | 1 / 1,865 | 1 / 1,965 | 1 / 1,965 |
| Music | 1 / 400 | 0 / 100 | 0 / 100 |
| Noise | 0 / 0 | 0 / 0 | 0 / 0 |
| English with noise | 1 / 0 | 1 / 117 | 1 / 217 |
| Silence | 0 / 0 | 0 / 0 | 0 / 0 |
| Archival video audio | 3 / 2,900 | 3 / 2,900 | 4 / 3,400 |
| Microphone «yes» | 1 / 400 | 1 / 400 | 1 / 500 |
| Microphone «no» | 1 / 400 | 1 / 500 | 1 / 500 |
| Microphone «stop» | 1 / 300 | 1 / 500 | 1 / 300 |

Relative to 6.2 GGML, 6.3's onset was 100 ms later on the Russian and slow Russian fixtures, with 200 ms from fixture start to the end of the first voiced frame. The English-with-noise fixture began at the same frame. Its last voiced frame ended 117 ms before the fixture ended with 6.3 and 83 ms after it with 6.2 GGML. The three microphone commands first registered at 200 ms in all versions and each formed one region. The last voiced frame with 6.3 ended 400, 400, and 100 ms before the end of the respective one-second microphone clips. Both shipped detectors retained the three checked key phrases from the same archival audio in Whisper, with three finalized captions for 6.2 and four for 6.3. Thresholds stayed at the existing values.

The microphone examples are public CC BY 4.0 recordings from TensorFlow's Speech Commands sample, extracted unchanged with these local names. [TensorFlow sample archive and tutorial](https://www.tensorflow.org/tutorials/audio/simple_audio) · [Dataset paper](https://arxiv.org/abs/1804.03209)

| Local filename | Entry in `mini_speech_commands.zip` |
| --- | --- |
| `yes.wav` | `mini_speech_commands/yes/93ec8b84_nohash_0.wav` |
| `no.wav` | `mini_speech_commands/no/439c84f4_nohash_1.wav` |
| `stop.wav` | `mini_speech_commands/stop/b87bdb22_nohash_1.wav` |

Run from the project root with the local paths to the model assets and optional audio fixtures. The 6.2 ONNX control came from the official v6.2 tag, and `jfk.wav` comes from the pinned whisper.cpp checkout. `VADCASE` prints onset and offset for each fixture. [Official 6.2 ONNX control](https://github.com/snakers4/silero-vad/blob/v6.2/src/silero_vad/data/silero_vad.onnx)

```sh
LOCALCAPTION_TEST_MODELS="$PWD/.deps/test-models" \
LOCALCAPTION_TEST_NLLB="$PWD/.deps/nllb-prep/LocalCaption-NLLB-200-600M" \
LOCALCAPTION_TEST_VAD63="$PWD/.deps/vad63/silero_vad.onnx" \
LOCALCAPTION_TEST_VAD62_ONNX="$PWD/.deps/vad63/silero-v6.2.onnx" \
LOCALCAPTION_TEST_VAD62_GGML="$PWD/.deps/test-models/ggml-silero-v6.2.0.bin" \
LOCALCAPTION_TEST_VAD_PLAYBACK="$PWD/.deps/whisper/samples/jfk.wav" \
LOCALCAPTION_TEST_VAD_MICROPHONE="$PWD/.deps/vad63/speech-commands" \
LOCALCAPTION_TEST_VAD_STRESS=1 ./Scripts/test.sh
```

### Performance on Apple M5 Pro

The standalone arm64 process replayed the same English recording for 300 audio seconds using the app's 100 ms blocks. RSS includes the process and loaded libraries. CPU time covers the whole benchmark process.

| Runtime | Mean per block | P95 per block | Peak process RSS | CPU time |
| --- | ---: | ---: | ---: | ---: |
| 6.2 GGML | 0.486 ms | 0.549 ms | 57.0 MiB | 1.466 s |
| 6.2 ONNX | 0.195 ms | 0.249 ms | 43.8 MiB | 0.603 s |
| 6.3 ONNX | 0.179 ms | 0.229 ms | 35.8 MiB | 0.555 s |

### Automated verification

The arm64 suite reported 60 tests across four suites with networking denied. The optional network test ran separately and downloaded both official pins, replaced a damaged copy of each, and opened both installed models. The offline suite exercised actual Whisper, MarianMT, and NLLB inference, both capture sample-rate conversions, invalid models and frame sizes, state reset and separation, session lifecycle, and translation phrase aggregation. The 6.3 stress test processed 36,000 blocks representing 30 audio minutes on each of two concurrent detector instances in 3.70 seconds. This test fed audio at compute speed. The rollback regression suite also passed against the original 6.2 GGML backend. The pinned 6.2 implementation is in the current source tree and baseline commit `4cca215`.

### Live verification on macOS 27.2.1

- The signed QA build ran with network access denied and an isolated transcript database. The Automatic System Audio source used the Core Audio process tap. The built-in microphone used the HAL input. System Audio transcribed English YouTube playback. Speech played through the Mac's speakers reached both inputs, and the paced English fixture produced one complete MarianMT translation in each lane. Muting the microphone left System Audio running.
- The first session recorded for **30:04 before Pause** and finished at **30:21** after Resume. System Audio detected a paced Russian sentence after an extended quiet interval, saved translations from about a minute of archival playback, and detected the final English fixture at 28:41 and after Resume. The session saved 31 caption rows. The QA process averaged 9.0% of one core across 23 samples, with a sampled peak RSS of 2.39 GiB during playback and about 1.90 GiB late in the quiet interval. Those figures include capture, Whisper, translation, and the UI.
- Pause and Stop released the system audio tap. Resume started a fresh 6.3 detector, and the next new session initialized 6.3 separately for both sources. Each lane saved the paced sentence and its translation on restart. The rollback launch selected 6.2 for both inputs, saved System Audio captions, and closed normally. The two QA app processes exited after Stop and Quit.
- The workspace release passed strict app-bundle signature verification. The verified 6.3 model was installed in the existing LocalCaption model library alongside the original 6.2 file. A normal launch of 1.2.1 uses 6.3 for new streams with neural VAD enabled. Quit before applying the 6.2 launch override.

The live endurance run used System Audio throughout its initial 30-minute interval and the microphone during the opening dual-source check. The live microphone source received controlled playback through speakers. A 30-minute continuous dual-source run, spontaneous spoken conversation, external microphones, ScreenCaptureKit display capture, and earlier macOS releases were outside this live run. Live translation used MarianMT. NLLB ran in the offline automated suite.

### Files changed

- `Native/Inference.mm` and `Sources/CInference/inference.h` implement and expose the native bridge. `Scripts/build-app.sh` and `Scripts/test.sh` rebuild the bridge after source or header changes.
- `Sources/CaptionCore/Inference.swift`, `Streaming.swift`, and `Sources/LocalCaption/AppModel.swift` wire streaming inference, source lifecycle, and fallback. `Sources/CaptionCore/ModelStore.swift` and `Resources/Models.json` pin and validate the models.
- `Tests/CaptionCoreTests/InferenceTests.swift` and `VADTests.swift` cover conversion, downloads, graph validation, streaming, comparison, and endurance. `AppResources/Info.plist`, `MODEL-LICENSES.md`, and `README.md` carry the release metadata, attribution, installation, and rollback.

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
