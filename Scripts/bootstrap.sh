#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -m)" != arm64 ]]; then
    echo "Build on an Apple Silicon Mac using an arm64 shell." >&2
    exit 1
fi
mkdir -p .deps/assets .deps/native

fetch() {
    local url="$1" file="$2" expected="$3"
    if [[ ! -f "$file" ]] || ! printf '%s  %s\n' "$expected" "$file" | shasum -a 256 -c --status; then
        curl -fLSs --retry 2 "$url" -o "$file.partial"
        printf '%s  %s\n' "$expected" "$file.partial" | shasum -a 256 -c
        mv "$file.partial" "$file"
    fi
}

if command -v cmake >/dev/null; then
    cmake="$(command -v cmake)"
else
    fetch https://github.com/Kitware/CMake/releases/download/v3.31.8/cmake-3.31.8-macos-universal.tar.gz .deps/assets/cmake.tar.gz d1449f969c54d5c00886d5b643340d493dfb3c81cb39ee29b35453395c11ebf7
    cmake="$PWD/.deps/cmake-3.31.8-macos-universal/CMake.app/Contents/bin/cmake"
    [[ -x "$cmake" ]] || tar -xzf .deps/assets/cmake.tar.gz -C .deps
fi
fetch https://codeload.github.com/ggml-org/whisper.cpp/tar.gz/refs/tags/v1.8.3 .deps/assets/whisper.tar.gz 870ba21409cdf66697dc4db15ebdb13bc67037d76c7cc63756c81471d8f1731a
fetch https://codeload.github.com/google/sentencepiece/tar.gz/refs/tags/v0.2.1 .deps/assets/sentencepiece.tar.gz c1a59e9259c9653ad0ade653dadff074cd31f0a6ff2a11316f67bee4189a8f1b
fetch https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime/1.24.4/microsoft.ml.onnxruntime.1.24.4.nupkg .deps/assets/onnxruntime.zip 4b978d5065b85e7004b6c6f60ca494bd978fbe6836cbf0a0b52d82b61ab99638
fetch https://codeload.github.com/OpenNMT/CTranslate2/tar.gz/refs/tags/v4.6.3 .deps/assets/ctranslate2-4.6.3.tar.gz 23def7d28198aa6c81af3377306e24d05dc23d7646770ae59c7310cd9372b467
# The official arm64 wheel publishes the standalone CPU dylib. The app uses just that library.
ct2_wheel=.deps/assets/ctranslate2-4.6.3-cp313-cp313-macosx_11_0_arm64.whl
fetch https://files.pythonhosted.org/packages/12/a8/e4e254a019195bfa4dd97c382e66f9b186ace42d495cb20e179bb8d7528a/ctranslate2-4.6.3-cp313-cp313-macosx_11_0_arm64.whl "$ct2_wheel" 95ff7fdd70bd64d40834cb6ba82bcec15228a9f34dff587babd03a1c3064c302
mkdir -p .deps/ctranslate2
tar -xzf .deps/assets/ctranslate2-4.6.3.tar.gz -C .deps/ctranslate2 --strip-components 1
ct2_library=libctranslate2.4.6.3.dylib
ct2_stage="$(mktemp -d .deps/ctranslate2/.runtime.XXXXXXXX)"
trap 'rm -rf "$ct2_stage"' EXIT
unzip -jq "$ct2_wheel" "ctranslate2/.dylibs/$ct2_library" -d "$ct2_stage"
install_name_tool -id "@rpath/$ct2_library" "$ct2_stage/$ct2_library"
codesign --force --sign - "$ct2_stage/$ct2_library"
mv "$ct2_stage/$ct2_library" ".deps/native/$ct2_library"

for dep in whisper sentencepiece; do
    if [[ ! -f ".deps/$dep/CMakeLists.txt" ]]; then
        mkdir -p ".deps/$dep"
        tar -xzf ".deps/assets/$dep.tar.gz" -C ".deps/$dep" --strip-components 1
    fi
done
mkdir -p .deps/onnxruntime/{include,lib,notices}
unzip -joq .deps/assets/onnxruntime.zip 'build/native/include/*.h' -d .deps/onnxruntime/include
unzip -joq .deps/assets/onnxruntime.zip 'runtimes/osx-arm64/native/libonnxruntime.dylib' -d .deps/onnxruntime/lib
unzip -joq .deps/assets/onnxruntime.zip 'LICENSE*' 'ThirdPartyNotices*' -d .deps/onnxruntime/notices
cp .deps/onnxruntime/lib/libonnxruntime.dylib .deps/native/libonnxruntime.1.24.4.dylib

common=(-DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_OSX_ARCHITECTURES=arm64)
"$cmake" -S .deps/whisper -B .deps/whisper-build "${common[@]}" -DBUILD_SHARED_LIBS=OFF \
    -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_SERVER=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_OPENMP=OFF -DGGML_NATIVE=OFF
"$cmake" --build .deps/whisper-build --parallel "${LOCALCAPTION_BUILD_JOBS:-6}"
"$cmake" -S .deps/sentencepiece -B .deps/sp-build "${common[@]}" -DSPM_ENABLE_SHARED=OFF -DSPM_ENABLE_TCMALLOC=OFF -DSPM_BUILD_TEST=OFF
"$cmake" --build .deps/sp-build --target sentencepiece-static --parallel "${LOCALCAPTION_BUILD_JOBS:-6}"
"$cmake" -S Native -B .deps/native-build "${common[@]}" -DCMAKE_LIBRARY_OUTPUT_DIRECTORY="$PWD/.deps/native"
"$cmake" --build .deps/native-build --parallel "${LOCALCAPTION_BUILD_JOBS:-6}"
