#!/usr/bin/env bash
# Tear down the Phase 2 lab: the kind cluster and the lab registry. Nothing else.
#
# ---------------------------------------------------------------------------
# SAFETY. This machine also runs a real minikube profile (gamification-hub,
# ingress-nginx, envoy-gateway-system). This script must never touch it, and
# never touch a container it did not create. Three guards enforce that:
#
#   1. Only the kind cluster `${AXLAB_KIND_CLUSTER_NAME}` is deleted, by name.
#      It is never reached through "the current context" and never through
#      `minikube stop`/`minikube delete`.
#   2. The registry container is removed only if it carries the label
#      `created-by=agent-substrate` that hack/create-kind-cluster.sh:65 puts on
#      it. A same-named container that is not ours is left alone and reported.
#   3. The ambient kubectl context is restored on exit, so running this cannot
#      leave the user pointed at a cluster that no longer exists.
# ---------------------------------------------------------------------------
#
# Safe to run when the cluster is already gone (idempotent).
#
# ---------------------------------------------------------------------------
# OPT-IN: restoring the host inotify limits that scripts/substrate-up.sh raised
#
# substrate-up.sh writes fs.inotify.max_user_instances and
# fs.inotify.max_user_watches from inside the kind node container, but
# /proc/sys/fs/inotify/* is not namespaced and the node shares the host user
# namespace, so those are HOST-GLOBAL values. Deleting the cluster does not put
# them back, and this script does not touch them unless you ask.
#
#   AXLAB_RESTORE_INOTIFY=1              restore the recorded pre-lab defaults
#   AXLAB_RESTORE_INOTIFY="128 65536"    restore explicit values
#   AXLAB_RESTORE_INOTIFY="" (default)   do nothing at all
#
# Why opt-in, and why not unconditional: if anything else on this machine has
# legitimately raised these limits, restoring the old values on teardown would
# break *that* workload. Leaving a higher value is harmless; lowering it
# underneath someone else is not.
#
# Where the defaults come from, since "just put it back" needs a number:
#   fs.inotify.max_user_instances = 128
#       The in-kernel default (INOTIFY_MAX_USER_INSTANCES). No sysctl config
#       file on this host sets it: /etc/sysctl.d/, /etc/sysctl.conf and
#       /usr/lib/sysctl.d/ contain no inotify.max_user_instances entry. It read
#       128 before the lab first ran, and 128 now with the lab's value removed.
#   fs.inotify.max_user_watches = 65536
#       Set on purpose by this distribution: /usr/lib/sysctl.d/30-localsearch.conf
#       contains "fs.inotify.max_user_watches = 65536". It read 65536 before the
#       lab first ran.
# Both were also observed directly on the host at lab start, agreeing with the
# above. If you believe they were something else, pass them explicitly.
#
# Ordering note: the restore writes through the kind node container (the only
# unprivileged way to reach a host sysctl), so it happens BEFORE the cluster is
# deleted. If the cluster is already gone, this script tells you the exact
# privileged command to run yourself rather than failing silently.
#
#   AXLAB_DRY_RUN=1   print what would be done, change nothing
# ---------------------------------------------------------------------------
#
# Overrides (all optional):
#   AXLAB_KIND_CLUSTER_NAME   kind cluster to delete       (default: ax-lab)
#   AXLAB_KUBECTL_CONTEXT     that cluster's context       (default: kind-<cluster>)
#   AXLAB_KIND_REGISTRY_PORT  registry port, for reporting (default: 5001)
#   AXLAB_KEEP_REGISTRY       set to 1 to keep the registry container
#   AXLAB_RESTORE_INOTIFY     1, or "<instances> <watches>", to restore them
#   AXLAB_DRY_RUN             set to 1 to print actions without taking them

set -o errexit -o nounset -o pipefail

LAB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

AXLAB_KIND_CLUSTER_NAME="${AXLAB_KIND_CLUSTER_NAME:-ax-lab}"
AXLAB_KUBECTL_CONTEXT="${AXLAB_KUBECTL_CONTEXT:-kind-${AXLAB_KIND_CLUSTER_NAME}}"
AXLAB_KIND_REGISTRY_PORT="${AXLAB_KIND_REGISTRY_PORT:-5001}"
AXLAB_KEEP_REGISTRY="${AXLAB_KEEP_REGISTRY:-0}"
# Empty by default: restoring host inotify limits is opt-in. See the header.
AXLAB_RESTORE_INOTIFY="${AXLAB_RESTORE_INOTIFY:-}"

REGISTRY_CONTAINER="kind-registry"
# The label as docker actually stores it: a key and a value, not one string.
# hack/create-kind-cluster.sh:65 sets --label created-by=agent-substrate, which
# lands as {"created-by":"agent-substrate"}. Indexing the composite string
# instead of the key returns empty, so the guard never matched.
REGISTRY_LABEL_KEY="created-by"
REGISTRY_LABEL_VALUE="agent-substrate"

lab_step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
lab_note() { printf '    %s\n' "$*"; }
lab_ok()   { printf '    \033[32mok\033[0m  %s\n' "$*"; }
lab_warn() { printf '    \033[33mwarn\033[0m  %s\n' "$*"; }
lab_die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  # Leading comment block, tolerant of blank lines; not a fixed range, so
  # header edits cannot truncate it.
  awk 'NR==1{next}
       /^#/          { sub(/^# ?/, ""); print; next }
       /^[[:space:]]*$/ { print; next }
       { exit }' "$0"
}

SAVED_CONTEXT=""
restore_context() {
  local rc=$?
  if [ -n "${SAVED_CONTEXT}" ] && [ "${SAVED_CONTEXT}" != "${AXLAB_KUBECTL_CONTEXT}" ]; then
    kubectl config use-context "${SAVED_CONTEXT}" >/dev/null 2>&1 \
      && printf '\nrestored kubectl context: %s\n' "${SAVED_CONTEXT}" \
      || printf '\n\033[31mwarning: could not restore context %s\033[0m\n' "${SAVED_CONTEXT}" >&2
  fi
  return $rc
}

# minikube_namespaces prints the namespaces that prove the user's cluster is
# intact. Cheap enough to run as a before/after diff, which is the whole point.
#
# The context may legitimately not exist: this lab also runs inside the axlab VM,
# where there is no minikube at all. Guarding with `kubectl config get-contexts`
# matters because the script runs under `set -o errexit -o pipefail`, so a failing
# `kubectl` inside this pipeline would abort the whole teardown before it deleted
# anything - which is exactly what happened before this guard existed.
minikube_namespaces() {
  kubectl config get-contexts -o name 2>/dev/null | grep -qx minikube || return 0
  kubectl --context minikube get ns --no-headers 2>/dev/null | awk '{print $1}' | sort || true
}

# --- main -------------------------------------------------------------------

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) usage; lab_die "unknown argument: $1" ;;
esac

command -v docker >/dev/null 2>&1 || lab_die "docker not on PATH"
docker info >/dev/null 2>&1 || lab_die "cannot talk to the docker daemon"

SAVED_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
trap restore_context EXIT
printf 'kubectl context on entry: %s\n' "${SAVED_CONTEXT:-<none>}"

BEFORE_NS="$(minikube_namespaces)"

# --- host inotify restore (opt-in) -------------------------------------------

# Pre-lab values. See the header for the evidence behind each number.
INOTIFY_DEFAULT_INSTANCES=128
INOTIFY_DEFAULT_WATCHES=65536

# restore_inotify puts the host's inotify limits back. Opt-in only.
#
# The write goes through the kind node container because that is the only
# unprivileged way to reach a host-global sysctl, so this must run while the
# cluster still exists -- hence it is called before the delete below.
restore_inotify() {
  local spec="${AXLAB_RESTORE_INOTIFY:-}"
  [ -n "${spec}" ] || return 0

  # An explicit "no" is a no-op, not an error. Someone exporting
  # AXLAB_RESTORE_INOTIFY=0 to mean "don't" must not get a failed teardown.
  case "${spec}" in
    0|no|false|off|NO|FALSE|OFF|False|Off)
      lab_note "AXLAB_RESTORE_INOTIFY=${spec}: leaving host inotify limits alone"
      return 0
      ;;
  esac

  local want_inst want_watch
  if [ "${spec}" = "1" ]; then
    want_inst="${INOTIFY_DEFAULT_INSTANCES}"
    want_watch="${INOTIFY_DEFAULT_WATCHES}"
  else
    # read -r, not `set --`: word splitting here must not glob, and a
    # three-field read cannot be satisfied by "#2" the way "$#" could.
    local extra=""
    read -r want_inst want_watch extra <<<"${spec}"
    if [ -n "${extra}" ] || [ -z "${want_inst}" ] || [ -z "${want_watch}" ]; then
      lab_die "AXLAB_RESTORE_INOTIFY must be 1, an explicit no (0/no/false/off), or two numbers \"<instances> <watches>\" (got '${spec}')"
    fi
    case "${want_inst}${want_watch}" in
      *[!0-9]*) lab_die "AXLAB_RESTORE_INOTIFY values must be numbers (got '${spec}')" ;;
    esac
  fi

  lab_step "Restoring host inotify limits (requested)"

  local node cur_inst cur_watch
  cur_inst="$(cat /proc/sys/fs/inotify/max_user_instances)"
  cur_watch="$(cat /proc/sys/fs/inotify/max_user_watches)"

  if [ "${AXLAB_DRY_RUN:-0}" = "1" ]; then
    printf '    \033[33mDRY RUN\033[0m  would set host fs.inotify.max_user_instances %s -> %s\n' \
      "${cur_inst}" "${want_inst}"
    printf '    \033[33mDRY RUN\033[0m  would set host fs.inotify.max_user_watches   %s -> %s\n' \
      "${cur_watch}" "${want_watch}"
    return 0
  fi

  node="${AXLAB_KIND_CLUSTER_NAME}-control-plane"
  if ! docker ps --format '{{.Names}}' | grep -qx "${node}"; then
    lab_warn "the kind node ${node} is not running, so this unprivileged script"
    lab_warn "cannot reach the host sysctl. Nothing was changed. Run this yourself:"
    lab_warn "  sudo sysctl -w fs.inotify.max_user_instances=${want_inst}"
    lab_warn "  sudo sysctl -w fs.inotify.max_user_watches=${want_watch}"
    return 0
  fi

  docker exec "${node}" sysctl -q -w "fs.inotify.max_user_instances=${want_inst}" >/dev/null
  docker exec "${node}" sysctl -q -w "fs.inotify.max_user_watches=${want_watch}" >/dev/null
  printf '    \033[33mHOST KERNEL\033[0m  fs.inotify.max_user_instances %s -> %s\n' \
    "${cur_inst}" "$(cat /proc/sys/fs/inotify/max_user_instances)"
  printf '    \033[33mHOST KERNEL\033[0m  fs.inotify.max_user_watches   %s -> %s\n' \
    "${cur_watch}" "$(cat /proc/sys/fs/inotify/max_user_watches)"
  lab_ok "host inotify limits restored"
}

restore_inotify

# --- cluster ----------------------------------------------------------------

lab_step "Deleting kind cluster '${AXLAB_KIND_CLUSTER_NAME}'"
if [ "${AXLAB_DRY_RUN:-0}" = "1" ]; then
  # S1: the dry run used to be honoured only by restore_inotify, so control
  # fell straight through into a real delete. Every destructive step is
  # guarded now, not just the sysctl.
  if docker ps -a --format '{{.Names}}' | grep -qx "${AXLAB_KIND_CLUSTER_NAME}-control-plane"; then
    printf '    \033[33mDRY RUN\033[0m  would run: kind delete cluster --name %s\n' "${AXLAB_KIND_CLUSTER_NAME}"
  else
    printf '    \033[33mDRY RUN\033[0m  cluster already absent; nothing to delete\n'
  fi
elif docker ps -a --format '{{.Names}}' | grep -qx "${AXLAB_KIND_CLUSTER_NAME}-control-plane"; then
  # Only ever the kind CLI, only ever by name. `minikube` is never invoked.
  # Prefer the kind that hack/tools/kind pins (the same one substrate-up.sh
  # created the cluster with); fall back to PATH.
  if [ -x "${AXLAB_SUBSTRATE_DIR:-${LAB_ROOT}/upstream/substrate}/hack/kind.sh" ]; then
    ( cd "${AXLAB_SUBSTRATE_DIR:-${LAB_ROOT}/upstream/substrate}" \
        && ./hack/kind.sh delete cluster --name "${AXLAB_KIND_CLUSTER_NAME}" ) 2>&1 | sed 's/^/    /'
  elif command -v kind >/dev/null 2>&1; then
    kind delete cluster --name "${AXLAB_KIND_CLUSTER_NAME}" 2>&1 | sed 's/^/    /'
  else
    lab_die "no kind binary found (set AXLAB_SUBSTRATE_DIR or put kind on PATH)"
  fi
  lab_ok "kind cluster deleted"
else
  lab_note "no ${AXLAB_KIND_CLUSTER_NAME}-control-plane container; already gone"
fi

# The kubeconfig entries kind wrote are now dangling.
if [ "${AXLAB_DRY_RUN:-0}" = "1" ]; then
  if kubectl config get-contexts -o name 2>/dev/null | grep -qx "${AXLAB_KUBECTL_CONTEXT}"; then
    printf '    \033[33mDRY RUN\033[0m  would remove kubeconfig context %s\n' "${AXLAB_KUBECTL_CONTEXT}"
  else
    printf '    \033[33mDRY RUN\033[0m  kubeconfig context %s already absent\n' "${AXLAB_KUBECTL_CONTEXT}"
  fi
elif kubectl config get-contexts -o name 2>/dev/null | grep -qx "${AXLAB_KUBECTL_CONTEXT}"; then
  kubectl config delete-context "${AXLAB_KUBECTL_CONTEXT}" >/dev/null 2>&1 || true
  lab_ok "removed kubeconfig context ${AXLAB_KUBECTL_CONTEXT}"
else
  lab_note "kubeconfig context ${AXLAB_KUBECTL_CONTEXT} already absent"
fi

# --- registry ---------------------------------------------------------------

lab_step "Registry '${REGISTRY_CONTAINER}' on port ${AXLAB_KIND_REGISTRY_PORT}"
if [ "${AXLAB_KEEP_REGISTRY}" = "1" ]; then
  lab_note "AXLAB_KEEP_REGISTRY=1; leaving ${REGISTRY_CONTAINER} in place"
elif ! docker ps -a --format '{{.Names}}' | grep -qx "${REGISTRY_CONTAINER}"; then
  lab_note "${REGISTRY_CONTAINER} does not exist; nothing to do"
else
  # Guard 2: only remove it if it is the one upstream's script created.
  #
  # The label is keyed "created-by" with the value "agent-substrate"
  # (hack/create-kind-cluster.sh:65). Indexing the composite string
  # "created-by=agent-substrate" returns empty, so this guard never matched:
  # it under-deleted, leaked the registry and every image in it on every run,
  # and printed an accusation that was itself false. The failure direction was
  # safe, but the behaviour was not what the header promised.
  if [ "$(docker inspect -f "{{index .Config.Labels \"${REGISTRY_LABEL_KEY}\"}}" "${REGISTRY_CONTAINER}" 2>/dev/null)" = "${REGISTRY_LABEL_VALUE}" ]; then
    if [ "${AXLAB_DRY_RUN:-0}" = "1" ]; then
      printf '    \033[33mDRY RUN\033[0m  would remove %s (it carries created-by=agent-substrate)\n' "${REGISTRY_CONTAINER}"
    else
      docker rm -f "${REGISTRY_CONTAINER}" >/dev/null
      lab_ok "removed ${REGISTRY_CONTAINER} (carried created-by=agent-substrate)"
    fi
  else
    lab_warn "${REGISTRY_CONTAINER} exists but does not carry created-by=agent-substrate;"
    lab_warn "it is not ours, so it was left running. Remove it by hand if that is wrong."
  fi
fi

# --- report -----------------------------------------------------------------

lab_step "minikube untouched?"
AFTER_NS="$(minikube_namespaces)"
if [ -z "${BEFORE_NS}" ]; then
  lab_warn "could not read minikube namespaces before or after; cannot assert"
elif [ "${BEFORE_NS}" = "${AFTER_NS}" ]; then
  lab_ok "minikube namespace set unchanged:"
  printf '%s\n' "${AFTER_NS}" | sed 's/^/        /'
else
  lab_warn "minikube namespace set CHANGED:"
  diff <(printf '%s\n' "${BEFORE_NS}") <(printf '%s\n' "${AFTER_NS}") | sed 's/^/        /' || true
fi

cat <<EOF

Done. Remaining lab containers (not touched by this script):
$(docker ps --format '  {{.Names}}\t{{.Image}}' | grep -v "^  ${AXLAB_KIND_CLUSTER_NAME}-" || echo '  (none)')
EOF
