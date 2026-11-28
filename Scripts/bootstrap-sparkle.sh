#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

version=2.10.1
digest=1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27
destination=.deps/sparkle
if [[ -x "$destination/bin/generate_appcast" && -f "$destination/.version" &&
      "$(cat "$destination/.version")" == "$version" ]]; then
    exit 0
fi

mkdir -p .deps/assets
stage="$(mktemp -d .deps/.sparkle.XXXXXXXX)"
trap 'rm -rf "$stage"' EXIT
archive=".deps/assets/Sparkle-$version.tar.xz"
if [[ ! -f "$archive" ]] || ! printf '%s  %s\n' "$digest" "$archive" | shasum -a 256 -c --status; then
    curl --fail --location --silent --show-error --retry 2 \
        "https://github.com/sparkle-project/Sparkle/releases/download/$version/Sparkle-$version.tar.xz" \
        -o "$stage/Sparkle.tar.xz"
    printf '%s  %s\n' "$digest" "$stage/Sparkle.tar.xz" | shasum -a 256 -c
    mv "$stage/Sparkle.tar.xz" "$archive"
fi
mkdir "$stage/distribution"
tar -xf "$archive" -C "$stage/distribution"
printf '%s\n' "$version" > "$stage/distribution/.version"
if [[ -d "$destination" ]]; then mv "$destination" "$stage/previous"; fi
mv "$stage/distribution" "$destination"
