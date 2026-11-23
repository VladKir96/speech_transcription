# Third-party models and runtimes

LocalCaption ships the native runtimes. The catalog lists separately downloaded weights, expected file sizes, and SHA-256 checksums.

| Component | License and attribution |
| --- | --- |
| Whisper Small and Large-v3 Turbo | MIT, OpenAI. The ggml models are quantized conversions published by whisper.cpp. [Original Whisper](https://github.com/openai/whisper) · [MIT license](https://github.com/openai/whisper/blob/main/LICENSE) · [ggml conversions](https://huggingface.co/ggerganov/whisper.cpp) |
| Silero VAD 6.2 | MIT, Silero Team. The app downloads the ggml conversion published by ggml-org. [Upstream](https://github.com/snakers4/silero-vad) · [MIT license](https://github.com/snakers4/silero-vad/blob/master/LICENSE) · [ggml conversion](https://huggingface.co/ggml-org/whisper-vad) |
| Marian OPUS-MT English → Russian | Apache-2.0, Helsinki-NLP / OPUS-MT. Xenova converted the weights to ONNX and quantized them. Vocabulary and tokenizers come from the original model repository. [Original model](https://huggingface.co/Helsinki-NLP/opus-mt-en-ru) · [ONNX conversion](https://huggingface.co/Xenova/opus-mt-en-ru) · [Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0) |
| Marian OPUS-MT Russian → English | CC BY 4.0, Helsinki-NLP / OPUS-MT. Xenova converted the weights to ONNX and quantized them. Vocabulary and tokenizers come from the original model repository. [Original model](https://huggingface.co/Helsinki-NLP/opus-mt-ru-en) · [ONNX conversion](https://huggingface.co/Xenova/opus-mt-ru-en) · [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) |
| NLLB-200 Distilled 600M | CC BY-NC 4.0, Meta AI. The optional model folder uses Meta's pinned safetensors revision converted to CTranslate2 int8 and retains the original tokenizer assets. Commercial use requires separate permission. When sharing the model or an adaptation under this license, include attribution, the license, and a description of changes. [Pinned Meta checkpoint](https://huggingface.co/facebook/nllb-200-distilled-600M/tree/b3bbac6cd67efa90e0fcbe4c882ec79cfd782a17) · [CC BY-NC 4.0 legal code](https://creativecommons.org/licenses/by-nc/4.0/legalcode) |
| whisper.cpp and ggml | MIT, Georgi Gerganov and contributors. [whisper.cpp v1.8.3](https://github.com/ggml-org/whisper.cpp/tree/v1.8.3) |
| ONNX Runtime | MIT, Microsoft and contributors. The app bundles the arm64 CPU library and disables runtime telemetry events. The bundle contains the license and third-party notices. [Microsoft.ML.OnnxRuntime 1.24.4](https://www.nuget.org/packages/Microsoft.ML.OnnxRuntime/1.24.4) |
| CTranslate2 | MIT, OpenNMT contributors. LocalCaption includes the standalone arm64 CPU dylib from the official wheel, plus its license. [CTranslate2 v4.6.3](https://github.com/OpenNMT/CTranslate2/tree/v4.6.3) |
| SentencePiece | Apache-2.0, Google and contributors. [SentencePiece v0.2.1](https://github.com/google/sentencepiece/tree/v0.2.1) |
| SQLite | Public domain. LocalCaption links the library supplied with macOS. [SQLite copyright notice](https://sqlite.org/copyright.html) |

If you distribute the downloaded weights, include the corresponding notices and attribution. The standard packaging script keeps weights outside the app bundle.
