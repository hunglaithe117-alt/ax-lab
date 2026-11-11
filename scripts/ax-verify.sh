#!/usr/bin/env bash
# Phase 3 gate: ax's control plane is deployed on the Substrate cluster and a
# real Task reaches a running sandboxed actor.
#
# ---------------------------------------------------------------------------
# THIS SCRIPT NEEDS A LIVE CLUSTER. It is Phase 3's analogue of
# scripts/substrate-verify.sh, and for the same reason it is NOT part of
# scripts/verify-all.sh: that script's contract is "no cluster required".
#
#   scripts/ax-up.sh          # idempotent deploy (needs Phase 2 up first)
#   scripts/ax-verify.sh      # these checks; non-zero on failure
#
# SELF-CONTAINED. It resolves every binary by absolute path and never depends on
# the ambient PATH:
#   * kubectl    -- PATH, or $AXLAB_KUBECTL_BIN
#   * kubectl-ate -- AXLAB_KUBECTL_ATE_BIN, then $(go env GOBIN||GOPATH)/bin,
#                   then PATH            (same resolution as substrate-verify.sh)
#   * ax         -- $AXLAB_AX_BIN, then the clone's bin/ax, then PATH
# A gate that reports a different verdict depending on whose shell you are in
# is worse than no gate, so this one must not.
#
# It never changes the ambient kubectl context and never touches minikube, and it
# refuses outright if pointed at a minikube context (see the guard in main).
#
# AXLAB_SKIP_MUTATE=1 runs only the read-only checks 1-4. That is a PARTIAL
# verdict: the script counts what it skipped, says so, and exits 3. It never
# prints "all checks passed" when checks did not run.
#
# Overrides:
#   AXLAB_KUBECTL_CONTEXT   context                     (default: kind-ax-lab)
#   AXLAB_ACTOR             the demo task/actor name    (default: task123)
#   AXLAB_ATESPACE          task atespace               (default: default)
#   AXLAB_AX_BIN            the ax CLI                  (default: upstream/google-ax/bin/ax)
#   AXLAB_KUBECTL_ATE_BIN   kubectl-ate                 (default: resolved)
#   AXLAB_KUBECTL_BIN       kubectl                     (default: PATH)
#   AXLAB_SKIP_MUTATE       1 to skip the mutating checks
#
# Ports: none. Every call goes through the cluster API or the ax CLI's own
# ephemeral tunnel, so 80/6379/8080 are never bound.

set -o errexit -o nounset -o pipefail

LAB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

AXLAB_KUBECTL_CONTEXT="${AXLAB_KUBECTL_CONTEXT:-kind-ax-lab}"
AXLAB_ACTOR="${AXLAB_ACTOR:-task123}"
AXLAB_ATESPACE="${AXLAB_ATESPACE:-default}"
# The Workspace resource name the Task declares, and the directory its git spec
# clones INTO. They are different: cloneDestination
# (internal/workspace/setup.go:174-195) derives the directory from the repo URL
# when the entry is named `origin`, so the shipped Workspace `default-workspace`
# with repo chalk/git becomes /workspace/chalk. Check 8 asserts the directory.
AXLAB_WORKSPACE_NAME="${AXLAB_WORKSPACE_NAME:-default-workspace}"
AXLAB_WORKSPACE_DIR="${AXLAB_WORKSPACE_DIR:-}"
AXLAB_SKIP_MUTATE="${AXLAB_SKIP_MUTATE:-0}"

PASS=0
FAIL=0
SKIPPED=0
FAILED_CHECKS=()
SKIPPED_CHECKS=()
LAB_TMP=""

KUBECTL=""
KUBECTL_ATE=""
AX_BIN=""

lab_step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
lab_note() { printf '    %s\n' "$*"; }
check()    { printf '\n\033[1m--- %s\033[0m\n' "$*"; }
pass()     { printf '    \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS + 1)); }
fail()     { printf '    \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL + 1)); FAILED_CHECKS+=("$*"); }
show()     { printf '%s\n' "$1" | sed 's/^/      /'; }

usage() {
  awk 'NR==1{next}
       /^#/          { sub(/^# ?/, ""); print; next }
       /^[[:space:]]*$/ { print; next }
       { exit }' "$0"
}
stop_tunnel() {
  if [ -n "${AX_BIN}" ] && [ -x "${AX_BIN}" ]; then
    "${AX_BIN}" tunnel stop --context "${AXLAB_KUBECTL_CONTEXT}" >/dev/null 2>&1 || true
  fi
}
cleanup() { stop_tunnel; [ -n "${LAB_TMP}" ] && rm -rf "${LAB_TMP}"; return 0; }

k()    { "${KUBECTL}" --context "${AXLAB_KUBECTL_CONTEXT}" "$@"; }
ate()  { "${KUBECTL_ATE}" --context "${AXLAB_KUBECTL_CONTEXT}" "$@"; }
ax()   { "${AX_BIN}" --context "${AXLAB_KUBECTL_CONTEXT}" "$@"; }

# --- binary resolution ------------------------------------------------------

resolve_binaries() {
  KUBECTL=""
  if [ -n "${AXLAB_KUBECTL_BIN:-}" ] && [ -x "${AXLAB_KUBECTL_BIN}" ]; then
    KUBECTL="${AXLAB_KUBECTL_BIN}"
  else
    KUBECTL="$(command -v kubectl 2>/dev/null || true)"
  fi

  KUBECTL_ATE=""
  if [ -n "${AXLAB_KUBECTL_ATE_BIN:-}" ]; then
    if [ -x "${AXLAB_KUBECTL_ATE_BIN}" ]; then
      KUBECTL_ATE="${AXLAB_KUBECTL_ATE_BIN}"
    elif [ -x "${AXLAB_KUBECTL_ATE_BIN}/kubectl-ate" ]; then
      KUBECTL_ATE="${AXLAB_KUBECTL_ATE_BIN}/kubectl-ate"
    fi
  fi
  if [ -z "${KUBECTL_ATE}" ]; then
    local gobin=""
    if command -v go >/dev/null 2>&1; then
      gobin="$(go env GOBIN 2>/dev/null || true)"
      [ -n "${gobin}" ] || gobin="$(go env GOPATH 2>/dev/null || true)/bin"
    fi
    [ -n "${gobin}" ] && [ -x "${gobin}/kubectl-ate" ] && KUBECTL_ATE="${gobin}/kubectl-ate"
  fi
  if [ -z "${KUBECTL_ATE}" ]; then
    local c; c="$(command -v kubectl-ate 2>/dev/null || true)"
    case "${c}" in /*) KUBECTL_ATE="${c}" ;; esac
  fi

  AX_BIN=""
  if [ -n "${AXLAB_AX_BIN:-}" ] && [ -x "${AXLAB_AX_BIN}" ]; then
    AX_BIN="${AXLAB_AX_BIN}"
  elif [ -x "${LAB_ROOT}/bin/ax" ]; then
    AX_BIN="${LAB_ROOT}/bin/ax"
  elif [ -x "${LAB_ROOT}/upstream/google-ax/bin/ax" ]; then
    AX_BIN="${LAB_ROOT}/upstream/google-ax/bin/ax"
  else
    local c; c="$(command -v ax 2>/dev/null || true)"
    case "${c}" in /*) AX_BIN="${c}" ;; esac
  fi
}

# --- checks 1-2: the control plane is deployed -------------------------------

check_control_plane() {
  check "1/9  ax-redis, ax-controller and ax-server all Running in ax-system"
  local out missing=0
  out="$(k get deploy -n ax-system 2>&1)"
  show "${out}"
  local d
  for d in ax-redis ax-controller ax-server; do
    local ready
    ready="$(k get deploy -n ax-system "$d" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
    if [ "${ready:-0}" -lt 1 ]; then
      fail "deployment ${d} has 0 ready replicas"
      missing=1
    fi
  done
  # A bare `[ ... ] && pass` as the last statement of a function returns 1 when
  # the test is false, which under `set -e` aborts the whole script before the
  # summary. Use an if/else so the function's exit status is never the test's.
  if [ "${missing}" -eq 0 ]; then
    pass "ax-redis, ax-controller and ax-server are ready"
  fi

  # The image story: the kubelet-side containerd certs.d mirror is what makes a
  # localhost:5001 pull work for a plain Deployment, independent of substrate's
  # own --localhost-registry-replacement flag.
  lab_note "images actually running:"
  k get pods -n ax-system -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.containers[0].image}{"\n"}{end}' 2>&1 | sed 's/^/      /'
  local pulled
  # imageID, not image: containerStatus.image is the bare digest ("sha256:...")
  # with no repository, so matching on localhost:5001 there always finds nothing.
  pulled="$(k get pods -n ax-system -o jsonpath='{range .items[*]}{.status.containerStatuses[*].imageID}{"\n"}{end}' 2>&1 | grep -c 'localhost:5001' || true)"
  if [ "${pulled:-0}" -ge 2 ]; then
    pass "${pulled} container(s) pulled an image from the local registry via certs.d"
  else
    fail "expected the ax images to be pulled from localhost:5001 (found ${pulled:-0})"
  fi
}

check_substrate_intact() {
  check "2/9  Substrate is still healthy (Phase 2 not broken)"
  if k get svc api -n ate-system >/dev/null 2>&1; then
    k get svc api -n ate-system | sed 's/^/      /'
    local notready
    notready="$(k get pods -n ate-system --no-headers 2>/dev/null | awk '$3!="Running" && $3!="Completed"' | wc -l)"
    if [ "${notready}" -eq 0 ]; then
      pass "svc/api present and every ate-system pod is Running"
    else
      fail "${notready} ate-system pod(s) are not Running"
    fi
  else
    fail "svc/api missing from ate-system"
  fi
}

# --- checks 3-4: the WorkerPool and the bucket ------------------------------

check_workerpool() {
  check "3/9  the WorkerPool ax never creates (gap 2)"
  local out ready
  out="$(k get workerpools.ate.dev -A 2>&1)"
  show "${out}"
  if ! k get workerpool.ate.dev -n ax-system ax-worker >/dev/null 2>&1; then
    fail "WorkerPool ax-system/ax-worker is missing; every ax task would stay unschedulable"
    return
  fi
  ready="$(k get deploy -n ax-system ax-worker -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  if [ "${ready:-0}" -ge 1 ]; then
    pass "WorkerPool ax-system/ax-worker has ${ready} ready worker(s)"
  else
    fail "WorkerPool exists but no worker pod is ready"
  fi
  # The nodeSelector has to match the label substrate stamps, or nothing schedules.
  local sel nodever
  sel="$(k get workerpool.ate.dev -n ax-system ax-worker -o jsonpath='{.spec.template.nodeSelector}' 2>/dev/null || true)"
  nodever="$(k get nodes -l ate.dev/substrate-version -o jsonpath='{.items[0].metadata.labels.ate\.dev/substrate-version}' 2>/dev/null || true)"
  if [ -n "${sel}" ] && printf '%s' "${sel}" | grep -q "${nodever}"; then
    pass "nodeSelector matches the node's substrate-version label (${nodever})"
  else
    fail "WorkerPool nodeSelector '${sel}' does not match the node label '${nodever}'"
  fi
}

check_bucket_repointed() {
  check "4/9  AX_SNAPSHOTS_BUCKET repointed off the private GCS path (gap 3)"
  local bucket
  bucket="$(k get deploy -n ax-system ax-controller \
    -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="AX_SNAPSHOTS_BUCKET")]}{.value}{end}' 2>/dev/null || true)"
  lab_note "AX_SNAPSHOTS_BUCKET=${bucket:-<unset>}"
  if [ -z "${bucket}" ]; then
    fail "the controller has no AX_SNAPSHOTS_BUCKET env var"
  elif printf '%s' "${bucket}" | grep -qE 'snapshot-substrate-test-ax-substrate|gcr\.io|gs://[a-z0-9-]*-test'; then
    fail "still points at a private GCS path: ${bucket}"
  elif printf '%s' "${bucket}" | grep -q 'ate-snapshots'; then
    pass "repointed at the in-cluster bucket: ${bucket}"
  else
    fail "unexpected bucket value: ${bucket}"
  fi
  # The live bucket name, read from the deployed rustfs init rather than assumed.
  local live
  live="$(k get pods -n ate-system --no-headers 2>/dev/null | awk '/bucket-init/ {print $1}' | while read -r p; do
      k get pod -n ate-system "$p" -o jsonpath='{.spec.containers[0].command}' 2>/dev/null
    done | grep -oE 'head-bucket --bucket [a-z0-9-]+' | head -1 | awk '{print $NF}')"
  if [ -n "${live}" ] && printf '%s' "${bucket}" | grep -q "${live}"; then
    pass "the deployed rustfs init really creates that bucket (${live})"
  else
    fail "bucket '${bucket}' does not match the live rustfs bucket '${live:-unknown}'"
  fi
}

# --- checks 5-7: a real task, running in a real sandbox ---------------------

check_task_suspended_shape() {
  check "5/9  a Task applies Suspended, with an actor that holds no worker"
  if [ -z "${AX_BIN}" ]; then
    fail "the ax CLI was not found; cannot drive the Task (set AXLAB_AX_BIN)"
    return 1
  fi
  # Start from a clean Task so the phases below are deterministic. Only a
  # *suspended* actor can be deleted (substrate: "Only suspended actors can be
  # deleted"), so ax's own delete is used rather than substrate's.
  ax delete task "${AXLAB_ACTOR}" >/dev/null 2>&1 || true
  sleep 3

  local taskfile="${LAB_ROOT}/.work/p3/task.yaml"
  if [ ! -f "${taskfile}" ]; then
    fail "no task manifest at ${taskfile}; run scripts/ax-up.sh"
    return 1
  fi

  # The Workspace must exist BEFORE the Task is first reconciled: ax bakes
  # AX_WORKSPACES_YAML into an immutable per-task ActorTemplate, and an existing
  # template is returned unchanged (internal/substrate/client.go:281-283).
  local wsfile="${LAB_ROOT}/.work/p3/workspace.yaml"
  [ -f "${wsfile}" ] && ax apply -f "${wsfile}" >/dev/null 2>&1 || true

  local out
  out="$(ax apply -f "${taskfile}" 2>&1)" || { show "${out}"; fail "ax apply failed"; return 1; }
  show "${out}"

  # Poll briefly rather than reading once, because `ax apply` returns before the
  # object is readable back. Keep this short: a *wrong task name* also produces an
  # empty phase, and a 2-minute wait for a task that will never appear hides the
  # real error instead of surfacing it. That mistake was made here - this loop
  # once ran 24 times, waiting on a name that did not exist, while the actual
  # fault was AXLAB_ACTOR holding the Substrate demo actor's name.
  local phase=""
  local _
  for _ in $(seq 1 6); do
    phase="$(ax get task "${AXLAB_ACTOR}" 2>/dev/null | sed -n 's/^ *phase: *//p' | head -1)"
    [ -n "${phase}" ] && break
    sleep 5
  done
  if [ "${phase}" = "Suspended" ]; then
    pass "Task ${AXLAB_ACTOR} is Suspended on apply (correct ax behaviour, not a failure)"
  else
    fail "expected phase Suspended on apply, got '${phase:-<none>}'"
  fi
  # The actor is created by the controller asynchronously, so poll for it rather
  # than reading once. Reading straight after `ax apply` is a race: on a cold
  # start (fresh Redis, fresh consumer group) the reconcile takes a few seconds,
  # and the gate reported "no actor" on a perfectly healthy system.
  #
  # Once it exists, the honest description is that the actor is present but
  # suspended and unassigned: no worker, no IP. There is not "no actor".
  local astate="" aworker=""
  local _
  for _ in $(seq 1 24); do
    astate="$(ate get actor "${AXLAB_ACTOR}" -a "${AXLAB_ATESPACE}" 2>/dev/null | awk 'NR==2{print $4}')"
    aworker="$(ate get actor "${AXLAB_ACTOR}" -a "${AXLAB_ATESPACE}" 2>/dev/null | awk 'NR==2{print $5}')"
    [ -n "${astate}" ] && break
    sleep 5
  done
  lab_note "actor state=${astate:-<none>} worker=${aworker:-<none>}"
  if [ "${astate}" = "ACTOR_STATE_SUSPENDED" ] && [ "${aworker}" = "<none>" ]; then
    pass "the actor exists but is SUSPENDED with no worker assigned"
  else
    fail "expected a suspended actor with no worker, got state='${astate:-}' worker='${aworker:-}'"
  fi
  return 0
}

check_task_running() {
  check "6/9  resume it: Running, a worker IP, and Ready/WorkspaceReady"
  local out
  out="$(ax resume task "${AXLAB_ACTOR}" 2>&1)" || { show "${out}"; fail "ax resume failed"; return; }
  show "${out}"

  # Wait for the worker IP, not for phase. `ax resume` sets phase=Running
  # immediately, before the controller has assigned a worker, so polling phase
  # returns while workerIP is still absent and the conditions still say
  # TaskSuspended. workerIP is the thing that proves an actor is really placed.
  # Condition statuses come back YAML-quoted ("True"), so strip the quotes.
  local phase="" wip="" ready_s="" status=""
  for _ in $(seq 1 40); do
    sleep 5
    status="$(ax get task "${AXLAB_ACTOR}" 2>/dev/null | sed -n '/^status:/,$p')"
    phase="$(printf '%s' "${status}" | sed -n 's/^ *phase: *//p' | head -1)"
    wip="$(printf '%s' "${status}" | sed -n 's/^ *workerIP: *//p' | head -1)"
    ready_s="$(printf '%s' "${status}" | grep -A3 'type: Ready' | sed -n 's/^ *status: *//p' | head -1 | tr -d '"')"
    if [ -n "${wip}" ] && [ "${ready_s}" = "True" ]; then break; fi
  done
  show "${status}"

  if [ "${phase}" = "Running" ]; then pass "phase is Running"; else fail "phase is '${phase:-<none>}', wanted Running"; fi

  if [ -n "${wip}" ]; then pass "task reports a worker IP (${wip})"; else fail "no workerIP on the task status"; fi

  local wsr
  wsr="$(printf '%s' "${status}" | grep -A3 'type: WorkspaceReady' | sed -n 's/^ *status: *//p' | head -1 | tr -d '"')"
  if [ "${ready_s}" = "True" ]; then pass "Ready=True"; else fail "Ready is '${ready_s:-<unset>}', wanted True"; fi
  if [ "${wsr}" = "True" ]; then pass "WorkspaceReady=True"; else fail "WorkspaceReady is '${wsr:-<unset>}', wanted True"; fi
}

check_actor_real() {
  check "7/9  the actor is a real gVisor sandbox running our runner image"
  local out
  out="$(ate get actor "${AXLAB_ACTOR}" -a "${AXLAB_ATESPACE}" 2>&1)"
  show "${out}"
  if ! printf '%s' "${out}" | grep -q 'ACTOR_STATE_RUNNING'; then
    fail "the actor is not RUNNING"
    return
  fi
  pass "actor ${AXLAB_ACTOR} is ACTOR_STATE_RUNNING"

  local pool pod
  pool="$(printf '%s' "${out}" | awk 'NR==2{print $5}')"
  pod="$(printf '%s' "${out}" | awk 'NR==2{print $6}')"
  lab_note "served by worker pool/pod: ${pool} / ${pod}"

  # The ActorTemplate must carry the image we built, not the private one.
  local tpl img
  tpl="$(printf '%s' "${out}" | awk 'NR==2{print $3}')"
  tpl="${tpl##*/}"
  img="$(ate get actor-template "${tpl}" -a "${AXLAB_ATESPACE}" -o yaml 2>/dev/null | sed -n 's/^ *image: *//p' | head -1)"
  lab_note "ActorTemplate ${tpl} image: ${img:-<none>}"
  if printf '%s' "${img}" | grep -q 'gcr.io/ax-substrate'; then
    fail "the template still points at the private image"
  elif printf '%s' "${img}" | grep -q 'localhost:5001'; then
    pass "template uses our locally built runner image"
  else
    fail "unexpected template image: ${img:-<none>}"
  fi

  # And the snapshot location must be the in-cluster bucket, proving gap 3 end
  # to end rather than just in the Deployment's env.
  # The golden snapshot's status is written asynchronously after the actor comes
  # up, so poll for it rather than reading once and failing on a race.
  local loc golden tyaml=""
  local _
  for _ in $(seq 1 24); do
    tyaml="$(ate get actor-template "${tpl}" -a "${AXLAB_ATESPACE}" -o yaml 2>/dev/null || true)"
    golden="$(printf '%s' "${tyaml}" | sed -n 's/^ *snapshotUri: *//p' | head -1)"
    [ -n "${golden}" ] && break
    sleep 5
  done
  loc="$(printf '%s' "${tyaml}" | sed -n 's/^ *storageLocation: *//p' | head -1)"
  lab_note "storageLocation: ${loc:-<none>}"
  lab_note "goldenSnapshot:  ${golden:-<none>}"
  if printf '%s' "${loc}" | grep -q 'ate-snapshots'; then
    pass "snapshots go to the in-cluster bucket (${loc})"
  else
    fail "storageLocation is not the in-cluster bucket: ${loc:-<none>}"
  fi
  if printf '%s' "${golden}" | grep -q 'ate-snapshots'; then
    pass "a real golden snapshot exists on the s3/rustfs path"
  else
    fail "no golden snapshot on the s3/rustfs path: ${golden:-<none>}"
  fi

  # Why the two assertions below exist. ax's readiness signals are TAUTOLOGICAL
  # about the workspace: reconciler.go:280-288 sets WorkspaceReady=True whenever
  # the runner answers /readyz, and the runner reports ready unless
  # SetupWorkspace returns an error -- which it does on only one path
  # (setup.go:95, the mkdir), while a FAILED git clone returns (res, nil) at
  # setup.go:123. So `WorkspaceReady=True` reports the runner's LIVENESS, not
  # whether the workspace was set up. These two assertions check the real thing.
  #
  # (a) root cause, deterministic: the template must actually carry the
  #     Workspace spec, or the runner never received it. The value is a YAML
  #     block scalar ("value: |" then indented lines), so match the name AND a
  #     recognisable line of the payload rather than a single value line.
  local tspec
  tspec="$(ate get actor-template "${tpl}" -a "${AXLAB_ATESPACE}" -o yaml 2>/dev/null || true)"
  if printf '%s' "${tspec}" | grep -qE '^[[:space:]]*- name: AX_WORKSPACES_YAML$'; then
    if printf '%s' "${tspec}" | grep -qE '^[[:space:]]+kind: Workspace$'; then
      pass "the ActorTemplate carries AX_WORKSPACES_YAML with a Workspace document -- the spec reached the sandbox"
    else
      fail "AX_WORKSPACES_YAML is present but carries no 'kind: Workspace' document"
    fi
  else
    fail "the ActorTemplate has no AX_WORKSPACES_YAML: the runner was never told about the Workspace"
  fi

  # The sandbox itself: gVisor's own banner in the actor's log.
  # Read into a file rather than piping to head: head closes the pipe early and
  # the writer dies of SIGPIPE, which under `set -o pipefail` kills the script.
  local glog="${LAB_TMP}/actor.log"
  ate logs actor "${AXLAB_ACTOR}" -a "${AXLAB_ATESPACE}" >"${glog}" 2>/dev/null || true
  if grep -q 'gVisor' "${glog}" 2>/dev/null; then
    pass "the actor's log shows a gVisor sandbox"
    grep -oE 'Version release-[^,]*, go[0-9.]+, amd64' "${glog}" 2>/dev/null | head -1 | sed 's/^/      /'
  else
    fail "no gVisor banner in the actor log -- is it really sandboxed?"
  fi
}

# --- 8: optional ax ssh -----------------------------------------------------

check_ssh() {
  check "8/9  ax ssh runs a command inside the sandbox"
  if [ -z "${AX_BIN}" ]; then
    fail "the ax CLI was not found; cannot run ax ssh"
    return
  fi
  local out rc=0
  # Check the workspace too, in the same ssh we already make. The Workspace the
  # task declares is named by AXLAB_WORKSPACE_NAME (the Task's first
  # workspaces[] entry), which is what a correct setup must have created.
  out="$("${AX_BIN}" ssh "${AXLAB_ACTOR}" --context "${AXLAB_KUBECTL_CONTEXT}" -- \
        /bin/sh -c "echo AXLAB_SSH_OK; uname -srm; echo AXLAB_WS_BEGIN; ls -A /workspace; echo AXLAB_WS_END" 2>&1)" || rc=$?
  show "${out}"
  if [ "${rc}" -ne 0 ]; then
    fail "ax ssh exited ${rc}"
    return
  fi
  if printf '%s' "${out}" | grep -q 'AXLAB_SSH_OK'; then
    pass "ax ssh executed a command inside the sandbox"
  else
    fail "no marker from the remote command"
  fi
  if printf '%s' "${out}" | grep -qi 'gvisor'; then
    pass "uname inside the sandbox reports a gVisor kernel"
  else
    fail "uname inside the sandbox did not report gvisor"
  fi

  # (b) symptom of a real workspace setup. Guarded on the sentinel markers so an
  # empty /workspace, or a failed `ls`, cannot read as a pass.
  #
  # The expected entry is the *repo* directory, not the Workspace resource name.
  # cloneDestination (internal/workspace/setup.go:174-195) uses repo.Dir if set,
  # else repo.Name -- and the shipped Workspace uses `name: origin`, which is
  # exactly the sentinel that makes it derive the name from the URL
  # (RepoDirName). So `/workspace/chalk`, not `/workspace/default-workspace`.
  local listing
  listing="$(printf '%s\n' "${out}" | sed -n '/AXLAB_WS_BEGIN/,/AXLAB_WS_END/p' \
    | grep -vE 'AXLAB_WS_(BEGIN|END)' | grep -v '^[[:space:]]*$' || true)"
  if [ -z "${listing}" ]; then
    fail "/workspace is empty inside the sandbox: the Workspace was never set up (WorkspaceReady=True would still have said otherwise)"
  elif [ -z "${AXLAB_WORKSPACE_DIR}" ]; then
    fail "cannot determine the expected workspace directory (set AXLAB_WORKSPACE_DIR)"
  elif printf '%s\n' "${listing}" | grep -qx "${AXLAB_WORKSPACE_DIR}"; then
    pass "/workspace contains '${AXLAB_WORKSPACE_DIR}', the directory the Workspace's git spec clones into"
    printf '%s' "${listing}" | head -3 | sed 's/^/      /'
  else
    fail "/workspace holds $(printf '%s' "${listing}" | tr '\n' ' ') but the git spec clones into '${AXLAB_WORKSPACE_DIR}'"
  fi
}

# --- 9: the per-actor suspend path, which is NOT the golden path ------------

# Checking only the template's golden snapshot proves the bucket is configured;
# it does not exercise `ax suspend`, which takes a different code path
# (workflow_suspend.go -> resources.NewActorSnapshotURI over the template's
# StorageLocation) and writes under a DIFFERENT key prefix. This is the check
# that actually closes gap 3.
check_suspend_roundtrip() {
  check "9/9  ax suspend writes a per-actor snapshot to the bucket, and resume restores it"
  if [ -z "${AX_BIN}" ]; then
    fail "the ax CLI was not found; cannot suspend/resume"
    return
  fi
  local ws_before out rc=0
  ws_before="$("${AX_BIN}" ssh "${AXLAB_ACTOR}" --context "${AXLAB_KUBECTL_CONTEXT}" -- \
    /bin/sh -c 'ls -A /workspace' 2>&1 || true)"
  lab_note "workspace before suspend: $(printf '%s' "${ws_before}" | tr '\n' ' ')"
  out="$("${AX_BIN}" suspend task "${AXLAB_ACTOR}" --context "${AXLAB_KUBECTL_CONTEXT}" 2>&1)" || rc=$?
  if [ "${rc}" -ne 0 ]; then
    show "${out}"
    fail "ax suspend failed (exit ${rc})"
    return
  fi
  sleep 5

  # The whole point: the per-actor prefix, not the golden one.
  local uri
  uri="$(ate get actor "${AXLAB_ACTOR}" -a "${AXLAB_ATESPACE}" -o yaml 2>/dev/null \
    | sed -n 's/^ *snapshotUri: *//p' | head -1)"
  lab_note "per-actor snapshotUri: ${uri:-<none>}"
  if [ -z "${uri}" ]; then
    fail "the suspended actor has no snapshotUri: the suspend wrote nothing"
    return
  fi
  if printf '%s' "${uri}" | grep -q 'ate-snapshots'; then
    pass "suspend wrote to the corrected bucket"
  else
    fail "suspend snapshot is not on the corrected bucket: ${uri}"
  fi
  if printf '%s' "${uri}" | grep -qE "atespaces/${AXLAB_ATESPACE}/actors/[0-9a-f-]+/snapshots/"; then
    pass "suspend used the PER-ACTOR path atespaces/${AXLAB_ATESPACE}/actors/<uid>/snapshots/, not the golden one"
  else
    fail "expected the per-actor snapshot prefix atespaces/${AXLAB_ATESPACE}/actors/<uid>/snapshots/, got: ${uri}"
  fi

  # Resume and wait for a real placement, not just phase.
  out="$("${AX_BIN}" resume task "${AXLAB_ACTOR}" --context "${AXLAB_KUBECTL_CONTEXT}" 2>&1)" || rc=$?
  if [ "${rc}" -ne 0 ]; then
    show "${out}"
    fail "ax resume failed (exit ${rc})"
    return
  fi
  local wip=""
  local _
  for _ in $(seq 1 40); do
    sleep 5
    wip="$(ax get task "${AXLAB_ACTOR}" 2>/dev/null | sed -n 's/^ *workerIP: *//p' | head -1)"
    [ -n "${wip}" ] && break
  done
  if [ -n "${wip}" ]; then
    pass "resume placed the actor again (worker IP ${wip})"
  else
    fail "no worker IP after resume"
  fi

  local astate
  astate="$(ate get actor "${AXLAB_ACTOR}" -a "${AXLAB_ATESPACE}" 2>/dev/null | awk 'NR==2{print $4}')"
  if [ "${astate}" = "ACTOR_STATE_RUNNING" ]; then
    pass "actor is ACTOR_STATE_RUNNING again after resume"
  else
    fail "actor state after resume is '${astate:-<none>}'"
  fi

  # The workspace must have survived the snapshot -> rustfs -> restore round
  # trip. Same non-empty guard as check 8.
  local ws_after
  ws_after="$("${AX_BIN}" ssh "${AXLAB_ACTOR}" --context "${AXLAB_KUBECTL_CONTEXT}" -- \
    /bin/sh -c 'ls -A /workspace' 2>&1 || true)"
  lab_note "workspace after resume:  $(printf '%s' "${ws_after}" | tr '\n' ' ')"
  if printf '%s' "${ws_after}" | grep -qx "${AXLAB_WORKSPACE_DIR}"; then
    pass "the workspace survived suspend/resume (${AXLAB_WORKSPACE_DIR} still present)"
  elif [ -n "${ws_before}" ] && [ "${ws_before}" = "${ws_after}" ]; then
    pass "the workspace survived suspend/resume (listing unchanged: $(printf '%s' "${ws_after}" | tr '\n' ' '))"
  else
    fail "the workspace did not survive suspend/resume (before: $(printf '%s' "${ws_before}" | tr '\n' ' ') after: $(printf '%s' "${ws_after}" | tr '\n' ' '))"
  fi
}

# --- main -------------------------------------------------------------------

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) usage; printf '\033[31merror: unknown argument: %s\033[0m\n' "$1" >&2; exit 2 ;;
esac

LAB_TMP="$(mktemp -d)"
trap cleanup EXIT

resolve_binaries

lab_step "Preflight"
[ -n "${KUBECTL}" ] || { printf 'error: kubectl not found (set AXLAB_KUBECTL_BIN)\n' >&2; exit 2; }
lab_note "kubectl:    ${KUBECTL}"
lab_note "context:    ${AXLAB_KUBECTL_CONTEXT}"
if [ -n "${KUBECTL_ATE}" ]; then
  lab_note "kubectl-ate: ${KUBECTL_ATE}"
else
  lab_note "kubectl-ate: NOT FOUND"
fi
if [ -n "${AX_BIN}" ]; then
  lab_note "ax:          ${AX_BIN}"
else
  lab_note "ax:          NOT FOUND"
fi

# This script MUTATES: it deletes the demo Task, applies the Workspace and the
# Task, and resumes the task. The context is overridable, so refuse a minikube
# context outright rather than relying on --context being passed correctly.
case "${AXLAB_KUBECTL_CONTEXT}" in
  minikube*)
    cat >&2 <<EOF

error: refusing to run against the minikube profile.

  AXLAB_KUBECTL_CONTEXT=${AXLAB_KUBECTL_CONTEXT}

This script deletes the demo Task, applies resources and resumes a task, so
running it against the user's minikube cluster would write into it. Point it at
the kind cluster instead:

    AXLAB_KUBECTL_CONTEXT=kind-ax-lab scripts/ax-verify.sh
EOF
    exit 2
    ;;
esac

if ! k version >/dev/null 2>&1; then
  cat >&2 <<EOF

error: context '${AXLAB_KUBECTL_CONTEXT}' is not reachable.

Unlike scripts/verify-all.sh, this script cannot run without the cluster.
Phase 2 builds it, Phase 3 deploys onto it:

    scripts/substrate-up.sh
    scripts/ax-up.sh
EOF
  exit 2
fi

# kubectl-ate is needed for the actor checks. Fail loudly rather than skipping.
if [ -z "${KUBECTL_ATE}" ]; then
  printf '\nerror: kubectl-ate could not be resolved; checks 5-9 need it\n' >&2
  # shellcheck disable=SC2016  # literal on purpose: user-facing help text.
  printf '        searched: $AXLAB_KUBECTL_ATE_BIN, then $(go env GOBIN||GOPATH)/bin, then PATH\n' >&2
  printf '        install it with:  cd upstream/substrate && go install ./cmd/kubectl-ate\n' >&2
  exit 2
fi

# Derive the expected workspace directory from the manifest we are about to
# apply, so checks 8-9 assert against what the Workspace spec actually declares
# rather than a hardcoded name.
if [ -z "${AXLAB_WORKSPACE_DIR}" ]; then
  wsfile="${LAB_ROOT}/.work/p3/workspace.yaml"
  if [ -f "${wsfile}" ]; then
    # The .git suffix is stripped in a second pass: making the capture greedy
    # and the .git group optional never backtracks, so it yields "chalk.git".
    AXLAB_WORKSPACE_DIR="$(sed -n 's|.*repo:.*/\([^/"]*\)"*$|\1|p' "${wsfile}" | head -1 | sed 's/\.git$//')"
  fi
fi
lab_note "workspace dir: ${AXLAB_WORKSPACE_DIR:-<undetermined; check 8 will fail>}"

lab_step "Checks 1-4: the control plane is deployed and Substrate is intact"
check_control_plane
check_substrate_intact
check_workerpool
check_bucket_repointed

lab_step "Checks 5-7: a real Task, running in a real sandbox"
if [ "${AXLAB_SKIP_MUTATE}" = "1" ]; then
  SKIPPED=$((SKIPPED + 3))
  SKIPPED_CHECKS+=("5/9 a Task applies Suspended")
  SKIPPED_CHECKS+=("6/9 resume it to Running with a worker IP")
  SKIPPED_CHECKS+=("7/9 the actor is a real gVisor sandbox")
  printf '    \033[33mSKIP\033[0m  AXLAB_SKIP_MUTATE=1; checks 5-7 did NOT run\n'
else
  if check_task_suspended_shape; then
    check_task_running
    check_actor_real
  else
    fail "6/9  resume it (skipped: the Task could not be applied)"
    fail "7/9  real gVisor sandbox (skipped: the Task could not be applied)"
  fi
fi

lab_step "Checks 8-9: inside the sandbox, and the per-actor suspend path"
if [ "${AXLAB_SKIP_MUTATE}" = "1" ]; then
  SKIPPED=$((SKIPPED + 2))
  SKIPPED_CHECKS+=("8/9 ax ssh into the sandbox, workspace present")
  SKIPPED_CHECKS+=("9/9 ax suspend writes a per-actor snapshot, resume restores it")
  printf '    \033[33mSKIP\033[0m  AXLAB_SKIP_MUTATE=1; checks 8-9 did NOT run\n'
else
  check_ssh
  check_suspend_roundtrip
fi

lab_step "Summary"
printf '    passed:  %d\n    failed:  %d\n    skipped: %d\n' "${PASS}" "${FAIL}" "${SKIPPED}"
if [ "${FAIL}" -ne 0 ]; then
  printf '\n\033[31mfailed checks:\033[0m\n'
  for c in "${FAILED_CHECKS[@]}"; do printf '  - %s\n' "${c}"; done
  exit 1
fi
if [ "${SKIPPED}" -ne 0 ]; then
  printf '\n\033[33mPARTIAL\033[0m  %d check(s) skipped, so this is not a full pass:\n' "${SKIPPED}"
  for c in "${SKIPPED_CHECKS[@]}"; do printf '  - %s\n' "${c}"; done
  printf '  re-run without AXLAB_SKIP_MUTATE=1 for a real verdict.\n'
  exit 3
fi
printf '\n\033[32mall checks passed\033[0m\n'
