#!/bin/bash
# Command Line Tools compatible: no XCTest or Xcode application required.
# Usage: Scripts/test.sh [path/to/MLX-model-directory]
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/LocalTranslate-tests.XXXXXX")"
trap 'rm -rf "$TEST_BUILD_DIR"' EXIT
swiftc "$PROJECT_DIR/Sources/LocalTranslate/InferenceEngine.swift" \
  "$PROJECT_DIR/Tests/PromptSmoke.swift" -o "$TEST_BUILD_DIR/prompt-smoke"
"$TEST_BUILD_DIR/prompt-smoke"
if [ "$#" -gt 0 ]; then
  if [ ! -d "$1" ]; then
    printf 'Model not found: %s\n' "$1" >&2
    exit 1
  fi
  swiftc "$PROJECT_DIR/Sources/LocalTranslate/InferenceEngine.swift" \
    "$PROJECT_DIR/Tests/InferenceSmoke.swift" -o "$TEST_BUILD_DIR/inference-smoke"
  "$TEST_BUILD_DIR/inference-smoke" "$1"
else
  printf '%s\n' 'Inference checks skipped. Pass a local MLX model directory to run them.'
fi
