#!/usr/bin/env python3
"""Generate a local, annotated speaker fixture using macOS voices."""

import argparse
from array import array
import json
import math
from pathlib import Path
import random
import subprocess
import wave


RATE = 16_000


def speech(directory, index, voice, phrase):
    aiff = directory / f"voice-{index}.aiff"
    wav = directory / f"voice-{index}.wav"
    subprocess.run(["/usr/bin/say", "-v", voice, "-r", "170", "-o", str(aiff), phrase], check=True)
    subprocess.run(["/usr/bin/afconvert", "-f", "WAVE", "-d", "LEI16@16000", "-c", "1", str(aiff), str(wav)],
                   check=True)
    with wave.open(str(wav), "rb") as source:
        samples = array("h")
        samples.frombytes(source.readframes(source.getnframes()))
    audible = [index for index, value in enumerate(samples) if abs(value) > 320]
    if not audible:
        raise ValueError(f"Voice fixture is silent: {voice}")
    start = max(0, audible[0] - 160)
    end = audible[-1] + 160
    return [value / 32768 for value in samples[start:end]]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    directory = parser.parse_args().directory
    directory.mkdir(parents=True, exist_ok=True)
    turns = [
        (0.5, "A", "Samantha", "Good morning. We are testing a meeting transcript on this computer.", 0.0),
        (5.0, "B", "Daniel", "Hello. Please leave enough time for the speakers to answer each question.", 0.0),
        (9.4, "A", "Samantha", "I think we should", 0.0),
        (11.3, "A", "Samantha", "consider another approach.", 0.0),
        (13.5, "B", "Daniel", "Yes.", 0.0),
        (14.8, "C", "Milena", "Давайте проверим запись. Теперь я буду говорить на русском языке.", 0.0),
        (20.3, "B", "Daniel", "The listener can hear both voices during this part of the interview.", 0.0),
        (21.3, "A", "Samantha", "I started to answer while the question was still being asked.", 0.0),
        (26.0, "D", "Flo (English (US))", "Thanks for the introduction. I will discuss a different part of the research project.", 0.0),
        (31.3, "D", "Flo (English (US))", "This recording has some background noise, but you should still be able to hear me clearly.", 0.012),
        (51.0, "A", "Samantha", "I am back after a long quiet pause. Please keep the same speaker label.", 0.0),
        (55.4, "C", "Milena", "Мы вернулись и продолжаем говорить. Проверим имя каждого участника.", 0.0),
    ]
    audio = [0.0] * (63 * RATE)
    reference = []
    noise = random.Random(127)
    for i, (start, speaker, voice, phrase, noise_level) in enumerate(turns):
        samples = speech(directory, i, voice, phrase)
        offset = round(start * RATE)
        for sample, value in enumerate(samples):
            audio[offset + sample] += value * 0.72 + noise.uniform(-noise_level, noise_level)
        reference.append({"speaker": speaker, "start": start, "end": start + len(samples) / RATE})
    for i in range(41 * RATE, 45 * RATE):
        time = (i - 41 * RATE) / RATE
        envelope = max(0, min(1, time * 10, (4 - time) * 10))
        audio[i] += envelope * sum(math.sin(2 * math.pi * frequency * time) for frequency in (220, 277.18, 329.63)) * 0.02
    pcm = array("h", (round(max(-0.999, min(0.999, value)) * 32768) for value in audio))
    with wave.open(str(directory / "speakers.wav"), "wb") as target:
        target.setparams((1, 2, RATE, 0, "NONE", "not compressed"))
        target.writeframes(pcm.tobytes())
    (directory / "speakers.json").write_text(json.dumps(reference, indent=2) + "\n")


if __name__ == "__main__":
    main()
