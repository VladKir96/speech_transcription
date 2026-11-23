#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -f .deps/native/libcaption_inference.dylib || ! -f .deps/native/libctranslate2.4.6.3.dylib ||
      Native/NLLB.cpp -nt .deps/native/libcaption_inference.dylib ||
      Native/Inference.mm -nt .deps/native/libcaption_inference.dylib ||
      Sources/CInference/inference.h -nt .deps/native/libcaption_inference.dylib ]]; then
    Scripts/bootstrap.sh
fi
source Scripts/swift-env.sh
configuration="${LOCALCAPTION_CONFIGURATION:-release}"
swift build "${swift_args[@]}" -c "$configuration" --product LocalCaption
build_dir="$(swift build "${swift_args[@]}" -c "$configuration" --show-bin-path)"
output_dir="${LOCALCAPTION_OUTPUT_DIRECTORY:-$PWD/dist}"
mkdir -p "$output_dir"
stage="$(mktemp -d "$output_dir/.staging.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/LocalCaption.app"
mkdir -p "$app/Contents/"{MacOS,Frameworks,Resources/ThirdParty}
cp "$build_dir/LocalCaption" "$app/Contents/MacOS/LocalCaption"
cp .deps/native/*.dylib "$app/Contents/Frameworks/"
cp AppResources/Info.plist "$app/Contents/"
cp Sources/CaptionCore/Resources/{Models,RollbackModels}.json "$app/Contents/Resources/"
cp .deps/whisper/LICENSE "$app/Contents/Resources/ThirdParty/whisper.cpp-LICENSE.txt"
cp .deps/sentencepiece/LICENSE "$app/Contents/Resources/ThirdParty/sentencepiece-LICENSE.txt"
cp .deps/onnxruntime/notices/LICENSE "$app/Contents/Resources/ThirdParty/ONNXRuntime-LICENSE.txt"
cp .deps/onnxruntime/notices/ThirdPartyNotices.txt "$app/Contents/Resources/ThirdParty/ONNXRuntime-NOTICES.txt"
cp .deps/ctranslate2/LICENSE "$app/Contents/Resources/ThirdParty/CTranslate2-LICENSE.txt"
cp MODEL-LICENSES.md "$app/Contents/Resources/ThirdParty/Model-Attributions.md"
executable="$app/Contents/MacOS/LocalCaption"
while IFS= read -r runpath; do
    case "$runpath" in
        /usr/lib/swift|@loader_path|@executable_path/../Frameworks) ;;
        *) install_name_tool -delete_rpath "$runpath" "$executable" ;;
    esac
done < <(otool -l "$executable" | awk '/cmd LC_RPATH/{r=1;next} r && / path / {
    sub(/^[[:space:]]*path /,""); sub(/ \(offset [0-9]+\)$/, ""); print; r=0
}')

mkdir "$stage/AppIcon.iconset"
swift Scripts/icon.swift "$stage/icon-1024.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$stage/icon-1024.png" --out "$stage/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    doubled=$(( size * 2 ))
    sips -z "$doubled" "$doubled" "$stage/icon-1024.png" --out "$stage/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$stage/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"

identity="${LOCALCAPTION_SIGN_IDENTITY:--}"
sign_flags=(--force --sign "$identity")
case "$identity" in
    -) ;;
    "Apple Development:"*|"Mac Developer:"*) sign_flags+=(--timestamp=none) ;;
    *) sign_flags+=(--options runtime --timestamp) ;;
esac
for library in "$app/Contents/Frameworks/"*.dylib; do
    codesign "${sign_flags[@]}" "$library"
done
codesign "${sign_flags[@]}" --entitlements AppResources/LocalCaption.entitlements "$app"
codesign --verify --deep --strict "$app"
if [[ -e "$output_dir/LocalCaption.app" ]]; then
    mv "$output_dir/LocalCaption.app" "$stage/Previous.app"
fi
if ! mv "$app" "$output_dir/LocalCaption.app"; then
    if [[ -e "$stage/Previous.app" ]]; then mv "$stage/Previous.app" "$output_dir/LocalCaption.app"; fi
    exit 1
fi
printf '%s\n' "Built $output_dir/LocalCaption.app"
