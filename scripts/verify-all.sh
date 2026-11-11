#!/usr/bin/env bash
# verify-all.sh -- the lab's regression gate.
#
# Discovers every ax-lab/examples/*/run.sh, runs them in numeric order from a
# known state, reports per-lesson results, and exits non-zero if any lesson
# fails so it can be used in automation.
#
# Ground rules this script enforces on itself:
#   * no cluster   -- KUBECONFIG is pointed at /dev/null so a stray kubectl call
#                     inside a lesson cannot reach a real context
#   * no root/sudo -- nothing here needs either
#   * no internet -- lessons use loopback HTTP and local processes only
#   * no leftovers -- processes from ax-lab/bin and lab-owned containers are
#                     reaped before the run and after each lesson
#   * never silently "passes" a lesson it did not run
#
# Knobs:
#   AXLAB_LESSON_TIMEOUT             seconds per lesson (default 300)
#   AXLAB_KEEP_RUNNING=1             skip the pre-run cleanup of leftover processes
#   AXLAB_CONTAINERS=0               never touch containers at all
#   AXLAB_REAP_RUNNING_CONTAINERS=1  also remove *running* lab containers, not just
#                                    stopped ones. Off by default: a running
#                                    axlab-* container may belong to a concurrent
#                                    gate run, and killing it breaks that run.
#   AXLAB_REQUIRE_LESSONS="01 02 03 04 05"
#                                    space-separated lesson numbers that MUST have
#                                    a run.sh for this run to pass. If any of them
#                                    is missing, the gate exits 1 with a FAIL
#                                    verdict instead of the default
#                                    "PASS (partial)" + exit 0.
#                                    Unset by default: while the track is being
#                                    written, "01..03 exist, 04 not yet" is the
#                                    normal state and should not turn the gate red.
#                                    Set it in CI, or once the track is complete,
#                                    so a deleted or renamed lesson directory is a
#                                    failure rather than a silent pass. The
#                                    comparison is on the NN prefix of the
#                                    NN-topic-name directory, so 04 and 04-anything
#                                    both satisfy "04".
#
# Exit codes:  0 all lessons passed   1 one or more failed, or a lesson listed in
#                                  AXLAB_REQUIRE_LESSONS had no run.sh
#              2 harness error (nothing to run, cleanup impossible, ...)

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
LAB_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd -P)"
EXAMPLES_DIR="$LAB_ROOT/examples"
BIN_DIR="$LAB_ROOT/bin"
UPSTREAM_BIN="$LAB_ROOT/upstream/google-ax/bin"
LOG_DIR="$LAB_ROOT/.work/verify-all"
PREV_LOG_DIR="$LAB_ROOT/.work/prev-verify-all"

TIMEOUT="${AXLAB_LESSON_TIMEOUT:-300}"
FAIL_TAIL_LINES=60

# Enforce "no cluster" without touching the user's kubeconfig on disk.
export KUBECONFIG=/dev/null

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; OFF=$'\033[0m'
[ -t 1 ] || { RED=""; GREEN=""; YELLOW=""; BOLD=""; OFF=""; }

say()  { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '%s!! %s%s\n' "$YELLOW" "$*" "$OFF"; }
hdr()  { printf '\n%s=== %s ===%s\n' "$BOLD" "$*" "$OFF"; }
harness_die() {
  printf '\n%sverify-all.sh harness error: %s%s\n' "$RED" "$*" "$OFF" >&2
  exit 2
}

# --------------------------------------------------------------- discovery ----
[ -d "$EXAMPLES_DIR" ] || harness_die "no $EXAMPLES_DIR directory"

# Numeric sort on the leading NN of each directory name.
LESSONS=$(find "$EXAMPLES_DIR" -mindepth 2 -maxdepth 2 -name run.sh -type f \
            -printf '%h\n' 2>/dev/null | sort)

# ------------------------------------------------- cleanup from a known state --
# Only touches things this lab created. Names and paths are explicit on purpose:
# a broad `pkill ax` or `docker rm -f` here would take out the user's other
# projects.
#
# Two tiers, because a sibling lesson's containers are a shared resource:
#   * garbage  -- containers in Exited/Created/Dead state. Always reaped. These
#                 are what a crashed previous run leaves, and nothing can own them.
#   * running  -- a *running* axlab-* container may belong to a concurrent gate
#                 run, so it is only reaped when AXLAB_REAP_RUNNING_CONTAINERS=1.
#                 By default it is reported loudly instead. Killing it blind is
#                 how two people running the lab at once sabotage each other.
LAB_CONTAINER_PREFIXES='axlab- ax-redis-local'

reap_processes() {
  local b d p exe killed=0
  # Both bin directories, because the lab has two of them and a lesson that
  # launches "$BIN_DIR/ax-server" is not cleaned up by a reaper that only knows
  # about "$UPSTREAM_BIN/ax-server".
  #
  # pgrep -f only *candidates*: it matches the pattern anywhere in the command
  # line, so the shell that invoked this gate, an editor with the path in its
  # argument list, or a grep in another terminal all match too. Killing those is
  # precisely the collateral damage this function exists to prevent -- and it is
  # not hypothetical: matching a bare path killed the shell that launched the
  # gate during development of this very function. So a candidate is only
  # reaped once /proc/<pid>/exe confirms it is actually running that binary.
  #
  # ax-controller is deliberately absent: no lesson launches it (lesson 04 goes
  # out of its way not to), so reaping it could only ever kill a process the
  # user started by hand.
  for d in "$BIN_DIR" "$UPSTREAM_BIN"; do
    for b in ax ax-server ax-task-runner; do
      for p in $(pgrep -f "$d/$b" 2>/dev/null); do
        [ "$p" = "$$" ] && continue
        exe=$(readlink -f "/proc/$p/exe" 2>/dev/null) || continue
        [ "$exe" = "$d/$b" ] || continue
        kill -TERM "$p" 2>/dev/null && { killed=$((killed + 1)); info "stopped leftover process $p ($exe)"; }
      done
    done
  done
  sleep 0.3
  for d in "$BIN_DIR" "$UPSTREAM_BIN"; do
    for b in ax ax-server ax-task-runner; do
      for p in $(pgrep -f "$d/$b" 2>/dev/null); do
        [ "$p" = "$$" ] && continue
        exe=$(readlink -f "/proc/$p/exe" 2>/dev/null) || continue
        [ "$exe" = "$d/$b" ] || continue
        kill -KILL "$p" 2>/dev/null
      done
    done
  done
  [ "$killed" -gt 0 ] && say "  reaped $killed leftover process(es) from $BIN_DIR and $UPSTREAM_BIN"
  return 0
}

reap_containers() {
  [ "${AXLAB_CONTAINERS:-1}" = "0" ] && { info "container cleanup disabled (AXLAB_CONTAINERS=0)"; return 0; }
  command -v docker >/dev/null 2>&1 || { info "docker not available; nothing to reap"; return 0; }
  docker info >/dev/null 2>&1 || { warn "docker daemon unreachable; cannot reap containers"; return 0; }

  local name ids id state reaped=0 reported=0
  for name in $LAB_CONTAINER_PREFIXES; do
    # ^/<name> so "axlab-foo" never matches "axlab-foobar"
    ids=$(docker ps -aq --filter "name=^/${name}" 2>/dev/null)
    [ -z "$ids" ] && continue
    for id in $ids; do
      state=$(docker inspect -f '{{.State.Status}}' "$id" 2>/dev/null)
      if [ "$state" = "running" ] && [ "${AXLAB_REAP_RUNNING_CONTAINERS:-0}" != "1" ]; then
        reported=$((reported + 1))
        warn "leaving RUNNING container $id ($name, $state) alone -- it may belong to a"
        warn "  concurrent run. Reap it with AXLAB_REAP_RUNNING_CONTAINERS=1 or by hand."
        continue
      fi
      docker rm -f "$id" >/dev/null 2>&1 \
        && { reaped=$((reaped + 1)); info "reaped ${state:-unknown} container $id ($name)"; } \
        || warn "could not remove container $id ($name)"
    done
  done
  [ "$reaped" -eq 0 ] && [ "$reported" -eq 0 ] && info "no leftover lab containers"
  return 0
}

hdr "Pre-run cleanup"
if [ "${AXLAB_KEEP_RUNNING:-0}" = "1" ]; then
  warn "AXLAB_KEEP_RUNNING=1 -- starting from whatever is already running. Results may be flaky."
else
  reap_processes
  reap_containers
fi
# Per-lesson logs from the previous gate run are *rotated*, not deleted.
#
# Deleting them up front is what made a failing gate useless: the one thing you
# want when lesson 01 goes red is the log of the last run where it was green, and
# `rm -rf .work` before the run threw that away before a single lesson had
# executed. Rotating keeps both sides of the comparison on disk:
#
#   .work/verify-all/<lesson>.log        this run
#   .work/prev-verify-all/<lesson>.log   the run before it
#
# Only the gate's own log directory is touched. Everything else under .work is a
# lesson's own scratch and each lesson clears its own (01/02 rm -rf it in an EXIT
# trap, 03/04 use mktemp -d, 05 rm -rf's its WORK up front), so a blanket
# `rm -rf .work` was never needed for correctness.
if [ -d "$LOG_DIR" ]; then
  rm -rf "$PREV_LOG_DIR" 2>/dev/null
  mv "$LOG_DIR" "$PREV_LOG_DIR" 2>/dev/null \
    || warn "could not rotate $LOG_DIR aside to $PREV_LOG_DIR; prior logs will be lost"
fi
mkdir -p "$LOG_DIR" || harness_die "cannot create $LOG_DIR"
[ -d "$PREV_LOG_DIR" ] && info "previous run's logs kept at ${PREV_LOG_DIR#$LAB_ROOT/}/"
info "per-lesson output will be written to ${LOG_DIR#$LAB_ROOT/}/"

# ------------------------------------------------------------------- report ----
# Binaries the lessons execute. Missing ones are reported loudly rather than
# turned into a silent pass.
EXPECT_BINS="ax ax-server ax-task-runner"
missing_bins=""
for b in $EXPECT_BINS; do
  if [ -x "$BIN_DIR/$b" ]; then
    info "found  $BIN_DIR/$b"
  else
    missing_bins="$missing_bins $b"
    warn "MISSING  $BIN_DIR/$b"
  fi
done
if [ -n "$missing_bins" ]; then
  warn "binaries not built yet:$missing_bins"
  warn "build them with:  cd $LAB_ROOT && ./scripts/setup.sh"
  warn "This gate does not skip a lesson because a binary is missing. A lesson that"
  warn "needs one of these runs anyway and FAILs, naming the binary in its own"
  warn "reason; a lesson that does not need one is unaffected. So this warning on"
  warn "its own does not change the verdict -- whatever the lessons actually did does."
fi

# ------------------------------------------------------------- run the gate ----
PASSED=0; FAILED=0; RESULTS=""

run_lesson() { # dir
  local dir="$1"
  local name; name="$(basename -- "$dir")"
  local script="$dir/run.sh"
  local log="$LOG_DIR/$name.log"
  local start end dur=0 rc=0

  if [ ! -x "$script" ]; then
    rc=126
    printf '    %s is not executable\n' "$script" > "$log"
    printf '    fix with: chmod +x %q\n' "$script" >> "$log"
  else
    start=$(date +%s)
    # timeout(1) so a wedged lesson cannot hang the gate forever.
    if command -v timeout >/dev/null 2>&1; then
      timeout -k 10 "$TIMEOUT" bash "$script" > "$log" 2>&1
      rc=$?
    else
      bash "$script" > "$log" 2>&1
      rc=$?
    fi
    end=$(date +%s); dur=$((end - start))
  fi

  # Exit 0 alone is not enough: a lesson must also print its own PASS line, so a
  # script that forgets to (or crashes before it) is never counted as passing.
  if [ "$rc" -eq 0 ] && grep -q "^PASS: $name\$" "$log" 2>/dev/null; then
    PASSED=$((PASSED + 1))
    printf '  %s%-4s PASS%s  %-28s %3ss  (log: %s)\n' "$GREEN" "[$rc]" "$OFF" "$name" "$dur" "${log#$LAB_ROOT/}"
    RESULTS="$RESULTS$name:pass "
    return 0
  fi

  FAILED=$((FAILED + 1))
  printf '  %s%-4s FAIL%s  %-28s %3ss  (log: %s)\n' "$RED" "[$rc]" "$OFF" "$name" "$dur" "${log#$LAB_ROOT/}"
  RESULTS="$RESULTS$name:fail "
  return 1
}

hdr "Lessons"
if [ -z "$LESSONS" ]; then
  harness_die "no examples/*/run.sh found under $EXAMPLES_DIR -- there is nothing to verify"
fi

info "$(( $(printf '%s\n' "$LESSONS" | wc -l) )) lesson script(s) discovered, running in numeric order"
info "per-lesson timeout: ${TIMEOUT}s"
say ""

for dir in $LESSONS; do
  run_lesson "$dir"
done

# Anything a lesson leaked is not "known state" any more.
printf '\n'
hdr "Post-run cleanup"
reap_processes
reap_containers
info "a RUNNING container still listed above was left by the lesson that created it;"
info "that lesson is responsible for tearing its own containers down"

# ------------------------------------------------------------------ summary ---
hdr "Summary"
PRESENTED=$(printf '%s\n' "$LESSONS" | xargs -n1 basename 2>/dev/null | tr '\n' ' ')

say "  ${GREEN}passed: $PASSED${OFF}"
say "  ${RED}failed: $FAILED${OFF}"
say "  lesson scripts found: $PRESENTED"
# Lesson-numbering gaps: reported as NOT RUN below, never as passing. Collect just
# the NN prefix of each NN-topic-name directory.
FOUND_NUMS=$(printf '%s\n' "$LESSONS" | while read -r d; do basename -- "$d" | grep -oE '^[0-9]+'; done | tr '\n' ' ')

say ""
# Lesson-numbering gaps. A track is ordered, so only numbers up to the highest one
# actually present are expected; anything above that is simply unwritten.
MAX_NUM=$(printf '%s\n' "$FOUND_NUMS" | tr ' ' '\n' | grep -E '^[0-9]+$' | sort -n | tail -1)
GAPS=""
if [ -n "${MAX_NUM:-}" ]; then
  i=1
  while [ "$i" -le "$MAX_NUM" ]; do
    n=$(printf '%02d' "$i")
    case " $FOUND_NUMS " in
      *" $n "*) ;;
      *) GAPS="$GAPS $n" ;;
    esac
    i=$((i + 1))
  done
fi
say "  lesson numbers present:$FOUND_NUMS (highest: ${MAX_NUM:-none})"

if [ -n "$GAPS" ]; then
  warn "NOT RUN -- no run.sh found for lesson(s):$GAPS"
  warn "These are holes below the highest lesson number present. They were not"
  warn "executed and are NOT counted as passing. A lesson only passes when its own"
  warn "run.sh prints 'PASS: <name>' and exits 0."
fi

# Optional strict mode. A "PASS (partial)" is the right answer while a track is
# being written and the missing lessons simply do not exist yet -- but it is the
# wrong answer for a caller that only looks at the exit code, which is every CI
# job. AXLAB_REQUIRE_LESSONS is how a caller says "these numbers must exist",
# and it is unset by default so the in-progress case keeps working.
REQUIRE_LESSONS="${AXLAB_REQUIRE_LESSONS:-}"
MISSING_REQUIRED=""
REQUIRED_LIST=""
for n in $REQUIRE_LESSONS; do
  case "$n" in
    ''|*[!0-9]*)
      warn "ignoring non-numeric entry [$n] in AXLAB_REQUIRE_LESSONS"
      continue
      ;;
  esac
  n=$(printf '%02d' "$((10#$n))")   # "4" and "04" are the same lesson
  REQUIRED_LIST="$REQUIRED_LIST $n"
  case " $FOUND_NUMS " in
    *" $n "*) ;;
    *) MISSING_REQUIRED="$MISSING_REQUIRED $n" ;;
  esac
done
if [ -n "$REQUIRED_LIST" ]; then
  say "  AXLAB_REQUIRE_LESSONS:${REQUIRED_LIST# }"
  if [ -n "$MISSING_REQUIRED" ]; then
    say "  ${RED}required but absent:${MISSING_REQUIRED}${OFF}"
  else
    say "  all required lessons are present"
  fi
fi

for r in $RESULTS; do
  name="${r%%:*}"; st="${r##*:}"
  [ "$st" = "fail" ] && say "  ${RED}failed lesson: $name${OFF}"
done

# Show the failing lesson's own output -- the whole point of capturing it.
FAILED_DIRS=""
for dir in $LESSONS; do
  name="$(basename -- "$dir")"
  case " $RESULTS " in *" $name:fail "*) FAILED_DIRS="$FAILED_DIRS $dir" ;; esac
done
for dir in $FAILED_DIRS; do
  name="$(basename -- "$dir")"
  hdr "Captured output: $name (last $FAIL_TAIL_LINES lines)"
  tail -n "$FAIL_TAIL_LINES" "$LOG_DIR/$name.log" | sed 's/^/  /'
done

hdr "Verdict"
if [ "$FAILED" -gt 0 ]; then
  say "  ${RED}${BOLD}FAIL${OFF} -- $FAILED of $((PASSED + FAILED)) lesson(s) failed."
  say "  Full logs: ${LOG_DIR#$LAB_ROOT/}/"
  exit 1
fi
if [ -n "$MISSING_REQUIRED" ]; then
  say "  ${RED}${BOLD}FAIL${OFF} -- all $PASSED discovered lesson(s) passed, but"
  say "  AXLAB_REQUIRE_LESSONS lists lesson(s)$MISSING_REQUIRED and no run.sh was"
  say "  found for them, so they were not run. An unrun lesson is a gap, not a pass."
  say "  Full logs: ${LOG_DIR#$LAB_ROOT/}/"
  exit 1
fi
if [ -n "$GAPS" ]; then
  say "  ${YELLOW}${BOLD}PASS (partial)${OFF} -- all $PASSED discovered lesson(s) passed,"
  say "  but lesson(s)$GAPS have no run.sh yet and were not run."
  say "  Set AXLAB_REQUIRE_LESSONS to make a gap in that set fail this gate (exit 1)."
  exit 0
fi
say "  ${GREEN}${BOLD}PASS${OFF} -- all $PASSED lesson(s) passed."
exit 0
