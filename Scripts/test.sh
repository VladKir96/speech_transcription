#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -f .deps/native/libcaption_inference.dylib || ! -f .deps/native/libctranslate2.4.6.3.dylib ||
      Native/NLLB.cpp -nt .deps/native/libcaption_inference.dylib ||
      Native/Inference.mm -nt .deps/native/libcaption_inference.dylib ||
      Sources/CInference/inference.h -nt .deps/native/libcaption_inference.dylib ]]; then
    Scripts/bootstrap.sh
fi
bash Scripts/bootstrap-sparkle.sh
source Scripts/swift-env.sh
test_args=()
if [[ "$developer_dir" == */CommandLineTools ]]; then
    frameworks="$developer_dir/Library/Developer/Frameworks"
    test_args+=(-Xswiftc -F -Xswiftc "$frameworks" -Xlinker -rpath -Xlinker "$frameworks")
fi
swift test "${swift_args[@]}" "${test_args[@]}" --enable-swift-testing --disable-xctest "$@"
