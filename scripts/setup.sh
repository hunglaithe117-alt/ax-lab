#!/usr/bin/env bash
# setup.sh -- idempotent bootstrap for the ax learning lab.
#
# Ensures upstream/google-ax is present (shallow clone if absent) and that the
# three binaries the lessons execute -- ax, ax-server, ax-task-runner -- are
# built into ax-lab/bin/.
#
# Source references (upstream/google-ax):
#   Makefile:31-38         `make build` -> bin/ax, bin/ax-controller, bin/ax-server
#   Makefile:46-51         `make build-task-runner` cross-compiles to bin/linux_amd64
#                          and then builds a *container image* with docker/podman.
#                          The lab needs the host binary, not the image, so the
#                          runner is built with a plain `go build` instead.
#   cmd/ax-task-runner/main.go:54-56   -port / -task-file / -workspace-file flags
#
# Deliberately does NOT touch ax-lab/go.mod or ax-lab/go.sum, and never runs
# `go mod tidy`: another lane owns the lab's Go module. GOFLAGS=-mod=readonly
# makes that a hard guarantee rather than a promise.
#
# No cluster, no root, no sudo, no containers. Safe to re-run.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
LAB_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
UPSTREAM_DIR="$LAB_ROOT/upstream/google-ax"
BIN_DIR="$LAB_ROOT/bin"
UPSTREAM_URL="https://github.com/google/ax.git"   # matches `git remote -v` of the lab's clone

export GOFLAGS="${GOFLAGS:--mod=readonly}"
export CGO_ENABLED="${CGO_ENABLED:-0}"

say()  { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }
die()  { printf '\nsetup.sh failed: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight --
say "Preflight"
command -v go >/dev/null 2>&1 || die "go is not on PATH. Install Go 1.27+ and re-run."
command -v git >/dev/null 2>&1 || die "git is not on PATH."
command -v make >/dev/null 2>&1 || die "make is not on PATH."
info "go:        $(go version)"
info "git:       $(git --version)"
info "lab root:  $LAB_ROOT"
info "upstream:  $UPSTREAM_DIR"

# ------------------------------------------------------------------- clone ---
# `make build` and the `go build` below both run inside the upstream checkout, so
# it has to exist. Shallow by design: the lab reads a few specific files and does
# not need history.
if [ -d "$UPSTREAM_DIR/.git" ]; then
  info "upstream clone already present, reusing it"
  info "  pinned at $(git -C "$UPSTREAM_DIR" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
else
  say "Cloning upstream (shallow, needs network -- one time only)"
  info "git clone --depth 1 $UPSTREAM_URL"
  mkdir -p "$(dirname -- "$UPSTREAM_DIR")"
  if ! git clone --depth 1 "$UPSTREAM_URL" "$UPSTREAM_DIR"; then
    die "clone failed. If this machine is offline, place a checkout of github.com/google/ax at $UPSTREAM_DIR and re-run."
  fi
  info "cloned at $(git -C "$UPSTREAM_DIR" rev-parse --short HEAD)"
fi

# ------------------------------------------------------------------- build ---
# `make build` is the repo's own entry point (Makefile:31) and is idempotent: go
# build re-links only what changed. It does not build the task runner, so the
# runner gets its own `go build` (see the note about Makefile:46-51 above).
say "Building ax, ax-controller, ax-server via \`make build\` (Makefile:31)"
make -C "$UPSTREAM_DIR" build || die "\`make build\` failed"
info "upstream binaries: $(ls "$UPSTREAM_DIR"/bin 2>/dev/null | tr '\n' ' ')"

mkdir -p "$BIN_DIR" || die "cannot create $BIN_DIR"
# Only the three binaries a lesson actually executes are installed. `make build`
# also produces ax-controller, and it is left sitting in upstream/google-ax/bin:
# no lesson runs a controller, and copying it here would only invite someone to
# run one outside the lab's cleanup. Lesson 04 is explicit that "no ax-controller
# runs" is the point of its Suspended-with-no-actor section.
for b in ax ax-server; do
  if [ -x "$UPSTREAM_DIR/bin/$b" ]; then
    cp -f "$UPSTREAM_DIR/bin/$b" "$BIN_DIR/$b" || die "cannot copy $b into $BIN_DIR"
    info "installed $BIN_DIR/$b"
  else
    warn "make build did not produce bin/$b -- skipping"
  fi
done
# A previous version of this script installed ax-controller here. Leaving the
# stale copy behind would make the lab's bin dir disagree with the line above,
# and would quietly satisfy a lesson that expected no controller to be around.
if [ -e "$BIN_DIR/ax-controller" ]; then
  rm -f "$BIN_DIR/ax-controller" && info "removed stale $BIN_DIR/ax-controller (no lesson runs one)"
fi

say "Building ax-task-runner (host binary for the local runner lessons)"
info "go build -o $BIN_DIR/ax-task-runner ./cmd/ax-task-runner"
(
  cd "$UPSTREAM_DIR" || exit 1
  # GOOS/GOARCH left at the host values on purpose: the lab runs the runner as a
  # local process. Makefile:49 cross-compiles to linux/amd64 for the *image*.
  go build -o "$BIN_DIR/ax-task-runner" ./cmd/ax-task-runner
) || die "building ax-task-runner failed"
info "installed $BIN_DIR/ax-task-runner"

# ------------------------------------------------------------------ verify ---
# Prove each binary actually executes before telling the user to run anything.
say "Smoke-checking the installed binaries"
smoke_ok=1
check_exec() { # path args...
  local bin="$1"; shift
  local out rc
  if [ ! -x "$bin" ]; then
    warn "MISSING  $bin"
    smoke_ok=0
    return
  fi
  out=$("$bin" "$@" 2>&1); rc=$?
  if [ "$rc" -eq 0 ]; then
    info "ok       $bin $*   ->   $(printf '%s' "$out" | head -n 1)"
  else
    warn "RAN BUT EXITED $rc  $bin $*"
    printf '         %s\n' "$(printf '%s' "$out" | head -n 3 | tr '\n' '|')"
    smoke_ok=0
  fi
}
# `ax` prints usage to stdout and exits 1 on both --help and no arguments, so it
# is smoke-tested with its real `version` subcommand instead.
check_exec "$BIN_DIR/ax" version
# ax-server and ax-task-runner use the Go flag package: -h prints usage and exits 0.
check_exec "$BIN_DIR/ax-server" --help
check_exec "$BIN_DIR/ax-task-runner" --help

# The exact flags lesson 05 depends on, straight from cmd/ax-task-runner/main.go:54-56.
if [ -x "$BIN_DIR/ax-task-runner" ]; then
  say "ax-task-runner flags (cmd/ax-task-runner/main.go:54-56)"
  "$BIN_DIR/ax-task-runner" --help 2>&1 | sed 's/^/   /'
fi

# ----------------------------------------------------------------- summary ---
say "Summary"
if [ "$smoke_ok" -eq 1 ]; then
  info "all expected binaries built and executable"
else
  warn "one or more binaries are missing or not runnable (see above)"
fi
info "bin dir:  $BIN_DIR"
info "upstream: $UPSTREAM_DIR  (read-only reference; do not edit)"
printf '\nNext command:\n'
printf '   cd %s\n' "$LAB_ROOT"
printf '   ./scripts/verify-all.sh          # run every lesson, non-zero exit on any failure\n'
printf '   ./examples/05-runner-sandbox/run.sh   # just the runner/sandbox lesson\n\n'
[ "$smoke_ok" -eq 1 ] || exit 1
exit 0
