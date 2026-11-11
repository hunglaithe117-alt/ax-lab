#!/usr/bin/env bash
# Phase 3: deploy ax's own control plane onto the Substrate cluster from Phase 2,
# and make a real Task schedulable.
#
# Upstream's `make deploy` cannot run as shipped. Three gaps, none documented by
# upstream, all solved here. They are the actual lesson; docs/07 explains them.
#
#   1. ax's default task image is private. examples/task.yaml pins
#      gcr.io/ax-substrate/ate-images/ax-task-runner@sha256:3a0dea6a..., which
#      returns 401/403. We build and push our own with the repo's own recipe
#      (`make build-task-runner`, Makefile:46-51).
#   2. ax never creates a Substrate WorkerPool. `grep -rni workerpool
#      --include='*.go'` over the ax Go sources returns nothing (scoping to
#      *.go matters: unscoped, it also matches a compiled binary under bin/,
#      which is not a source hit). So with no pool of your own there are no
#      worker pods and every task stays unschedulable forever. We author one.
#   3. The snapshot bucket is a private GCS path
#      (AX_SNAPSHOTS_BUCKET in deploy/ax-controller.yaml:82-83, and
#      internal/substrate/client.go:208 DefaultSnapshotsBucket). On the kind
#      path storage is in-cluster rustfs over S3, so every suspend/resume would
#      fail. We repoint it.
#
# ---------------------------------------------------------------------------
# SAFETY
#   * This machine also runs a real minikube cluster. Every kubectl call passes
#     --context explicitly; the ambient context is saved and restored on exit.
#   * `ko apply` does NOT inherit a kubectl context -- it uses the ambient one.
#     An earlier draft of this phase ran `ko apply` with the ambient context set
#     to minikube and it tried to apply into the user's cluster. It failed
#     (no ax-system namespace there) so nothing leaked, but this script avoids
#     the trap entirely by using `ko resolve | kubectl apply --context`, which
#     is also how the bucket repoint stays drift-free.
#   * It raises the host-global inotify sysctls only by delegating to
#     scripts/substrate-up.sh (Phase 2); it never writes them itself.
#   * It never touches Substrate's own components (ate-system, ate-demo-counter).
# ---------------------------------------------------------------------------
#
# Idempotent: re-running re-applies everything and reprints the health summary.
# The runner image build is cached by docker, so a re-run costs seconds.
#
# Overrides:
#   AXLAB_KUBECTL_CONTEXT   context to deploy into   (default: kind-ax-lab)
#   AXLAB_AX_DIR            ax clone                 (default: upstream/google-ax)
#   AXLAB_AX_IMAGE_REPO     image repo prefix        (default: localhost:5001/ax)
#   AXLAB_SNAPSHOTS_BUCKET  where ax puts snapshots  (default: s3://ate-snapshots/ate-env/)
#   AXLAB_WORKERPOOL_REPLICAS                        (default: 2)
#   AXLAB_WORKER_CPU / AXLAB_WORKER_MEMORY           (default: 2 / 4Gi)
#   AXLAB_SKIP_RUNNER=1    do not build/push the runner image (reuse what is there)
#   AXLAB_FORCE_RUNNER=1   rebuild the runner image even if it is present

set -o errexit -o nounset -o pipefail

LAB_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

AXLAB_KUBECTL_CONTEXT="${AXLAB_KUBECTL_CONTEXT:-kind-ax-lab}"
AXLAB_AX_DIR="${AXLAB_AX_DIR:-${LAB_ROOT}/upstream/google-ax}"
AXLAB_AX_IMAGE_REPO="${AXLAB_AX_IMAGE_REPO:-localhost:5001/ax}"
# Default only. If AXLAB_SNAPSHOTS_BUCKET is set in the environment we treat it
# as an explicit override and do NOT silently replace it with the live bucket;
# preflight then checks the two agree and warns loudly if they do not.
# (The test has to happen BEFORE the :- default, which always yields non-empty.)
AXLAB_SNAPSHOTS_BUCKET_OVERRIDDEN=""
if [ -n "${AXLAB_SNAPSHOTS_BUCKET:-}" ]; then
  AXLAB_SNAPSHOTS_BUCKET_OVERRIDDEN=1
fi
AXLAB_SNAPSHOTS_BUCKET="${AXLAB_SNAPSHOTS_BUCKET:-s3://ate-snapshots/ate-env/}"
AXLAB_WORKERPOOL_REPLICAS="${AXLAB_WORKERPOOL_REPLICAS:-2}"
AXLAB_WORKER_CPU="${AXLAB_WORKER_CPU:-2}"
AXLAB_WORKER_MEMORY="${AXLAB_WORKER_MEMORY:-4Gi}"
# The substrate version the node label must match. Overridden from the live
# node label in preflight so this does not have to be edited per commit.
AXLAB_SUBSTRATE_VERSION="${AXLAB_SUBSTRATE_VERSION:-}"

RUNNER_TAG="ax-task-runner"
RUNNER_IMAGE="${AXLAB_AX_IMAGE_REPO}/${RUNNER_TAG}:latest"
WORKDIR="${LAB_ROOT}/.work/p3"
TASK_YAML="${WORKDIR}/task.yaml"

lab_step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
lab_note() { printf '    %s\n' "$*"; }
lab_ok()   { printf '    \033[32mok\033[0m  %s\n' "$*"; }
lab_warn() { printf '    \033[33mwarn\033[0m  %s\n' "$*"; }
lab_die()  { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }

k() { kubectl --context "${AXLAB_KUBECTL_CONTEXT}" "$@"; }

usage() {
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

# --- preflight --------------------------------------------------------------

preflight() {
  lab_step "Preflight"
  mkdir -p "${WORKDIR}"

  [ -d "${AXLAB_AX_DIR}" ] || lab_die "no ax clone at ${AXLAB_AX_DIR} (set AXLAB_AX_DIR)
  Clone it with:  git clone https://github.com/google/ax.git ${AXLAB_AX_DIR}"
  [ -f "${AXLAB_AX_DIR}/deploy/ax-controller.yaml" ] \
    || lab_die "${AXLAB_AX_DIR} does not look like the ax repo (no deploy/ax-controller.yaml)"

  # Refuse the user's minikube profile outright. This script creates a namespace,
  # a WorkerPool and three Deployments; the context is overridable, so do not
  # rely on --context being passed correctly everywhere.
  case "${AXLAB_KUBECTL_CONTEXT}" in
    minikube*) lab_die "refusing to deploy against the minikube profile
  This would create ax-system, a WorkerPool and three Deployments in the user's
  cluster. Use the kind cluster instead:
    AXLAB_KUBECTL_CONTEXT=kind-ax-lab scripts/ax-up.sh" ;;
  esac

  k version >/dev/null 2>&1 || lab_die "context ${AXLAB_KUBECTL_CONTEXT} is not reachable.
  Phase 2 builds that cluster:  scripts/substrate-up.sh"
  lab_ok "context ${AXLAB_KUBECTL_CONTEXT}"

  # Phase 2 must be up: ax needs the Substrate Control API to exist.
  if ! k get svc api -n ate-system >/dev/null 2>&1; then
    lab_die "svc/api is not in ate-system; run scripts/substrate-up.sh first (Phase 2)"
  fi
  lab_ok "Substrate Control API present (svc/api in ate-system)"

  # The host inotify limit: at the pre-lab 128, atenet-router crash-loops on
  # restart. Warn loudly rather than silently writing host sysctls from here.
  local inst
  inst="$(cat /proc/sys/fs/inotify/max_user_instances)"
  if [ "${inst}" -lt 512 ]; then
    lab_warn "host fs.inotify.max_user_instances=${inst} (Phase 3 raises this to 8192)"
    lab_warn "at 128 atenet-router's Envoy crash-loops on restart and no actor is reachable."
    lab_warn "Fix with: scripts/substrate-up.sh   (host-global; AXLAB_RESTORE_INOTIFY=1 undoes it)"
  else
    lab_ok "host fs.inotify.max_user_instances=${inst}"
  fi

  # The node label the WorkerPool's nodeSelector must match.
  if [ -z "${AXLAB_SUBSTRATE_VERSION}" ]; then
    AXLAB_SUBSTRATE_VERSION="$(k get nodes -l ate.dev/substrate-version \
      -o jsonpath='{.items[0].metadata.labels.ate\.dev/substrate-version}' 2>/dev/null || true)"
  fi
  [ -n "${AXLAB_SUBSTRATE_VERSION}" ] \
    || lab_die "no node carries the ate.dev/substrate-version label; run scripts/substrate-up.sh"
  lab_ok "substrate version label: ${AXLAB_SUBSTRATE_VERSION}"

  # The ateom worker image the pool runs. Reuse whatever Substrate's own install
  # pushed rather than rebuilding it, so the pool matches the running substrate.
  AXLAB_ATEOM_IMAGE="$(k get workerpools.ate.dev -A -o jsonpath='{range .items[*]}{.spec.workerImage}{"\n"}{end}' 2>/dev/null | head -1)"
  [ -n "${AXLAB_ATEOM_IMAGE}" ] || lab_die "could not read a workerImage from any existing WorkerPool"
  lab_ok "ateom worker image: ${AXLAB_ATEOM_IMAGE}"

  # The bucket, read from the deployed rustfs init rather than assumed, so the
  # default follows the cluster instead of a hardcoded name.
  local bucket
  bucket="$(k get pods -n ate-system --no-headers 2>/dev/null \
    | awk '/bucket-init/ {print $1}' | while read -r p; do
        k get pod -n ate-system "$p" -o jsonpath='{.spec.containers[0].command}' 2>/dev/null
      done | grep -oE 'head-bucket --bucket [a-z0-9-]+' | head -1 | awk '{print $NF}')"
  if [ -z "${bucket}" ]; then
    lab_warn "could not read the bucket name from the rustfs init; keeping ${AXLAB_SNAPSHOTS_BUCKET}"
  elif [ -z "${AXLAB_SNAPSHOTS_BUCKET_OVERRIDDEN:-}" ]; then
    # No explicit override: derive it, so a cluster whose bucket is named
    # something else still gets a correct AX_SNAPSHOTS_BUCKET.
    AXLAB_SNAPSHOTS_BUCKET="s3://${bucket}/ate-env/"
    lab_ok "rustfs bucket read from the deployed init: ${bucket} -> ${AXLAB_SNAPSHOTS_BUCKET}"
  else
    lab_ok "rustfs bucket (from the deployed init): ${bucket}"
    case "${AXLAB_SNAPSHOTS_BUCKET}" in
      *"${bucket}"*) : ;;
      *)
        lab_warn "AXLAB_SNAPSHOTS_BUCKET=${AXLAB_SNAPSHOTS_BUCKET} does not name the live bucket ${bucket}"
        lab_warn "snapshots will not be found unless that bucket exists"
        ;;
    esac
  fi

  export KOCACHE="${AXLAB_KO_CACHE:-${HOME}/.cache/ko}"
  export PATH="${HOME}/go/bin:${PATH}"
  command -v ko >/dev/null 2>&1 || lab_die "ko not on PATH (expected ${HOME}/go/bin/ko)"
  command -v docker >/dev/null 2>&1 || lab_die "docker not on PATH"
  lab_ok "ko: $(command -v ko)"
}

# --- gap 1: the task-runner image -------------------------------------------

build_runner_image() {
  lab_step "Gap 1: build and push the ax-task-runner image"

  if [ "${AXLAB_SKIP_RUNNER:-0}" = "1" ]; then
    lab_note "AXLAB_SKIP_RUNNER=1; reusing the image already in the registry"
  elif [ "${AXLAB_FORCE_RUNNER:-0}" = "1" ] \
       || ! docker image inspect "${RUNNER_IMAGE}" >/dev/null 2>&1; then
    # Makefile:46-51 -- cross-compiles cmd/ax-task-runner for linux/amd64 and
    # builds Dockerfile.task-runner (python:3.12-slim + google-antigravity).
    # CONTAINER_CLI=docker because the Makefile probes for podman first.
    ( cd "${AXLAB_AX_DIR}" \
      && make build-task-runner "AX_IMAGE_REPO=${AXLAB_AX_IMAGE_REPO}" CONTAINER_CLI=docker )
    # Makefile:54-58 would also run `gcloud container images list-tags` to print
    # the digest. We push by hand and read the digest off the push output, so no
    # GCP credentials or gcloud are needed.
    docker push "${RUNNER_IMAGE}" >/dev/null
    lab_ok "pushed ${RUNNER_IMAGE}"
  else
    lab_note "image already built locally; pushing to be sure the registry has it"
    docker push "${RUNNER_IMAGE}" >/dev/null
    lab_ok "pushed ${RUNNER_IMAGE}"
  fi

  # Digest-pinned from here on: a tag is mutable and the golden snapshot bakes
  # whatever was pulled, so a re-run must resolve the same bytes. Read from
  # RepoDigests, which docker populates on push -- not from the push output.
  RUNNER_IMAGE_REF="$(docker inspect -f '{{index .RepoDigests 0}}' "${RUNNER_IMAGE}" 2>/dev/null || true)"
  if [ -z "${RUNNER_IMAGE_REF}" ]; then
    lab_die "could not resolve a digest for ${RUNNER_IMAGE}; is it pushed?"
  fi
  lab_ok "runner image: ${RUNNER_IMAGE_REF}"
}

# --- gap 2: the WorkerPool --------------------------------------------------

apply_workerpool() {
  lab_step "Gap 2: apply the WorkerPool ax never creates"

  # Modelled on upstream/substrate/demos/counter/counter.yaml.tmpl.
  #  * nodeSelector must match the label substrate's install stamps on the node,
  #    or the workers never schedule.
  #  * limits advertise the per-actor ceiling (scheduling.go: HasRoom reads
  #    limits only); the kube-scheduler packs by requests, so the CPU request is
  #    set well below the limit. Memory is not compressible, so its request
  #    matches its limit.
  k apply -f - <<EOF
apiVersion: ate.dev/v1alpha1
kind: WorkerPool
metadata:
  name: ax-worker
  namespace: ax-system
  labels:
    app.kubernetes.io/part-of: ax
    axlab.teacher/owner: phase3
spec:
  replicas: ${AXLAB_WORKERPOOL_REPLICAS}
  workerImage: ${AXLAB_ATEOM_IMAGE}
  template:
    nodeSelector:
      ate.dev/substrate-version: "${AXLAB_SUBSTRATE_VERSION}"
    resources:
      limits:
        cpu: "${AXLAB_WORKER_CPU}"
        memory: ${AXLAB_WORKER_MEMORY}
      requests:
        cpu: 500m
        memory: ${AXLAB_WORKER_MEMORY}
EOF

  if ! k wait --for=create "deployment/ax-worker" -n ax-system --timeout=120s >/dev/null 2>&1; then
    lab_die "ate-controller did not create deployment/ax-worker for the WorkerPool"
  fi
  k rollout status deployment/ax-worker -n ax-system --timeout=300s >/dev/null
  lab_ok "ax-worker: $(k get deploy -n ax-system ax-worker -o jsonpath='{.status.readyReplicas}') ready"
}

# --- deploy the control plane ----------------------------------------------

# deploy_ko <manifest> [sed-recipe]
#
# ko resolve + kubectl apply rather than `ko apply`, for two reasons: the
# explicit --context can never be lost, and the rendered YAML can be edited
# before it is applied (which is how gap 3 stays drift-free).
deploy_ko() {
  local manifest="$1"
  local out
  out="${WORKDIR}/$(basename "${manifest}" .yaml)-resolved.yaml"

  ( cd "${AXLAB_AX_DIR}" && KO_DOCKER_REPO="${AXLAB_AX_IMAGE_REPO}" ko resolve -f "deploy/${manifest}" ) \
    > "${out}" 2>/dev/null

  # Repoint the snapshot bucket. Only the ax controller carries it.
  if [ "${manifest}" = "ax-controller.yaml" ]; then
    # Rewrite the value line that *follows* the AX_SNAPSHOTS_BUCKET name, rather
    # than pattern-matching the private path itself. That is robust to whatever
    # upstream ships, and idempotent: a re-run rewrites the already-correct value
    # to the same thing. (An earlier version regex-matched the path and mangled
    # it, because the alternation backtracked into the trailing [^"]*.)
    local tmp
    tmp="${out}.tmp"
    awk -v b="${AXLAB_SNAPSHOTS_BUCKET}" '
      /^[[:space:]]*- name: AX_SNAPSHOTS_BUCKET[[:space:]]*$/ {
        print
        if (getline > 0) { sub(/value:.*/, "value: \"" b "\""); print }
        next
      }
      { print }
    ' "${out}" > "${tmp}"
    mv "${tmp}" "${out}"

    if ! grep -q "value: \"${AXLAB_SNAPSHOTS_BUCKET}\"" "${out}"; then
      lab_die "failed to repoint AX_SNAPSHOTS_BUCKET to ${AXLAB_SNAPSHOTS_BUCKET}"
    fi
    lab_ok "gap 3: AX_SNAPSHOTS_BUCKET -> ${AXLAB_SNAPSHOTS_BUCKET}"
  fi

  k apply -f "${out}" >/dev/null
  lab_ok "applied ${manifest}"
}

deploy_control_plane() {
  lab_step "Deploy the control plane"

  # make deploy = deploy-redis -> deploy-controller -> deploy-server (Makefile:68)
  k apply -f "${AXLAB_AX_DIR}/deploy/redis.yaml" >/dev/null
  lab_ok "applied redis.yaml"

  deploy_ko ax-controller.yaml
  deploy_ko ax-server.yaml

  k rollout status deployment/ax-redis      -n ax-system --timeout=180s >/dev/null
  k rollout status deployment/ax-controller -n ax-system --timeout=300s
  k rollout status deployment/ax-server     -n ax-system --timeout=300s
}

# --- the task manifest ------------------------------------------------------

write_task_manifest() {
  lab_step "Write the Task manifest"
  # examples/task.yaml with three edits, each for a reason:
  #   * our own image (gap 1);
  #   * the `mcp:` block dropped -- it points at
  #     http://git-mcp.default.svc.cluster.local:8080, which does not exist, and
  #     a failed workspace setup is only logged (runner.go:156-161), leaving
  #     WorkspaceReady false forever;
  #   * the `Model` dropped -- no Gemini key is needed or wanted here.
  # The `git:` block is kept: the runner image has git, and the clone is what
  # proves the workspace really was set up.
  cat > "${TASK_YAML}" <<EOF
apiVersion: ax.io/v1alpha1
kind: Task
metadata:
  name: task123
  atespace: default
spec:
  env:
    - name: ENVIRONMENT
      value: "test"
  image: "${RUNNER_IMAGE_REF}"
  # ax never reads these: nothing in the tree copies task.Spec.Resources onto
  # the ActorTemplate, so the sandbox is unsized. Kept to show that.
  resources:
    requests:
      cpu: "500m"
      memory: "1Gi"
    limits:
      cpu: "2"
      memory: "4Gi"
  workspaces:
    - name: default-workspace
      path: "/workspace"
  debug: true
---
apiVersion: ax.io/v1alpha1
kind: Workspace
metadata:
  name: default-workspace
  atespace: default
spec:
  git:
    - name: origin
      repo: "https://github.com/chalk/chalk.git"
      branch: "main"
EOF
  lab_ok "wrote ${TASK_YAML}"
  # The Workspace must already exist when the Task is first reconciled: ax bakes
  # AX_WORKSPACES_YAML into an *immutable* per-task ActorTemplate, and
  # EnsureActorTemplateWithImage returns an existing template unchanged
  # (internal/substrate/client.go:281-283). Applying both in one file can
  # reconcile the Task before the Workspace is readable, and then the template
  # is permanently wrong -- the task still reports WorkspaceReady=True with an
  # empty /workspace. So apply the Workspace first, then the Task.
  cat > "${WORKDIR}/workspace.yaml" <<EOF
apiVersion: ax.io/v1alpha1
kind: Workspace
metadata:
  name: default-workspace
  atespace: default
spec:
  git:
    - name: origin
      repo: "https://github.com/chalk/chalk.git"
      branch: "main"
EOF
  lab_ok "wrote ${WORKDIR}/workspace.yaml (applied first, on purpose)"
}

# --- health -----------------------------------------------------------------

health_summary() {
  lab_step "Health summary (${AXLAB_KUBECTL_CONTEXT})"

  lab_note "ax-system:"
  k get deploy,svc -n ax-system 2>&1 | sed 's/^/      /'

  lab_note "pods:"
  k get pods -n ax-system -o wide 2>&1 | sed 's/^/      /'

  lab_note "images actually running (proves the local registry + certs.d work):"
  k get pods -n ax-system -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.spec.containers[0].image}{"\n"}{end}' 2>&1 | sed 's/^/      /'

  lab_note "WorkerPool (the one ax never creates):"
  k get workerpools.ate.dev -A 2>&1 | sed 's/^/      /'

  lab_note "Substrate must still be healthy (Phase 2):"
  k get svc api -n ate-system 2>&1 | sed 's/^/      /'
  k get pods -n ate-system --no-headers 2>&1 | awk '{printf "      %-34s %s %s\n", $1, $2, $3}'

  cat <<EOF

Next:
  scripts/ax-verify.sh      the Phase 3 gate (needs this cluster)
  docs/07-ax-control-plane.md

Apply a task:
  ./bin/ax apply -f ${WORKDIR}/workspace.yaml --context ${AXLAB_KUBECTL_CONTEXT}
  ./bin/ax apply -f ${TASK_YAML} --context ${AXLAB_KUBECTL_CONTEXT}
  ./bin/ax resume task task123 --context ${AXLAB_KUBECTL_CONTEXT}
  ./bin/ax get task task123 --context ${AXLAB_KUBECTL_CONTEXT}
EOF
}

# --- main -------------------------------------------------------------------

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  --force-runner) ;;
  *) usage; lab_die "unknown argument: $1" ;;
esac

command -v kubectl >/dev/null 2>&1 || lab_die "kubectl not on PATH"

SAVED_CONTEXT="$(kubectl config current-context 2>/dev/null || true)"
trap restore_context EXIT
printf 'kubectl context on entry: %s\n' "${SAVED_CONTEXT:-<none>}"

preflight
build_runner_image
# The control plane's namespace must exist before the WorkerPool goes in.
k create namespace ax-system --dry-run=client -o yaml | k apply -f - >/dev/null
apply_workerpool
deploy_control_plane
write_task_manifest
health_summary
