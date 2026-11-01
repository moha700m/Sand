#!/usr/bin/env bash
# Downloads the official llama.cpp iOS XCFramework into Frameworks/.
set -euo pipefail
TAG="${LLAMA_TAG:-b11960}"
cd "$(dirname "$0")/.."
if [ -d Frameworks/device/llama.framework ]; then echo "llama.framework already present"; exit 0; fi
mkdir -p Frameworks build
curl -fL --retry 4 -o build/llama.zip "https://github.com/ggml-org/llama.cpp/releases/download/${TAG}/llama-${TAG}-xcframework.zip"
rm -rf build/llama-unzip && mkdir -p build/llama-unzip
unzip -q build/llama.zip -d build/llama-unzip
XC=$(find build/llama-unzip -type d -name "llama.xcframework" | head -1)
[ -n "$XC" ] || { echo "llama.xcframework not found in archive"; find build/llama-unzip -maxdepth 3; exit 1; }
mkdir -p Frameworks/device
rm -rf Frameworks/device/llama.framework
cp -R "$XC/ios-arm64/llama.framework" Frameworks/device/
ls Frameworks/device/llama.framework
