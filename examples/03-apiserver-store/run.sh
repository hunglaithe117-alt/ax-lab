#!/usr/bin/env bash
# Lesson 03 - the API server is a thin gRPC shim over a Redis store.
#
# Everything below is the real prebuilt binary, the real CLI, and a real Redis
# container. No Kubernetes, no cluster, no network egress beyond loopback.
#
# The executable claim of this lesson: kill ax-server, start a *new*
# ax-server process, and the objects are still there. That is only possible
# because the state lives in Redis.
#
# Prints exactly one of
#   PASS: 03-apiserver-store   (exit 0)
#   FAIL: 03-apiserver-store   (exit non-zero, with the reason above it)
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
LAB_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd)"
UPSTREAM="$LAB_ROOT/upstream/google-ax"
# The binaries a lesson executes come from the lab's own bin/, not from
# upstream/google-ax/bin/. That is the directory scripts/setup.sh installs into
# and the one scripts/verify-all.sh checks (`MISSING ax-lab/bin/ax` is a real
# signal), so if this lesson ran the upstream copies instead, deleting
# ax-lab/bin/ax would print MISSING in the gate and still leave every lesson
# green. Lesson 05 already works this way.
BIN_DIR="$LAB_ROOT/bin"
NAME="03-apiserver-store"

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

# --- preflight --------------------------------------------------------------

[ -x "$BIN_DIR/ax" ]       || fail "missing the lab's prebuilt CLI at $BIN_DIR/ax (build it with ./scripts/setup.sh)"
[ -x "$BIN_DIR/ax-server" ] || fail "missing the lab's prebuilt server at $BIN_DIR/ax-server (build it with ./scripts/setup.sh)"
command -v docker >/dev/null || fail "docker is required"
command -v curl   >/dev/null || fail "curl is required"
command -v jq     >/dev/null || fail "jq is required (section 3 decodes the stored task as JSON)"

LAB_AX_BIN="$BIN_DIR/ax"
LAB_AX_SERVER_BIN="$BIN_DIR/ax-server"

lab_section "picking host ports for the lesson's Redis and API server"
LAB_REDIS_PORT="${AXLAB_REDIS_PORT:-$(lab_pick_redis_port)}" \
  || fail "could not find a free host port for Redis"
LAB_SERVER_ADDR="${AXLAB_SERVER_ADDR:-$(lab_pick_server_addr)}" \
  || fail "could not find a free host port for the API server"
lab_note "container : $LAB_REDIS_CONTAINER ($LAB_REDIS_IMAGE)"
lab_note "redis port: $LAB_REDIS_PORT  (host) -> 6379 (container)"
lab_note "api server: $LAB_SERVER_ADDR  (--addr)  --redis-addr 127.0.0.1:$LAB_REDIS_PORT"
lab_note "the lab brief asked for host port 16379 and api port 18081. Both are"
lab_note "taken on this shared machine (another project publishes 16379, another"
lab_note "lesson in this track binds 18081), and either can be torn down mid-run,"
lab_note "so the defaults here are the lab-owned 16390 / 18091. Force the brief's"
lab_note "ports with:  AXLAB_REDIS_PORT=16379 AXLAB_SERVER_ADDR=127.0.0.1:18081"

lab_start_redis || fail "${LAB_ERROR:-could not start Redis}"
lab_start_server  || fail "${LAB_ERROR:-could not start ax-server}"
lab_note "ax-server pid $LAB_SERVER_PID, log at ${LAB_LOG_FILE}"

# --- 1. apply ---------------------------------------------------------------

lab_section "1. apply a real manifest through the real CLI"
lab_cmd "AX_SERVER=$LAB_SERVER_ADDR ax apply -f upstream/google-ax/examples/task.yaml"
APPLY_OUT="$(lab_ax apply -f "$UPSTREAM/examples/task.yaml")" || fail "ax apply failed: $APPLY_OUT"
printf '%s\n' "$APPLY_OUT" | sed 's/^/  /'
for want in "task.ax.io/task123 created" \
            "workspace.ax.io/default-workspace created" \
            "model.ax.io/default-model created"; do
  printf '%s\n' "$APPLY_OUT" | grep -qF "$want" || fail "expected \"$want\" in apply output"
done
lab_note "three documents in one file, three typed RPCs (cmd/ax/main.go:266-302):"
lab_note "  Task      -> CreateTask"
lab_note "  Workspace -> GetWorkspace + UpdateWorkspace"
lab_note "  Model     -> GetModel + UpdateModel"
lab_note "the server never sees YAML; the CLI decodes it and sends protobufs."

# --- 2. read back -----------------------------------------------------------

lab_section "2. read it back"
for res in tasks workspaces models; do
  lab_cmd "AX_SERVER=$LAB_SERVER_ADDR ax get $res"
  lab_ax get "$res" | sed 's/^/  /'
done
lab_cmd "AX_SERVER=$LAB_SERVER_ADDR ax describe task task123"
lab_ax describe task task123 | sed 's/^/  /'
lab_note "Phase is Suspended with no actor: CreateTask hardcodes it"
lab_note "(internal/server/server.go:141). See lesson 04."

# --- 3. where the state actually is -----------------------------------------

lab_section "3. the state is literally in Redis, not in the process"
lab_cmd "docker exec $LAB_REDIS_CONTAINER redis-cli keys 'ax:*'"
lab_redis keys 'ax:*' | sort | sed 's/^/  /'
lab_redis keys 'ax:*' | grep -qx 'ax:task:default:task123' \
  || fail "expected key ax:task:default:task123 to exist"
lab_cmd "docker exec $LAB_REDIS_CONTAINER redis-cli get ax:task:default:task123"
lab_redis get ax:task:default:task123 | sed 's/^/  /'
lab_note "The value is protojson (internal/store/redis/store.go:146). Prose is"
lab_note "not a check, so it goes through a real JSON decoder: if the store ever"
lab_note "stopped writing JSON, this fails the lesson instead of being believed."
STORED_TASK_JSON="$(lab_redis get ax:task:default:task123)"
[ -n "$STORED_TASK_JSON" ] || fail "ax:task:default:task123 held no value"
printf '%s' "$STORED_TASK_JSON" | jq -e . >/dev/null \
  || fail "the stored task is not valid JSON: $STORED_TASK_JSON"
lab_note "  PASS  jq -e parsed it: it really is one JSON object"
printf '%s' "$STORED_TASK_JSON" | jq -e '{apiVersion, kind, name: .metadata.name, phase: .status.phase}' | sed 's/^/  /'
# The key layout, one sentence per family. Constructors are named in
# store.go:81-120; the split is record / index / atespace-index / pubsub.
lab_note ""
lab_note "  what each key is for. Three shapes, and every one of them is a"
lab_note "  constructor named in internal/store/redis/store.go:"
lab_note ""
lab_note "  1. THE OBJECT (a plain string holding protojson)"
lab_note "     ax:task:default:task123            the whole Task, one key"
lab_note "       (taskKey, store.go:81-83)"
lab_note "     ax:workspace:default:default-workspace   wsKey, :98-100"
lab_note "     ax:model:default:default-model          modelKey, :86-88"
lab_note ""
lab_note "  2. THE INDEXES (so listing is a ZRANGE, never a KEYS scan)"
lab_note "     ax:tasks:index                      sorted set of <atespace>:<name>"
lab_note "                                            (taskIndexKey, :110-112)"
lab_note "     ax:tasks:atespace:default           sorted set of just the names in"
lab_note "                                            one atespace, so a listing can"
lab_note "                                            skip the other atespaces"
lab_note "                                            (taskAtespaceIndexKey, :114-116)"
lab_note "     ax:workspaces:index / ax:workspaces:atespace:default"
lab_note "     ax:models:index     / ax:models:atespace:default"
lab_note "                                            the same two shapes,"
lab_note "                                            :90-96 and :102-108"
lab_note "     So a delete is not one DEL. DeleteTask is a DEL of the record plus"
lab_note "     a ZREM from each of the two indexes (store.go:319-333), which is"
lab_note "     exactly why those index constructors exist."
lab_note ""
lab_note "  3. THE WORK QUEUE"
lab_note "     ax:stream:tasks                     a Redis STREAM; every SaveTask"
lab_note "                                            XADDs a reconcile event"
lab_note "                                            (defaultStreamName, :32; used"
lab_note "                                            at :161 and :305). The"
lab_note "                                            controller is the consumer"
lab_note "                                            (Subscribe, :590-655). It is"
lab_note "                                            the reason millions of"
lab_note "                                            short-lived tasks are not"
lab_note "                                            Kubernetes objects."
lab_note ""
lab_note "  Mental model: one blob per object, indexes to find them, a stream to"
lab_note "  be told about them. There is also a pub/sub channel per task"
lab_note "  (ax:pubsub:task:<atespace>:<name>, taskPubSubChannel :118-120) which is"
lab_note "  what 'ax watch' subscribes to - pub/sub channels are not keys, so it"
lab_note "  does not appear in the listing above."

BEFORE_TASK_JSON="$(lab_redis get ax:task:default:task123)"
BEFORE_TS="$(printf '%s' "$BEFORE_TASK_JSON" | sed -n 's/.*"creationTimestamp":"\([^"]*\)".*/\1/p')"
BEFORE_AGE="$(lab_ax get tasks | awk 'NR==2 {print $NF}')"
[ -n "$BEFORE_TS" ] || fail "could not read creationTimestamp out of the stored task"
lab_note "record creationTimestamp: $BEFORE_TS   (ax get tasks reports AGE $BEFORE_AGE)"

# --- 4. restart the API server ---------------------------------------------

lab_section "4. kill ax-server, start a new one, and look again"
# Sleep so the AGE column visibly advances *across* the restart. A brand new
# process that had re-created the record would restart the clock at 0s.
sleep 2
OLD_PID="$LAB_SERVER_PID"
lab_cmd "kill $OLD_PID   # ax-server pid before restart"
lab_stop_server
kill -0 "$OLD_PID" 2>/dev/null && fail "ax-server pid $OLD_PID survived the kill"
lab_note "pid $OLD_PID is gone. Nothing in that process's memory survived with it."

lab_start_server || fail "${LAB_ERROR:-could not restart ax-server}"
NEW_PID="$LAB_SERVER_PID"
[ "$NEW_PID" != "$OLD_PID" ] || fail "ax-server pid did not change across the restart"
lab_note "new ax-server pid $NEW_PID ($OLD_PID -> $NEW_PID), same --addr, same Redis."

lab_cmd "AX_SERVER=$LAB_SERVER_ADDR ax get tasks"
AFTER_TASKS="$(lab_ax get tasks)" || fail "ax get tasks failed after restart"
printf '%s\n' "$AFTER_TASKS" | sed 's/^/  /'
printf '%s\n' "$AFTER_TASKS" | grep -q 'task123' \
  || fail "task123 did not survive the ax-server restart"

lab_cmd "AX_SERVER=$LAB_SERVER_ADDR ax get workspaces"
lab_ax get workspaces | sed 's/^/  /'
lab_cmd "AX_SERVER=$LAB_SERVER_ADDR ax get models"
lab_ax get models | sed 's/^/  /'

AFTER_TASK_JSON="$(lab_redis get ax:task:default:task123)"
AFTER_TS="$(printf '%s' "$AFTER_TASK_JSON" | sed -n 's/.*"creationTimestamp":"\([^"]*\)".*/\1/p')"
[ "$BEFORE_TASK_JSON" = "$AFTER_TASK_JSON" ] \
  || fail "the stored task changed across the restart"
[ "$BEFORE_TS" = "$AFTER_TS" ] \
  || fail "creationTimestamp changed across the restart: $BEFORE_TS -> $AFTER_TS"
AFTER_AGE="$(printf '%s\n' "$AFTER_TASKS" | awk 'NR==2 {print $NF}')"
[ "$AFTER_AGE" != "$BEFORE_AGE" ] \
  || fail "AGE did not advance across the restart ($BEFORE_AGE -> $AFTER_AGE); the check proves nothing"
lab_note "stored bytes identical before and after: yes"
lab_note "creationTimestamp after restart: $AFTER_TS (unchanged)"
lab_note "AGE went $BEFORE_AGE -> $AFTER_AGE across a brand new server process."
lab_note "ax computes AGE from the record's own creationTimestamp"
lab_note "(cmd/ax/main.go:377-379), so a fresh process that had re-created"
lab_note "the task would show 0s. Conclusion: the API server holds no state."

# --- 5. the in-memory store exists but is not wired in ---------------------

lab_section "5. READ, not executed: internal/store/memory is not wired in"
lab_note "Everything in this section is grep/go-test over the upstream source. No"
lab_note "ax-server behaviour is demonstrated here; sections 1-4 and 5b are the"
lab_note "executed parts. It is labelled separately so a reader knows which lines"
lab_note "are the binary talking and which are the source being read."

lab_cmd "grep -n 'internal/store' upstream/google-ax/cmd/ax-server/main.go"
grep -n 'internal/store' "$UPSTREAM/cmd/ax-server/main.go" | sed 's/^/  /'
grep -q 'internal/store/redis' "$UPSTREAM/cmd/ax-server/main.go" \
  || fail "expected cmd/ax-server/main.go to import the redis store"

lab_cmd "grep -n 'redis.NewStore' upstream/google-ax/cmd/ax-server/main.go"
grep -n 'redis.NewStore' "$UPSTREAM/cmd/ax-server/main.go" | sed 's/^/  /'
lab_note "The redis store is constructed unconditionally at cmd/ax-server/main.go:65-66."
lab_note "Scoped claim: in THIS file the three flags are -addr, -redis-addr and"
lab_note "-redis-password (main.go:39-41), the env overrides are ADDR, REDIS_ADDR"
lab_note "and REDIS_PASSWORD (main.go:44-52), and NewStore is called on the line"
lab_note "after them with no branch around it. So no flag or env var in"
lab_note "cmd/ax-server/main.go chooses a store. What that file alone cannot rule"
lab_note "out is a build tag or an init-time side effect elsewhere in the tree, so"
lab_note "the two checks below widen the evidence to the whole module rather than"
lab_note "concluding from one file."

lab_cmd "grep -n 'memory' upstream/google-ax/cmd/ax-server/main.go   # expect no match"
set +e
grep -n 'memory' "$UPSTREAM/cmd/ax-server/main.go"
GREP_RC=$?
set -e
if [ "$GREP_RC" -eq 0 ]; then
  fail "cmd/ax-server/main.go references the memory store; the lesson text is wrong"
fi
lab_note "no match, and grep exited $GREP_RC (1 = no lines selected)."

lab_cmd "grep -rln 'internal/store/memory' upstream/google-ax --include='*.go'"
( cd "$UPSTREAM" && grep -rln 'internal/store/memory' --include='*.go' . ) | sed 's/^/  /'
MEMORY_USERS="$(cd "$UPSTREAM" && grep -rln 'internal/store/memory' --include='*.go' . | grep -v '_test\.go$' || true)"
[ -z "$MEMORY_USERS" ] \
  || fail "non-test code uses the memory store: $MEMORY_USERS"
lab_note "every one of those is a _test.go file. No shipped binary constructs it."
lab_note "This is the check that carries the claim: it is module-wide, not"
lab_note "file-wide, so 'not reachable from the shipped binary' rests on the"
lab_note "import graph rather than on one file's contents."

# The one thing a file-scoped read cannot rule out was a build tag. Checked
# explicitly so the narrowed claim above is not just an assumption.
lab_cmd "grep -rn '^//go:build' upstream/google-ax/internal/store upstream/google-ax/cmd/ax-server --include='*.go'   # expect no match"
set +e
( cd "$UPSTREAM" && grep -rn '^//go:build' --include='*.go' internal/store cmd/ax-server )
TAG_RC=$?
set -e
[ "$TAG_RC" -eq 1 ] \
  || fail "a build constraint now exists under internal/store or cmd/ax-server; the 'no build tag chooses a store' claim needs revisiting"
lab_note "no match, grep exited $TAG_RC (1 = no lines selected). So there is no"
lab_note "build-constrained alternative implementation to be selected instead."

lab_cmd "go test ./internal/store/...    # inside the upstream clone"
( cd "$UPSTREAM" && go test ./internal/store/... 2>&1 ) | sed 's/^/  /'
lab_note "note the real output above: all three packages report 'no test files'."
lab_note "The memory store has no tests of its own, and the redis store has"
lab_note "none either. So 'run the store tests' is NOT evidence here; the"
lab_note "import graph is. (The lab brief expected otherwise.)"

# A real demonstration that the memory store is complete: compile it inside the
# upstream module via `go run -overlay`, which writes nothing to the clone.
lab_section "5b. what an in-memory harness would actually look like"
OVERLAY="$LAB_TMP/storeprobe-overlay.json"
cat >"$OVERLAY" <<JSON
{"Replace":{"$UPSTREAM/cmd/labstoreprobe/main.go":"$LAB_ROOT/testdata/overlay/storeprobe/main.go"}}
JSON
lab_note "virtual file: $UPSTREAM/cmd/labstoreprobe/main.go"
lab_note "real source:  testdata/overlay/storeprobe/main.go (never in the module build)"
lab_cmd "cd upstream/google-ax && go run -overlay \$TMP/storeprobe-overlay.json ./cmd/labstoreprobe"
( cd "$UPSTREAM" && go run -overlay "$OVERLAY" ./cmd/labstoreprobe ) | sed 's/^/  /' \
  || fail "the in-memory store probe did not run"
[ -e "$UPSTREAM/cmd/labstoreprobe" ] && fail "the overlay leaked a directory into the upstream clone"
lab_note "and the upstream clone is untouched: cmd/labstoreprobe does not exist."
lab_note ""
lab_note "what this means for you:"
lab_note "  * internal/store/memory implements the full store.Store interface, so"
lab_note "    the server's logic is store-agnostic - only the wiring is not."
lab_note "  * you cannot point the shipped ax-server at it. There is no flag."
lab_note "  * you cannot import it from your own module either: internal/ is"
lab_note "    unimportable outside github.com/google/ax. Writing an in-process"
lab_note "    test harness means either contributing a test inside the ax module"
lab_note "    or running the same Redis the shipped server uses."

echo "PASS: $NAME"
