#!/bin/bash
# CI stage runner (called by the thin workflow). Writes results/summary.md + results/libs.txt.
set -u
cd "$(dirname "$0")/.."
mkdir -p results
{
  echo "## Runner environment"
  echo "- date: $(date)"
  echo "- runner: $(sw_vers -productName) $(sw_vers -productVersion), $(uname -m), $(sysctl -n machdep.cpu.brand_string)"
  echo "- xcode: $(xcodebuild -version | head -1)"
  echo "- iphoneos SDK: $(xcrun --sdk iphoneos --show-sdk-path)"
  echo "- disk free: $(df -h . | tail -1 | awk '{print $4}')"
} >> results/summary.md
bash deps/build-foundation.sh
