#!/bin/bash
# Command Line Tools compatible: no XCTest or Xcode application required.
# Usage: Scripts/test.sh [path/to/MLX-model-directory]
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/LocalTranslate-tests.XXXXXX")"
trap 'rm -rf "$TEST_BUILD_DIR"' EXIT
swiftc "$PROJECT_DIR/Sources/LocalTranslate/GlossaryStore.swift" "$PROJECT_DIR/Sources/LocalTranslate/InferenceEngine.swift" \
  "$PROJECT_DIR/Tests/PromptSmoke.swift" -o "$TEST_BUILD_DIR/prompt-smoke"
"$TEST_BUILD_DIR/prompt-smoke"
for name in GlossarySmoke PromptFeaturesSmoke; do
  swiftc "$PROJECT_DIR/Sources/LocalTranslate/GlossaryStore.swift" "$PROJECT_DIR/Sources/LocalTranslate/InferenceEngine.swift" \
    "$PROJECT_DIR/Tests/$name.swift" -o "$TEST_BUILD_DIR/$name"
  "$TEST_BUILD_DIR/$name"
done
swiftc "$PROJECT_DIR/Sources/LocalTranslate/DocumentTranslation.swift" "$PROJECT_DIR/Tests/DocumentSmoke.swift" -o "$TEST_BUILD_DIR/document-smoke"
"$TEST_BUILD_DIR/document-smoke"
"$PROJECT_DIR/.venv/bin/python" "$PROJECT_DIR/Tests/test_document_plan.py"
"$PROJECT_DIR/.venv/bin/python" "$PROJECT_DIR/Tests/test_queue.py"
if [ "$#" -gt 0 ]; then
  if [ ! -d "$1" ]; then
    printf 'Model not found: %s\n' "$1" >&2
    exit 1
  fi
  swiftc "$PROJECT_DIR/Sources/LocalTranslate/GlossaryStore.swift" "$PROJECT_DIR/Sources/LocalTranslate/InferenceEngine.swift" \
    "$PROJECT_DIR/Tests/InferenceSmoke.swift" -o "$TEST_BUILD_DIR/inference-smoke"
  "$TEST_BUILD_DIR/inference-smoke" "$1"
  swiftc "$PROJECT_DIR/Sources/LocalTranslate/GlossaryStore.swift" "$PROJECT_DIR/Sources/LocalTranslate/InferenceEngine.swift" \
    "$PROJECT_DIR/Sources/LocalTranslate/TranslationSegments.swift" "$PROJECT_DIR/Sources/LocalTranslate/DocumentTranslation.swift" \
    "$PROJECT_DIR/Sources/LocalTranslate/TranslationPipeline.swift" "$PROJECT_DIR/Sources/LocalTranslate/TranslationQueue.swift" \
    "$PROJECT_DIR/Tests/FeatureInferenceSmoke.swift" -o "$TEST_BUILD_DIR/feature-inference"
  "$TEST_BUILD_DIR/feature-inference" "$1"
else
  printf '%s\n' 'Inference checks skipped. Pass a local MLX model directory to run them.'
fi
