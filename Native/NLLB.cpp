#include "inference.h"
#include "ctranslate2/translator.h"
#include "sentencepiece_processor.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <filesystem>
#include <memory>
#include <new>
#include <stdexcept>
#include <string>
#include <string_view>
#include <vector>

struct lc_nllb {
    sentencepiece::SentencePieceProcessor tokenizer;
    std::unique_ptr<ctranslate2::Translator> translator;
};

struct lc_cancel_flag { std::atomic<bool> canceled{false}; };

static void set_error(char **out, const char *message) {
    if (out) *out = strdup(message);
}

lc_nllb *lc_nllb_open(const char *folder, int threads, char **error) {
    try {
        auto engine = std::make_unique<lc_nllb>();
        const auto path = std::filesystem::path(folder);
        const auto tokenizer_status = engine->tokenizer.Load((path / "sentencepiece.bpe.model").string());
        if (!tokenizer_status.ok())
            throw std::runtime_error("NLLB SentencePiece tokenizer could not be loaded. Reimport the model folder.");
        ctranslate2::ReplicaPoolConfig pool;
        pool.num_threads_per_replica = std::clamp(threads, 1, 4);
        pool.max_queued_batches = 1;
        engine->translator = std::make_unique<ctranslate2::Translator>(
            path.string(), ctranslate2::Device::CPU, ctranslate2::ComputeType::INT8,
            std::vector<int>{0}, false, pool);
        return engine.release();
    } catch (const std::bad_alloc &) {
        set_error(error, "There is not enough memory to load NLLB-200.");
    } catch (const std::exception &exception) {
        set_error(error, exception.what());
    }
    return nullptr;
}

void lc_nllb_close(lc_nllb *engine) { delete engine; }
lc_cancel_flag *lc_cancel_flag_open(void) { return new (std::nothrow) lc_cancel_flag; }
void lc_cancel_flag_set(lc_cancel_flag *flag) { if (flag) flag->canceled.store(true); }
void lc_cancel_flag_close(lc_cancel_flag *flag) { delete flag; }

static bool language_token(std::string_view value) {
    const auto lowercase = [](char c) { return c >= 'a' && c <= 'z'; };
    return value.size() == 8 && value[3] == '_' && value[4] >= 'A' && value[4] <= 'Z'
        && std::all_of(value.begin(), value.begin() + 3, lowercase)
        && std::all_of(value.begin() + 5, value.end(), lowercase);
}

char *lc_nllb_translate(lc_nllb *engine, const char *text, const char *source, const char *target,
                        int timeout_ms, const lc_cancel_flag *flag, char **error) {
    try {
        if (!engine || !text || !*text || !source || !target || !language_token(source)
            || !language_token(target) || std::strcmp(source, target) == 0)
            throw std::invalid_argument("NLLB requires non-empty text and a supported translation direction.");

        using clock = std::chrono::steady_clock;
        const auto deadline = clock::now() + std::chrono::milliseconds(timeout_ms);
        const auto canceled = [flag] { return flag && flag->canceled.load(); };
        if (canceled()) throw std::runtime_error("NLLB translation was canceled.");

        std::vector<std::string> tokens;
        const auto encoded = engine->tokenizer.Encode(text, &tokens);
        if (!encoded.ok() || tokens.empty())
            throw std::runtime_error("NLLB could not tokenize the source text.");
        constexpr size_t max_input = 256;
        if (tokens.size() + 2 > max_input)
            throw std::runtime_error("This phrase exceeds NLLB's 256-token input limit.");
        // The pinned tokenizer uses the modern NLLB layout: source language, pieces, EOS.
        tokens.insert(tokens.begin(), source);
        tokens.emplace_back("</s>");

        ctranslate2::TranslationOptions options;
        options.beam_size = 1;  // Allows a stop callback at each generated token.
        options.max_input_length = max_input;
        options.max_decoding_length = 256;
        options.no_repeat_ngram_size = 3;
        options.disable_unk = true;
        options.return_end_token = true;
        options.callback = [&](ctranslate2::GenerationStepResult) { return canceled() || clock::now() >= deadline; };
        const auto results = engine->translator->translate_batch({tokens},
            std::vector<std::vector<std::string>>{{target}}, options);
        if (canceled()) throw std::runtime_error("NLLB translation was canceled.");
        if (clock::now() >= deadline) throw std::runtime_error("NLLB translation timed out.");
        const auto &output = results.at(0).output();
        if (output.size() < 3 || output.front() != target || output.back() != "</s>")
            throw std::runtime_error("NLLB did not return a complete translation for the selected language.");

        std::string decoded;
        const std::vector<std::string> pieces(output.begin() + 1, output.end() - 1);
        if (!engine->tokenizer.Decode(pieces, &decoded).ok() || decoded.empty())
            throw std::runtime_error("NLLB returned empty or invalid text.");
        auto result = strdup(decoded.c_str());
        if (!result) throw std::bad_alloc();
        return result;
    } catch (const std::bad_alloc &) {
        set_error(error, "There is not enough memory to finish NLLB translation.");
    } catch (const std::exception &exception) {
        set_error(error, exception.what());
    }
    return nullptr;
}
