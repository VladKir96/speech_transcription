#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct lc_whisper lc_whisper;
typedef struct lc_vad lc_vad;
typedef struct lc_silero_onnx lc_silero_onnx;
typedef struct lc_translator lc_translator;
typedef struct lc_nllb lc_nllb;
typedef struct lc_cancel_flag lc_cancel_flag;

lc_whisper *lc_whisper_open(const char *path, bool use_gpu, char **error);
void lc_whisper_close(lc_whisper *engine);
bool lc_whisper_has_metal(void);
bool lc_whisper_run(lc_whisper *engine, const float *samples, int count,
                    const char *language, const char *prompt,
                    int threads, int beam, bool partial, char **error);
int lc_whisper_count(lc_whisper *engine);
const char *lc_whisper_language(lc_whisper *engine);
const char *lc_whisper_text(lc_whisper *engine, int index);
double lc_whisper_start(lc_whisper *engine, int index);
double lc_whisper_end(lc_whisper *engine, int index);
float lc_whisper_no_speech(lc_whisper *engine, int index);

lc_vad *lc_vad_open(const char *path);
float lc_vad_probability(lc_vad *engine, const float *samples, int count);
void lc_vad_close(lc_vad *engine);
lc_silero_onnx *lc_silero_onnx_open(const char *path, int sample_rate, char **error);
float lc_silero_onnx_probability(lc_silero_onnx *engine, const float *samples, int count, char **error);
void lc_silero_onnx_reset(lc_silero_onnx *engine);
void lc_silero_onnx_close(lc_silero_onnx *engine);

lc_translator *lc_translator_open(const char *folder, char **error);
char *lc_translate(lc_translator *engine, const char *text, char **error);
void lc_translator_close(lc_translator *engine);
lc_nllb *lc_nllb_open(const char *folder, int threads, char **error);
void lc_nllb_close(lc_nllb *engine);
lc_cancel_flag *lc_cancel_flag_open(void);
void lc_cancel_flag_set(lc_cancel_flag *flag);
void lc_cancel_flag_close(lc_cancel_flag *flag);
char *lc_nllb_translate(lc_nllb *engine, const char *text, const char *source, const char *target,
                        int timeout_ms, const lc_cancel_flag *flag, char **error);
void lc_string_free(char *string);

#ifdef __cplusplus
}
#endif
