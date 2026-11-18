#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Benchmark checks require macOS and Xcode Command Line Tools." >&2
  exit 1
fi
benchmark_check_dir="$(mktemp -d "${TMPDIR:-/tmp}/digisuite-benchmark-check.XXXXXX")"
trap 'rm -rf "$benchmark_check_dir"' EXIT
xcrun swiftc -target arm64-apple-macosx14.0 -parse-as-library -O \
  -framework Foundation -framework CryptoKit \
  BenchmarkCore.swift Tests/BenchmarkSmokeTests.swift \
  -o "$benchmark_check_dir/BenchmarkSmokeTests"
"$benchmark_check_dir/BenchmarkSmokeTests"
