#!/usr/bin/env bash
# Lesson 01 - the manifest schema is a protobuf, not a Go struct.
#
# Runs from any cwd, cleans up after itself, and prints exactly one of
#   PASS: 01-schema      (exit 0)
#   FAIL: 01-schema      (exit non-zero, with the reason above it)
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
UPSTREAM="$LAB_ROOT/upstream/google-ax"
NAME="01-schema"

fail() {
  echo "FAIL: $NAME"
  echo "reason: $*" >&2
  exit 1
}

[ -d "$UPSTREAM/pkg/apis/v1alpha1" ] || fail "upstream clone not found at $UPSTREAM"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "building the lesson program"
BIN="$WORK/lesson01"
( cd "$LAB_ROOT" && go build -o "$BIN" ./examples/01-schema ) || fail "go build failed"

echo "running the lesson"
AX_UPSTREAM="$UPSTREAM" "$BIN" || fail "the lesson program exited non-zero"

echo "PASS: $NAME"
