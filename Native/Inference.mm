#import <Foundation/Foundation.h>
#include <os/log.h>
#include "ggml-metal.h"
#include "inference.h"
#include "whisper.h"
#include "sentencepiece_processor.h"
#include "onnxruntime_cxx_api.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

struct lc_whisper { whisper_context *context; };
struct lc_vad { whisper_vad_context *context; };

static void set_error(char **out, const char *message) {
    if (out) *out = strdup(message);
}

// whisper.cpp changes a shared ggml log callback while initializing its backends.
static std::mutex backend_initialization;

static void configure_whisper_logging() {
    static const bool configured = [] {
        whisper_log_set([](ggml_log_level level, const char *message, void *) {
            if (level >= GGML_LOG_LEVEL_WARN) {
                static os_log_t log = os_log_create("local.caption", "whisper-native");
                os_log_with_type(log, level >= GGML_LOG_LEVEL_ERROR ? OS_LOG_TYPE_ERROR : OS_LOG_TYPE_DEFAULT,
                                 "%{private}s", message);
            }
        }, nullptr);
        return true;
    }();
    (void)configured;
}

bool lc_whisper_has_metal(void) {
    @autoreleasepool {
        try {
            std::lock_guard<std::mutex> lock(backend_initialization);
            configure_whisper_logging();
            const auto backend = ggml_backend_metal_init();
            if (!backend) return false;
            ggml_backend_free(backend);
            return true;
        } catch (const std::exception &error) {
            os_log_error(OS_LOG_DEFAULT, "LocalCaption Metal probe failed: %{private}s", error.what());
            return false;
        }
    }
}

lc_whisper *lc_whisper_open(const char *path, bool use_gpu, char **error) {
    @autoreleasepool {
        try {
            std::lock_guard<std::mutex> lock(backend_initialization);
            configure_whisper_logging();
            auto options = whisper_context_default_params();
            options.use_gpu = use_gpu;
            std::unique_ptr<whisper_context, decltype(&whisper_free)> context(
                whisper_init_from_file_with_params(path, options), whisper_free);
            if (!context) {
                set_error(error, "Whisper could not load the model. Reinstall it in Settings.");
                return nullptr;
            }
            return new lc_whisper{context.release()};
        } catch (const std::exception &exception) {
            set_error(error, exception.what());
            return nullptr;
        }
    }
}

void lc_whisper_close(lc_whisper *engine) {
    @autoreleasepool {
        if (!engine) return;
        whisper_free(engine->context);
        delete engine;
    }
}

bool lc_whisper_run(lc_whisper *engine, const float *samples, int count,
                    const char *language, const char *prompt,
                    int threads, int beam, bool partial, char **error) {
    @autoreleasepool {
        auto options = whisper_full_default_params(
            beam > 1 ? WHISPER_SAMPLING_BEAM_SEARCH : WHISPER_SAMPLING_GREEDY);
        options.n_threads = threads;
        options.beam_search.beam_size = beam;
        options.greedy.best_of = 1;
        options.language = language;
        options.translate = false;
        options.no_context = true;
        options.initial_prompt = prompt;
        options.print_progress = false;
        options.print_realtime = false;
        options.print_special = false;
        options.print_timestamps = false;
        options.temperature_inc = partial ? 0.0f : 0.2f;
        if (whisper_full(engine->context, options, samples, count) == 0) return true;
        set_error(error, "Whisper inference failed. Check the model and acceleration settings.");
        return false;
    }
}

int lc_whisper_count(lc_whisper *engine) { return whisper_full_n_segments(engine->context); }
const char *lc_whisper_language(lc_whisper *engine) {
    const int id = whisper_full_lang_id(engine->context);
    return id >= 0 ? whisper_lang_str(id) : nullptr;
}
const char *lc_whisper_text(lc_whisper *engine, int index) {
    return whisper_full_get_segment_text(engine->context, index);
}
double lc_whisper_start(lc_whisper *engine, int index) {
    return whisper_full_get_segment_t0(engine->context, index) / 100.0;
}
double lc_whisper_end(lc_whisper *engine, int index) {
    return whisper_full_get_segment_t1(engine->context, index) / 100.0;
}
float lc_whisper_no_speech(lc_whisper *engine, int index) {
    return whisper_full_get_segment_no_speech_prob(engine->context, index);
}

lc_vad *lc_vad_open(const char *path) {
    try {
        std::lock_guard<std::mutex> lock(backend_initialization);
        configure_whisper_logging();
        auto options = whisper_vad_default_context_params();
        options.n_threads = 1;
        options.use_gpu = false;
        std::unique_ptr<whisper_vad_context, decltype(&whisper_vad_free)> context(
            whisper_vad_init_from_file_with_params(path, options), whisper_vad_free);
        return context ? new lc_vad{context.release()} : nullptr;
    } catch (const std::exception &exception) {
        os_log_error(OS_LOG_DEFAULT, "LocalCaption VAD initialization failed: %{private}s", exception.what());
        return nullptr;
    }
}

float lc_vad_probability(lc_vad *engine, const float *samples, int count) {
    if (!whisper_vad_detect_speech(engine->context, samples, count)) return -1;
    const float *probs = whisper_vad_probs(engine->context);
    const int size = whisper_vad_n_probs(engine->context);
    if (!probs || size == 0) return -1;
    return *std::max_element(probs + size / 2, probs + size);
}

void lc_vad_close(lc_vad *engine) {
    if (!engine) return;
    whisper_vad_free(engine->context);
    delete engine;
}

using Tensors = std::map<std::string, Ort::Value>;

class Graph {
    Ort::Session session;
    std::vector<std::string> inputs, outputs;
public:
    Graph(Ort::Env &environment, const std::string &path, Ort::SessionOptions &options)
        : session(environment, path.c_str(), options) {
        Ort::AllocatorWithDefaultOptions allocator;
        for (size_t i = 0; i < session.GetInputCount(); ++i)
            inputs.emplace_back(session.GetInputNameAllocated(i, allocator).get());
        for (size_t i = 0; i < session.GetOutputCount(); ++i)
            outputs.emplace_back(session.GetOutputNameAllocated(i, allocator).get());
    }

    Tensors run(const std::map<std::string, const OrtValue *> &available) {
        std::vector<const char *> names, resultNames;
        std::vector<const OrtValue *> values;
        for (const auto &input : inputs) {
            names.push_back(input.c_str());
            auto iterator = available.find(input);
            if (iterator == available.end()) throw std::runtime_error("Missing Marian input " + input);
            values.push_back(iterator->second);
        }
        for (const auto &output : outputs) resultNames.push_back(output.c_str());
        std::vector<OrtValue *> result(outputs.size(), nullptr);
        auto status = Ort::GetApi().Run(session, nullptr, names.data(), values.data(), values.size(),
                                       resultNames.data(), resultNames.size(), result.data());
        Tensors tensors;
        for (size_t i = 0; i < outputs.size(); ++i) tensors.emplace(outputs[i], Ort::Value(result[i]));
        Ort::ThrowOnError(status);
        return tensors;
    }
};

static Ort::Env &translation_environment() {
    static Ort::Env environment = [] {
        Ort::Env configured(ORT_LOGGING_LEVEL_ERROR, "LocalCaption");
        configured.DisableTelemetryEvents();
        return configured;
    }();
    return environment;
}

static NSDictionary *json_dictionary(const std::string &path) {
    NSString *filename = [NSString stringWithUTF8String:path.c_str()];
    NSData *data = [NSData dataWithContentsOfFile:filename];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![json isKindOfClass:NSDictionary.class]) throw std::runtime_error("Invalid Marian file " + path);
    return json;
}

struct lc_translator {
    sentencepiece::SentencePieceProcessor source, target;
    std::map<std::string, int64_t> vocab;
    std::map<int64_t, std::string> reverse;
    int64_t eos, pad, unknown;
    std::unique_ptr<Graph> encoder, decoder, cached;

    explicit lc_translator(const std::string &folder) {
        auto config = json_dictionary(folder + "/config.json");
        eos = [config[@"eos_token_id"] longLongValue];
        pad = [config[@"decoder_start_token_id"] longLongValue];
        auto words = json_dictionary(folder + "/vocab.json");
        unknown = [words[@"<unk>"] longLongValue];
        for (NSString *token in words) {
            const int64_t id = [words[token] longLongValue];
            vocab.emplace(token.UTF8String, id);
            reverse.emplace(id, token.UTF8String);
        }
        if (eos == pad || words[@"<unk>"] == nil ||
            !source.Load(folder + "/source.spm").ok() || !target.Load(folder + "/target.spm").ok()) {
            throw std::runtime_error("Invalid Marian vocabulary or tokenizer. Reinstall this translation model.");
        }
        Ort::SessionOptions options;
        options.SetIntraOpNumThreads(3);
        options.SetInterOpNumThreads(1);
        options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
        auto &env = translation_environment();
        encoder = std::make_unique<Graph>(env, folder + "/encoder_model_quantized.onnx", options);
        decoder = std::make_unique<Graph>(env, folder + "/decoder_model_quantized.onnx", options);
        cached = std::make_unique<Graph>(env, folder + "/decoder_with_past_model_quantized.onnx", options);
    }

    std::string translate(const std::string &text) {
        std::vector<std::string> pieces;
        if (!source.Encode(text, &pieces).ok() || pieces.empty())
            throw std::runtime_error("Marian could not tokenize this phrase.");
        std::string translated;
        constexpr size_t chunk_size = 192;
        for (size_t offset = 0; offset < pieces.size(); offset += chunk_size) {
            const auto end = std::min(pieces.size(), offset + chunk_size);
            auto next = translate_pieces(pieces, offset, end);
            if (!translated.empty()) translated += " ";
            translated += next;
        }
        return translated;
    }

    std::string translate_pieces(const std::vector<std::string> &pieces, size_t start, size_t end) {
        std::vector<int64_t> ids;
        for (size_t i = start; i < end; ++i) {
            auto match = vocab.find(pieces[i]);
            ids.push_back(match == vocab.end() ? unknown : match->second);
        }
        ids.push_back(eos);
        std::vector<int64_t> mask(ids.size(), 1);
        const int64_t shape[] = {1, static_cast<int64_t>(ids.size())};
        auto memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
        auto ids_tensor = Ort::Value::CreateTensor<int64_t>(memory, ids.data(), ids.size(), shape, 2);
        auto mask_tensor = Ort::Value::CreateTensor<int64_t>(memory, mask.data(), mask.size(), shape, 2);
        auto encoded = encoder->run({{"input_ids", ids_tensor}, {"attention_mask", mask_tensor}});

        int64_t token = pad;
        const int64_t token_shape[] = {1, 1};
        auto token_tensor = Ort::Value::CreateTensor<int64_t>(memory, &token, 1, token_shape, 2);
        const std::map<std::string, const OrtValue *> base = {
            {"input_ids", token_tensor},
            {"encoder_attention_mask", mask_tensor},
            {"encoder_hidden_states", encoded.at("last_hidden_state")}
        };
        Tensors cache;
        std::vector<std::string> result;
        for (size_t step = 0; step < std::min<size_t>(320, ids.size() * 3 + 24); ++step) {
            auto request = base;
            for (const auto &[name, tensor] : cache) request.emplace(name, tensor);
            auto decoded = (step == 0 ? decoder : cached)->run(request);
            const auto &logits = decoded.at("logits");
            const auto count = logits.GetTensorTypeAndShapeInfo().GetElementCount();
            const auto *values = logits.GetTensorData<float>();
            if (count == 0) throw std::runtime_error("Marian returned empty logits.");
            int64_t best = eos;
            for (size_t i = 0; i < count; ++i) {
                if (i != static_cast<size_t>(pad) && values[i] > values[best]) best = static_cast<int64_t>(i);
            }
            if (best == eos && step > 0) break;
            if (best == eos) throw std::runtime_error("Marian returned an empty translation.");
            if (auto match = reverse.find(best); match != reverse.end()) result.push_back(match->second);
            token = best;
            for (auto &[name, tensor] : decoded) {
                if (name.rfind("present.", 0) == 0) {
                    const auto key = "past_key_values." + name.substr(8);
                    if (step == 0 || key.find(".encoder.") == std::string::npos) {
                        cache.insert_or_assign(key, std::move(tensor));
                    }
                }
            }
        }
        std::string output;
        if (result.empty() || !target.Decode(result, &output).ok() || output.empty())
            throw std::runtime_error("Marian could not decode this translation.");
        return output;
    }
};

lc_translator *lc_translator_open(const char *folder, char **error) {
    @autoreleasepool {
        try {
            return new lc_translator(folder);
        } catch (const std::exception &exception) {
            set_error(error, exception.what());
            return nullptr;
        }
    }
}

char *lc_translate(lc_translator *engine, const char *text, char **error) {
    try {
        return strdup(engine->translate(text).c_str());
    } catch (const std::exception &exception) {
        set_error(error, exception.what());
        return nullptr;
    }
}
void lc_translator_close(lc_translator *engine) { delete engine; }
void lc_string_free(char *string) { free(string); }
