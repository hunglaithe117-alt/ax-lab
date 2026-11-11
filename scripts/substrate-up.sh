#!/usr/bin/env bash
# Bring up Agent Substrate on a dedicated kind cluster for the ax lab.
#
# This is Phase 2 of the lab. Phase 1 (scripts/setup.sh, scripts/verify-all.sh)
# is cluster-free; this script is the first thing in the lab that creates one.
#
# It does NOT implement anything itself: every step is upstream's own supported
# path, run from the pinned clone in upstream/substrate:
#
#   hack/create-kind-cluster.sh     kind cluster + local registry on 5001
#                                   + per-node certs.d + proxy_arp
#   hack/install-ate-kind.sh        control plane + CRDs + the counter demo
#   go install ./cmd/kubectl-ate    the `kubectl ate` plugin
#
# Nothing in either clone is written to; the scripts only read them.
#
# ---------------------------------------------------------------------------
# This cluster is deliberately NOT the user's minikube profile. kind switches
# the ambient kubectl context as a side effect of `kind create cluster`, so this
# script saves current-context on entry and restores it on exit, including on
# failure. It also always passes --context explicitly downstream rather than
# trusting the ambient context. Do not remove the restore; the lab shares a
# machine with a real minikube cluster.
# ---------------------------------------------------------------------------
#
# Idempotent: re-running against a healthy cluster re-applies the cluster
# prerequisites and reprints the health summary without rebuilding anything.
# Pass --force-install to redo the Substrate install (pushes images again, waits
# for rollouts again; a few minutes with a warm ko cache).
#
# ---------------------------------------------------------------------------
# SIDE EFFECT OUTSIDE THE CLUSTER: this script raises two HOST-GLOBAL kernel
# sysctls, fs.inotify.max_user_instances and fs.inotify.max_user_watches.
#
# It does this by writing them from inside the kind node container, but that is
# NOT containment: /proc/sys/fs/inotify/* is not namespaced and the kind node
# runs in the host user namespace, so the write lands on the host and applies to
# every process on the machine. The values are runtime state, so a reboot clears
# them, but scripts/substrate-down.sh does not -- the lab cluster going away does
# not put them back.
#
# It has to happen: atenet-router's Envoy creates an inotify instance for the
# podcert SDS secrets, and on a host with a small max_user_instances that fails
# and crash-loops the data plane, so no actor is reachable at all. See
# docs/06-substrate-on-kind.md. Upstream's hack/create-kind-cluster.sh does not
# do this, which is why a plain upstream bring-up hits it.
#
# This script prints the host's before/after values when it writes them. To
# restore:  AXLAB_RESTORE_INOTIFY=1 scripts/substrate-down.sh
#
# Other things it touches outside the kind cluster, all of them small and all
# of them disclosed rather than assumed:
#
#   * $(go env GOBIN||GOPATH)/bin  -- `go install ./cmd/kubectl-ate` writes the
#     kubectl-ate binary there (honouring AXLAB_KUBECTL_ATE_BIN via GOBIN).
#   * $KOCACHE, default ~/.cache/ko  -- ko's image cache. It grows into the
#     hundreds of MB on a first run and is the thing that makes re-runs fast.
#   * three kubeconfig entries  -- upstream's hack/create-kind-cluster.sh adds
#     a context, a cluster and a user for kind-<name>.
#     scripts/substrate-down.sh removes only the *context*, so the cluster and
#     user entries are left behind as dangling records.
#   * the shared "kind" docker network  -- `docker network connect kind
#     kind-registry` attaches the registry, which does make it reachable from
#     the node containers of any *other* kind cluster on this machine.
#     The reassuring half: upstream binds it to loopback only
#     (create-kind-cluster.sh:64-65, 127.0.0.1:5001 and [::1]:5001), so it is
#     not exposed off-host.
# ---------------------------------------------------------------------------
#
# Overrides (all optional):
#   AXLAB_KIND_CLUSTER_NAME   kind cluster name           (default: ax-lab)
#   AXLAB_KUBECTL_CONTEXT     kubectl context to use      (default: kind-<cluster>)
#   AXLAB_KIND_REGISTRY_PORT  local registry host port    (default: 5001)
#   AXLAB_KO_CACHE            ko's image cache            (default: ~/.cache/ko)
#   AXLAB_INOTIFY_INSTANCES   host fs.inotify.max_user_instances (default: 8192)
#   AXLAB_INOTIFY_WATCHES     host fs.inotify.max_user_watches   (default: 524288)
#   AXLAB_SUBSTRATE_DIR       pinned substrate clone      (default: upstream/substrate)
#   AXLAB_KUBECTL_ATE_BIN     where kubectl-ate is written (default: $(go env GOBIN|GOPATH)/bin)

set -o errexit -o nounset -o pipefail

LAB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SUBSTRATE="${AXLAB_SUBSTRATE_DIR:-${LAB_ROOT}/upstream/substrate}"

# Upstream's own default for the registry. The lab brief forbids 80/6379/8080;
# 5001 is upstream's expectation (hack/install-ate-kind.sh:28 hardcodes it into
# KO_DOCKER_REPO) so changing it means re-pinning that too.
AXLAB_KIND_CLUSTER_NAME="${AXLAB_KIND_CLUSTER_NAME:-ax-lab}"
AXLAB_KUBECTL_CONTEXT="${AXLAB_KUBECTL_CONTEXT:-kind-${AXLAB_KIND_CLUSTER_NAME}}"
AXLAB_KIND_REGISTRY_PORT="${AXLAB_KIND_REGISTRY_PORT:-5001}"
# Host port substrate-verify.sh port-forwards svc/atenet-router onto.
AXLAB_ROUTER_LOCAL_PORT="${AXLAB_ROUTER_LOCAL_PORT:-8000}"
AXLAB_KO_CACHE="${AXLAB_KO_CACHE:-${HOME}/.cache/ko}"

# inotify instance/watch headroom for the kind node. See ensure_cluster_prereqs
# for why the host default is not enough for atenet-router's Envoy.
AXLAB_INOTIFY_INSTANCES="${AXLAB_INOTIFY_INSTANCES:-8192}"
AXLAB_INOTIFY_WATCHES="${AXLAB_INOTIFY_WATCHES:-524288}"

# kind nodes install the substrate's own images from here.
REGISTRY_CONTAINER="kind-registry"
FORBIDDEN_PORTS=(80 6379 8080)

# --- output -----------------------------------------------------------------

lab_step()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
lab_note()  { printf '    %s\n' "$*"; }
lab_ok()    { printf '    \033[32mok\033[0m  %s\n' "$*"; }
lab_warn()  { printf '    \033[33mwarn\033[0m  %s\n' "$*"; }
lab_die()   { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

k() { kubectl --context "${AXLAB_KUBECTL_CONTEXT}" "$@"; }

usage() {
  # Print the leading comment block: skip the shebang, strip "# " from each
  # comment line, keep blank lines, and stop at the first line of actual code.
  # Not a fixed line range, so editing the header cannot truncate --help; and
  # blank lines inside the header do not end it either.
  awk 'NR==1{next}
       /^#/          { sub(/^# ?/, ""); print; next }
       /^[[:space:]]*$/ { print; next }
       { exit }' "$0"
}

# --- context preservation ---------------------------------------------------
#
# The one hard safety rule of this phase: whatever context the user was on when
# they ran this must be the context they are on when it returns.

SAVED_CONTEXT=""
restore_context() {
  local rc=$?
  if [ -n "${SAVED_CONTEXT}" ] && [ "${SAVED_CONTEXT}" != "${AXLAB_KUBECTL_CONTEXT}" ]; then
    if kubectl config use-context "${SAVED_CONTEXT}" >/dev/null 2>&1; then
      printf '\nrestored kubectl context: %s\n' "${SAVED_CONTEXT}"
    else
      # shellcheck disable=SC2016  # the backticks are deliberate: this prints
      # the literal command the user should type, so they must NOT expand.
      printf '\n\033[31mwarning: could not restore kubectl context %s; run `kubectl config use-context %s`\033[0m\n' \
        "${SAVED_CONTEXT}" "${SAVED_CONTEXT}" >&2
    fi
  fi
  return $rc
}

# --- preflight --------------------------------------------------------------

preflight() {
  lab_step "Preflight"

  # R1: upstream/substrate is gitignored and scripts/setup.sh clones only
  # google-ax, so on a fresh checkout there is no substrate tree at all. Print
  # the exact commands rather than just naming the problem.
  if [ ! -d "${SUBSTRATE}" ]; then
    cat >&2 <<EOF

error: no substrate clone at ${SUBSTRATE}

  upstream/substrate/ is gitignored, and scripts/setup.sh clones only
  google-ax -- so a fresh checkout does not have one. Create the pinned clone:

    git clone https://github.com/agent-substrate/substrate.git ${SUBSTRATE}
    git -C ${SUBSTRATE} checkout 672533541dbfcd29084e4de2475267088bda3651

  That commit is what ax depends on (upstream/google-ax/go.mod pins
  github.com/agent-substrate/substrate v0.0.0-20260911232748-672533541dbf), and
  neither repo documents compatibility across that boundary -- so do not use
  main. Leave the clone pristine; nothing here writes to it.

  Or point somewhere else with AXLAB_SUBSTRATE_DIR=/path/to/substrate
EOF
    exit 1
  fi
  [ -f "${SUBSTRATE}/hack/install-ate-kind.sh" ] \
    || lab_die "${SUBSTRATE} does not look like the substrate repo (no hack/install-ate-kind.sh)"

  for b in docker kubectl go; do
    command -v "$b" >/dev/null 2>&1 || lab_die "required tool not on PATH: $b"
  done
  docker info >/dev/null 2>&1 || lab_die "cannot talk to the docker daemon"
  go version >/dev/null 2>&1 || lab_die "cannot run go"

  # Confirm we are pointed at the pinned commit, not main. ax/go.mod pins
  # github.com/agent-substrate/substrate v0.0.0-20260911232748-672533541dbf and
  # the two repos make no compatibility promise across that boundary.
  local head pinned
  head="$(git -C "${SUBSTRATE}" rev-parse --short=8 HEAD)"
  pinned="$(git -C "${SUBSTRATE}" rev-parse --short=8 67253354)"
  if [ "${head}" != "${pinned}" ]; then
    lab_warn "substrate HEAD is ${head}, not the pinned ${pinned}"
    lab_warn "ax/go.mod expects 672533541dbf; continuing anyway"
  else
    lab_ok "substrate pinned at ${head}"
  fi

  if [ -n "$(git -C "${SUBSTRATE}" status --porcelain)" ]; then
    lab_warn "substrate clone has uncommitted changes; phase 2 requires it pristine"
  else
    lab_ok "substrate clone clean"
  fi

  # Port hygiene. The rule is that this lab never *binds* 80/6379/8080, not
  # that it refuses to run when something else already does -- on this host
  # port 8080 is held by the user's own dozzle container, which is none of our
  # business. So: fail only if one of OUR ports is a forbidden one, and merely
  # report a forbidden port that some other process already owns.
  local p
  for p in "${FORBIDDEN_PORTS[@]}"; do
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$p\$"; then
      lab_warn "host port ${p} is in use by another process (not this lab); leaving it alone"
    fi
  done

  # The ports we do choose must not be forbidden ones.
  local ours
  for ours in "${AXLAB_KIND_REGISTRY_PORT}" "${AXLAB_ROUTER_LOCAL_PORT}"; do
    for p in "${FORBIDDEN_PORTS[@]}"; do
      [ "${ours}" = "${p}" ] && lab_die "this lab must not bind ${p} (set the *_PORT override to something else)"
    done
  done
  lab_ok "lab binds only ${AXLAB_KIND_REGISTRY_PORT} (registry) and ${AXLAB_ROUTER_LOCAL_PORT} (verify port-forward)"

  # The registry port may legitimately be held by our own registry from a
  # previous run; anything else means we would be stealing it.
  if [ "$(docker inspect -f '{{.State.Running}}' "${REGISTRY_CONTAINER}" 2>/dev/null || true)" != "true" ]; then
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${AXLAB_KIND_REGISTRY_PORT}\$"; then
      lab_die "host port ${AXLAB_KIND_REGISTRY_PORT} is held by something other than ${REGISTRY_CONTAINER}; refusing to touch it"
    fi
    lab_ok "registry port ${AXLAB_KIND_REGISTRY_PORT} free"
  else
    lab_ok "registry ${REGISTRY_CONTAINER} already running"
  fi

  mkdir -p "${AXLAB_KO_CACHE}"
  # Upstream invokes ko through hack/run-tool.sh (hack/install-ate.sh:209), i.e.
  # the ko pinned in hack/tools/ko, not whatever is on PATH. KOCACHE is read by
  # ko itself, so exporting it is what actually warms the cache.
  export KOCACHE="${AXLAB_KO_CACHE}"
  export KIND_CLUSTER_NAME="${AXLAB_KIND_CLUSTER_NAME}"
  export KIND_REGISTRY_PORT="${AXLAB_KIND_REGISTRY_PORT}"
  lab_ok "KOCACHE=${KOCACHE}"
}

# --- cluster ----------------------------------------------------------------

cluster_exists() {
  docker ps -a --format '{{.Names}}' | grep -qx "${AXLAB_KIND_CLUSTER_NAME}-control-plane"
}

# ensure_cluster_prereqs re-applies steps 3-5 of hack/create-kind-cluster.sh.
# create-kind-cluster.sh *deletes and recreates* the cluster, so on a re-run we
# cannot call it; these three steps are the parts that can go stale (a node
# rebuilt, the registry container restarted, the network re-created).
ensure_cluster_prereqs() {
  local regdir="/etc/containerd/certs.d/localhost:${AXLAB_KIND_REGISTRY_PORT}"

  lab_step "Cluster prerequisites on ${AXLAB_KUBECTL_CONTEXT}"

  # --- inotify limits: the one thing upstream's kind script does not do ------
  #
  # !!! THIS MUTATES THE HOST KERNEL, NOT JUST THE LAB. !!!
  #
  # atenet-router's Envoy watches the podcertcontroller-issued credential
  # bundles as *files* over SDS. Creating that inotify instance is an
  # `inotify_init()`, and the inotify limits are HOST-GLOBAL and NOT
  # namespaced -- /proc/sys/fs/inotify/* is not per-container, and a kind node
  # container runs in the host user namespace (UsernsMode=""), so a write from
  # inside the node lands on the host. Verified directly: writing 9000 from
  # inside the node, the host immediately read 9000.
  #
  # Consequences you are agreeing to by running this script:
  #   * every process on the host -- minikube, dozzle, your desktop, anything
  #     else -- gets the larger limit, not just the lab;
  #   * the value is runtime state, so it does NOT survive a reboot, but it
  #     also does NOT go away when you run scripts/substrate-down.sh;
  #   * to put it back, see AXLAB_RESTORE_INOTIFY in scripts/substrate-down.sh.
  #
  # Why it is needed: this host shipped fs.inotify.max_user_instances=128, which
  # is too small once the root-run containers on it are counted, so Envoy's
  # watcher init fails and it dies on:
  #
  #   [critical][assert] [source/common/filesystem/inotify/watcher_impl.cc:25]
  #   assert failure: inotify_fd_ >= 0
  #
  # `inotify_fd_` is the fd returned by inotify_init(), so the failing call is
  # the *init* -- the instance quota -- not add_watch, which fails with ENOSPC
  # when the *watch* quota is hit. That is why raising max_user_watches alone
  # would not have helped, and why raising both is the right move anyway.
  #
  # The crash handler then dumps state and re-crashes, which masks the assert
  # (see docs/06). The data plane never comes up, so no actor is reachable.
  # Runtime-only, so it must be re-applied on every up -- hence here.
  #
  # Node list: from hack/kind.sh, exactly as upstream does at
  # create-kind-cluster.sh:177. `docker ps | grep "^${NAME}-"` would also match a
  # foreign container that merely shares the name prefix.
  local node inst_before watch_before inst_after watch_after
  for node in $(cd "${SUBSTRATE}" && ./hack/kind.sh get nodes --name "${AXLAB_KIND_CLUSTER_NAME}" 2>/dev/null); do
    # Read the HOST's value before/after so the host-wide effect is visible
    # rather than implied. (The node shares the host's /proc/sys for these
    # knobs, so reading the host is reading the same value the write changed.)
    inst_before="$(cat /proc/sys/fs/inotify/max_user_instances)"
    watch_before="$(cat /proc/sys/fs/inotify/max_user_watches)"

    docker exec "${node}" sysctl -q -w fs.inotify.max_user_instances="${AXLAB_INOTIFY_INSTANCES}" >/dev/null
    docker exec "${node}" sysctl -q -w fs.inotify.max_user_watches="${AXLAB_INOTIFY_WATCHES}" >/dev/null

    inst_after="$(cat /proc/sys/fs/inotify/max_user_instances)"
    watch_after="$(cat /proc/sys/fs/inotify/max_user_watches)"

    printf '    \033[33mHOST KERNEL\033[0m  fs.inotify.max_user_instances %s -> %s\n' \
      "${inst_before}" "${inst_after}"
    printf '    \033[33mHOST KERNEL\033[0m  fs.inotify.max_user_watches   %s -> %s\n' \
      "${watch_before}" "${watch_after}"
    lab_ok "node ${node}: inotify raised (host-wide; restore with AXLAB_RESTORE_INOTIFY=1 scripts/substrate-down.sh)"

    # gVisor loopback pod-to-pod networking needs proxy_arp on the node.
    docker exec "${node}" sysctl -q net.ipv4.conf.all.proxy_arp=1 >/dev/null
    docker exec "${node}" sysctl -q -e net.ipv6.conf.all.proxy_ndp=1 >/dev/null 2>&1 || true
    # Teach containerd that localhost:<port> is a plain-HTTP registry.
    docker exec "${node}" mkdir -p "${regdir}"
    printf '[host."http://%s:5000"]\n' "${REGISTRY_CONTAINER}" \
      | docker exec -i "${node}" tee "${regdir}/hosts.toml" >/dev/null
    lab_ok "node ${node}: proxy_arp + certs.d"
  done

  if [ "$(docker inspect -f='{{json .NetworkSettings.Networks.kind}}' "${REGISTRY_CONTAINER}" 2>/dev/null)" = "null" ]; then
    docker network connect kind "${REGISTRY_CONTAINER}"
    lab_ok "registry attached to the kind network"
  else
    lab_ok "registry already on the kind network"
  fi

  kubectl --context "${AXLAB_KUBECTL_CONTEXT}" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "localhost:${AXLAB_KIND_REGISTRY_PORT}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
  lab_ok "kube-public/local-registry-hosting documents localhost:${AXLAB_KIND_REGISTRY_PORT}"
}

ensure_cluster() {
  if cluster_exists; then
    lab_step "kind cluster '${AXLAB_KIND_CLUSTER_NAME}' already exists; not recreating it"
  else
    lab_step "Creating kind cluster '${AXLAB_KIND_CLUSTER_NAME}' (upstream hack/create-kind-cluster.sh)"
    # KIND_CLUSTER_NAME/KIND_REGISTRY_PORT are what upstream reads; it also
    # switches the ambient context, which the EXIT trap undoes.
    ( cd "${SUBSTRATE}" && ./hack/create-kind-cluster.sh )
    kubectl --context "${AXLAB_KUBECTL_CONTEXT}" wait --for=condition=Ready node --all --timeout=180s >/dev/null
    lab_ok "node Ready"
  fi

  # Both paths need this: the inotify limits are host-global and are NOT part of
  # the cluster, so they have to be (re)applied after the node exists but before
  # the install starts atenet-router.
  ensure_cluster_prereqs
}

# --- install ----------------------------------------------------------------

ate_system_healthy() {
  k get svc api -n ate-system >/dev/null 2>&1 \
    && k get deploy -n ate-system ate-api-server >/dev/null 2>&1 \
    && k rollout status -n ate-system deploy/ate-api-server --timeout=5s >/dev/null 2>&1
}

ensure_install() {
  local force=0
  [ "${1:-}" = "--force-install" ] && force=1

  if [ "${force}" -eq 0 ] && ate_system_healthy; then
    lab_step "Substrate already installed and healthy; skipping install"
    lab_note "pass --force-install to rebuild and reapply"
    return 0
  fi

  lab_step "Installing Substrate + demo-counter (upstream hack/install-ate-kind.sh)"
  lab_note "KO_DOCKER_REPO=localhost:${AXLAB_KIND_REGISTRY_PORT}, ATE_INSTALL_KIND=true, BUCKET_NAME=ate-snapshots"
  ( cd "${SUBSTRATE}" && ./hack/install-ate-kind.sh --deploy-ate-system --deploy-demo-counter )
}

ensure_kubectl_ate() {
  lab_step "Installing the kubectl-ate plugin"

  local bindir="${AXLAB_KUBECTL_ATE_BIN:-}"
  if [ -z "${bindir}" ]; then
    bindir="$(go env GOBIN)"
    [ -n "${bindir}" ] || bindir="$(go env GOPATH)/bin"
  fi

  # GOBIN is what makes `go install` honour AXLAB_KUBECTL_ATE_BIN. Without it,
  # go install ignores the override and writes to the default GOBIN/GOPATH/bin,
  # so the warning below could name a directory with no binary in it.
  ( cd "${SUBSTRATE}" && GOBIN="${bindir}" go install ./cmd/kubectl-ate )

  if [ -x "${bindir}/kubectl-ate" ]; then
    lab_ok "kubectl-ate installed at ${bindir}/kubectl-ate"
  else
    lab_warn "go install did not produce ${bindir}/kubectl-ate"
  fi
  # `kubectl ate` only resolves the plugin if its directory is on PATH; the
  # verify script does not need that (it calls the absolute path), but a human
  # typing `kubectl ate` does.
  case ":${PATH}:" in
    *":${bindir}:"*) lab_ok "kubectl ate available on PATH" ;;
    *)
      lab_warn "${bindir} is not on PATH, so bare 'kubectl ate' will not resolve"
      lab_note "add it with: export PATH=\"${bindir}:\$PATH\""
      ;;
  esac
}

# --- health summary ---------------------------------------------------------

health_summary() {
  lab_step "Health summary (${AXLAB_KUBECTL_CONTEXT})"

  lab_note "nodes:"
  k get nodes -o wide | sed 's/^/      /'

  lab_note "the ax gate (upstream/google-ax/README.md:72) -- svc/api in ate-system:"
  if k get svc api -n ate-system >/dev/null 2>&1; then
    k get svc api -n ate-system | sed 's/^/      /'
  else
    lab_warn "svc/api is missing; ax cannot talk to Substrate"
  fi

  lab_note "ate-system workloads:"
  k get pods -n ate-system -o wide | sed 's/^/      /'

  lab_note "atelet version stamped on its DaemonSet:"
  k get ds -n ate-system -l app=atelet \
    -L ate.dev/substrate-version 2>/dev/null | sed 's/^/      /' \
    || lab_warn "no DaemonSet labelled app=atelet"

  lab_note "ClusterTrustBundles (podcertcontroller publishes these):"
  k get clustertrustbundles 2>/dev/null | sed 's/^/      /' \
    || lab_warn "ClusterTrustBundle CRD missing -- the PodCertificateRequest feature gates are not on"

  lab_note "Substrate CRDs:"
  k get crd 2>/dev/null | grep -E 'NAME|ate.dev' | sed 's/^/      /' \
    || lab_warn "no ate.dev CRDs"

  lab_note "demo-counter WorkerPool:"
  k get workerpools -A 2>/dev/null | sed 's/^/      /' || true

  cat <<EOF

Next:
  scripts/substrate-verify.sh          the 7 evidence checks (needs this cluster)
  docs/06-substrate-on-kind.md         the lesson page

Cluster-scoped kubectl calls in this lab always pass
  --context ${AXLAB_KUBECTL_CONTEXT}
and never rely on the ambient context.
EOF
}

# --- main -------------------------------------------------------------------

main() {
  case "${1:-}" in
    -h|--help) usage; exit 0 ;;
    --force-install) ;;
    "") ;;
    *) usage; lab_die "unknown argument: $1" ;;
  esac

  # Snapshot the context BEFORE kind gets a chance to move it.
  SAVED_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
  trap restore_context EXIT
  printf 'kubectl context on entry: %s\n' "${SAVED_CONTEXT:-<none>}"

  preflight
  ensure_cluster
  ensure_install "$@"
  ensure_kubectl_ate
  health_summary
}

main "$@"
