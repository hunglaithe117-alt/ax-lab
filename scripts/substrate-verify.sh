#!/usr/bin/env bash
# Phase 2 gate: the seven evidence checks for "Agent Substrate is really up on
# kind, and a real sandboxed actor survives suspend/resume".
#
# ---------------------------------------------------------------------------
# THIS SCRIPT NEEDS A LIVE CLUSTER. That is the entire difference from
# scripts/verify-all.sh, which is deliberately cluster-free and is what a clean
# checkout runs. substrate-verify.sh is NOT called by verify-all.sh and must not
# be added to it: verify-all.sh's contract is "no cluster required", and these
# checks cannot honour that.
#
#   scripts/substrate-up.sh          # brings the cluster up (idempotent)
#   scripts/substrate-verify.sh      # these seven checks; non-zero on failure
#
# Checks 5 and 6 mutate state: they create the demo actor, then suspend and
# resume it. Everything else is read-only. Set AXLAB_SKIP_MUTATE=1 to skip those
# two against a cluster you do not want touched.
#
# This script never touches the user's minikube profile: it only ever passes
# --context "${AXLAB_KUBECTL_CONTEXT}".
#
# Overrides:
#   AXLAB_KUBECTL_CONTEXT   context to test        (default: kind-ax-lab)
#   AXLAB_ACTOR             demo actor name        (default: my-counter-1)
#   AXLAB_ATESPACE          demo atespace          (default: ate-demo-counter)
#   AXLAB_TEMPLATE          ActorTemplate name     (default: counter)
#   AXLAB_ROUTER_LOCAL_PORT port-forward host port (default: 8000)
#   AXLAB_SKIP_MUTATE       1 to skip checks 5 and 6
#   AXLAB_KUBECTL_ATE_BIN   kubectl-ate path or directory (default: resolved
#                           from $AXLAB_KUBECTL_ATE_BIN, then
#                           $(go env GOBIN||GOPATH)/bin, then PATH)
#
# Ports: 8000 for the port-forward, deliberately not 80/6379/8080.
#
# This script is self-contained: it does not assume $(go env GOPATH)/bin is on
# PATH, and it does not modify the ambient kubectl context. It must reach the
# same verdict in a clean environment as in an interactive shell.

set -o errexit -o nounset -o pipefail

LAB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

AXLAB_KUBECTL_CONTEXT="${AXLAB_KUBECTL_CONTEXT:-kind-ax-lab}"
AXLAB_ACTOR="${AXLAB_ACTOR:-my-counter-1}"
AXLAB_ATESPACE="${AXLAB_ATESPACE:-ate-demo-counter}"
AXLAB_TEMPLATE="${AXLAB_TEMPLATE:-counter}"
AXLAB_ROUTER_LOCAL_PORT="${AXLAB_ROUTER_LOCAL_PORT:-8000}"
AXLAB_SKIP_MUTATE="${AXLAB_SKIP_MUTATE:-0}"

PASS=0
FAIL=0
SKIPPED=0
FAILED_CHECKS=()
SKIPPED_CHECKS=()
LAB_TMP=""

k()   { kubectl --context "${AXLAB_KUBECTL_CONTEXT}" "$@"; }
# Every actor call goes through the absolute path resolved by
# resolve_kubectl_ate, never a bare `kubectl ate`. `kubectl` finds a plugin named
# kubectl-ate by looking on PATH, and whether $(go env GOBIN|GOPATH)/bin is on
# PATH depends on whose shell you are in. Gating the gate on that made this
# script report a false failure in a clean environment, so resolve it ourselves.
ate() { "${KUBECTL_ATE}" --context "${AXLAB_KUBECTL_CONTEXT}" "$@"; }

# resolve_kubectl_ate prints an absolute path to kubectl-ate, or nothing.
# Order: explicit override, then the Go install dir, then PATH.
resolve_kubectl_ate() {
  local candidate

  if [ -n "${AXLAB_KUBECTL_ATE_BIN:-}" ]; then
    # Accept either the directory or the full path.
    if [ -x "${AXLAB_KUBECTL_ATE_BIN}" ]; then
      printf '%s\n' "${AXLAB_KUBECTL_ATE_BIN}"; return 0
    fi
    if [ -x "${AXLAB_KUBECTL_ATE_BIN}/kubectl-ate" ]; then
      printf '%s\n' "${AXLAB_KUBECTL_ATE_BIN}/kubectl-ate"; return 0
    fi
    return 1
  fi

  local gobin=""
  if command -v go >/dev/null 2>&1; then
    gobin="$(go env GOBIN 2>/dev/null || true)"
    [ -n "${gobin}" ] || gobin="$(go env GOPATH 2>/dev/null || true)/bin"
  fi
  if [ -n "${gobin}" ] && [ -x "${gobin}/kubectl-ate" ]; then
    printf '%s\n' "${gobin}/kubectl-ate"; return 0
  fi

  candidate="$(command -v kubectl-ate 2>/dev/null || true)"
  if [ -n "${candidate}" ]; then
    case "${candidate}" in /*) printf '%s\n' "${candidate}"; return 0 ;; esac
  fi
  return 1
}

lab_step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
lab_note() { printf '    %s\n' "$*"; }
check()    { printf '\n\033[1m--- %s\033[0m\n' "$*"; }
pass()     { printf '    \033[32mPASS\033[0m  %s\n' "$*"; PASS=$((PASS + 1)); }
fail()     { printf '    \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=$((FAIL + 1)); FAILED_CHECKS+=("$*"); }
show()     { printf '%s\n' "$1" | sed 's/^/      /'; }

usage() {
  # Leading comment block, tolerant of blank lines; not a fixed range, so
  # header edits cannot truncate it.
  awk 'NR==1{next}
       /^#/          { sub(/^# ?/, ""); print; next }
       /^[[:space:]]*$/ { print; next }
       { exit }' "$0"
}

# PF_PID is the port-forward this script owns. cleanup() runs on every exit
# path, including the early `return`s in check_actor_lifecycle, so a failed run
# can never leave port AXLAB_ROUTER_LOCAL_PORT bound and break the next one.
PF_PID=""
stop_pf() {
  [ -n "${PF_PID}" ] || return 0
  kill "${PF_PID}" 2>/dev/null || true
  wait "${PF_PID}" 2>/dev/null || true
  PF_PID=""
}
cleanup() {
  stop_pf
  [ -n "${LAB_TMP}" ] && rm -rf "${LAB_TMP}"
  return 0
}

# --- checks 1-4: is the control plane there? --------------------------------

check_ax_gate() {
  check "1/7  svc/api in ate-system (the exact gate in ax/README.md:72)"
  local out rc=0
  out="$(k get svc api -n ate-system 2>&1)" || rc=$?
  show "$out"
  if [ "${rc}" -eq 0 ]; then pass "svc api exists"; else fail "svc api missing -- ax cannot reach the Substrate control API"; fi
}

check_atelet_version() {
  check "2/7  atelet DaemonSet and its substrate-version label"
  local out ready
  out="$(k get ds -n ate-system -l app=atelet -L ate.dev/substrate-version 2>&1)" || true
  show "$out"
  if ! printf '%s' "$out" | grep -q 'ate.dev/substrate-version'; then
    fail "no DaemonSet labelled app=atelet, or no version label"
    return
  fi
  ready="$(k get ds -n ate-system -l app=atelet -o jsonpath='{.items[0].status.numberReady}' 2>/dev/null || echo 0)"
  if [ "${ready:-0}" -ge 1 ]; then
    pass "atelet ready (${ready}) with a substrate-version label"
  else
    fail "atelet DaemonSet has 0 ready pods"
  fi

  # G3: the label only proves the DaemonSet is self-consistent -- not that the
  # tree it was built from is the commit ax actually depends on. Read the pin
  # out of ax's go.mod and compare it to the checkout, so a reader sitting on
  # substrate@main cannot get a green gate.
  local ax_gomod sub_dir want have
  ax_gomod="${AXLAB_GO_MOD:-${LAB_ROOT}/upstream/google-ax/go.mod}"
  sub_dir="${AXLAB_SUBSTRATE_DIR:-${LAB_ROOT}/upstream/substrate}"
  if [ ! -f "${ax_gomod}" ]; then
    fail "cannot find ${ax_gomod}; cannot verify the Substrate pin (set AXLAB_GO_MOD)"
    return
  fi
  if [ ! -d "${sub_dir}/.git" ]; then
    fail "no substrate git checkout at ${sub_dir}; cannot verify the pin"
    return
  fi
  # v0.0.0-<utc>-<12-hex-commit>
  want="$(sed -n 's|.*github.com/agent-substrate/substrate v0\.0\.0-[0-9]*-\([0-9a-f]\{12\}\).*|\1|p' \
    "${ax_gomod}" | head -1)"
  have="$(git -C "${sub_dir}" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
  if [ -z "${want}" ]; then
    fail "could not parse a substrate pseudo-version out of ${ax_gomod}"
  elif [ "${want}" = "${have}" ]; then
    pass "substrate checkout ${have} is the commit ax pins (ax/go.mod)"
  else
    fail "substrate checkout is ${have} but ax pins ${want} -- this gate is only valid on the pin"
  fi
}

check_cert_publisher() {
  check "3/7  ClusterTrustBundles published, podcertificate-controller healthy"
  local pid_ctb dns_ctb pcc_ready
  pid_ctb="$(k get clustertrustbundles -o name 2>/dev/null | grep -c 'podidentity.*primary-bundle' || true)"
  dns_ctb="$(k get clustertrustbundles -o name 2>/dev/null | grep -c 'servicedns.*primary-bundle' || true)"
  k get clustertrustbundles 2>/dev/null | sed 's/^/      /'
  # NB: `get deploy/NAME`, not `get deploy NAME deploy/NAME` -- kubectl rejects
  # mixing a bare resource type with a resource/name argument.
  pcc_ready="$(k get -n podcertificate-controller-system deploy/podcertificate-controller \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo 0)"
  if [ "${pid_ctb:-0}" -ge 1 ] && [ "${dns_ctb:-0}" -ge 1 ] && [ "${pcc_ready:-0}" -ge 1 ]; then
    pass "podidentity + servicedns primary bundles present; controller ready=${pcc_ready}"
  else
    fail "podidentity=${pid_ctb:-0} servicedns=${dns_ctb:-0} controller_ready=${pcc_ready:-0} (want >=1 each)"
  fi
}

check_crds() {
  check "4/7  ate.dev CRDs"
  if k get crd workerpools.ate.dev sandboxconfigs.ate.dev >/dev/null 2>&1; then
    k get crd workerpools.ate.dev sandboxconfigs.ate.dev | sed 's/^/      /'
    pass "workerpools.ate.dev and sandboxconfigs.ate.dev present"
  else
    k get crd 2>/dev/null | grep ate.dev | sed 's/^/      /' || true
    fail "workerpools.ate.dev / sandboxconfigs.ate.dev missing"
  fi
}

# --- checks 5-6: a real actor, suspended and resumed -------------------------

# hit sends one request through atenet-router to the demo actor and echoes the
# response. memcount pulls the demo's in-process counter out of that response.
hit() {
  curl -sS --max-time 180 -X POST \
    -H "ate-target-actor: ${AXLAB_ATESPACE}/${AXLAB_ACTOR}" \
    "http://localhost:${AXLAB_ROUTER_LOCAL_PORT}" 2>&1
}
memcount() { printf '%s' "$1" | sed -n 's/.*preserved memory count: \([0-9][0-9]*\).*/\1/p'; }
# workerof reads the WORKER POD column (5th) of `kubectl ate get actor`.
workerof() { ate get actor "$1" -a "${AXLAB_ATESPACE}" 2>/dev/null | awk 'NR==2{print $5}'; }

check_actor_lifecycle() {
  check "5/7  create a real gVisor actor and drive it over the atenet-router"
  if [ -z "${KUBECTL_ATE}" ]; then
    fail "kubectl-ate could not be resolved; cannot create the actor"
    # shellcheck disable=SC2016  # literal on purpose: user-facing help text.
    printf '           searched: $AXLAB_KUBECTL_ATE_BIN, then $(go env GOBIN||GOPATH)/bin, then PATH\n'
    printf '           install it with:  cd %s && go install ./cmd/kubectl-ate\n' \
      "${AXLAB_SUBSTRATE_DIR:-upstream/substrate}"
    fail "6/7  suspend/resume (skipped: no kubectl-ate)"
    return
  fi

  # Start from a clean slate so the counter walkthrough is reproducible. Only a
  # *suspended* actor can be deleted (ateapi.proto: "Only suspended actors can
  # be deleted"), so a leftover actor from a previous run has to be suspended
  # first or the delete fails with FailedPrecondition.
  if ate get actor "${AXLAB_ACTOR}" -a "${AXLAB_ATESPACE}" >/dev/null 2>&1; then
    lab_note "actor ${AXLAB_ACTOR} already exists; suspending then deleting it"
    ate suspend actor "${AXLAB_ACTOR}" -a "${AXLAB_ATESPACE}" >/dev/null 2>&1 || true
    if ! ate delete actor "${AXLAB_ACTOR}" -a "${AXLAB_ATESPACE}" >/dev/null 2>&1; then
      fail "a leftover actor ${AXLAB_ACTOR} could not be removed; set AXLAB_ACTOR to a fresh name"
      fail "6/7  suspend/resume (skipped: stale actor)"
      return
    fi
  fi

  local out rc=0
  out="$(ate create actor "${AXLAB_ACTOR}" -a "${AXLAB_ATESPACE}" --template "${AXLAB_TEMPLATE}" 2>&1)" || rc=$?
  show "$out"
  if [ "${rc}" -ne 0 ]; then
    fail "could not create the actor"
    fail "6/7  suspend/resume (skipped: no actor)"
    return
  fi

  if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${AXLAB_ROUTER_LOCAL_PORT}\$"; then
    fail "host port ${AXLAB_ROUTER_LOCAL_PORT} is already in use; set AXLAB_ROUTER_LOCAL_PORT"
    fail "6/7  suspend/resume (skipped: no port-forward)"
    return
  fi
  # Call kubectl directly rather than through the k() wrapper: backgrounding a
  # shell *function* makes $! the subshell's PID, not kubectl's, so the cleanup
  # kill silently misses and the port stays bound for the next run.
  kubectl --context "${AXLAB_KUBECTL_CONTEXT}" port-forward \
    -n ate-system svc/atenet-router "${AXLAB_ROUTER_LOCAL_PORT}:80" \
    >"${LAB_TMP}/pf.log" 2>&1 &
  PF_PID=$!
  for _ in $(seq 1 50); do
    grep -q 'Forwarding from' "${LAB_TMP}/pf.log" 2>/dev/null && break
    if ! kill -0 "${PF_PID}" 2>/dev/null; then
      show "$(cat "${LAB_TMP}/pf.log")"
      fail "port-forward died immediately"
      fail "6/7  suspend/resume (skipped: no port-forward)"
      return
    fi
    sleep 0.2
  done
  lab_note "port-forward ${AXLAB_ROUTER_LOCAL_PORT} -> svc/atenet-router:80"

  # First call resumes the actor on demand from its golden snapshot.
  local r1 r2 r3 m1 m2 m3
  r1="$(hit)"; printf '      call 1: %s\n' "${r1}"
  r2="$(hit)"; printf '      call 2: %s\n' "${r2}"
  r3="$(hit)"; printf '      call 3: %s\n' "${r3}"
  m1="$(memcount "${r1}")"; m2="$(memcount "${r2}")"; m3="$(memcount "${r3}")"

  if [ -z "${m1}" ] || [ -z "${m2}" ] || [ -z "${m3}" ]; then
    fail "could not parse the counter out of the response(s)"
  elif [ "${m1}" = "${m2}" ] || [ "${m2}" = "${m3}" ] || [ "${m2}" -le "${m1}" ] || [ "${m3}" -le "${m2}" ]; then
    fail "counter did not increment across calls (${m1} / ${m2} / ${m3})"
  else
    pass "counter incremented ${m1} -> ${m2} -> ${m3}; it is in-process memory, so this is a real sandboxed actor"
  fi

  # --- 6 ---
  check "6/7  suspend to rustfs, then resume with state intact"
  local before after
  before="$(workerof "${AXLAB_ACTOR}")"
  lab_note "worker before suspend: ${before:-<none>}"

  local sout src=0
  sout="$(ate suspend actor "${AXLAB_ACTOR}" -a "${AXLAB_ATESPACE}" 2>&1)" || src=$?
  show "${sout}"
  if [ "${src}" -ne 0 ]; then
    fail "suspend failed"
    stop_pf
    return
  fi
  if printf '%s' "${sout}" | grep -q 'ACTOR_STATE_SUSPENDED'; then
    lab_note "state is ACTOR_STATE_SUSPENDED and the worker assignment was cleared"
  else
    fail "actor is not ACTOR_STATE_SUSPENDED after suspend"
  fi

  local snap_uri
  snap_uri="$(ate get actor "${AXLAB_ACTOR}" -a "${AXLAB_ATESPACE}" -o yaml 2>/dev/null \
    | sed -n 's/.*snapshotUri: //p' | head -1)"
  if [ -n "${snap_uri}" ]; then
    lab_note "external snapshot: ${snap_uri}"
  else
    fail "actor has no externalSnapshot.snapshotUri after suspend (nothing reached object storage?)"
  fi

  # The router resumes on demand, so the next call is the resume.
  local r4 m4
  r4="$(hit)"; printf '      call 4 (after suspend): %s\n' "${r4}"
  m4="$(memcount "${r4}")"
  if [ -z "${m4}" ]; then
    fail "no usable response after suspend; the resume did not happen"
  elif [ "${m4}" -le "${m3}" ]; then
    fail "state did not survive: memory count went ${m3} -> ${m4} (expected greater than ${m3})"
  else
    pass "state survived suspend/resume: memory count ${m3} -> ${m4}"
  fi

  after="$(workerof "${AXLAB_ACTOR}")"
  lab_note "worker after resume:  ${after:-<none>}"
  if [ "${after}" = "${before}" ]; then
    lab_note "resumed onto the SAME worker (${after}); its node-local snapshot was still there"
  else
    lab_note "resumed onto a DIFFERENT worker: ${before} -> ${after}"
  fi

  stop_pf
}

# --- check 7: prewarm, and nothing crash-looping -----------------------------

check_prewarm() {
  check "7/7  atelet pre-warmed the gVisor asset, and nothing is crash-looping"
  # G2: the prewarm line alone proves nothing about gVisor -- the string
  # "Sandbox assets prewarmed" contains no "gvisor", so the old grep would have
  # passed on a microvm-only prewarm. The config name on that same line is the
  # discriminator, so require it.
  local prewarm gvisor_prewarm
  prewarm="$(k logs -n ate-system -l app=atelet --tail=5000 2>/dev/null \
    | grep -E 'Sandbox assets prewarmed' | tail -1 || true)"
  gvisor_prewarm="$(printf '%s' "${prewarm}" | grep -i 'gvisor' || true)"

  if [ -n "${prewarm}" ] && [ -n "${gvisor_prewarm}" ]; then
    show "${gvisor_prewarm}"
    pass "atelet prewarmed a gVisor sandbox config (SandboxConfig gvisor-default)"
  elif [ -n "${prewarm}" ]; then
    show "${prewarm}"
    fail "a sandbox asset was prewarmed but it is NOT gvisor: $(printf '%s' "${prewarm}" | grep -o '"config":"[^"]*"')"
  else
    k logs -n ate-system -l app=atelet --tail=200 2>/dev/null | grep -i prewarm | sed 's/^/      /' || true
    fail "no 'Sandbox assets prewarmed' line in the atelet log"
  fi

  # Independent corroboration: a real restore actually ran on the gvisor class.
  local restore
  restore="$(k logs -n ate-system -l app=atelet --tail=5000 2>/dev/null \
    | grep -E 'Restore timing breakdown' | grep -i '"ate.sandbox.class":"gvisor"' | tail -1 || true)"
  if [ -n "${restore}" ]; then
    lab_note "and a restore ran on it: $(printf '%s' "${restore}" | grep -o '"ate.sandbox.class":"[^"]*"')"
    pass "atelet restored an actor on the gvisor sandbox class"
  else
    fail "no atelet restore log naming the gvisor sandbox class"
  fi

  local crashy
  crashy="$(k get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{" "}{range .status.containerStatuses[*]}{.name}{"="}{.restartCount}{" "}{end}{"\n"}{end}' 2>/dev/null \
    | awk '{ for (i=2; i<=NF; i++) { split($i, kv, "="); if (kv[2]+0 > 2) { print $0; break } } }' || true)"
  if [ -n "${crashy}" ]; then
    show "${crashy}"
    fail "pods restarting more than twice (see above)"
  else
    lab_note "no pod has restarted more than twice"
    pass "no crash-looping pods"
  fi
}

# --- main -------------------------------------------------------------------

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) usage; printf '\033[31merror: unknown argument: %s\033[0m\n' "$1" >&2; exit 2 ;;
esac

command -v kubectl >/dev/null 2>&1 || { echo "kubectl not on PATH" >&2; exit 2; }

LAB_TMP="$(mktemp -d)"
trap cleanup EXIT

lab_step "Preflight"
lab_note "context: ${AXLAB_KUBECTL_CONTEXT}"
if ! k version >/dev/null 2>&1; then
  cat >&2 <<EOF

error: context '${AXLAB_KUBECTL_CONTEXT}' is not reachable.

Unlike scripts/verify-all.sh, this script cannot run without the lab cluster.
Bring it up first:

    scripts/substrate-up.sh

or aim it elsewhere:
    AXLAB_KUBECTL_CONTEXT=... scripts/substrate-verify.sh
EOF
  exit 2
fi
lab_note "server: $(k version -o json 2>/dev/null | python3 -c 'import json,sys;print(json.load(sys.stdin)["serverVersion"]["gitVersion"])' 2>/dev/null || echo unknown)"

# Resolve kubectl-ate once, up front, so checks 5-6 do not depend on PATH.
KUBECTL_ATE=""
if KUBECTL_ATE="$(resolve_kubectl_ate)"; then
  lab_note "kubectl-ate: ${KUBECTL_ATE}"
else
  KUBECTL_ATE=""
  printf '    \033[33mwarn\033[0m  kubectl-ate not found; checks 5 and 6 will fail\n'
  # shellcheck disable=SC2016  # literal on purpose: this is user-facing help text
  # naming the search order, not code that should expand.
  printf '           searched: $AXLAB_KUBECTL_ATE_BIN, then $(go env GOBIN||GOPATH)/bin, then PATH\n'
  printf '           install it with:  cd %s && go install ./cmd/kubectl-ate\n' \
    "${AXLAB_SUBSTRATE_DIR:-upstream/substrate}"
fi

lab_step "Checks 1-4: the control plane is up"
check_ax_gate
check_atelet_version
check_cert_publisher
check_crds

lab_step "Checks 5-6: a real actor, suspended and resumed"
if [ "${AXLAB_SKIP_MUTATE}" = "1" ]; then
  # G1: these were requested to be skipped, so they must be counted as
  # skipped. A gate that reported "all checks passed" here would be claiming
  # evidence it never collected -- the same class of bug as a gate that only
  # passes under one operator's PATH.
  SKIPPED=$((SKIPPED + 2))
  SKIPPED_CHECKS+=("5/7 create + drive a real gVisor actor")
  SKIPPED_CHECKS+=("6/7 suspend and resume it with state intact")
  printf '    \033[33mSKIP\033[0m  AXLAB_SKIP_MUTATE=1; checks 5 and 6 did NOT run\n'
else
  check_actor_lifecycle
fi

lab_step "Check 7: prewarm and pod health"
check_prewarm

lab_step "Summary"
printf '    passed:  %d\n    failed:  %d\n    skipped: %d\n' "${PASS}" "${FAIL}" "${SKIPPED}"
if [ "${FAIL}" -ne 0 ]; then
  printf '\n\033[31mfailed checks:\033[0m\n'
  for c in "${FAILED_CHECKS[@]}"; do printf '  - %s\n' "${c}"; done
  exit 1
fi
if [ "${SKIPPED}" -ne 0 ]; then
  # Never say "all checks passed" when checks did not run.
  printf '\n\033[33mPARTIAL\033[0m  %d check(s) skipped, so this is not a full pass:\n' "${SKIPPED}"
  for c in "${SKIPPED_CHECKS[@]}"; do printf '  - %s\n' "${c}"; done
  printf '  re-run without AXLAB_SKIP_MUTATE=1 for a real verdict.\n'
  exit 3
fi
printf '\n\033[32mall checks passed\033[0m\n'
