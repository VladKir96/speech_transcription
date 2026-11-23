#!/bin/bash
# Resolve the macOS SDK and keep build caches in the project.
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$PWD/.build/clang-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$CLANG_MODULE_CACHE_PATH}"
mkdir -p "$CLANG_MODULE_CACHE_PATH"
developer_dir="$(xcode-select -p)"
if [[ -z "${SDKROOT:-}" && "$developer_dir" == */CommandLineTools ]]; then
    current_sdk="$(xcrun --show-sdk-version)"
    if [[ "${current_sdk%%.*}" -ge 27 && -d "$developer_dir/SDKs/MacOSX26.sdk" ]]; then
        export SDKROOT="$developer_dir/SDKs/MacOSX26.sdk"
    fi
fi
swift_args=(--manifest-cache local --cache-path "$PWD/.build/shared-cache" --config-path "$PWD/.build/swift-config"
    --security-path "$PWD/.build/swift-security")
if [[ "$developer_dir" == */CommandLineTools && -n "${SDKROOT:-}" ]]; then
    swift_args+=(--build-system native)
fi
if [[ "${LOCALCAPTION_SWIFTPM_NO_SANDBOX:-0}" == 1 ]]; then
    swift_args+=(--disable-sandbox)
fi
