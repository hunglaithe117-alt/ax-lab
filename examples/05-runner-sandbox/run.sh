#!/usr/bin/env bash
# 05-runner-sandbox -- what actually happens inside an ax task container.
#
# This lesson drives the REAL ax-task-runner binary as a local process and shows
# every claim by execution, not by assertion.
#
# READ THIS BEFORE TRUSTING ANY OUTPUT BELOW
# ------------------------------------------
# In a real cluster, spec.command runs *inside the task container image*, with
# the image's own PATH and filesystem. When you run the binary directly on a
# laptop the way this lesson does, there is no container: spec.command is exec'd
# against THIS host's PATH and THIS host's filesystem, as THIS user. Everything
# the runner does (workspace setup, marker file, AX_METADATA_URL, the HTTP
# surface) is real; the isolation around it is not. That is also why the two
# default paths below are unwritable here and writable in the real container,
# where the runner is PID 1 and runs as root.
#
# Source map (upstream/google-ax):
#   cmd/ax-task-runner/main.go:54-56  -port / -task-file / -workspace-file
#   cmd/ax-task-runner/main.go:75-80  signal.NotifyContext -> Run -> fatal
#   runner/runner.go:119-201          Run(): the boot sequence
#   runner/runner.go:140-144          AX_METADATA_URL + spec.env on the runner
#   runner/runner.go:146-149          metadata server starts BEFORE workspace setup
#   runner/runner.go:155-165          maiden run loop + SetWorkspaceReady
#   runner/runner.go:167-172          no spec.command -> serve metadata forever
#   runner/runner.go:174-187          exec of spec.command, cmd.Dir = 1st workspace
#   runner/runner.go:184-186          command-start failure is fatal
#   runner/runner.go:192-199          "<-ctx.Done()" -- the stay-alive invariant
#   runner/runner.go:205-220          SIGTERM to the process group, 10s grace
#   runner/runner.go:223-236          reportExit: the exit status is only logged
#   runner/runner.go:240-245          commandEnv(): AX_METADATA_URL + spec.env
#   internal/metadata/server.go:89    guest services off unless spec.debug
#   internal/metadata/server.go:93-100 the four registered HTTP routes
#   internal/metadata/server.go:180-197 /healthz and /readyz
#   internal/metadata/server.go:199-213 /metadata/v1alpha1/ax/task
#   internal/metadata/server.go:217-237 /metadata/v1alpha1/ax/workspaces
#   internal/workspace/setup.go:33    DefaultAXDir = "/ax"
#   internal/workspace/setup.go:64    var AXDir -- Go code is the only way to move it
#   internal/workspace/setup.go:83-105 SetupWorkspace + the marker existence check
#   internal/workspace/setup.go:94    mkdir of the workspace path (fails -> no ready)
#   internal/workspace/setup.go:97-99 /ax is best-effort: warn only
#   internal/workspace/setup.go:126   writeMarker
#   internal/workspace/setup.go:336-345 MarkerName(): path -> marker file name
#   internal/workspace/setup.go:348-357 marker file contents
#   internal/workspace/setup.go:380-400 writeFiles, the inlined spec.files
#   pkg/apis/v1alpha1/types.go:213    DefaultWorkspacePath = "/workspace"
#   pkg/apis/v1alpha1/types.go:233-244 WorkspacePaths()
#
# Contract: last line is exactly "PASS: 05-runner-sandbox" and exit 0, or
# "FAIL: 05-runner-sandbox" plus a reason and a non-zero exit.

set -uo pipefail

# ------------------------------------------------------------------ layout ---
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
LAB_ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
BIN_DIR="$LAB_ROOT/bin"
RUNNER_BIN="$BIN_DIR/ax-task-runner"
WORK="$LAB_ROOT/.work/05-runner-sandbox"

# Ports: 18080-18100 only. 80/6379/8080 belong to other projects on this host.
PORT_BASE="${AXLAB_RUNNER_PORT_BASE:-18080}"

# ------------------------------------------------------------------ output ---
if [ -t 1 ]; then RED=$'\033[31m'; GRN=$'\033[32m'; YEL=$'\033[33m'; B=$'\033[1m'; N=$'\033[0m'
else RED=""; GRN=""; YEL=""; B=""; N=""; fi

PRINTED=0
COMPLETED=0

hdr()  { printf '\n%s--- %s ---%s\n' "$B" "$*" "$N"; }
say()  { printf '%s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %sok%s   %s\n' "$GRN" "$N" "$*"; }
note() { printf '    %snote%s %s\n' "$YEL" "$N" "$*"; }

die() {
  PRINTED=1
  printf '\n%sFAIL: 05-runner-sandbox%s\n' "$B" "$N"
  printf 'reason: %s\n' "$*"
  exit 1
}

# ----------------------------------------------------------------- cleanup ---
# Every runner started here is registered and killed on every exit path.
PIDS=""
track() { PIDS="$PIDS $1"; }
untrack() { PIDS="${PIDS% $1}"; }

cleanup() {
  local p
  for p in $PIDS; do [ -n "$p" ] && kill -TERM "$p" 2>/dev/null; done
  sleep 0.3
  for p in $PIDS; do [ -n "$p" ] && kill -KILL "$p" 2>/dev/null; done
  PIDS=""
}

trap 'rc=$?
      cleanup
      if [ "$COMPLETED" -ne 1 ] && [ "$PRINTED" -ne 1 ]; then
        printf "\n%sFAIL: 05-runner-sandbox%s\n" "$B" "$N"
        # No line number here on purpose: inside an EXIT trap ${LINENO} is the
        # trap'"'"'s own line, so printing it points at nothing useful. And the
        # status is labelled as what it is -- the last command'"'"'s, not this
        # script'"'"'s -- because a SIGTERM from an external `timeout` lands on
        # this same path with a perfectly innocent-looking status.
        printf "reason: aborted before reaching a verdict (last command exited %s)\n" "$rc"
        printf "  a SIGTERM from an external timeout also lands here, and this trap\n"
        printf "  cannot tell the two apart; the number above is not the lesson exit code.\n"
        exit 1
      fi' EXIT

# ---------------------------------------------------------------- assertions -
fail_reason=""

expect_eq() { # desc expected actual
  if [ "$2" != "$3" ]; then fail_reason="$1: expected [$2], got [$3]"; return 1; fi
  ok "$1 = $3"
}
expect_contains() { # desc haystack needle
  case "$2" in *"$3"*) ok "$1" ;; *) fail_reason="$1: expected to find [$3]"; return 1 ;; esac
}
expect_absent() { # desc haystack needle
  case "$2" in *"$3"*) fail_reason="$1: did NOT expect to find [$3]"; return 1 ;; *) ok "$1" ;; esac
}
expect_ne() { # desc not_expected actual
  if [ "$2" = "$3" ]; then fail_reason="$1: did NOT expect [$3]"; return 1; fi
  ok "$1 (got $3)"
}
# Assert the numbered boot steps really happened in this order.
expect_order() { # desc file needle1 needle2 ...
  local desc="$1" file="$2"; shift 2
  local prev=0 prev_nd="" n nd
  for n in "$@"; do
    nd=$(grep -n -m1 -F -- "$n" "$file" 2>/dev/null | cut -d: -f1)
    if [ -z "$nd" ]; then fail_reason="$desc: step never happened: [$n]"; return 1; fi
    if [ "$prev" -ne 0 ] && [ "$nd" -le "$prev" ]; then
      fail_reason="$desc: [$n] appeared at line $nd, not after [$prev_nd] at line $prev"
      return 1
    fi
    prev=$nd; prev_nd="$n"
  done
  ok "$desc (${#} steps, strictly in order)"
}
gate() { [ -n "$fail_reason" ] && die "$fail_reason"; return 0; }

# ---------------------------------------------------------------- utilities ---
port_free() { ! ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"; }

# Sets PORTS=(...) to $1 free ports, scanning upward from PORT_BASE. Deliberately
# runs in the caller's shell rather than a command substitution, so a hard
# failure can still be reported.
alloc_ports() {
  local want="$1" p exhausted
  PORT_RANGE_LO="$PORT_BASE"
  PORTS=(); PORT_ALLOC_MSG=""
  while [ "$want" -gt 0 ]; do
    p="$PORT_BASE"; exhausted=1
    while [ "$p" -lt $((PORT_RANGE_LO + 20)) ]; do
      if port_free "$p"; then
        PORTS+=("$p"); PORT_BASE=$((p + 1)); want=$((want - 1)); exhausted=0; break
      fi
      p=$((p + 1))
    done
    if [ "$exhausted" -eq 1 ]; then
      PORT_ALLOC_MSG="only ${#PORTS[@]} of the $1 ports wanted are free in the $PORT_RANGE_LO-$((PORT_RANGE_LO + 19)) range"
      break
    fi
  done
}

wait_for_log() { # file regex tries(0.1s)
  local f="$1" re="$2" tries="$3" i=0
  while [ "$i" -lt "$tries" ]; do
    grep -qE -- "$re" "$f" 2>/dev/null && return 0
    sleep 0.1; i=$((i + 1))
  done
  return 1
}

# http <port> <path> -> $H_CODE $H_CT $H_BODY
http() {
  local port="$1" path="$2" tmp="$WORK/.http-body"
  H_CODE=$(curl -sS -o "$tmp" -w '%{http_code}' "http://127.0.0.1:$port$path" 2>/dev/null)
  H_CT=$(curl -sS -o /dev/null -w '%{content_type}' "http://127.0.0.1:$port$path" 2>/dev/null)
  H_BODY=$(cat "$tmp" 2>/dev/null)
}

# Render a probe the way the learner should read it: status, type, body.
show() { # port path
  http "$1" "$2"
  printf '    GET %s\n' "$2"
  printf '      status:       %s\n' "$H_CODE"
  printf '      content-type: %s\n' "$H_CT"
  printf '      body:         %s\n' "$(printf '%s' "$H_BODY" | head -c 300 | tr '\n' '|')"
}

show_full() { # port path
  http "$1" "$2"
  printf '    GET %s -> %s (%s)\n' "$2" "$H_CODE" "$H_CT"
  printf '%s\n' "$H_BODY" | sed 's/^/      /'
}

# MarkerName() from internal/workspace/setup.go:336-345, reimplemented in shell
# so the lesson can check the runner's real marker path against the rule.
expected_marker_name() {
  local clean="${1#/}"; clean="${clean%/}"
  [ -z "$clean" ] && clean="root"
  printf 'initialized-%s' "${clean//\//-}"
}

# ================================================================= preflight ==
say "$B""05-runner-sandbox -- inside an ax task container$N"
say "=================================================================="
say "driver:  $RUNNER_BIN"
say "scratch: $WORK"
say ""
note "spec.command below runs against THIS host's PATH and filesystem, as this user."
note "In a cluster it would run inside the task image. The runner's own behavior is"
note "identical; only the surrounding isolation is missing here. Section 5 proves it."

command -v curl >/dev/null 2>&1 || die "curl is required but is not on PATH"
command -v ss    >/dev/null 2>&1 || die "ss (iproute2) is required to pick a free port"
[ -x "$RUNNER_BIN" ] || die "$RUNNER_BIN not found. Build it first:  cd $LAB_ROOT && ./scripts/setup.sh"

say ""
say "Real flags, from cmd/ax-task-runner/main.go:54-56:"
"$RUNNER_BIN" --help 2>&1 | sed 's/^/    /'

rm -rf "$WORK" || die "cannot clear $WORK"
mkdir -p "$WORK/ws" || die "cannot create $WORK/ws"

alloc_ports 4
[ -n "$PORT_ALLOC_MSG" ] && die "$PORT_ALLOC_MSG"
[ "${#PORTS[@]}" -eq 4 ] || die "port allocation returned ${#PORTS[@]} ports, expected 4"
PORT_A=${PORTS[0]}; PORT_B=${PORTS[1]}; PORT_C=${PORTS[2]}; PORT_D=${PORTS[3]}
say ""
say "Ports allocated (never 80/6379/8080; other projects own those):"
say "    $PORT_A  $PORT_B  $PORT_C  $PORT_D"

# ============================================================ 1. /workspace ===
hdr "1. The default workspace path /workspace is not writable on this host"
say ""
say "pkg/apis/v1alpha1/types.go:213 -> DefaultWorkspacePath = \"/workspace\""
say "A task that binds no workspaces still gets an empty dir at that path"
say "(runner/runner.go:125-128). This host is not root, so / is read-only to us."
say ""

cat > "$WORK/task-default.yaml" <<'YAML'
apiVersion: ax.io/v1alpha1
kind: Task
metadata:
  name: lesson05-default
spec:
  command: ["/bin/sh", "-c", "echo 'the command ran'"]
YAML

say "Booting a runner on the default path, with a command:"
say "    ax-task-runner --task-file task-default.yaml --port $PORT_A"
say ""
"$RUNNER_BIN" --task-file "$WORK/task-default.yaml" --port "$PORT_A" \
  > "$WORK/1-default.log" 2>&1 &
DPID=$!; track $DPID
wait "$DPID"; DRC=$?
untrack $DPID

say "runner exit code: $DRC"
say "runner log, verbatim:"
sed 's/^/    /' "$WORK/1-default.log"
say ""
LOG1=$(cat "$WORK/1-default.log")
expect_contains "setup failed trying to create the workspace dir (setup.go:94)" \
  "$LOG1" "creating workspace directory /workspace: mkdir /workspace: permission denied"
expect_contains "the metadata server had already bound the port (runner.go:146-149)" \
  "$LOG1" "metadata and guest server started"
expect_contains "the task command was never started (runner.go:184-186)" \
  "$LOG1" "starting task command"
expect_contains "and it failed because its working dir does not exist" \
  "$LOG1" "no such file or directory"
expect_absent  "the runner logged only the failure" "$LOG1" "level=INFO msg=\"task command"
# The command's own stdout would appear as a bare line, not inside a log record.
# (Its argv does show up in the error above, so match the whole line, not a substring.)
expect_eq "spec.command produced no output line of its own" "0" \
  "$(grep -cxF "the command ran" "$WORK/1-default.log")"
expect_eq "the whole runner exits 1 (main.go:78-80 -> fatal -> os.Exit(1))" "1" "$DRC"
gate

say ""
note "Two failures, one cause. SetupWorkspace could not mkdir /workspace, so"
note "cmd.Dir -- the command's working directory, set at runner/runner.go:175 --"
note "does not exist either. exec.Cmd.Start fails its chdir, runner.go:184 returns an"
note "error, and the process dies. On this host a workspace failure does not merely"
note "delay your command, it prevents the command from ever running."
say ""
note "Inside the real container /workspace is a mounted volume, so this boot gets"
note "past step 1. The lesson reproduces the failure on purpose so you can see it."

# ================================================ 2. failure-path HTTP codes ==
hdr "2. What the HTTP surface returns when setup did NOT succeed"
say ""
say "Same default path, but with no spec.command. runner/runner.go:167-172 then"
say "serves metadata until told to stop, so the failure-path codes are observable."
say ""

cat > "$WORK/task-nocmd.yaml" <<'YAML'
apiVersion: ax.io/v1alpha1
kind: Task
metadata:
  name: lesson05-nocmd
spec: {}
YAML

"$RUNNER_BIN" --task-file "$WORK/task-nocmd.yaml" --port "$PORT_C" \
  > "$WORK/2-nocmd.log" 2>&1 &
NPID=$!; track $NPID
wait_for_log "$WORK/2-nocmd.log" 'serving metadata until stopped' 100 \
  || die "runner never reached its steady state; log: $(cat "$WORK/2-nocmd.log")"

info "liveness -- always 200, whether or not setup worked (server.go:180-183):"
show "$PORT_C" /healthz
expect_eq "  /healthz status" "200" "$H_CODE"

info "readiness -- 503 until every workspace is ready (server.go:190-193):"
show "$PORT_C" /readyz
expect_eq "  /readyz status" "503" "$H_CODE"
expect_contains "  /readyz body" "$H_BODY" "workspace initializing"

info "workspace metadata -- 404 when the task binds none (server.go:222-225):"
show "$PORT_C" /metadata/v1alpha1/ax/workspaces
expect_eq "  /workspaces status" "404" "$H_CODE"
expect_contains "  /workspaces body" "$H_BODY" "workspace metadata not available"

info "task metadata -- 200, the launch config as application/yaml (server.go:199-213):"
show_full "$PORT_C" /metadata/v1alpha1/ax/task
expect_eq "  /task status" "200" "$H_CODE"
expect_contains "  /task content-type" "$H_CT" "application/yaml"
expect_contains "  /task body names the task" "$H_BODY" "name: lesson05-nocmd"
gate

kill -TERM $NPID 2>/dev/null; wait $NPID 2>/dev/null; untrack $NPID

# ================================================= 3. the happy-path boot log ==
hdr "3. Boot sequence on a writable workspace, in the order the runner does it"
say ""
say "Give the workspace an explicit, writable path: WorkspacePaths()"
say "(pkg/apis/v1alpha1/types.go:233-244) prefers spec.workspaces[].path when set."
say ""

WS_PATH="$WORK/ws"

# The command is a script rather than an inline string so the runner's log stays
# readable and so the assertions in section 5 read as real observations.
cat > "$WORK/command.sh" <<SCRIPT
#!/bin/sh
# This process is spec.command. runner/runner.go:174 exec's it with
# cmd.Dir = the first workspace, and commandEnv() (runner.go:240-245) supplies
# its environment.
printf 'AX_METADATA_URL=%s\n' "\$AX_METADATA_URL"
printf 'LESSON_MARKER=%s\n'   "\$LESSON_MARKER"
printf 'cwd=%s\n'             "\$(pwd)"
printf 'uid=%s\n'             "\$(id -u)"
printf 'hostname=%s\n'        "\$(hostname 2>/dev/null || echo unknown)"
printf 'lab-root-visible=%s\n' "\$([ -d '$LAB_ROOT' ] && echo yes || echo no)"
printf 'ax-task-runner-on-PATH=%s\n' "\$(command -v ax-task-runner || echo not-on-PATH)"
exit 7
SCRIPT

cat > "$WORK/task-ok.yaml" <<YAML
apiVersion: ax.io/v1alpha1
kind: Task
metadata:
  name: lesson05-runner
spec:
  workspaces:
    - name: code
      path: $WS_PATH
  command: ["/bin/sh", "$WORK/command.sh"]
  env:
    - name: LESSON_MARKER
      value: injected-by-spec-env
YAML

cat > "$WORK/workspace.yaml" <<'YAML'
apiVersion: ax.io/v1alpha1
kind: Workspace
metadata:
  name: code
spec:
  files:
    - path: from-maiden-run.txt
      content: written during the workspace maiden run
YAML

say "spec.command exits 7 immediately. That is what makes section 4 decisive."
say ""
say "    ax-task-runner --task-file task-ok.yaml --workspace-file workspace.yaml --port $PORT_B"
say ""

"$RUNNER_BIN" --task-file "$WORK/task-ok.yaml" --workspace-file "$WORK/workspace.yaml" \
  --port "$PORT_B" > "$WORK/3-boot.log" 2>&1 &
RPID=$!; track $RPID
wait_for_log "$WORK/3-boot.log" 'started task command' 100 \
  || die "spec.command never started; log: $(cat "$WORK/3-boot.log")"

say "runner log, verbatim (note the order):"
sed 's/^/    /' "$WORK/3-boot.log"
say ""
LOG3=$(cat "$WORK/3-boot.log")

# This is the numbered boot sequence of docs/sandbox.md:3-8, verified as an
# ordering rather than a set of independent greps.
expect_order "the six boot steps happened in the documented order" "$WORK/3-boot.log" \
  'msg="initializing AX task runner"' \
  'msg="metadata and guest server started"' \
  'msg="executing workspace maiden run setup"' \
  'msg="wrote inlined workspace file"' \
  'msg="workspace maiden run setup marked ready"' \
  'msg="started task command"'

expect_contains "the /ax state dir could not be created, warn only (setup.go:97-99)" \
  "$LOG3" 'msg="creating ax state directory" dir=/ax error="mkdir /ax: permission denied"'
expect_contains "the marker write was ATTEMPTED and failed (setup.go:126 -> :348-357)" \
  "$LOG3" 'msg="failed to write initialized marker file"'
expect_contains "setup still reports success -- the marker failure is non-fatal" \
  "$LOG3" 'msg="maiden run workspace setup completed successfully"'
expect_contains "guest services are off because spec.debug is unset (server.go:89)" \
  "$LOG3" 'msg="guest services disabled; set spec.debug: true on the Task to enable ax ssh"'
expect_eq "the inlined spec.files entry really exists on disk" "yes" \
  "$([ -f "$WS_PATH/from-maiden-run.txt" ] && echo yes || echo no)"
gate

say ""
note "The /ax state directory is a compile-time constant, not configuration:"
note "internal/workspace/setup.go:33 (DefaultAXDir) and :64 (var AXDir). No flag and no"
note "environment variable can move it -- only Go code can, which is what the runner's"
note "own tests do at runner/runner_test.go:166-168. Section 6 shows what that costs."

# ================================================== 4. the stay-alive invariant ==
hdr "4. The invariant: the runner outlives its own command"
say ""
say "docs/runner.md:43 and runner/runner.go:192-199. The command above has already"
say "exited with status 7. If the runner died with it, the metadata server would go too"
say "and \`ax ssh\` would stop working. Check that; do not assume it."
say ""

wait_for_log "$WORK/3-boot.log" 'task command exited with error' 100 \
  || die "never saw spec.command's exit; log: $(cat "$WORK/3-boot.log")"
CMD_LINE=$(grep -m1 -E 'task command exited with error' "$WORK/3-boot.log")
say "  the runner logged: $CMD_LINE"
expect_contains "the exit status is logged, not swallowed (runner.go:223-236)" \
  "$CMD_LINE" "exitCode=7"
gate

say ""
say "Is the runner -- the process holding the whole sandbox open -- still there?"
say "Three probes, half a second apart, each a live HTTP request:"
say ""
for i in 1 2 3; do
  if ! kill -0 "$RPID" 2>/dev/null; then
    die "the runner died when its command exited: the invariant does not hold"
  fi
  ELAPSED=$(ps -o etimes= -p "$RPID" 2>/dev/null | tr -d ' ')
  KIDS=$(pgrep -P "$RPID" 2>/dev/null | wc -l | tr -d ' ')
  http "$PORT_B" /healthz
  printf '    probe %d  t+%-4s  children=%s  GET /healthz -> %s\n' "$i" "${ELAPSED:-?}s" "$KIDS" "$H_CODE"
  expect_eq "  probe $i: /healthz still 200 after the command exited" "200" "$H_CODE"
  http "$PORT_B" /readyz
  expect_eq "  probe $i: /readyz still 200 after the command exited" "200" "$H_CODE"
  [ "$i" -lt 3 ] && sleep 0.5
done
gate

say ""
info "and the full Workspace document is still served, unchanged, after the exit:"
show_full "$PORT_B" /metadata/v1alpha1/ax/workspaces
expect_eq "  /workspaces status" "200" "$H_CODE"
gate

say ""
note "In a cluster the runner is PID 1 (docs/sandbox.md:3), so this waiting process is"
note "literally what holds the container open. Locally it is an ordinary background"
note "process, but it is the same wait at runner/runner.go:196 either way."

# ============================== 5. what the command itself actually observed ====
hdr "5. What spec.command was actually handed"
say ""
say "commandEnv() (runner/runner.go:240-245) = the runner's environment +"
say "AX_METADATA_URL + every spec.env entry. cmd.Dir is the first workspace"
say "(runner/runner.go:175). The command's stdout is the runner's stdout"
say "(runner.go:177), so it is in the log above; here is each line on its own."
say ""
grep -E '^(AX_METADATA_URL|LESSON_MARKER|cwd|uid|hostname|lab-root-visible|ax-task-runner-on-PATH)=' \
  "$WORK/3-boot.log" | sed 's/^/    /'
say ""
kv() { grep -m1 -E "^$1=" "$WORK/3-boot.log"; }
R_URL=$(kv AX_METADATA_URL); R_ENV=$(kv LESSON_MARKER); R_CWD=$(kv cwd)
R_UID=$(kv uid); R_LAB=$(kv lab-root-visible); R_PATH=$(kv ax-task-runner-on-PATH)

expect_eq "AX_METADATA_URL points at the runner's own port (runner.go:241)" \
  "AX_METADATA_URL=http://127.0.0.1:$PORT_B" "$R_URL"
expect_eq "the command's working dir is the first workspace (runner.go:175)" \
  "cwd=$WS_PATH" "$R_CWD"
expect_eq "every spec.env entry reached the command (runner.go:242-244)" \
  "LESSON_MARKER=injected-by-spec-env" "$R_ENV"
expect_eq "PROVEN NOT A CONTAINER: the command can see this lab's directory tree" \
  "lab-root-visible=yes" "$R_LAB"
expect_ne   "PROVEN NOT A CONTAINER: the command is not uid 0" "0" "${R_UID#uid=}"
expect_eq   "PROVEN NOT A CONTAINER: the host PATH does not contain the lab bin dir" \
  "ax-task-runner-on-PATH=not-on-PATH" "$R_PATH"
gate

say ""
say "and the shell that launched all of this:"
say "    AX_METADATA_URL in this shell = ${AX_METADATA_URL:-<unset>}"
say ""
note "The URL is absent here and present in the child: the runner injected it."
note "runner/runner.go:140-144 also calls os.Setenv on the runner's own process, so"
note "the URL is available to the runner itself, but that is not observable from a"
note "child shell, and /proc/<pid>/environ does not show it either -- that file is the"
note "exec-time snapshot and Go's os.Setenv does not rewrite it. The only one of the"
note "two you can watch arrive is the child env built at runner.go:241."

# =============================================== 6. the /ax marker gotcha ======
hdr "6. Second boot: why the maiden run re-runs every single time here"
say ""
say "SetupWorkspace is meant to be a no-op after the first boot. It decides that by"
say "stat'ing a marker file under /ax (setup.go:101-105). Boot the same workspace path"
say "again and watch which branch it takes."
say ""
say "    ax-task-runner --task-file task-ok.yaml --workspace-file workspace.yaml --port $PORT_C"
say ""

"$RUNNER_BIN" --task-file "$WORK/task-ok.yaml" --workspace-file "$WORK/workspace.yaml" \
  --port "$PORT_C" > "$WORK/6-secondboot.log" 2>&1 &
SPID=$!; track $SPID
wait_for_log "$WORK/6-secondboot.log" 'started task command' 100 \
  || die "second boot never reached the command; log: $(cat "$WORK/6-secondboot.log")"
sleep 0.4
kill -TERM $SPID 2>/dev/null; wait $SPID 2>/dev/null; untrack $SPID

say "runner log, verbatim:"
sed 's/^/    /' "$WORK/6-secondboot.log"
say ""
LOG6=$(cat "$WORK/6-secondboot.log")
REAL_MARKER=$(grep -oE '/ax/initialized-[A-Za-z0-9._-]+' "$WORK/6-secondboot.log" | head -n 1)
WANT_MARKER="/ax/$(expected_marker_name "$WS_PATH")"

expect_contains "boot 2 took the MAIDEN-RUN branch again" "$LOG6" "executing workspace maiden run setup"
expect_absent  "boot 2 did NOT take the skip branch"    "$LOG6" "workspace already initialized"
expect_contains "/ax still cannot be created (setup.go:97-99)" "$LOG6" 'mkdir /ax: permission denied'
expect_contains "the marker write failed again (setup.go:355)" "$LOG6" "failed to write initialized marker file"
expect_eq "the marker path matches MarkerName() (setup.go:336-345)" "$WANT_MARKER" "$REAL_MARKER"
if [ -d /ax ]; then fail_reason="/ax exists, so this lesson's premise no longer holds"; else ok "/ax still does not exist"; fi
gate

say ""
note "setup.go:97 only warns when /ax is uncreatable and setup.go:355 only warns when"
note "the marker cannot be written. So a runner sitting on an unwritable /ax silently"
note "re-clones and re-bootstraps on every single boot, with no failure anywhere."
note "In the container /ax is writable, and boot 2 would instead log"
note "\"workspace already initialized; skipping maiden run setup\" (setup.go:103)."
say ""
note "That skip branch is NOT executable on this host: creating /ax needs root, and"
note "the lab has no sudo and no user namespaces (unshare -r fails with EPERM here)."
note "The lesson therefore reproduces the failure branch and checks the marker NAME"
note "against MarkerName() instead of exercising the skip."
say ""
note "Why it matters in production: the maiden run is what makes suspend/resume safe,"
note "because a resumed container gets a new process tree but the same volume"
note "(docs/runner.md:26). Re-cloning into a restored workspace would destroy the"
note "agent's state -- which is exactly the bug a silently-missing marker causes."

# ==================================================== 7. shutdown on SIGTERM ====
hdr "7. Shutdown: SIGTERM, then the process group, then the grace period"
say ""
say "Stop and suspend both deliver SIGTERM to PID 1 (docs/runner.md:45). The runner"
say "forwards it to the command's process group, waits 10s, then SIGKILLs whatever is"
say "left (runner/runner.go:205-220, stopGracePeriod at :49)."
say ""

# A command that ignores SIGTERM, so the grace period is real rather than claimed.
cat > "$WORK/task-stubborn.yaml" <<YAML
apiVersion: ax.io/v1alpha1
kind: Task
metadata:
  name: lesson05-stubborn
spec:
  workspaces:
    - name: code
      path: $WS_PATH
  command: ["/bin/sh", "-c", "trap '' TERM; echo stubborn-started; while true; do sleep 0.2; done"]
YAML

"$RUNNER_BIN" --task-file "$WORK/task-stubborn.yaml" --port "$PORT_D" \
  > "$WORK/7-sigterm.log" 2>&1 &
KPID=$!; track $KPID
wait_for_log "$WORK/7-sigterm.log" 'stubborn-started' 150 \
  || die "the stubborn command never started; log: $(cat "$WORK/7-sigterm.log")"
KID=$(pgrep -P "$KPID" 2>/dev/null | head -n 1)
say "    runner pid $KPID, its stubborn child pid $KID"
say "    sending SIGTERM to the runner and timing the shutdown"
say ""

T0=$(date +%s)
kill -TERM "$KPID"
wait_for_log "$WORK/7-sigterm.log" 'did not exit within grace period' 400 \
  || die "expected the grace-period kill to be logged; log: $(cat "$WORK/7-sigterm.log")"
wait "$KPID"; KRC=$?
T1=$(date +%s)
untrack $KPID

say ""
say "runner log, verbatim (shutdown took ~$((T1 - T0))s):"
sed 's/^/    /' "$WORK/7-sigterm.log"
say ""
LOG7=$(cat "$WORK/7-sigterm.log")
expect_contains "SIGTERM is forwarded to the command's process group (runner.go:207)" "$LOG7" "stopping task command"
expect_contains "the child ignored it, so the grace period ran out (runner.go:210-216)" "$LOG7" "did not exit within grace period"
expect_contains "the log names the grace period it waited (stopGracePeriod, runner.go:49)" "$LOG7" "gracePeriod=10s"
expect_contains "then the process group is SIGKILLed (runner.go:216)" "$LOG7" "did not exit within grace period; killing"
expect_eq       "the runner still exits 0 after the forced kill" "0" "$KRC"
expect_absent  "the stubborn child is gone" "$(kill -0 "$KID" 2>/dev/null && echo alive || echo gone)" "alive"
gate

say ""
note "The child was /bin/sh in a loop with TERM trapped to nothing. It took the full"
note "ten-second grace period to disappear, which is precisely why stopGracePeriod"
note "exists instead of the runner killing instantly."

# ================================================== 8. final state + shutdown ==
hdr "8. Final state, then a clean shutdown"
say ""

show "$PORT_B" /healthz
expect_eq "  /healthz status" "200" "$H_CODE"
show "$PORT_B" /readyz
expect_eq "  /readyz status (setup succeeded, so the workspace is ready)" "200" "$H_CODE"
show_full "$PORT_B" /metadata/v1alpha1/ax/task
expect_eq "  /task status" "200" "$H_CODE"
expect_contains "  /task still carries the command and the workspace binding" "$H_BODY" "path: $WS_PATH"
expect_contains "  /task carries spec.env too" "$H_BODY" "LESSON_MARKER"
gate

say ""
say "Stopping the runner the way a stop or a suspend does -- SIGTERM to the runner:"
kill -TERM $RPID 2>/dev/null
wait "$RPID"; RRC=$?
untrack $RPID
say "    runner exit code: $RRC"
sed -n '/shutting down metadata server/p' "$WORK/3-boot.log" | sed 's/^/    /'
expect_eq "the runner exits 0 (main.go:75 signal.NotifyContext, Run returns nil)" "0" "$RRC"
expect_contains "and it stopped the metadata server on the way out (runner.go:150-153)" \
  "$(cat "$WORK/3-boot.log")" "shutting down metadata server"
gate

# ------------------------------------------------------------------ verdict ---
# Nothing may still be running at the moment PASS is claimed.
cleanup
[ -n "$PIDS" ] && die "internal cleanup left processes behind:$PIDS"
expect_eq "no stray ax-task-runner processes remain" "0" \
  "$(pgrep -f "$BIN_DIR/ax-task-runner" 2>/dev/null | wc -l | tr -d ' ')"
gate

COMPLETED=1
PRINTED=1
printf '\n'
say "Runner logs kept for inspection under ${WORK#$LAB_ROOT/}/"
say "PASS: 05-runner-sandbox"
exit 0
