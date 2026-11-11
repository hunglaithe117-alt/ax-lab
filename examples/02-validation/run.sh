#!/usr/bin/env bash
# Lesson 02 - validation: what the API server refuses, and the exact strings.
#
# Runs from any cwd, needs no cluster, no redis, and no network.
# Prints exactly one of
#   PASS: 02-validation   (exit 0)
#   FAIL: 02-validation   (exit non-zero, with the reason above it)
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
# AXLAB_UPSTREAM exists so this lesson's decode controls can be *exercised*
# rather than only claimed: point it at a copy of the ax checkout whose
# examples/ has been doctored (a `kind:` typo, a broken manifest) and this
# script must print FAIL: 02-validation and exit non-zero. It defaults to the
# lab's own clone, so an unset variable behaves exactly as before.
UPSTREAM="${AXLAB_UPSTREAM:-$LAB_ROOT/upstream/google-ax}"
NAME="02-validation"

fail() {
  echo "FAIL: $NAME"
  echo "reason: $*" >&2
  exit 1
}

[ -d "$UPSTREAM/pkg/apis/v1alpha1" ] || fail "upstream clone not found at $UPSTREAM"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "building the lesson program"
BIN="$WORK/lesson02"
( cd "$LAB_ROOT" && go build -o "$BIN" ./examples/02-validation ) || fail "go build failed"

echo "running the lesson"
# The program itself exits non-zero if any negative control behaved differently
# than this script claims, so a false PASS is not possible.
AX_UPSTREAM="$UPSTREAM" "$BIN" || fail "a validation expectation did not hold"

echo "PASS: $NAME"
