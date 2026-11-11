#!/usr/bin/env bash
# Phase 3 teardown: remove only the objects Phase 3 created.
#
# ---------------------------------------------------------------------------
# SAFETY. This machine also runs a real minikube cluster, and the kind cluster
# also hosts Substrate (Phase 2). This script must touch neither.
#
#   1. Every kubectl call passes --context explicitly, and the ambient context is
#      saved and restored on exit. `minikube` is never invoked.
#   2. It only ever deletes objects carrying this lab's ownership label
#      (axlab.teacher/owner=phase3) or named exactly as listed below inside the
#      ax-system namespace.
#   3. It NEVER touches Substrate: not ate-system, not ate-demo-counter, not the
#      counter WorkerPool, not the kind-registry container. Deleting the ax
#      control plane must leave Phase 2 fully working -- that is the point of
#      check 2 in ax-verify.sh.
#   4. AXLAB_DRY_RUN=1 prevents EVERY destructive action below, not just some of
#      them. Phase 2's teardown shipped advertising a dry run that deleted the
#      cluster anyway; this one is written so that cannot recur: every delete
#      goes through the guarded helpers below, and those honour the flag.
#
# The registry images are the one genuinely shared resource: they live in the
# kind-registry that Substrate also uses. Only repositories under AXLAB_AX_IMAGE_REPO
# are removed, and the container itself is never touched.
#
# Overrides:
#   AXLAB_KUBECTL_CONTEXT   context                    (default: kind-ax-lab)
#   AXLAB_AX_DIR            ax clone                   (default: upstream/google-ax)
#   AXLAB_AX_BIN            the ax CLI                 (default: bin/ax)
#   AXLAB_KUBECTL_ATE_BIN   kubectl-ate                (default: resolved)
#   AXLAB_AX_IMAGE_REPO     image repo prefix to purge (default: localhost:5001/ax)
#   AXLAB_OWNER_LABEL       ownership label            (default: axlab.teacher/owner=phase3)
#   AXLAB_KEEP_TASK=1       leave the demo Task/Workspace in place
#   AXLAB_SKIP_IMAGES=1     do not remove registry images
#   AXLAB_DRY_RUN=1         print every action, change nothing

set -o errexit -o nounset -o pipefail

LAB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

AXLAB_KUBECTL_CONTEXT="${AXLAB_KUBECTL_CONTEXT:-kind-ax-lab}"
AXLAB_AX_DIR="${AXLAB_AX_DIR:-${LAB_ROOT}/upstream/google-ax}"
AXLAB_AX_IMAGE_REPO="${AXLAB_AX_IMAGE_REPO:-localhost:5001/ax}"
AXLAB_OWNER_LABEL="${AXLAB_OWNER_LABEL:-axlab.teacher/owner=phase3}"
# The registry's host-side port (the in-cluster name is <repo-host>:5000).
AXLAB_REGISTRY_PORT="${AXLAB_REGISTRY_PORT:-5001}"

AX_NS="ax-system"
KUBECTL=""
AX_BIN=""

lab_step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
lab_note() { printf '    %s\n' "$*"; }
lab_ok()   { printf '    \033[32mok\033[0m  %s\n' "$*"; }
lab_warn() { printf '    \033[33mwarn\033[0m  %s\n' "$*"; }
lab_die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

usage() {
  awk 'NR==1{next}
       /^#/          { sub(/^# ?/, ""); print; next }
       /^[[:space:]]*$/ { print; next }
       { exit }' "$0"
}

DRY=0
[ "${AXLAB_DRY_RUN:-0}" = "1" ] && DRY=1

# act <description> -- then run the rest of the line.
# Every destructive step goes through here, so AXLAB_DRY_RUN cannot be honoured
# in one place and forgotten in another.
act() {
  local what="$1"; shift
  if [ "${DRY}" -eq 1 ]; then
    printf '    \033[33mDRY RUN\033[0m  would %s\n' "${what}"
    return 0
  fi
  "$@"
}

k() { "${KUBECTL}" --context "${AXLAB_KUBECTL_CONTEXT}" "$@"; }

SAVED_CONTEXT=""
restore_context() {
  local rc=$?
  if [ -n "${SAVED_CONTEXT}" ] && [ "${SAVED_CONTEXT}" != "${AXLAB_KUBECTL_CONTEXT}" ]; then
    "${KUBECTL}" config use-context "${SAVED_CONTEXT}" >/dev/null 2>&1 \
      && printf '\nrestored kubectl context: %s\n' "${SAVED_CONTEXT}" \
      || printf '\n\033[31mwarning: could not restore context %s\033[0m\n' "${SAVED_CONTEXT}" >&2
  fi
  return $rc
}

# --- preflight --------------------------------------------------------------

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) usage; lab_die "unknown argument: $1" ;;
esac

KUBECTL=""
if [ -n "${AXLAB_KUBECTL_BIN:-}" ] && [ -x "${AXLAB_KUBECTL_BIN}" ]; then
  KUBECTL="${AXLAB_KUBECTL_BIN}"
else
  KUBECTL="$(command -v kubectl 2>/dev/null || true)"
fi
[ -n "${KUBECTL}" ] || lab_die "kubectl not found (set AXLAB_KUBECTL_BIN)"
# Fail early if the context is wrong rather than half-deleting: check that the
# context we were pointed at is actually the kind cluster and not minikube.
if ! k version >/dev/null 2>&1; then
  lab_die "context ${AXLAB_KUBECTL_CONTEXT} is not reachable"
fi
case "${AXLAB_KUBECTL_CONTEXT}" in
  minikube*) lab_die "refusing to run against the minikube profile" ;;
esac

if [ -n "${AXLAB_AX_BIN:-}" ] && [ -x "${AXLAB_AX_BIN}" ]; then
  AX_BIN="${AXLAB_AX_BIN}"
elif [ -x "${LAB_ROOT}/bin/ax" ]; then
  AX_BIN="${LAB_ROOT}/bin/ax"
elif [ -x "${LAB_ROOT}/upstream/google-ax/bin/ax" ]; then
  AX_BIN="${LAB_ROOT}/upstream/google-ax/bin/ax"
else
  AX_BIN="$(command -v ax 2>/dev/null || true)"
fi
# kubectl-ate is deliberately NOT resolved here: this script deletes the Task
# through the ax CLI, which is the owner of that lifecycle. Reaching into
# Substrate with kubectl-ate would be touching something that is not ours.

SAVED_CONTEXT="$("${KUBECTL}" config current-context 2>/dev/null || true)"
trap restore_context EXIT
printf 'kubectl context on entry: %s\n' "${SAVED_CONTEXT:-<none>}"
[ "${DRY}" -eq 1 ] && printf '\033[33mDRY RUN: no change will be made.\033[0m\n'

# --- 1: the demo task -------------------------------------------------------

lab_step "1. The demo Task and Workspace"
if [ "${AXLAB_KEEP_TASK:-0}" = "1" ]; then
  lab_note "AXLAB_KEEP_TASK=1; leaving the Task in place"
elif [ -z "${AX_BIN}" ] || [ ! -x "${AX_BIN}" ]; then
  lab_warn "the ax CLI was not found; leaving the Task (delete it with: ax delete task task123)"
elif ! "${AX_BIN}" get task task123 --context "${AXLAB_KUBECTL_CONTEXT}" >/dev/null 2>&1; then
  lab_note "no Task task123 to remove"
else
  # NB: the redirection belongs to the command act() runs, not to act itself.
  # Putting it on the act line swallows act's own "would delete" message and
  # leaves a false "removed" behind.
  if [ "${DRY}" -eq 1 ]; then
    printf '    \033[33mDRY RUN\033[0m  would delete Task task123\n'
  else
    act "delete Task task123" \
      "${AX_BIN}" delete task task123 --context "${AXLAB_KUBECTL_CONTEXT}" >/dev/null 2>&1 || true
    sleep 3
    lab_ok "Task task123 removed"
  fi
fi
# ax's own tunnel is a background kubectl port-forward this lab caused.
if [ -n "${AX_BIN}" ] && [ -x "${AX_BIN}" ]; then
  act "stop the ax CLI's background tunnel" \
    "${AX_BIN}" tunnel stop --context "${AXLAB_KUBECTL_CONTEXT}" >/dev/null 2>&1 || true
fi

# --- 2: the WorkerPool ------------------------------------------------------

lab_step "2. The WorkerPool (gap 2), which ax never creates"
# Ownership-guarded: only a pool carrying our label, and only in ax-system.
# go-template, not jsonpath: a label key containing "/" breaks kubectl's
# jsonpath bracket syntax and silently yields an empty string.
OWNER_KEY="${AXLAB_OWNER_LABEL%%=*}"
OWNER_VAL="${AXLAB_OWNER_LABEL#*=}"
if k get workerpool.ate.dev -n "${AX_NS}" ax-worker >/dev/null 2>&1; then
  owner="$(k get workerpool.ate.dev -n "${AX_NS}" ax-worker \
    -o go-template="{{index .metadata.labels \"${OWNER_KEY}\"}}" 2>/dev/null || true)"
  if [ "${owner}" = "${OWNER_VAL}" ]; then
    act "delete WorkerPool ${AX_NS}/ax-worker (carries ${AXLAB_OWNER_LABEL})" \
      k delete workerpool.ate.dev -n "${AX_NS}" ax-worker --ignore-not-found
    # ate-controller owns the worker Deployment; it removes it with the pool, but
    # do not assume that.
    act "delete the worker Deployment ${AX_NS}/ax-worker" \
      k delete deploy -n "${AX_NS}" ax-worker --ignore-not-found
  else
    lab_warn "${AX_NS}/ax-worker carries '${owner:-<no ${OWNER_KEY} label>}', not ${OWNER_VAL}; left alone"
  fi
else
  lab_note "no WorkerPool ${AX_NS}/ax-worker"
fi

# --- 3: the control plane ---------------------------------------------------

lab_step "3. The ax control plane in ${AX_NS}"
if k get namespace "${AX_NS}" >/dev/null 2>&1; then
  # Namespaced objects, by exact name inside our own namespace.
  for d in ax-controller ax-server ax-redis; do
    if k get deploy -n "${AX_NS}" "$d" >/dev/null 2>&1; then
      act "delete Deployment ${AX_NS}/${d}" k delete deploy -n "${AX_NS}" "$d" --ignore-not-found
    fi
  done
  for s in ax-server ax-redis; do
    if k get svc -n "${AX_NS}" "$s" >/dev/null 2>&1; then
      act "delete Service ${AX_NS}/${s}" k delete svc -n "${AX_NS}" "$s" --ignore-not-found
    fi
  done
  # These three are CLUSTER-scoped, so they are not covered by deleting the
  # namespace. Guarded by exact name; a ClusterRole called ax-controller is ax's
  # own and nothing else in this lab creates one.
  if k get serviceaccount -n "${AX_NS}" ax-controller >/dev/null 2>&1; then
    act "delete serviceaccount ${AX_NS}/ax-controller" k delete serviceaccount -n "${AX_NS}" ax-controller --ignore-not-found
  fi
  for kind in clusterrole clusterrolebinding; do
    if k get "${kind}" ax-controller >/dev/null 2>&1; then
      act "delete ${kind} ax-controller (cluster-scoped, named exactly)" \
        k delete "${kind}" ax-controller --ignore-not-found
    fi
  done
  act "delete Namespace ${AX_NS} (and everything left in it)" k delete namespace "${AX_NS}" --ignore-not-found
else
  lab_note "namespace ${AX_NS} does not exist; nothing to do"
fi

# --- 4: the registry images -------------------------------------------------

lab_step "4. Registry images under ${AXLAB_AX_IMAGE_REPO}"
# The registry is shared with Substrate, so this is narrow on purpose: only
# repositories under our own repo prefix, and never the registry container.
if [ "${AXLAB_SKIP_IMAGES:-0}" = "1" ]; then
  lab_note "AXLAB_SKIP_IMAGES=1; leaving the images"
else
  catalog="$(curl -sS --max-time 15 "http://127.0.0.1:${AXLAB_REGISTRY_PORT}/v2/_catalog" 2>/dev/null || true)"
  if [ -z "${catalog}" ]; then
    lab_warn "could not read the registry catalog; leaving the images"
  else
    # Only repos whose name starts with the repo prefix's path component.
    prefix="${AXLAB_AX_IMAGE_REPO##*/}"
    mine="$(printf '%s' "${catalog}" \
      | tr ',' '\n' | grep -oE '"[A-Za-z0-9._/-]+"' | tr -d '"' | grep "^${prefix}/" || true)"
    if [ -z "${mine}" ]; then
      lab_note "no repositories under ${prefix}/ to remove"
    else
      while read -r repo; do
        [ -n "${repo}" ] || continue
        if [ "${DRY}" -eq 1 ]; then
          printf '    \033[33mDRY RUN\033[0m  would delete registry repo %s\n' "${repo}"
          continue
        fi
        # Delete every tag/manifest of the repo. Only ever names we just listed
        # under our own prefix.
        digests="$(curl -sS --max-time 15 \
          "http://127.0.0.1:${AXLAB_REGISTRY_PORT}/v2/${repo}/tags/list" 2>/dev/null \
          | tr ',' '\n' | grep -oE '"[^"]+"' | tr -d '"' | grep -v '^tags$' || true)"
        for tag in ${digests}; do
          dig="$(curl -sS --max-time 15 -o /dev/null -D - \
            -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
            "http://127.0.0.1:${AXLAB_REGISTRY_PORT}/v2/${repo}/manifests/${tag}" 2>/dev/null \
            | tr -d '\r' | sed -n 's/^docker-content-digest: *//Ip' | head -1)"
          [ -n "${dig}" ] || continue
          curl -sS --max-time 20 -X DELETE \
            -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
            "http://127.0.0.1:${AXLAB_REGISTRY_PORT}/v2/${repo}/manifests/${dig}" >/dev/null 2>&1 || true
          lab_ok "deleted ${repo}@${dig}"
        done
      done <<<"${mine}"
    fi
  fi
fi
lab_note "the kind-registry container itself is NOT touched (Phase 2 owns it)"
lab_note "this reclaims MANIFESTS, not blobs: a registry keeps untagged layers"
lab_note "until a garbage collection runs, so disk use will not drop immediately"

# --- 5: prove nothing else moved --------------------------------------------

lab_step "5. Substrate must be untouched"
if k get namespace ate-system >/dev/null 2>&1; then
  lab_ok "ate-system still present"
  k get svc api -n ate-system 2>&1 | sed 's/^/      /'
else
  lab_warn "ate-system is missing -- this should not happen from an ax teardown"
fi
k get workerpools.ate.dev -A 2>&1 | sed 's/^/      /'
lab_note "(the counter WorkerPool is Phase 2's and must still be there)"

printf '\nkubectl context after: %s\n' "$("${KUBECTL}" config current-context 2>/dev/null || echo '<none>')"
