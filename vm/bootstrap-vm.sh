#!/usr/bin/env bash
# Bring the ax-lab VM to a fully working state, from nothing to a live sandboxed task.
#
# Runs INSIDE the VM. Everything it does is contained in the VM: its own kernel,
# its own docker, its own sysctls. The host is not modified — which is the point,
# because Substrate's install raises fs.inotify.max_user_instances and that limit
# is host-global, not namespaced per container.
#
# Idempotent: safe to re-run. Each step checks whether it is already satisfied.
set -o errexit -o nounset -o pipefail

export PATH=/usr/local/go/bin:$HOME/go/bin:$PATH

LAB="${AXLAB_VM_LAB:-$HOME/ax-lab}"
# The substrate checkout is ~2GB. Building it from the 9p mount would be painful,
# so it lives on the VM's own ext4 and the lab points at it via the override its
# scripts already support (AXLAB_SUBSTRATE_DIR).
CACHE="${AXLAB_VM_CACHE:-$HOME/axlab-cache}"
SUBSTRATE_DIR="$CACHE/substrate"
SUBSTRATE_SHA=672533541dbfcd29084e4de2475267088bda3651
export AXLAB_SUBSTRATE_DIR="$SUBSTRATE_DIR"
export KOCACHE="$CACHE/ko"

# Worker sizing, and why the defaults are right and must be kept.
#
# Measured inside this VM: the kind node has 9.7G allocatable, and the Substrate
# control plane (ateapi, atelet, atenet, postgres, rustfs, envoy, prometheus, otel,
# jaeger, podcertcontroller) plus ax (redis, ax-server, ax-controller) request only
# ~1.6Gi combined. The memory actually goes to the *worker pools*.
#
# Two worker mistakes, both worth recording:
#
# 1. ax-up.sh's 2-replica pool is NOT arbitrary. A suspend/resume needs somewhere
#    to land: the suspended actor still holds its worker until the checkpoint
#    finishes, so resuming onto a 1-replica pool fails with "no free workers
#    available" and the task goes to phase Failed. Found by shrinking to 1 to save
#    RAM and then watching resume fail. Keep 2 replicas.
# 2. The 4Gi in ax-up.sh's default is a *limit*; the scheduler weighs *requests*.
#    Counter demo 3x1Gi + 2 ax workers at 2Gi requests + ~1.6Gi of control plane is
#    ~8.6Gi of 9.7Gi, which fits. Going to 4Gi requests (3+8+1.6) overruns the node
#    and the pod never schedules - that is the "Insufficient memory" that started
#    this. So: keep replicas=2, but hold the request at 2Gi.
export AXLAB_WORKERPOOL_REPLICAS="${AXLAB_WORKERPOOL_REPLICAS:-2}"
export AXLAB_WORKER_CPU="${AXLAB_WORKER_CPU:-2}"
export AXLAB_WORKER_MEMORY="${AXLAB_WORKER_MEMORY:-2Gi}"

# Leave the counter demo at Substrate's own 3. An earlier version of this script
# shrank it to 1 "to save memory", which was wrong twice over: the memory was never
# going there, and a 1-worker pool cannot reliably serve a suspend/resume either.
export AXLAB_VM_COUNTER_REPLICAS="${AXLAB_VM_COUNTER_REPLICAS:-3}"

# Actor identity for the Phase 2 walkthrough, scoped to the Substrate gate.
#
# Do NOT export these globally. substrate-verify.sh and ax-verify.sh both read
# AXLAB_ACTOR, and they mean different things by it: for Substrate it is the demo
# actor inside the ate-demo-counter atespace, for ax it is the name of the Task
# manifest (default `task123`). Exporting the demo name here made the ax gate
# apply `task123` and then go looking for a task called `my-counter-1`, which does
# not exist - reported as "expected phase Suspended on apply, got '<none>'".
# That was a name collision, not a race, and it cost a wrong diagnosis.
# Pass them to the Substrate gate only.
substrate_actor="${AXLAB_ACTOR:-my-counter-1}"
substrate_atespace="${AXLAB_ATESPACE:-ate-demo-counter}"

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

step "Preflight"
printf '  user=%s kernel=%s cpus=%s mem=%s\n' \
  "$(whoami)" "$(uname -r)" "$(nproc)" "$(awk '/MemTotal/{printf "%dG",$2/1048576}' /proc/meminfo)"
printf '  this VM has its own fs.inotify.max_user_instances=%s\n' \
  "$(cat /proc/sys/fs/inotify/max_user_instances)"

# The lab needs four host-side tools. On the original machine they were already
# installed; a fresh VM has none of them, so install them here rather than letting
# a later step fail with a bare "kubectl not on PATH".
step "Tooling (kubectl, kind, ko)"
if ! have kubectl; then
  # Take the current stable client rather than pinning a version that can drift.
  # It must not be older than the kind node by more than one minor version.
  # Writes to /usr/local/bin need root: this script runs as `ubuntu`, while the
  # cloud-init that runs as root has already installed these on a fresh VM.
  kv="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
  curl -fsSL -o /tmp/kubectl "https://dl.k8s.io/release/${kv}/bin/linux/amd64/kubectl"
  sudo install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
fi
if ! have kind; then
  # v0.33.0 is the version the lab was verified with; its default node image is
  # v1.37.0, which is what Substrate needs for the pod-certificate feature gates.
  curl -fsSL -o /tmp/kind https://kind.sigs.k8s.io/dl/v0.33.0/kind-linux-amd64
  sudo install -m 0755 /tmp/kind /usr/local/bin/kind
fi
if ! have ko; then
  # ax's `make deploy` needs ko; Substrate uses its own pinned copy internally.
  go install github.com/google/ko@v0.19.1
fi
printf '  kubectl %s\n  kind    %s\n  ko      %s\n' \
  "$(kubectl version --client 2>/dev/null | awk '{print $3}')" \
  "$(kind version 2>/dev/null | awk '{print $2}')" \
  "$(ko version 2>/dev/null | awk '{print $1, $2}')"

# `make` is required by the ax repo's Makefile; without it setup.sh falls back to
# silently using host-built binaries from the 9p mount, which is misleading.
if ! have make; then
  step "Installing build tooling (make)"
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq make >/dev/null
fi
have make || { echo "FATAL: make still unavailable" >&2; exit 1; }
printf '  make: %s\n' "$(make --version | head -1)"

step "Substrate checkout (VM-local disk, pinned)"
mkdir -p "$CACHE"
if [ ! -d "$SUBSTRATE_DIR/.git" ]; then
  git clone --filter=blob:none -q https://github.com/agent-substrate/substrate.git "$SUBSTRATE_DIR"
fi
git -C "$SUBSTRATE_DIR" checkout -q "$SUBSTRATE_SHA"
got="$(git -C "$SUBSTRATE_DIR" rev-parse HEAD)"
[ "$got" = "$SUBSTRATE_SHA" ] || { echo "FATAL: substrate is at $got, expected $SUBSTRATE_SHA" >&2; exit 1; }
printf '  %s  (matches ax/go.mod pin)\n' "$(git -C "$SUBSTRATE_DIR" rev-parse --short HEAD)"

step "Lab binaries (built inside the VM, not inherited from the host)"
cd "$LAB"
./scripts/setup.sh

step "Phase 1 gate - the five lessons"
./scripts/verify-all.sh

step "Phase 2 - Agent Substrate on kind (this raises the VM's inotify, not the host's)"
./scripts/substrate-up.sh

# Fit the demo pool to the VM. Done after substrate-up.sh, which deploys the
# demo at Substrate's own default of 3 replicas. The WorkerPool's `replicas` is
# a plain field on the CR, so this is a scale, not a redeploy.
step "Fit the counter demo to the VM's memory"
K="kubectl --context kind-ax-lab"
want="$AXLAB_VM_COUNTER_REPLICAS"
have_replicas="$($K get workerpool counter -n ate-demo-counter -o jsonpath='{.spec.replicas}' 2>/dev/null || echo '?')"
if [ "$have_replicas" != "$want" ]; then
  $K patch workerpool counter -n ate-demo-counter --type=merge \
    -p "{\"spec\":{\"replicas\":$want}}" >/dev/null 2>&1 \
    || printf 'warning: could not scale the counter pool to %s (left at %s)\n' "$want" "$have_replicas" >&2
fi
printf '  counter pool replicas: %s -> %s\n' "$have_replicas" "$want"
for _ in $(seq 1 30); do
  ready="$($K get workerpool counter -n ate-demo-counter -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  [ "$ready" = "$want" ] && break
  sleep 5
done
printf '  counter pool ready:    %s/%s\n' "${ready:-0}" "$want"

# After a VM restart the control plane needs a moment before it will answer.
# substrate-up.sh is idempotent and will not reinstall over a healthy cluster, so
# without this wait the gate that follows can fail against a half-started stack.
step "Waiting for the Substrate control plane to be healthy"
for _ in $(seq 1 60); do
  api_pods="$($K get pods -n ate-system -l app=ate-api-server --no-headers 2>/dev/null | grep -c '1/1' || echo 0)"
  router="$($K get pod -n ate-system -l app=atenet-router -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo false)"
  if [ "${api_pods:-0}" -ge 1 ] && [ "$router" = "true" ]; then
    printf '  ate-api-server ready, atenet-router ready\n'
    break
  fi
  sleep 10
done

step "Phase 2 gate"
# A stopped VM can leave an actor stranded in ACTOR_STATE_SUSPENDING: the gVisor
# checkpoint cannot complete once the VM that hosted the sandbox is gone, and
# Substrate only lets you delete an actor once it is fully SUSPENDED. The gate
# already knows this and points at AXLAB_ACTOR, so rather than fight it, pick a
# fresh actor name when the default one is stuck. The stranded actor is inert.
K2="kubectl --context kind-ax-lab"
stuck_state="$(kubectl-ate get actor "$substrate_actor" -a "$substrate_atespace" -o yaml 2>/dev/null \
  | awk '/^ *state:/{print $2; exit}' || true)"
if [ -n "$stuck_state" ] && [ "$stuck_state" != "ACTOR_STATE_SUSPENDED" ] && [ "$stuck_state" != "ACTOR_STATE_DELETED" ]; then
  printf '  actor %s is %s (stranded by an earlier VM stop) - using a fresh name\n' \
    "$substrate_actor" "$stuck_state"
  substrate_actor="${substrate_actor}-$(date +%H%M%S)"
  printf '  AXLAB_ACTOR=%s (scoped to this gate)\n' "$substrate_actor"
fi
AXLAB_ACTOR="$substrate_actor" AXLAB_ATESPACE="$substrate_atespace" ./scripts/substrate-verify.sh

step "Phase 3 - ax control plane"
./scripts/ax-up.sh

step "Phase 3 gate"
# Explicitly drop the Substrate actor name: ax-verify.sh uses AXLAB_ACTOR for the
# Task manifest name, and inheriting the demo actor name breaks it.
env -u AXLAB_ACTOR -u AXLAB_ATESPACE ./scripts/ax-verify.sh

step "Phase 4 - a real sandboxed task, reached from inside the VM"
./bin/ax --context kind-ax-lab ssh task123 -- /bin/sh -c \
  'echo "  uname:    $(uname -srm)"; echo "  uid:      $(id -u)"; echo "  workspace: $(ls -A /workspace | tr "\n" " ")"'

step "Done"
cat <<EOF
  The lab is live inside the VM. From the HOST you can now:

    ./vm/ctl.sh status      # is it up?
    ./vm/ctl.sh shell       # a shell inside the VM
    ./vm/ctl.sh verify      # run all three gates inside the VM
    ./vm/ctl.sh stop        # stop the VM: nothing left running, host untouched
    ./vm/ctl.sh start       # bring it back

  The host was never modified. The only thing this VM costs while running is
  8 vCPU / 10GB RAM / 40GB disk.
EOF
