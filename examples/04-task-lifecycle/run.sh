#!/usr/bin/env bash
# Lesson 04 - task lifecycle, and the two traps that waste people's afternoon.
#
# Part A (EXECUTED, via the real CLI + a real server + a real Redis):
#   * a newly created Task is Suspended with no actor, and stays there forever
#     until somebody runs `ax resume`
#   * `ax watch` on a task that never resumes prints exactly one line
#   * what a Task's conditions actually are - and an honest demonstration that
#     there are none of them without a controller, which there is not here
#   * re-applying a Task - even byte-identical - is rejected FailedPrecondition
#   * the same re-apply on a Workspace or Model succeeds
# Part B (EXECUTED, inside the upstream module via `go test -overlay`) - a
#   self-contained detour about internal/model, unrelated to the lifecycle:
#   * the model client fabricates a plan and a token count when the key is
#     empty or the API answers 401/403/429/503
# Part C (READ, not executed): the exact source lines for both traps, printed
#   with their real line numbers so you can check them yourself.
#
# Prints exactly one of
#   PASS: 04-task-lifecycle   (exit 0)
#   FAIL: 04-task-lifecycle   (exit non-zero, with the reason above it)
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
UPSTREAM="$LAB_ROOT/upstream/google-ax"
MODEL_CLIENT="$UPSTREAM/internal/model/client.go"
# See examples/03-apiserver-store/run.sh: the binaries come from the lab's own
# bin/, which is what scripts/setup.sh installs into and what
# scripts/verify-all.sh checks, so a MISSING there is a real signal.
BIN_DIR="$LAB_ROOT/bin"
NAME="04-task-lifecycle"

# shellcheck source=../../scripts/lablib.sh
. "$LAB_ROOT/scripts/lablib.sh"

LAB_TMP="$(mktemp -d)"
LAB_STARTED_REDIS=0
trap 'rc=$?; lab_cleanup; exit $rc' EXIT

fail() {
  echo "FAIL: $NAME"
  echo "reason: $*" >&2
  exit 1
}

expect() { # expect <what> <needle> <haystack>
  if printf '%s' "$3" | grep -qF -- "$2"; then
    lab_note "  PASS  $1"
  else
    fail "$1 - expected to find \"$2\" in:
$3"
  fi
}
refute() { # refute <what> <needle> <haystack>
  if printf '%s' "$3" | grep -qF -- "$2"; then
    fail "$1 - did NOT expect to find \"$2\" in:
$3"
  else
    lab_note "  PASS  $1"
  fi
}

# show_src <file> <start> <end> prints lines start..end with their REAL line
# numbers. This section exists so a reader can check a citation against the
# file, so the number printed has to be the number in the file. An earlier
# version used `cat -n` plus a hardcoded `49` prefix, which is only correct
# for lines 490-499 and silently renumbered 498-502 as 491-495 -- i.e. it
# sent the reader to the wrong five lines of the trap it was quoting.
# `grep -n ''` rather than `nl`: nl's field separator swallows the leading tab
# of tab-indented Go, so the excerpt would stop looking like the file.
show_src() { # file start end
  grep -n '' "$1" | sed -n "$2,$3p" | sed 's/^/    /'
}

# --- preflight --------------------------------------------------------------

[ -x "$BIN_DIR/ax" ]        || fail "missing the lab's prebuilt CLI at $BIN_DIR/ax (build it with ./scripts/setup.sh)"
[ -x "$BIN_DIR/ax-server" ] || fail "missing the lab's prebuilt server at $BIN_DIR/ax-server (build it with ./scripts/setup.sh)"
[ -f "$MODEL_CLIENT" ]      || fail "missing $MODEL_CLIENT"
command -v docker >/dev/null || fail "docker is required"
command -v curl   >/dev/null || fail "curl is required"
command -v jq     >/dev/null || fail "jq is required (section 7 decodes the stored task as JSON)"

LAB_AX_BIN="$BIN_DIR/ax"
LAB_AX_SERVER_BIN="$BIN_DIR/ax-server"

lab_section "environment"
lab_note "ax-server only. There is NO ax-controller in this lesson, so nothing"
lab_note "will ever create an actor or a worker IP. That is deliberate: it is"
lab_note "how you can see that 'Suspended with no actor' is the server's doing"
lab_note "and not a failed reconcile."

LAB_REDIS_PORT="${AXLAB_REDIS_PORT:-$(lab_pick_redis_port)}" || fail "no free Redis host port"
LAB_SERVER_ADDR="${AXLAB_SERVER_ADDR:-$(lab_pick_server_addr)}" || fail "no free API server port"
lab_note "redis $LAB_REDIS_PORT, api server $LAB_SERVER_ADDR"
lab_note "(the lab brief asked for 16379/18081; both are contended on this shared"
lab_note " machine, so the defaults are the lab-owned 16390/18091. Force the"
lab_note " brief's ports with AXLAB_REDIS_PORT=16379 AXLAB_SERVER_ADDR=127.0.0.1:18081)"

lab_start_redis || fail "${LAB_ERROR:-could not start Redis}"
lab_start_server || fail "${LAB_ERROR:-could not start ax-server}"
lab_note "ax-server pid $LAB_SERVER_PID"

# --- fixtures ---------------------------------------------------------------

cat >"$LAB_TMP/task.yaml" <<'YAML'
apiVersion: ax.io/v1alpha1
kind: Task
metadata:
  name: lab-task
  atespace: default
spec:
  image: example/task-runner:latest
  env:
    - name: ENVIRONMENT
      value: "lab"
  workspaces:
    - name: lab-workspace
      goal: "make the tests pass"
YAML

cat >"$LAB_TMP/task-changed.yaml" <<'YAML'
apiVersion: ax.io/v1alpha1
kind: Task
metadata:
  name: lab-task
  atespace: default
spec:
  image: example/task-runner:V2-DIFFERENT
  env:
    - name: ENVIRONMENT
      value: "lab"
  workspaces:
    - name: lab-workspace
      goal: "make the tests pass"
YAML

cat >"$LAB_TMP/workspace.yaml" <<'YAML'
apiVersion: ax.io/v1alpha1
kind: Workspace
metadata:
  name: lab-workspace
  atespace: default
spec:
  files:
    - path: /workspace/NOTES.md
      content: "first revision"
YAML

cat >"$LAB_TMP/workspace-changed.yaml" <<'YAML'
apiVersion: ax.io/v1alpha1
kind: Workspace
metadata:
  name: lab-workspace
  atespace: default
spec:
  files:
    - path: /workspace/NOTES.md
      content: "second revision - this update is allowed"
YAML

cat >"$LAB_TMP/model.yaml" <<'YAML'
apiVersion: ax.io/v1alpha1
kind: Model
metadata:
  name: lab-model
  atespace: default
spec:
  provider: google
  model: gemini-3.8-flash
  secretKey:
    name: lab-gemini-secret
    key: GEMINI_API_KEY
YAML

cat >"$LAB_TMP/model-changed.yaml" <<'YAML'
apiVersion: ax.io/v1alpha1
kind: Model
metadata:
  name: lab-model
  atespace: default
spec:
  provider: google
  model: gemini-3.8-flash
  parameters:
    temperature: 0.2
  secretKey:
    name: lab-gemini-secret
    key: GEMINI_API_KEY
YAML

# --- 1. create ---------------------------------------------------------------

lab_section "1. create the task (and the workspace it binds)"
lab_cmd "AX_SERVER=$LAB_SERVER_ADDR ax apply -f workspace.yaml"
WS1="$(lab_ax apply -f "$LAB_TMP/workspace.yaml")" || fail "workspace apply failed: $WS1"
printf '%s\n' "$WS1" | sed 's/^/  /'
lab_cmd "AX_SERVER=$LAB_SERVER_ADDR ax apply -f model.yaml"
M1="$(lab_ax apply -f "$LAB_TMP/model.yaml")" || fail "model apply failed: $M1"
printf '%s\n' "$M1" | sed 's/^/  /'
lab_cmd "AX_SERVER=$LAB_SERVER_ADDR ax apply -f task.yaml"
T1="$(lab_ax apply -f "$LAB_TMP/task.yaml")" || fail "task apply failed: $T1"
printf '%s\n' "$T1" | sed 's/^/  /'
expect "the task was created" "task.ax.io/lab-task created" "$T1"

# --- 2. a new task is Suspended, with no actor -------------------------------

lab_section "2. a brand new task is Suspended, with no actor"
lab_cmd "AX_SERVER=$LAB_SERVER_ADDR ax get tasks"
GET_TASKS="$(lab_ax get tasks)" || fail "ax get tasks failed"
printf '%s\n' "$GET_TASKS" | sed 's/^/  /'
expect "phase is Suspended" "Suspended" "$GET_TASKS"
expect "actor is <none>"    "<none>"    "$GET_TASKS"
expect "worker IP is <none>" "<none>"   "$GET_TASKS"
lab_note "This is not a failure state. CreateTask hardcodes it:"
lab_note "  internal/server/server.go:141  task.Status.Phase = \"Suspended\""
lab_note "Nothing in the API server ever sets an actor or a worker IP; only the"
lab_note "controller does (internal/controller/reconciler.go), and it is not running."

lab_cmd "AX_SERVER=$LAB_SERVER_ADDR ax describe task lab-task"
DESCRIBE="$(lab_ax describe task lab-task)" || fail "ax describe failed"
printf '%s\n' "$DESCRIBE" | sed 's/^/  /'
expect "describe shows Phase: Suspended" "Phase:        Suspended" "$DESCRIBE"
lab_note "Actor: and Worker IP: print as empty lines, not <none>. The <none>"
lab_note "substitution only happens in the ax get table (cmd/ax/main.go:365-370)."

# --- 3. watch a task that never resumes --------------------------------------

lab_section "3. watch a task that never resumes"
lab_cmd "timeout 6 env AX_SERVER=$LAB_SERVER_ADDR ax watch task lab-task   # then killed on purpose"
WATCH_OUT="$(timeout 6 env AX_SERVER="$LAB_SERVER_ADDR" "$LAB_AX_BIN" watch task lab-task 2>&1 || true)"
printf '%s\n' "$WATCH_OUT" | sed 's/^/  /'
WATCH_LINES="$(printf '%s\n' "$WATCH_OUT" | grep -c '^\[' || true)"
if [ "$WATCH_LINES" -ne 1 ]; then
  fail "expected exactly 1 watch line (the INITIAL snapshot) in 6s of a Suspended task, got $WATCH_LINES:
$WATCH_OUT"
fi
lab_note "  PASS  exactly one watch line: the server sends the current state once"
lab_note "        as action INITIAL (internal/server/server.go:232-236) and then"
lab_note "        blocks on the Redis pub/sub channel. No phase change, no line."
lab_note "  note: ax watch also exits on Running (cmd/ax/main.go:715-718), so it"
lab_note "        stops long before the task finishes. It is not a completion tool."

# --- 4. TRAP: a Task is immutable -------------------------------------------

lab_section "4. TRAP: re-applying a Task fails, even unchanged"
LAB_EXPECT_KEY="ax:task:default:lab-task"
lab_assert_redis || fail "${LAB_ERROR:-redis went away before section 4}"
lab_cmd "AX_SERVER=$LAB_SERVER_ADDR ax apply -f task.yaml            # byte-identical re-apply"
set +e
SAME_OUT="$(lab_ax apply -f "$LAB_TMP/task.yaml" 2>&1)"
SAME_RC=$?
set -e
printf '%s\n' "$SAME_OUT" | sed 's/^/  /'
lab_note "  exit code: $SAME_RC"
[ "$SAME_RC" -ne 0 ] || fail "re-applying an unchanged Task was accepted; the lesson claim is wrong"
expect "rejected with FailedPrecondition" "code = FailedPrecondition" "$SAME_OUT"
expect "with the immutability message"    "already exists and is immutable" "$SAME_OUT"

lab_cmd "AX_SERVER=$LAB_SERVER_ADDR ax apply -f task-changed.yaml   # changed image"
set +e
CHG_OUT="$(lab_ax apply -f "$LAB_TMP/task-changed.yaml" 2>&1)"
CHG_RC=$?
set -e
printf '%s\n' "$CHG_OUT" | sed 's/^/  /'
lab_note "  exit code: $CHG_RC"
[ "$CHG_RC" -ne 0 ] || fail "re-applying a changed Task was accepted; the lesson claim is wrong"
expect "rejected with FailedPrecondition" "code = FailedPrecondition" "$CHG_OUT"
expect "with the immutability message"    "already exists and is immutable" "$CHG_OUT"
lab_note "The check is on existence, not on a diff: internal/server/server.go:127-133"
lab_note "does GetTask and rejects anything that comes back without ErrNotFound."
lab_note "That is why the identical re-apply above fails too. To change a task you"
lab_note "must delete it first, and ax delete task needs a controller to finish"
lab_note "the teardown (internal/server/server.go:148-165, store.go:284-316)."

lab_cmd "AX_SERVER=$LAB_SERVER_ADDR ax get task lab-task   # look at the stored spec"
STORED_TASK="$(lab_ax get task lab-task)"
printf '%s\n' "$STORED_TASK" | grep -E '^ +image:' | sed 's/^/  /'
printf '%s\n' "$STORED_TASK" | grep -E '^ +path:' -A0 | sed 's/^/  /' || true
refute "the rejected apply did NOT change the image" "V2-DIFFERENT" "$STORED_TASK"
expect "the stored image is still the original" "image: example/task-runner:latest" "$STORED_TASK"

# --- 5. the contrast: Workspace and Model are mutable -----------------------

lab_section "5. Workspace and Model take the same re-apply happily"
lab_cmd "AX_SERVER=$LAB_SERVER_ADDR ax apply -f workspace.yaml            # again, unchanged"
WS2="$(lab_ax apply -f "$LAB_TMP/workspace.yaml")" || fail "workspace re-apply failed: $WS2"
printf '%s\n' "$WS2" | sed 's/^/  /'
expect "unchanged workspace is a no-op" "workspace.ax.io/lab-workspace unchanged" "$WS2"

lab_cmd "AX_SERVER=$LAB_SERVER_ADDR ax apply -f workspace-changed.yaml   # changed"
WS3="$(lab_ax apply -f "$LAB_TMP/workspace-changed.yaml")" || fail "workspace update failed: $WS3"
printf '%s\n' "$WS3" | sed 's/^/  /'
expect "changed workspace is configured" "workspace.ax.io/lab-workspace configured" "$WS3"

lab_cmd "AX_SERVER=$LAB_SERVER_ADDR ax apply -f model-changed.yaml       # changed"
M2="$(lab_ax apply -f "$LAB_TMP/model-changed.yaml")" || fail "model update failed: $M2"
printf '%s\n' "$M2" | sed 's/^/  /'
expect "changed model is configured" "model.ax.io/lab-model configured" "$M2"

lab_cmd "AX_SERVER=$LAB_SERVER_ADDR ax get workspace lab-workspace"
STORED_WS="$(lab_ax get workspace lab-workspace)"
printf '%s\n' "$STORED_WS" | sed 's/^/  /'
expect "the workspace update actually landed" "second revision - this update is allowed" "$STORED_WS"
refute "the first revision is gone" "first revision" "$STORED_WS"
lab_note "The 'unchanged' vs 'configured' wording comes from the CLI comparing"
lab_note "the new spec against the stored one (cmd/ax/main.go:315-326). Only"
lab_note "Workspace and Model reach that code path: Task goes to CreateTask,"
lab_note "which is a create-only RPC (cmd/ax/main.go:266-276)."

lab_cmd "AX_SERVER=$LAB_SERVER_ADDR ax get model lab-model"
lab_ax get model lab-model | sed 's/^/  /'

# --- 6. resume is the only thing that starts the lifecycle ------------------

lab_section "6. resume: the one transition you have to ask for"
lab_cmd "AX_SERVER=$LAB_SERVER_ADDR ax resume task lab-task"
RES="$(lab_ax resume task lab-task)" || fail "ax resume failed: $RES"
printf '%s\n' "$RES" | sed 's/^/  /'
expect "resume acknowledged" "task.ax.io/lab-task resumed" "$RES"

lab_cmd "AX_SERVER=$LAB_SERVER_ADDR ax describe task lab-task"
DESCRIBE2="$(lab_ax describe task lab-task)"
printf '%s\n' "$DESCRIBE2" | sed 's/^/  /'
expect "phase is now Running" "Phase:        Running" "$DESCRIBE2"
lab_note "Actor is still empty, and it will stay empty: ResumeTask only flips the"
lab_note "phase (internal/server/server.go:192-215). Creating the actor is the"
lab_note "controller's job, and there is no controller in this lesson. A Task in"
lab_note "Running with no actor is a stuck task, not a running one."

lab_cmd "AX_SERVER=$LAB_SERVER_ADDR ax get tasks"
lab_ax get tasks | sed 's/^/  /'

# --- 7. conditions: the other half of TaskStatus ---------------------------

lab_section "7. conditions: the other half of TaskStatus, and why it is empty here"
lab_note "TaskStatus.conditions is field 7 (pkg/apis/v1alpha1/ax.proto:112), a"
lab_note "repeated Condition{type, status, lastTransitionTime, reason, message}"
lab_note "(ax.proto:126-132). ax defines exactly two condition types, both in the"
lab_note "controller: Ready and WorkspaceReady (reconciler.go:302-309). Upstream's"
lab_note "own README advertises 'ax watch task <name>  # stream phase and"
lab_note "condition changes live' (README.md:101 and :137), so this section shows"
lab_note "what a real task actually carries - on the real server, just resumed."

lab_cmd "AX_SERVER=$LAB_SERVER_ADDR ax describe task lab-task"
DESCRIBE3="$(lab_ax describe task lab-task)" || fail "ax describe failed"
printf '%s\n' "$DESCRIBE3" | sed 's/^/  /'
# cmd/ax/main.go:658-666 renders the Conditions: table only when
# len(conditions) > 0, so its ABSENCE is the observation, not a display bug.
refute "no Conditions: table, even though the phase is Running" "Conditions:" "$DESCRIBE3"

# The same fact from the store rather than the CLI, through a real JSON
# decoder. "the value is protojson" is otherwise only prose; jq -e turns it
# into a check that either parses or fails the lesson.
lab_cmd "redis-cli get ax:task:default:lab-task | jq -e '.status'"
# Re-asserted rather than inherited from section 4: if LAB_EXPECT_KEY were
# renamed there, this section would silently read a different task.
LAB_EXPECT_KEY="ax:task:default:lab-task"
STORED3="$(lab_redis get "$LAB_EXPECT_KEY")" || fail "could not read $LAB_EXPECT_KEY"
[ -n "$STORED3" ] || fail "$LAB_EXPECT_KEY is empty"
printf '%s' "$STORED3" | jq -e . >/dev/null \
  || fail "the stored task is not valid JSON: $STORED3"
lab_note "  PASS  the stored value parses as JSON (protojson, store.go:146)"
printf '%s' "$STORED3" | jq -e '.status' | sed 's/^/  /'
STORE_PHASE="$(printf '%s' "$STORED3" | jq -r '.status.phase')"
[ "$STORE_PHASE" = "Running" ] \
  || fail "stored phase is \"$STORE_PHASE\", want \"Running\" after resume"
STORE_CONDS="$(printf '%s' "$STORED3" | jq -r '.status.conditions // "absent"')"
[ "$STORE_CONDS" = "absent" ] \
  || fail "expected no conditions in the stored task, got: $STORE_CONDS"
lab_note "  PASS  .status.phase is Running and .status.conditions is absent"
lab_note "        (protojson omits an empty repeated field, so 'absent' is the"
lab_note "        correct encoding of 'zero conditions', not a parse miss)"

# The decisive part: WHO could write a condition. This is a grep over source
# (READ, not executed) that is nevertheless asserted, because it is what makes
# the emptiness above explainable rather than mysterious.
lab_cmd "grep -rn 'Status\\.Conditions' upstream/google-ax --include='*.go'"
COND_REFS="$(cd "$UPSTREAM" && grep -rn 'Status\.Conditions' --include='*.go' . | grep -v '_test\.go' || true)"
printf '%s\n' "$COND_REFS" | sed 's/^/    /'
# reconciler.go writes conditions; cmd/ax/main.go:630 only reads them for the
# describe table. Nothing else in the tree may touch the field.
UNEXPECTED_COND="$(printf '%s\n' "$COND_REFS" \
  | grep -v '^\./internal/controller/reconciler\.go:' \
  | grep -v '^\./cmd/ax/main\.go:' || true)"
[ -z "$UNEXPECTED_COND" ] \
  || fail "a non-controller file now touches Status.Conditions, so the 'no conditions without a controller' claim is stale: $UNEXPECTED_COND"
lab_note "  PASS  every non-test reference to Status.Conditions is in"
lab_note "        internal/controller/reconciler.go (the writer) or"
lab_note "        cmd/ax/main.go:630 (the describe table). No other file can"
lab_note "        produce a condition, and ax-server is not among them."

lab_note ""
lab_note "  READ, not executed - the two lines that would create the conditions"
lab_note "  you asked about. Neither can run in this lesson: both are inside the"
lab_note "  controller's reconcile loop, which needs a Substrate atespace and a"
lab_note "  real sandbox (Phase 2/3)."
lab_note "  reconciler.go:201  Ready=False  TaskSuspended  \"Task is suspended\""
show_src "$UPSTREAM/internal/controller/reconciler.go" 200 201
lab_note "  reconciler.go:285  Ready=True   TaskRunning    \"...workspace is ready\""
show_src "$UPSTREAM/internal/controller/reconciler.go" 284 285

lab_note ""
lab_note "  So, plainly: in Phase 1 a task carries ZERO conditions. That is the"
lab_note "  correct observation, not an omission in this lesson, and nothing here"
lab_note "  simulates a Running condition to paper over it. Concretely:"
lab_note "    * ax-server never writes one. CreateTask hardcodes"
lab_note "      phase=\"Suspended\" (server.go:141) and ResumeTask only flips the"
lab_note "      phase (server.go:192-215) - which is exactly why the table above"
lab_note "      is still empty after the resume in section 6."
lab_note "    * Ready=True/TaskRunning and WorkspaceReady=True/SetupComplete"
lab_note "      (reconciler.go:283, :285) require the controller to poll a"
lab_note "      workspace that has finished setup inside a live actor."
lab_note "    * the task runner's own workspace-ready signal is NOT a condition."
lab_note "      It is a readiness endpoint the controller polls; lesson 05 runs"
lab_note "      that endpoint for real. Turning it into a Condition is the"
lab_note "      controller's step, not the runner's."
lab_note "  That is the honest version of 'stream phase and condition changes':"
lab_note "  in Phase 1 there is nothing to stream but the one INITIAL snapshot"
lab_note "  section 3 already counted."

# --- 8. TRAP: the model client fabricates output ----------------------------

lab_section "8. SELF-CONTAINED, off-topic: internal/model fabricates a plan"
lab_note "Everything from here to section 9 is a SEPARATE topic stapled onto this"
lab_note "lifecycle lesson. Nothing below has to do with phases, conditions or the"
lab_note "immutability rule, and you can skip it without missing anything above."
lab_note "It is here because the model client is the one part of ax that fails"
lab_note "*silently*, which is worth knowing about even though nothing in a task"
lab_note "run reaches it yet."
lab_note ""
lab_note "EXECUTED below. The file is compiled into the upstream module with"
lab_note "go test -overlay, so it runs the real internal/model code. Nothing is"
lab_note "written into the upstream clone."
OVERLAY="$LAB_TMP/model-overlay.json"
cat >"$OVERLAY" <<JSON
{"Replace":{"$UPSTREAM/internal/model/zz_lab_fallback_test.go":"$LAB_ROOT/testdata/overlay/modelfallback/fallback_test.go"}}
JSON
lab_cmd "cd upstream/google-ax && go test -count=1 -overlay \$TMP/model-overlay.json ./internal/model/ -run TestLabFallback -v"
set +e
MODEL_OUT="$(cd "$UPSTREAM" && go test -count=1 -overlay "$OVERLAY" ./internal/model/ -run TestLabFallback -v 2>&1)"
MODEL_RC=$?
set -e
printf '%s\n' "$MODEL_OUT" | sed 's/^/  /'
[ "$MODEL_RC" -eq 0 ] || fail "the model fabrication probe failed (exit $MODEL_RC)"
refute "the probe really ran this time (not a cached result)" "(cached)" "$MODEL_OUT"
[ -e "$UPSTREAM/internal/model/zz_lab_fallback_test.go" ] \
  && fail "the overlay leaked a file into the upstream clone"
# The per-case assertions are the Go probe's: every status code has its own
# t.Fatalf/t.Errorf, and the MODEL_RC check above is what turns a failed one
# into a failed lesson. These greps are spot-checks that the probe really
# produced both shapes of outcome. There is deliberately one grep per *distinct*
# needle and not one per status code: "FABRICATED, err == nil" matches all four
# of 401/403/429/503, so four greps of it would look like four checks while
# being one.
expect "no key produced the canned plan" "Synthesized plan using" "$MODEL_OUT"
expect "no key produced invented token counts" "usage   = prompt=" "$MODEL_OUT"
expect "the 401/403/429/503 group fabricated (>=1 case, err == nil)" "FABRICATED, err == nil" "$MODEL_OUT"
expect "the 400/500 controls were NOT swallowed (>=1 case)" "propagated as an error" "$MODEL_OUT"
expect "HTTP 200 really called through" "REAL ANSWER FROM THE SERVER" "$MODEL_OUT"
lab_note "  PASS  per-status-code coverage comes from the probe's own t.Fatalf/"
lab_note "        t.Errorf per case plus its exit code, not from these greps."
lab_note "  PASS  the upstream clone is still untouched (no zz_lab_fallback_test.go)."

lab_note ""
lab_note "Is this reachable from a task run? Not in this revision. Non-test"
lab_note "callers of Client.Generate:"
GEN_CALLERS="$(cd "$UPSTREAM" && grep -rn '\.Generate(' --include='*.go' . | grep -v '_test\.go' || true)"
[ -n "$GEN_CALLERS" ] && printf '%s\n' "$GEN_CALLERS" | sed 's/^/    /'
lab_note "Non-test callers of Planner.PlanEnvironment:"
PLAN_CALLERS="$(cd "$UPSTREAM" && grep -rn 'PlanEnvironment(' --include='*.go' . | grep -v '_test\.go' | grep -v 'planner\.go' || true)"
if [ -z "$PLAN_CALLERS" ]; then
  lab_note "    (none)"
  lab_note "So no shipped binary can reach fallbackResponse today: the planner is"
  lab_note "the only bridge and nothing calls it. The moment something does, the"
  lab_note "failure is silent - err == nil, a plausible plan, invented token"
  lab_note "counts. The lab brief's claim that a keyless task run produces a fake"
  lab_note "plan does not hold for this revision; the behaviour it describes is"
  lab_note "real and is demonstrated above, but the call site is missing."
else
  printf '%s\n' "$PLAN_CALLERS" | sed 's/^/    /'
  lab_note "  (upstream changed: something now calls the planner, so a task run"
  lab_note "   may reach the fallback. Re-read the section above.)"
fi

# --- 8. the source, for reading --------------------------------------------

lab_section "9. the code behind both traps (READ, not executed)"
lab_note "every excerpt below is printed with its real line number"
lab_note "internal/model/client.go:500 - empty key or DisableRemote"
show_src "$MODEL_CLIENT" 498 502
lab_note "internal/model/client.go:563-569 - which HTTP statuses are swallowed"
show_src "$MODEL_CLIENT" 563 569
lab_note "internal/model/client.go:608-621 - the canned text and the fake usage"
show_src "$MODEL_CLIENT" 608 621
lab_note "internal/server/server.go:127-133 - existence, not diff"
show_src "$UPSTREAM/internal/server/server.go" 127 133
lab_note "internal/server/server.go:141 - where Suspended comes from"
show_src "$UPSTREAM/internal/server/server.go" 138 142

echo "PASS: $NAME"
