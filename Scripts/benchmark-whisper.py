#!/usr/bin/env python3
"""Compare Whisper artifacts through LocalCaption's native bridge on Apple Silicon."""

import argparse
from array import array
import ctypes as c
import json
import math
from pathlib import Path
import random
import re
import resource
import statistics
import subprocess
import sys
import time
import wave


ROOT = Path(__file__).resolve().parents[1]
RATE = 16_000


def read_wave(path):
    with wave.open(str(path), "rb") as audio:
        if (audio.getnchannels(), audio.getsampwidth(), audio.getframerate()) != (1, 2, RATE):
            raise ValueError(f"Expected mono 16 kHz signed 16-bit PCM in {path}")
        samples = array("h")
        samples.frombytes(audio.readframes(audio.getnframes()))
    return [value / 32768 for value in samples]


def synthesize(folder, name, voice, rate, text):
    aiff = folder / f"{name}.aiff"
    wav = folder / f"{name}.wav"
    subprocess.run(["/usr/bin/say", "-v", voice, "-r", str(rate), "-o", str(aiff), text], check=True)
    subprocess.run(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(wav)],
                   check=True)
    return read_wave(wav)


def save_wave(path, samples):
    pcm = array("h", (round(max(-1, min(32767 / 32768, value)) * 32768) for value in samples))
    with wave.open(str(path), "wb") as audio:
        audio.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
        audio.writeframes(pcm.tobytes())


def prepare_fixtures(folder, microphone):
    folder.mkdir(parents=True, exist_ok=True)
    existing = ROOT / "Tests/CaptionCoreTests/Fixtures"
    english = "Today we are testing local speech transcription. The microphone and system audio are working together."
    russian = "Сегодня мы проверяем распознавание речи. Микрофон и системный звук работают одновременно."
    clips = [
        ("en-conversation", "en", english, read_wave(existing / "en.wav")),
        ("ru-conversation", "ru", russian, read_wave(existing / "ru.wav")),
    ]
    prompts = [
        ("en-technical", "en", "Samantha", 170,
         "The compiler uses a thread pool and reuses a memory buffer. We measure latency and throughput on each device."),
        ("ru-technical", "ru", "Milena", 165,
         "Компилятор распределяет задачи между потоками. Измерьте задержку, пропускную способность и нагрузку на процессор."),
        ("en-fast", "en", "Samantha", 265,
         "We were already running late when the train arrived, so we took the first two seats near the door."),
        ("en-irish", "en", "Moira", 175,
         "We walked past the market in the morning and met our friends just before it started raining."),
    ]
    for name, language, voice, rate, reference in prompts:
        clips.append((name, language, reference, synthesize(folder, name, voice, rate, reference)))
    parts = ["I think", "we should", "consider another approach"]
    slow = []
    for index, part in enumerate(parts):
        slow.extend(synthesize(folder, f"slow-part-{index}", "Samantha", 135, part))
        if index < len(parts) - 1:
            slow.extend([0] * (RATE * 8 // 10))
    clips.append(("en-slow", "en", " ".join(parts), slow))
    clips.append(("en-quiet", "en", english, [sample * 0.04 for sample in read_wave(existing / "en.wav")]))
    commands = ["yes", "no", "stop", "yes", "stop", "no"]
    noise = random.Random(573)
    noisy = []
    for command in commands:
        noisy.extend(sample + noise.uniform(-0.012, 0.012) for sample in read_wave(microphone / f"{command}.wav"))
    clips.append(("en-noisy-microphone", "en", " ".join(commands), noisy))
    clips.append(("en-video", "en",
                  "And so my fellow Americans ask not what your country can do for you. Ask what you can do for your country.",
                  read_wave(ROOT / ".deps/whisper/samples/jfk.wav")))

    manifest = []
    for name, language, reference, samples in clips:
        path = folder / f"{name}.wav"
        save_wave(path, samples)
        manifest.append({"name": name, "language": language, "reference": reference, "path": path.name})
    (folder / "fixtures.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")


def normalized_words(text):
    return re.findall(r"[^\W_]+", text.casefold(), flags=re.UNICODE)


def edit_count(reference, candidate):
    row = list(range(len(candidate) + 1))
    for i, expected in enumerate(reference, 1):
        next_row = [i]
        for j, actual in enumerate(candidate, 1):
            next_row.append(min(row[j] + 1, next_row[j - 1] + 1, row[j - 1] + (expected != actual)))
        row = next_row
    return row[-1]


def native_library():
    lib = c.CDLL(str(ROOT / ".deps/native/libcaption_inference.dylib"))
    pcm = c.POINTER(c.c_float)
    error = c.POINTER(c.c_char_p)
    signatures = [
        ("lc_whisper_has_metal", [], c.c_bool),
        ("lc_whisper_open", [c.c_char_p, c.c_bool, error], c.c_void_p),
        ("lc_whisper_run", [c.c_void_p, pcm, c.c_int, c.c_char_p, c.c_char_p, c.c_int, c.c_int, c.c_bool, error], c.c_bool),
        ("lc_whisper_language", [c.c_void_p], c.c_char_p),
        ("lc_whisper_count", [c.c_void_p], c.c_int),
        ("lc_whisper_text", [c.c_void_p, c.c_int], c.c_char_p),
        ("lc_whisper_close", [c.c_void_p], None),
        ("lc_string_free", [c.c_char_p], None),
    ]
    for name, arguments, result in signatures:
        function = getattr(lib, name)
        function.argtypes = arguments
        function.restype = result
    return lib


def measure(model, folder, repeats, beam):
    lib = native_library()
    manifest = json.loads((folder / "fixtures.json").read_text(encoding="utf-8"))
    for fixture in manifest:
        samples = read_wave(folder / fixture["path"])
        fixture["pcm"] = (c.c_float * len(samples))(*samples)
    error = c.c_char_p()

    def check(success):
        if not success:
            message = error.value.decode() if error.value else "Whisper failed"
            lib.lc_string_free(error)
            raise RuntimeError(message)

    start = time.perf_counter()
    check(lib.lc_whisper_has_metal())
    messages = []
    log_type = c.CFUNCTYPE(None, c.c_int, c.c_char_p, c.c_void_p)
    logger = log_type(lambda _, message, unused: messages.append(message.decode(errors="replace")))
    lib.whisper_log_set.argtypes = [log_type, c.c_void_p]
    lib.whisper_log_set.restype = None
    lib.whisper_log_set(logger, None)
    handle = lib.lc_whisper_open(str(model).encode(), True, c.byref(error))
    check(handle)
    load = time.perf_counter() - start

    def recognize(pcm):
        start = time.perf_counter()
        check(lib.lc_whisper_run(handle, pcm, len(pcm), b"auto", None, 4, beam, False, c.byref(error)))
        elapsed = time.perf_counter() - start
        detected = lib.lc_whisper_language(handle).decode()
        text = " ".join(lib.lc_whisper_text(handle, i).decode().strip() for i in range(lib.lc_whisper_count(handle)))
        return elapsed, detected, text

    try:
        metal = next((line.strip() for line in messages if "using Metal backend" in line), None)
        if metal is None:
            raise RuntimeError("Native Whisper did not report a Metal backend")
        device_weights = next(line.strip() for line in messages if "Metal total size" in line)
        warmup, _, _ = recognize(manifest[0]["pcm"])
        rows = []
        timings = []
        for fixture in manifest:
            expected = normalized_words(fixture["reference"])
            samples = fixture["pcm"]
            runs = [recognize(samples) for _ in range(repeats)]
            elapsed = [seconds for seconds, _, _ in runs]
            timings.extend(elapsed)
            _, detected, text = runs[0]
            actual = normalized_words(text)
            rows.append({
                "name": fixture["name"], "language": detected, "expected_language": fixture["language"],
                "reference": fixture["reference"], "hypothesis": text, "audio_seconds": len(samples) / RATE,
                "mean_seconds": statistics.mean(elapsed), "word_errors": edit_count(expected, actual),
                "words": len(expected), "character_errors": edit_count("".join(expected), "".join(actual)),
                "characters": len("".join(expected)),
            })
        totals = {name: sum(row[name] for row in rows)
                  for name in ("audio_seconds", "word_errors", "words", "character_errors", "characters")}
        print(json.dumps({
            "model": model.name, "metal": metal, "device_weights": device_weights, "beam": beam,
            "load_seconds": load, "first_inference_seconds": warmup, "mean_seconds": statistics.mean(timings),
            "p95_seconds": sorted(timings)[math.ceil(0.95 * len(timings)) - 1],
            "rtf": sum(timings) / (totals["audio_seconds"] * repeats),
            "peak_rss_bytes": resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
            "wer": totals["word_errors"] / totals["words"], "cer": totals["character_errors"] / totals["characters"],
            "audio_seconds": totals["audio_seconds"], "calls": len(timings), "fixtures": rows
        }, ensure_ascii=False, indent=2))
    finally:
        lib.lc_whisper_close(handle)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixtures", type=Path, help="Fixture work directory containing fixtures.json")
    parser.add_argument("--prepare", type=Path, metavar="MICROPHONE_DIR",
                        help="Create fixtures with local macOS voices and the specified Speech Commands WAV directory")
    parser.add_argument("--model", type=Path, help="Measure one GGML model in this process")
    parser.add_argument("--repeats", type=int, default=5)
    parser.add_argument("--beam", type=int, choices=[1, 4], default=4)
    args = parser.parse_args()
    if args.prepare:
        prepare_fixtures(args.fixtures, args.prepare)
    elif args.model and args.repeats > 0 and sys.platform == "darwin":
        measure(args.model, args.fixtures, args.repeats, args.beam)
    else:
        parser.error("Use --prepare or run --model with a positive repeat count on macOS")


if __name__ == "__main__":
    main()
