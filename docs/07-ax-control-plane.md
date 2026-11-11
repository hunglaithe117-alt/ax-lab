# 07 — ax's control plane on Substrate

Phase 3. Phase 2 gave us a Substrate cluster with a real gVisor actor. This
phase puts **ax's own control plane** on that cluster and drives a real `Task`
through it to a running sandboxed actor.

Everything substrate-side is in [06](06-substrate-on-kind.md). This page does not
repeat it; it covers what ax adds and the three things you must fix before any
of it works.

## How ax reaches Substrate

ax is a control plane. It never runs your workload. Each `Task` becomes one
sandboxed **actor** on Substrate, driven over the ate API:

```
  you ──ax apply──▶ ax-server ──▶ Redis (task store)
                        │
                        ▼
                  ax-controller  ──gRPC/mTLS──▶  api.ate-system.svc:443
                                                          │
                                                          ▼
                                     atespace → ActorTemplate → Actor → gVisor sandbox
```

The controller is what talks to Substrate. `deploy/ax-controller.yaml` wires it
up, and the four parts that matter are worth reading closely because they are
easy to break:

| What | Where | Why it is there |
|---|---|---|
| `--substrate-endpoint=api.ate-system.svc.cluster.local:443` | `deploy/ax-controller.yaml:73` | the Control API Service from Phase 2 |
| `--substrate-authority=api.ate-system.svc` | `:74` | the TLS name mTLS must match |
| projected SA token, `audience: api.ate-system.svc` | `:107` | Substrate authenticates by audience; the wrong audience is rejected |
| `clusterTrustBundle` for `servicedns.podcert.ate.dev/identity`, label selector `podcert.ate.dev/canarying: live` | `:114-119` | the CA that signed the serving identity |

Do not "fix" a connection problem by loosening the token audience or dropping
the trust bundle. Phase 2 published those bundles precisely so this mTLS works;
the controller authenticates as `spiffe://cluster.local/ns/ate-system/sa/ax-controller`.

### The two-plane model, as ax uses it

From [06](06-substrate-on-kind.md#the-two-plane-resource-model): `WorkerPool` is
Kubernetes, `ActorTemplate`/`Actor` are Substrate's own gRPC API. ax lives
entirely on the **Substrate** side of that line, and it creates three things per
task:

1. **an atespace** — `internal/controller/reconciler.go:120` calls
   `EnsureAtespace`, using the Task's `metadata.atespace`. Our Task used
   `default`, so `kubectl ate get atespace` now lists it alongside Phase 2's
   `ate-demo-counter`.
2. **an ActorTemplate** — per task, named by a hash of the task name, image and
   env (`reconciler.go:173` `taskTemplateName`). Ours came out
   `default/task123-tmpl-c2e4b714`. Substrate then takes its **golden snapshot**.
3. **an Actor** — `reconciler.go:185` `EnsureActor`, and the actor is named
   after the task (`reconciler.go:129`: `actorName := task.Metadata.Name`). That
   is deliberate: the comment above it notes the two are interchangeable "for
   example in the router's `ate-target-actor` header", which is exactly how
   Phase 2's counter was reached.

The `WorkerPool` is **yours**. ax never creates one — that is gap 2 below.

## The three gaps

Upstream documents none of these. They are the actual content of this phase.

### Gap 1 — ax's task image is private

`examples/task.yaml:24` pins

```
image: "gcr.io/ax-substrate/ate-images/ax-task-runner@sha256:3a0dea6ad8b55278685db58aca6e37dc4ba04056831d45bef3aaeafdca43cac6"
```

That registry is not readable (401 on the manifest, 403 on the token endpoint),
so **both** shipped example manifests are unrunnable as shipped.
`pkg/apis/v1alpha1/types.go:38` hardcodes the same repository as
`DefaultTaskImage`, and `reconciler.go:111-112` substitutes it whenever a Task
leaves `spec.image` empty.

Build your own, with the repo's own recipe (`Makefile:46-51`): it cross-compiles
`cmd/ax-task-runner` for `linux/amd64` and builds `Dockerfile.task-runner`, which
is `python:3.12-slim` plus git/curl/openssh (`Dockerfile.task-runner:15-24`) and
`pip install google-antigravity` (`:26`).

```console
$ cd upstream/google-ax
$ make build-task-runner AX_IMAGE_REPO=localhost:5001/ax CONTAINER_CLI=docker
...
#10 naming to localhost:5001/ax/ax-task-runner:latest done
```

**Bypass the `gcloud` line.** `push-task-runner` ends with
`gcloud container images list-tags` (`Makefile:58`) purely to print the digest,
which needs GCP credentials. Push by hand and read the digest off the output:

```console
$ docker push localhost:5001/ax/ax-task-runner:latest
latest: digest: sha256:654af96988c2c4a94e875c15c89760ec830fa552d00b42391cf7943d7cffd456 size: 856
```

That is the **real upstream image** — 649MB, Antigravity and all. No minimal
fallback was needed. Two things about the contract that the build gives you, from
the runner's own source rather than guesswork:

- the guest command is hardcoded to `/usr/local/bin/ax-task-runner`
  (`internal/substrate/client.go:207` `DefaultGuestCommand`), which is why
  `Dockerfile.task-runner:31` sets that as `ENTRYPOINT`;
- readiness is probed at **`/readyz` on port 80** (`client.go:248-253`), and the
  runner's `DefaultPort` is 80 (`runner/runner.go:42`, whose comment says it
  "matches the port Agent Substrate probes for readiness").

### Gap 2 — ax never creates a `WorkerPool`

`grep -rni workerpool --include='*.go'` over the ax **Go sources** returns
**zero hits**. (Scope it: unscoped, it also matches a compiled binary under
`bin/`, which this phase builds, and reports a match that is not a source hit.)
So does any
reference to `Spec.Resources`. Consequences, in order of how they bite:

- **No workers, so nothing schedules.** Worker pods come from `WorkerPool` CRs;
  `ate-controller` turns each into a Deployment. With no pool of your own, a
  fresh Substrate has no worker pods and every ax task sits unschedulable
  forever.
- **`BuildActorTemplate` sets no `WorkerSelector`**
  (`internal/substrate/client.go:212-276` never assigns it), and
  `schedulingConstraints` (`substrate/cmd/ateapi/internal/controlapi/workflow_resume.go:598-614`)
  leaves both the template and actor selectors empty. The consequence is "any
  worker", but the mechanism is worth stating precisely, because the obvious
  reading of the code is wrong: `Applies` guards with
  `if constraints.ActorSelector != nil && !…Matches(set)`
  (`scheduling.go:141,144`), and that nil test **never fires** — it is not
  skipped. `schedulingConstraints` calls `labels.SelectorFromSet(nil)`, which
  returns a non-nil selector, and apimachinery's own doc says "A nil and empty
  Sets are considered equivalent to `Everything()`"
  (`vendor/k8s.io/apimachinery/pkg/labels/selector.go:946-947`). An empty
  selector matches every label set, so the check runs and passes. Constraint:
  none.
- **The scheduler picks uniformly at random** among the workers that qualify
  (`scheduling.go:128`: `candidates[s.intn(len(candidates))]`), over the **whole
  fleet** — `Schedule` filters `s.source.Workers()` with no namespace scoping
  (`scheduling.go:102-129`).

So the pool you author is *necessary* but not *selective*. We watched this
happen three times: our runs landed on `ate-demo-counter/counter-7dd86bcc6c-lvsks`,
then on our own `ax-system/ax-worker`, then back on
`ate-demo-counter/counter-7dd86bcc6c-5qdp5` — because every free gVisor worker in
the cluster qualifies and the choice is random. If you need determinism, the only
lever is to make the other pools' workers occupied (every worker holds one actor,
`HasRoom` at `scheduling.go:164-166`).

A `WorkerPool` modelled on `substrate/demos/counter/counter.yaml.tmpl`:

```yaml
apiVersion: ate.dev/v1alpha1
kind: WorkerPool
metadata:
  name: ax-worker
  namespace: ax-system
  labels:
    axlab.teacher/owner: phase3     # ax-down.sh refuses to delete without this
spec:
  replicas: 2
  workerImage: localhost:5001/ateom-gvisor-...@sha256:fdd1d0ad...
  template:
    nodeSelector:
      ate.dev/substrate-version: "67253354"   # must match the node's label
    resources:
      limits:   { cpu: "2", memory: 4Gi }
      requests: { cpu: 500m,  memory: 4Gi }
```

Two sizing rules from the counter's own comments
(`counter.yaml.tmpl:45-53`): **limits** advertise the per-actor ceiling
(`workerCapacity` reads limits only), while kube-scheduler packs nodes by
**requests**; and memory is not compressible, so its request matches its limit.
The `nodeSelector` is not optional — the versioned atelet and the workers only
schedule onto a node labelled `ate.dev/substrate-version`, which Phase 2 stamped.

One more consequence of ax ignoring `spec.Resources`: the ActorTemplate has no
resource limits at all, and `HasRoom` returns true for **any** free worker when
the limits are empty (`scheduling.go:168-172`, `if err != nil || len(want) == 0
{ return err == nil }`). So the `resources:` block in `examples/task.yaml` is
decorative, and the sandbox is unsized. We kept the block in our Task manifest
purely to show that.

### Gap 3 — the snapshot bucket is a private GCS path

`deploy/ax-controller.yaml:82-83`:

```yaml
- name: AX_SNAPSHOTS_BUCKET
  value: "gs://snapshot-substrate-test-ax-substrate/ate-env/"
```

and `internal/substrate/client.go:208` hardcodes the same value as
`DefaultSnapshotsBucket`, used whenever the env var is empty
(`client.go:222-228`). On the kind path storage is in-cluster rustfs over S3, so
every suspend/resume would fail against a bucket that does not exist. Repoint it
to `s3://ate-snapshots/ate-env/`.

Verify the bucket name from the deployed init rather than assuming — Substrate's
own `rustfs-bucket-init` creates exactly one:

```console
$ kubectl get pod -n ate-system -l app=rustfs-bucket-init -o jsonpath='{.spec.containers[0].command}'
["/bin/sh","-c","set -e\nfor i in $(seq 1 60); do\n  if aws s3api head-bucket --bucket ate-snapshots ...
```

**The `s3://` scheme is cosmetic, and that is worth knowing.** Substrate splits
the URI with `url.Parse` and takes `parsed.Host` as the bucket
(`substrate/internal/objectstore/objectstore.go:118-130`); the scheme is never
examined. That is exactly why Phase 2's `gs://ate-snapshots/...` worked against
rustfs, and why `s3://` works here. Either scheme reaches the same bucket.

### A fourth one: `WorkspaceReady` is not a workspace check, and repairing it is blocked by the actor

Not on the brief, but it cost real time and it is the most interesting bug here.

**`WorkspaceReady=True` reports the runner's liveness, not whether the workspace
was set up.** The chain:

- `SetupWorkspace` (`internal/workspace/setup.go:83-128`) returns an error on
  exactly one path — the `os.MkdirAll` at `:95`. Its other three returns
  (`:104,123,128`) are all `(res, nil)`. Critically, `:121-123` is the
  *git-clone-failed* path, and it returns **nil**.
- So `runner.go:156-165`'s `if err != nil { ready = false }` only trips on a
  failed mkdir. A failed `git clone` logs a warning and still reports ready.
- The controller then sets `WorkspaceReady=True/SetupComplete` and
  `Ready=True/TaskRunning` for **any** task that has a worker
  (`reconciler.go:280-288`).
- And `workspaceReady` is driven by an HTTP **`/readyz` probe** — direct, then
  through `ATENET_ROUTER_ADDR` (`reconciler.go:237-250`) — which the runner
  answers as soon as it is up.

Net effect: the condition can only read False if the probe misses the runner
inside `WorkspaceReadyTimeout`. It is a liveness signal wearing a correctness
label. (An earlier draft of this page claimed a failed workspace leaves
`WorkspaceReady` false forever. That is wrong, and the reason it is wrong is the
interesting part.)

**How we hit it.** The Workspace is delivered to the sandbox as an env var,
`AX_WORKSPACES_YAML` (`reconciler.go:165-168`), read by the runner
(`cmd/ax-task-runner/main.go:119-120`) and resolved from ax's store per reconcile
(`internal/controller/worker.go:138-149`). If the Task reconciles before the
Workspace is readable, the template is created without it — and the failure is
invisible:

```console
$ ax get task task123        # first run
        - type: WorkspaceReady
          status: "True"
          reason: SetupComplete
$ ax ssh task123 -- /bin/sh -c 'du -sh /workspace; ls -d /workspace/.git'
4.0K    /workspace
```

**Why a re-reconcile does not repair it — and the real blocker is the actor, not
the template.** Two things happen on a later reconcile, and they cancel out:

1. The template *is* replaced. `taskTemplateName` (`reconciler.go:371-382`)
   hashes task name + image + env, so new env mints a **new template name**, and
   the controller does create it. That is the repair path, and it is why the name
   changed in our own evidence (`task123-tmpl-c2e4b714` → `task123-tmpl-8feb31f7`).
2. But `EnsureActor` (`client.go:307-330`) calls `CreateActor`, gets
   `AlreadyExists`, and **returns the existing actor** — still bound to the old,
   workspaceless template. The corrected template is created and then orphaned.

So the actor is the thing that has to go first. The fix is ordering, and
`ax-up.sh` bakes it in: **apply the Workspace first, then the Task.** After
`ax delete task` + re-apply:

```console
$ kubectl ate get actor-template task123-tmpl-8feb31f7 -a default -o yaml | grep -oE "name: AX_[A-Z_]+"
name: AX_TASK_YAML
name: AX_WORKSPACES_YAML
$ ax ssh task123 -- /bin/sh -c 'ls -A /workspace'
chalk
```

A note on what that `chalk` proves, because it is less than it looks: the clone
of `chalk` never completed — `/workspace/chalk` contains a 71K `.git` with no
commits (`your current branch 'master' does not have any commits yet`). That was
already true before we suspended anything. So the honest claim is that **the
workspace directory the Workspace spec created, and its git metadata, are
present and survive** — not that a full checkout succeeded. The gate therefore
asserts the workspace is non-empty and contains the declared Workspace name,
rather than anything about a third-party repo's contents, which would make it
network-dependent and flaky.

Two smaller notes: the shipped `mcp:` block points at
`http://git-mcp.default.svc.cluster.local:8080`, which does not exist here, and a
failed workspace setup is only logged — so it would leave `WorkspaceReady` false
forever. We dropped `mcp:` and `skills:` (the latter queries a Google-backed
registry) and kept `git:`. And **no Gemini key is needed**: the `Model` resource
is not required by a Task, and nothing in a shipped binary reaches the model
client, so we simply left the `Model` out.

## Deploying

```console
$ scripts/ax-up.sh
```

That is `make deploy` (`Makefile:68` = `deploy-redis` → `deploy-controller` →
`deploy-server`) with three changes, all in the script.

**The registry.** `AX_IMAGE_REPO` defaults to `gcr.io/ax-substrate/ate-images`
(`Makefile:18`), so both `ko apply` steps are overridden with
`KO_DOCKER_REPO=localhost:5001/ax`. The kubelet-side containerd `certs.d`
mirror Phase 2 wrote is what makes the pull work — a *different* mechanism from
Substrate's `--localhost-registry-replacement` flag, which is substrate-internal
and irrelevant here. Proof it resolved and pulled:

```console
$ kubectl get pods -n ax-system -o jsonpath='{range .items[*]}{.metadata.name}{" -> "}{.status.containerStatuses[*].imageID}{"\n"}{end}'
ax-controller-7494bb7d... -> localhost:5001/ax/ax-controller-7ebf6094...@sha256:54b31098...
ax-server-5bf68bb458...    -> localhost:5001/ax/ax-server-340c3583c...@sha256:42c5b4ff...
ax-worker-798767bd57-l6phb -> localhost:5001/ateom-gvisor-7158896646...@sha256:fdd1d0ad...
```

**`ko apply` does not take a kubectl context.** This bit us, and it is worth
stating because the failure is aimed at whatever cluster is *current*. A first
attempt ran `make deploy-server` (i.e. `ko apply -f deploy/ax-server.yaml`,
`Makefile:78-80`) with the ambient context set to the user's **minikube**:

```
Error from server (NotFound): error when creating "STDIN": namespaces "ax-system" not found
```

Nothing leaked — minikube has no `ax-system` namespace, so the apply failed
atomically — but it was one namespace away from writing into the user's cluster.
`ax-up.sh` avoids the trap entirely by using `ko resolve | kubectl apply
--context`, which also lets it edit the bucket before applying with no drift. (If
you must use `ko apply`, the context goes after `--`:
`ko apply -f x.yaml -- --context=kind-ax-lab`, the form Substrate's own
`hack/install-ate.sh:209-211` uses.)

**The bucket**, rewritten in the resolved YAML before it is applied. An earlier
version regex-matched the private path and *mangled* it — the alternation
backtracked into a trailing `[^"]*` and produced
`s3://ate-snapshots/ate-env/ax-substrate`. The shipped version rewrites the
`value:` line that follows the `- name: AX_SNAPSHOTS_BUCKET` line, which is
robust to whatever upstream ships and idempotent:

```console
$ kubectl get deploy -n ax-system ax-controller \
    -o jsonpath='{range .spec.template.spec.containers[0].env[?(@.name=="AX_SNAPSHOTS_BUCKET")]}{.value}{end}'
s3://ate-snapshots/ate-env/
```

## Driving a task

The real verbs, from `ax --help` (and `ax version` is useless for detection: it
prints a hardcoded `ax version v1alpha1 (standalone redis engine)` —
`cmd/ax/main.go:103`). Every call needs `--context`, or the CLI talks to whatever
cluster is current.

**Apply. The Task comes up `Suspended`, and that is correct.**

```console
$ ax apply -f .work/p3/workspace.yaml --context kind-ax-lab
workspace.ax.io/default-workspace created
$ ax apply -f .work/p3/task.yaml --context kind-ax-lab
task.ax.io/task123 created
$ ax get task task123 --context kind-ax-lab
status:
    phase: Suspended
    actor: task123
    conditions:
        - type: Ready
          status: "False"
          reason: TaskSuspended
          message: Task is suspended
```

Worth being precise about, because the obvious reading is wrong: there **is** an
actor. ax created it eagerly; it is just suspended and holds no worker.

```console
$ kubectl ate get actor task123 -a default --context kind-ax-lab
ATESPACE   NAME      TEMPLATE                        STATE                   WORKER POD   WORKER IP   VERSION   AGE
default    task123   default/task123-tmpl-c2e4b714   ACTOR_STATE_SUSPENDED   <none>                   1         14s
```

**Resume.** Note for anyone scripting this: `ax resume` sets `phase: Running`
*immediately*, before the controller has placed a worker — so a check that polls
`phase` will read `Running` while `workerIP` is still absent and the conditions
still say `TaskSuspended`. Poll for the **worker IP**.

```console
$ ax resume task task123 --context kind-ax-lab
task.ax.io/task123 resumed
$ ax get task task123 --context kind-ax-lab
status:
    phase: Running
    id: task-task123-1790529333
    actor: task123
    workerIP: 10.244.0.20
    conditions:
        - type: Ready
          status: "True"
          reason: TaskRunning
          message: Task is running and its workspace is ready
        - type: WorkspaceReady
          status: "True"
          reason: SetupComplete
          message: Workspace setup completed at 10.244.0.20
```

## The evidence that it is real

**The actor, in Substrate:**

```console
$ kubectl ate get actor task123 -a default --context kind-ax-lab
default    task123   default/task123-tmpl-8feb31f7   ACTOR_STATE_RUNNING   ax-system/ax-worker-798767bd57-mcgn6   10.244.0.29   3   67s
```

**Our image, and the in-cluster bucket, on the template:**

```console
$ kubectl ate get actor-template task123-tmpl-8feb31f7 -a default -o yaml | grep -E "image:|storageLocation:|snapshotUri:"
            image: localhost:5001/ax/ax-task-runner@sha256:654af969...
    storageLocation: s3://ate-snapshots/ate-env/
        snapshotUri: s3://ate-snapshots/ate-env/atespaces/ate-golden/actors/4f98bf16-.../snapshots/242696fd-...
```

That golden snapshot is real but it is **not the path `ax suspend` takes**, so on
its own it does not prove gap 3. The golden is produced by Substrate's
`ActorTemplateReconciler` driving a golden actor in the reserved `ate-golden`
atespace (`template_reconciler.go:183-208`); no task is involved. `ax suspend`
goes elsewhere — `workflow_suspend.go:325` →
`resources.NewActorSnapshotURI(template.SnapshotsConfig.StorageLocation,
atespace, actor.UID, name)` — and writes under a **different key prefix**. The
closing check is therefore a real suspend/resume round trip.

**Suspend.** Note the content scope: `SNAPSHOT_CONTENT_SCOPE_DATA`, because ax's
template uses `DATA` (`client.go:265-266`) where Phase 2's counter used `FULL`.
So only the durable dir is captured — which is exactly the workspace.

```console
$ ax suspend task task123 --context kind-ax-lab
task.ax.io/task123 suspended
$ kubectl ate get actor task123 -a default -o yaml | grep -E "state:|snapshotUri|contentScope"
      contentScope: SNAPSHOT_CONTENT_SCOPE_DATA
      snapshotUri: s3://ate-snapshots/ate-env/atespaces/default/actors/8bcaa9fd-339c-4a27-bd9c-40826baca3c4/snapshots/43ca3fa6-c0eb-45ad-8c86-55684f676a95
    state: ACTOR_STATE_SUSPENDED
```

There it is: the **per-actor** prefix `atespaces/default/actors/<uid>/snapshots/`,
not the golden one, on the corrected bucket. And `atelet` really uploaded it:

```console
$ kubectl logs -n ate-system -l app=atelet --tail=8000 | grep "Compressed zstd upload" | grep 43ca3fa6
  ate-env/atespaces/default/actors/8bcaa9fd-339c-4a27-bd9c-40826baca3c4/snapshots/43ca3fa6-.../durable-dir.tar.zstd
```

**Resume — onto a different worker, with the workspace intact.**

```console
$ ax resume task task123 --context kind-ax-lab
task.ax.io/task123 resumed
$ kubectl ate get actor task123 -a default
default  task123  default/task123-tmpl-5da47a45  ACTOR_STATE_RUNNING  ate-demo-counter/counter-7dd86bcc6c-5qdp5  10.244.0.21  7  6m1s
$ ax ssh task123 -- /bin/sh -c 'ls -A /workspace'
chalk
```

It came back on `counter-7dd86bcc6c-5qdp5` at `10.244.0.21`, having suspended
from `10.244.0.29` — a different worker, and `chalk` still there. That closes
gap 3 on the path that matters, and doubles as the regression test for gap 4: if
the template had been built without `AX_WORKSPACES_YAML`, this workspace would
have been empty.

**A real gVisor sandbox**, from the actor's own log:

```console
$ kubectl ate logs actor task123 -a default --context kind-ax-lab | head -4
{"message":"I0927 17:15:56.724016 1441 cli.go:276] Version release-20260824.0-120-g727c8c389c36-dirty, go1.26.3, amd64, 16 CPUs, linux, PID 1441, PPID 1, UID 0, GID 0"}
{"message":"I0927 17:15:56.729069 1441 config.go:554] Platform: systrap"}
{"message":"I0927 17:15:56.729111 1441 config.go:557] Network: sandbox"}
{"message":"I0927 17:15:56.809293 1441 cli.go:317] Exiting with status: 0"}
```

**And a command inside it:**

```console
$ ax ssh task123 --context kind-ax-lab -- /bin/sh -c 'echo HELLO_FROM_SANDBOX; id; hostname; uname -srm; ls -A /workspace'
HELLO_FROM_SANDBOX
uid=0(root) gid=0(root) groups=0(root)
actor
Linux 4.19.0-gvisor x86_64
chalk
```

`uname` reporting a **gVisor kernel** is the strongest single piece of evidence
here: it cannot be faked by a plain container.

## Operational notes

**`ax` opens a tunnel, and it is a real side effect.** The CLI auto-starts a
background `kubectl port-forward` to `ax-system/ax-server` on an ephemeral port
and remembers it:

```console
$ ax tunnel list --context kind-ax-lab
CONTEXT      LOCAL PORT  REMOTE SERVICE       PID      STATUS    CREATED
kind-ax-lab  44963       ax-system/ax-server  2752124  Active    2026-09-28 00:15:32
```

Good news: it picks a high port, so 80/6379/8080 are never bound.
`scripts/ax-down.sh` stops it (`ax tunnel stop`).

**The host inotify limit.** Phase 3 needs it raised: at the pre-lab `128`,
`atenet-router`'s Envoy crash-loops on *restart*, so any pod churn during a
deploy can take the data plane down. `ax-up.sh` does not write it — it warns and
points at `scripts/substrate-up.sh`, which owns that change and prints the
before/after under a `HOST KERNEL` label. It is a **host-global** sysctl that
outlives the cluster; restore with `AXLAB_RESTORE_INOTIFY=1 scripts/substrate-down.sh`.
The host is currently at `8192`/`524288` because Phase 3 is live.

**`ax-up.sh` writes into the ax clone.** `make build-task-runner` puts its
cross-compiled binary at `bin/linux_amd64/` inside `upstream/google-ax`
(`Makefile:49`). That is inside the read-only clone, but `bin/` is gitignored
(ax `.gitignore:2`), so `git status --porcelain` stays empty and the clone is
still pristine. Worth knowing before you are surprised by the directory.

## The gate

`scripts/ax-verify.sh` — 9 checks, 27 assertions, exit 0:

```console
$ scripts/ax-verify.sh
--- 1/9  ax-redis, ax-controller and ax-server all Running in ax-system
    PASS  ax-redis, ax-controller and ax-server are ready
    PASS  4 container(s) pulled an image from the local registry via certs.d
--- 2/9  Substrate is still healthy (Phase 2 not broken)
    PASS  svc/api present and every ate-system pod is Running
--- 3/9  the WorkerPool ax never creates (gap 2)
    PASS  WorkerPool ax-system/ax-worker has 2 ready worker(s)
    PASS  nodeSelector matches the node's substrate-version label (67253354)
--- 4/9  AX_SNAPSHOTS_BUCKET repointed off the private GCS path (gap 3)
    PASS  repointed at the in-cluster bucket: s3://ate-snapshots/ate-env/
    PASS  the deployed rustfs init really creates that bucket (ate-snapshots)
--- 5/9  a Task applies Suspended, with an actor that holds no worker
    PASS  Task task123 is Suspended on apply (correct ax behaviour, not a failure)
    PASS  the actor exists but is SUSPENDED with no worker assigned
--- 6/9  resume it: Running, a worker IP, and Ready/WorkspaceReady
    PASS  phase is Running
    PASS  task reports a worker IP (10.244.0.30)
    PASS  Ready=True
    PASS  WorkspaceReady=True
--- 7/9  the actor is a real gVisor sandbox running our runner image
    PASS  actor task123 is ACTOR_STATE_RUNNING
    PASS  template uses our locally built runner image
    PASS  snapshots go to the in-cluster bucket (s3://ate-snapshots/ate-env/)
    PASS  a real golden snapshot exists on the s3/rustfs path
    PASS  the ActorTemplate carries AX_WORKSPACES_YAML with a Workspace document -- the spec reached the sandbox
    PASS  the actor's log shows a gVisor sandbox
--- 8/9  ax ssh runs a command inside the sandbox
    PASS  ax ssh executed a command inside the sandbox
    PASS  uname inside the sandbox reports a gVisor kernel
    PASS  /workspace contains 'chalk', the directory the Workspace's git spec clones into
--- 9/9  ax suspend writes a per-actor snapshot to the bucket, and resume restores it
    PASS  suspend wrote to the corrected bucket
    PASS  suspend used the PER-ACTOR path atespaces/default/actors/<uid>/snapshots/, not the golden one
    PASS  resume placed the actor again (worker IP 10.244.0.30)
    PASS  actor is ACTOR_STATE_RUNNING again after resume
    PASS  the workspace survived suspend/resume (chalk still present)
    passed: 27  failed: 0
all checks passed
```

**Two of those assertions exist because the obvious ones are tautologies.**
`WorkspaceReady=True` proves nothing about the workspace (see the fourth gap
above), so the gate checks the two things that are actually load-bearing:

- the running ActorTemplate's env carries `AX_WORKSPACES_YAML` **with a
  Workspace document in it** — the root cause, deterministic. (The value is a
  YAML block scalar, `value: |`, so matching the name alone would be weak.)
- `/workspace` actually contains the directory the Workspace's git spec clones
  into — the symptom. The expected directory is **derived from the manifest at
  run time**, and it is the *repo* name, not the Workspace resource name:
  `cloneDestination` (`internal/workspace/setup.go:174-195`) uses `repo.Dir` if
  set, else `repo.Name`, and the shipped Workspace's `name: origin` is exactly
  the sentinel that makes it derive the name from the URL. So
  `default-workspace` + `github.com/chalk/chalk.git` → `/workspace/chalk`. An
  earlier version of this check compared against the Workspace *resource* name
  and failed on a perfectly good deployment.

We proved both can fail, by reproducing the original bug on purpose — applying
the Task *before* the Workspace, which is what `examples/task.yaml` does, since
it lists the Task first:

```console
$ kubectl ate get actor-template <tpl> -a default -o yaml | grep -c AX_WORKSPACES_YAML
0
$ ax ssh task123 -- /bin/sh -c 'ls -A /workspace'
(end)                                    # empty
--- assertion (a) ---
    FAIL  the ActorTemplate has no AX_WORKSPACES_YAML: the runner was never told about the Workspace
--- assertion (b) ---
    FAIL  /workspace is empty inside the sandbox: the Workspace was never set up
          (WorkspaceReady=True would still have said otherwise)
--- for contrast: what the task CLAIMS about its workspace ---
        - type: WorkspaceReady
          status: "True"
          reason: SetupComplete
```

Both assertions failed while the task still reported `SetupComplete`. That is
the entire point of them. (A full gate run cannot be used to show this, because
check 5 deletes and re-applies the task and applies the Workspace *first* — it
would repair the state before the assertions ran.)

It is **self-contained**: it resolves `kubectl`, `kubectl-ate` and `ax` to
absolute paths, never trusts the ambient `PATH`, and refuses to run at all if
pointed at a minikube context — it mutates, so that guard is not optional. From
a stripped environment with `~/go/bin` absent:

```console
$ env -i HOME="$HOME" PATH=/snap/bin:/usr/bin:/bin:/home/linuxbrew/.linuxbrew/bin \
    KUBECONFIG="$HOME/.kube/config" ./scripts/ax-verify.sh
    kubectl:    /snap/bin/kubectl
    kubectl-ate: /home/hung1/go/bin/kubectl-ate
    ax:          /home/hung1/personal/ax-lab/bin/ax
    passed: 27  failed: 0
```

`AXLAB_SKIP_MUTATE=1` runs only the read-only checks 1–4 and reports **PARTIAL**,
exit 3 — it never claims "all checks passed" for checks that did not run.

It is deliberately **not** part of `verify-all.sh`, which must stay cluster-free.

## Teardown

```console
$ scripts/ax-down.sh              # or AXLAB_DRY_RUN=1 to rehearse
```

Removes only ax's own objects: the Task (via the ax CLI, which owns that
lifecycle), the `WorkerPool` (only if it carries `axlab.teacher/owner=phase3`),
the Deployments/Service/ServiceAccount in `ax-system`, the two **cluster-scoped**
`ax-controller` objects (which deleting the namespace would not catch), the
namespace, and only the registry repos under `localhost:5001/ax`. It never
touches `ate-system`, `ate-demo-counter`, the counter `WorkerPool`, or the
`kind-registry` container — Phase 2 owns all of those, and check 2 of the gate
exists to prove it.

`AXLAB_DRY_RUN=1` gates **every** destructive action through one helper, so it
cannot be honoured in one place and forgotten in another. It is smoke-tested, and
the negative case is the point:

It removes registry **manifests**, not blobs: a registry keeps untagged layers
until a garbage collection runs, so the ax images stop being pullable but disk
use on the node does not drop immediately. `AXLAB_SKIP_IMAGES=1` leaves them
alone entirely.

```console
$ AXLAB_DRY_RUN=1 ./scripts/ax-down.sh
DRY RUN: no change will be made.
==> 1. The demo Task and Workspace
    DRY RUN  would delete Task task123
==> 2. The WorkerPool (gap 2), which ax never creates
    DRY RUN  would delete WorkerPool ax-system/ax-worker (carries axlab.teacher/owner=phase3)
==> 3. The ax control plane in ax-system
    DRY RUN  would delete Deployment ax-system/ax-controller
    ...
    DRY RUN  would delete Namespace ax-system (and everything left in it)
==> 4. Registry images under localhost:5001/ax
    DRY RUN  would delete registry repo ax/ax-controller-7ebf6094b...
    DRY RUN  would delete registry repo ax/ax-server-340c3583c...
    DRY RUN  would delete registry repo ax/ax-task-runner
    the kind-registry container itself is NOT touched (Phase 2 owns it)
```

…and afterwards the namespace, WorkerPool, Task, four Deployments, the
ClusterRole and all three images were still present, with `current-context` still
`minikube`.

## Phase 3 files

| File | What it is |
|---|---|
| `scripts/ax-up.sh` | idempotent: build+push the runner, apply the WorkerPool, deploy the control plane, write the Task manifest, health summary |
| `scripts/ax-verify.sh` | the 9 checks; **needs** the cluster, so not in `verify-all.sh` |
| `scripts/ax-down.sh` | teardown, ax's objects only, fully dry-runnable |
| `.work/p3/{task,workspace}.yaml` | generated by `ax-up.sh`; the Task pins the built image digest |

Next: Phase 4 — a genuinely sandboxed task you can `ax ssh` into. (The `ax ssh`
above already runs in a real gVisor sandbox; Phase 4 makes it the point of the
exercise rather than a verification step.)
