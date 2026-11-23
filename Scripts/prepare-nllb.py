#!/usr/bin/env python3
"""Prepare LocalCaption's pinned NLLB model. Run with the documented conversion environment."""

import argparse
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import shutil
import tempfile
import urllib.request


CHECKPOINT = "facebook/nllb-200-distilled-600M"
REVISION = "b3bbac6cd67efa90e0fcbe4c882ec79cfd782a17"
INPUTS = {
    "config.json": "f9b4081d3d108e9d06532ea8d92b932c04ed3a15ff2f87e6982f8e14db51fbc5",
    "model.safetensors": "c26fea1b0788456e3e0d6dfd0165cacec798a0b6d957c9045a234826994dec41",
    "sentencepiece.bpe.model": "14bb8dfb35c0ffdea7bc01e56cea38b9e3d5efcdcb9c251d6b40538e1aab555a",
    "special_tokens_map.json": "992bd4ed610d644d6823081937bcc91bb8878dd556cea4ae5327f2480361330e",
    "tokenizer.json": "e316b82de11d0f951f370943b3c438311629547285129b0b81dadabd01bca665",
    "tokenizer_config.json": "d1aa8c3697d3e35674f97b5b7e9c99d22b010f528e80140257d97316be90d044",
}
VERSIONS = {
    "ctranslate2": "4.6.3",
    "torch": "2.9.1",
    "transformers": "4.57.6",
    "tokenizers": "0.22.2",
    "sentencepiece": "0.2.1",
    "huggingface-hub": "0.36.2",
    "safetensors": "0.8.0",
    "numpy": "2.5.5",
}


def digest(path):
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            hasher.update(block)
    return hasher.hexdigest()


def obtain_source(source, download):
    source.mkdir(parents=True, exist_ok=True)
    for name, expected in INPUTS.items():
        path = source / name
        if path.is_file() and digest(path) == expected:
            continue
        if not download:
            raise SystemExit(f"Missing or invalid input: {path}. Supply the pinned source or use --download.")
        url = f"https://huggingface.co/{CHECKPOINT}/resolve/{REVISION}/{name}?download=true"
        print(f"Downloading {name}", flush=True)
        with tempfile.NamedTemporaryFile(dir=source, delete=False) as stage:
            temporary = Path(stage.name)
        try:
            with urllib.request.urlopen(url, timeout=90) as upstream, temporary.open("wb") as destination:
                shutil.copyfileobj(upstream, destination, length=1024 * 1024)
            if digest(temporary) != expected:
                raise SystemExit(f"Unexpected SHA-256 for {name}")
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="folder for the verified Meta checkpoint")
    parser.add_argument("output", type=Path, help="new folder to import into LocalCaption")
    parser.add_argument("--download", action="store_true", help="fetch about 2.48 GB from Meta's Hugging Face repository")
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists():
        parser.error(f"output already exists: {output}")
    for package, expected in VERSIONS.items():
        if importlib.metadata.version(package) != expected:
            parser.error(f"the conversion requires {package}=={expected}")
    obtain_source(args.source.resolve(), args.download)

    # All framework inputs are loaded from the verified snapshot.
    os.environ["HF_HUB_OFFLINE"] = "1"
    os.environ["TRANSFORMERS_OFFLINE"] = "1"
    import torch
    from ctranslate2.converters import TransformersConverter

    torch.set_num_threads(2)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent) as staging:
        converted = Path(staging) / "assets"
        TransformersConverter(
            str(args.source.resolve()),
            copy_files=["sentencepiece.bpe.model", "tokenizer.json", "tokenizer_config.json", "special_tokens_map.json"],
        ).convert(str(converted), quantization="int8")
        metadata = {
            "checkpoint": CHECKPOINT,
            "revision": REVISION,
            "runtime": f"CTranslate2 {VERSIONS['ctranslate2']}",
            "quantization": "int8",
            "license": "CC BY-NC 4.0",
            "languages": {"en": "eng_Latn", "ru": "rus_Cyrl"},
        }
        (converted / "localcaption.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")

        catalog_path = Path(__file__).resolve().parents[1] / "Sources/CaptionCore/Resources/Models.json"
        model = next(item for item in json.loads(catalog_path.read_text()) if item["id"] == "nllb-200-600m")
        for asset in model["assets"]:
            path = converted / asset["name"]
            if path.stat().st_size != asset["bytes"] or digest(path) != asset["sha256"]:
                raise SystemExit(f"The converted {path.name} does not match this release's catalog.")
        converted.rename(output)
    print(f"Import this folder in Settings → Models: {output}")


if __name__ == "__main__":
    main()
