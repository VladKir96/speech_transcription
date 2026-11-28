#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/github-origin.sh
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    exec python3 Scripts/release.py "$@"
fi
LOCALCAPTION_RELEASE_REPOSITORY="$(github_repository origin)"
export LOCALCAPTION_RELEASE_REPOSITORY
# Select the SDK before Apple's python3 shim injects the system SDK into subprocesses.
source Scripts/swift-env.sh
exec python3 Scripts/release.py "$@"
