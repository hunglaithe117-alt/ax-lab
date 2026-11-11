# 06 — Agent Substrate on kind

Phase 2. Phase 1 read `ax`'s Go source and ran it against `ax-server`. Nothing
in `ax` runs end-to-end yet, because this phase is the one that stands up the
thing `ax` schedules onto.

## What Substrate is, and why `ax` needs it

`ax` is a control plane. It never runs your workload. It hands each task to
**Agent Substrate**, which sandboxes and runs it.

> AX schedules every task as a sandboxed actor on Agent Substrate, so Substrate
> must be running in your cluster before you deploy AX.
> — `upstream/google-ax/README.md:63`

The gate `ax` itself names is one `kubectl` call:

```console
$ kubectl get svc api -n ate-system
NAME   TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)   AGE
api    ClusterIP   None         <none>        443/TCP   22m
```

(`upstream/google-ax/README.md:72`. `ClusterIP: None` — the Service is headless;
it fronts `api.ate-system.svc.cluster.local:443`, where `ax` expects the Control
API. See `upstream/google-ax/README.md:69`.)

The one idea worth holding onto: Substrate maps **many actors onto few workers**.
An actor is a sandboxed process; a worker is a Kubernetes Pod that hosts one
actor at a time. Agent workloads are idle most of the time, so Substrate trades a
small number of always-warm workers for a large number of cheap actors — and
that is why it checkpoints actors to object storage instead of keeping them
resident.

## The two-plane resource model

**This is the part that trips everyone up, so read it twice.**

There are two completely separate kinds of "resource" here, and only one of them
is Kubernetes.

### Plane 1 — real Kubernetes objects

| Kind | Scope | Get it with |
|---|---|---|
| `WorkerPool` (`workerpools.ate.dev`) | Namespaced | `kubectl get workerpools.ate.dev` |
| `SandboxConfig` (`sandboxconfigs.ate.dev`) | **Cluster**-scoped | `kubectl get sandboxconfigs.ate.dev` |

A `WorkerPool` is the pool of worker Pods. `ate-controller` turns it into a
Deployment for you, so the Pods do not exist at apply time. Go type:
`pkg/api/v1alpha1/workerpool_types.go:80` (`WorkerPoolSpec`, with
`WorkerImage` at `:89` and the `SandboxClass` field at `:107` — its doc comment
starts at `:96`).

### Plane 2 — Substrate's own gRPC API, *not* Kubernetes

| Kind | What it is |
|---|---|
| `Atespace` | a namespace-like scope inside Substrate |
| `ActorTemplate` | an immutable recipe; carries a golden snapshot |
| `Actor` | one running (or suspended) instance of a template |

These live in `pkg/proto/ateapipb/ateapi.proto` — `Atespace` at `:708`,
`ActorTemplate` at `:744`, `Actor` at `:349` — and are served by the
`Control` service (`:25`, with `CreateActor` `:30`, `SuspendActor` `:38`,
`ResumeActor` `:44`, `DeleteActor` `:47`).

They are **not** API objects. There is no `kubectl get actor`:

```console
$ kubectl get actors -A
error: the server doesn't have a resource type "actors"
$ kubectl get actor
error: the server doesn't have a resource type "actor"
```

You reach them with the `kubectl ate` plugin, or over gRPC. Meanwhile the pool
they run on is right there in Kubernetes:

```console
$ kubectl get workerpools.ate.dev -A -o wide
NAMESPACE          NAME      DESIRED   REPLICAS   READY   AGE
ate-demo-counter   counter   3         3          3       22m
```

So, in one line: **`WorkerPool` is where actors run (Kubernetes);
`ActorTemplate`/`Actor` are what runs (Substrate's API, scoped by `atespace`).**
The demo makes the coupling concrete — the pool is named `counter`
(`demos/counter/counter.yaml.tmpl:29`) with `replicas: 3` (`:39`) in namespace
`ate-demo-counter`, and the atespace of that same name is what holds the
`counter` template. An actor's `worker_pool`/`worker_namespace` fields point back
across the boundary.

## Bringing it up

**Step 0 — get the pinned Substrate clone.** `upstream/substrate/` is
gitignored, and `scripts/setup.sh` clones **only** `google-ax`, so a fresh
checkout does not have one. Without it `scripts/substrate-up.sh` stops in
preflight (and prints these same commands):

```console
$ git clone https://github.com/agent-substrate/substrate.git upstream/substrate
$ git -C upstream/substrate checkout 672533541dbfcd29084e4de2475267088bda3651
```

That is the commit `ax` depends on, and the gate enforces it:
`upstream/google-ax/go.mod:7` pins
`github.com/agent-substrate/substrate v0.0.0-20260911232748-672533541dbf`, and
**neither repo documents compatibility across that boundary** — there is no
compatibility statement anywhere, so do not use `main`. Leave the clone
pristine; nothing in this lab writes to it.

Then the rest, which is all upstream's own supported path.
`scripts/substrate-up.sh` is a thin, idempotent wrapper around exactly these:

```console
$ cd upstream/substrate
$ KIND_CLUSTER_NAME=ax-lab KOCACHE=~/.cache/ko ./hack/create-kind-cluster.sh
$ KIND_CLUSTER_NAME=ax-lab KOCACHE=~/.cache/ko ./hack/install-ate-kind.sh \
      --deploy-ate-system --deploy-demo-counter
$ go install ./cmd/kubectl-ate
```

Why those flags, and why the cluster is named `ax-lab`:

- `hack/create-kind-cluster.sh:20` reads `KIND_CLUSTER_NAME` (default `kind`)
  and derives the context at `:21`. Override it rather than renaming later.
- `hack/install-ate-kind.sh:28` sets `KO_DOCKER_REPO=localhost:5001`,
  `:32` `ATE_INSTALL_KIND=true`, `:34` `BUCKET_NAME=ate-snapshots`, and
  `:39-40` targets `KIND_CLUSTER_NAME` → `KUBECTL_CONTEXT=kind-<name>`.
- `create-kind-cluster.sh:88-126` writes the kind config: the
  `ClusterTrustBundle` / `ClusterTrustBundleProjection` / `PodCertificateRequest`
  feature gates (`:107-110`) plus `serializeImagePulls: false` (`:121-125`),
  because the install pulls ~570MB of third-party images onto the one node.
- The gVisor asset is **not** pre-baked. `atelet` fetches it at runtime from a
  public GCS URL named in `manifests/ate-install/sandboxconfig-gvisor.yaml:34`
  (`gs://gvisor/releases/nightly/2026-09-02/x86_64/gvisor.tar.zstd`) and
  pre-warms it — see check 7 below.
- Micro-VM (kata) support is optional. `create-kind-cluster.sh:80` probes
  `/dev/kvm` and only wires it up if present; gVisor is the path we want anyway.

Confirmed on the node:

```console
$ docker exec ax-lab-control-plane grep -A4 featureGates /var/lib/kubelet/config.yaml
featureGates:
  ClusterTrustBundle: true
  ClusterTrustBundleProjection: true
  PodCertificateRequest: true
```

**Safety.** `kind create cluster` switches the ambient kubectl context as a side
effect. This machine also runs a real minikube profile, so both new scripts save
`current-context` on entry and restore it on exit (including on failure), and
pass `--context kind-ax-lab` explicitly everywhere instead of trusting the
ambient one. `scripts/substrate-down.sh` deletes only the kind cluster **by
name**, never `minikube`, and removes the registry container only if it carries
the `created-by=agent-substrate` label from `create-kind-cluster.sh:65`.

**One thing this lab is *not* contained to: your kernel.** `substrate-up.sh`
raises two host-global inotify sysctls, because `atenet-router` cannot start
without them. It prints the before/after values when it does, and
`AXLAB_RESTORE_INOTIFY=1 scripts/substrate-down.sh` puts them back — opt-in,
deliberately. Read [The one real gotcha](#the-one-real-gotcha-inotify) before
running it; it is the only step in this lab that reaches outside the cluster.

## Health checks, and their real output

`scripts/substrate-verify.sh` runs the seven checks below and exits non-zero on
any failure. Unlike `scripts/verify-all.sh` it **requires** the cluster, so it is
deliberately *not* wired into `verify-all.sh` — that script's contract is
"no cluster required".

Full run: **8 assertions across 7 checks, exit 0.**

**1 — the `ax` gate.** `svc/api` exists (output above).

**2 — Substrate's own version check.** The versioned DaemonSet name and the
label agree:

```console
$ kubectl get ds -n ate-system -l app=atelet -L ate.dev/substrate-version
NAME              DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR                        AGE   SUBSTRATE-VERSION
atelet-67253354   1         1         1       1            1           ate.dev/substrate-version=67253354   22m   67253354
```

The DaemonSet is named `atelet-<short-sha>` and selects on
`ate.dev/substrate-version=<short-sha>`; both are the pinned `67253354`. A
version mismatch is a scheduling failure, not a warning — see
`hack/install-ate.sh:304` (`label_nodes_substrate_version`).

That label is only *self-consistency* though — it says the DaemonSet agrees with
the tree it was built from, not that the tree is the commit `ax` depends on. So
check 2 also reads the pin out of `ax`'s own `go.mod` and compares it to the
checkout:

```console
    PASS  substrate checkout 672533541dbf is the commit ax pins (ax/go.mod)
```

Point a reader on `substrate@main` and this fails (verified with a doctored
`go.mod`: `FAIL substrate checkout is 672533541dbf but ax pins deadbeefcafe`),
rather than warning and handing out a green gate for a tree nobody validated.

**3 — the cert publisher everything else depends on.**

```console
$ kubectl get clustertrustbundles -A
NAME                                                            SIGNERNAME
kubernetes.io:kube-apiserver-serving:9bab42a567625f357c823e0b   kubernetes.io:kube-apiserver-serving
podidentity.podcert.ate.dev:identity:primary-bundle             podidentity.podcert.ate.dev/identity
servicedns.podcert.ate.dev:identity:primary-bundle              servicedns.podcert.ate.dev/identity

$ kubectl get pods -n podcertificate-controller-system
NAME                                       READY   STATUS    RESTARTS   AGE
podcertificate-controller-dbdf5987-mkrmx   1/1     Running   0          23m
```

These two `primary-bundle` entries are why mTLS works at all: `podidentity` is
the client identity every Substrate component presents, `servicedns` is the
serving identity. You can see them in use later — the ate-api-server log shows
`principal: spiffe://cluster.local/ns/ate-system/sa/atenet-router`.

**4 — CRDs.**

```console
$ kubectl get crd workerpools.ate.dev sandboxconfigs.ate.dev
NAME                     SCOPE        VERSIONS            CREATED AT
workerpools.ate.dev      Namespaced   v1alpha1(storage)   2026-09-27T15:52:13Z
sandboxconfigs.ate.dev   Cluster      v1alpha1(storage)   2026-09-27T15:52:13Z
```

Note the scope asymmetry: pools are namespaced, sandbox configs are not.

**7 — `atelet` pre-warmed the gVisor asset, and nothing is crash-looping.**

```console
$ kubectl logs -n ate-system -l app=atelet | grep -i prewarm
{"time":"2026-09-27T15:54:16.244921898Z","level":"INFO","msg":"Sandbox asset prewarm started","microvmCapable":true}
{"time":"2026-09-27T15:54:57.187028212Z","level":"INFO","msg":"Sandbox assets prewarmed","config":"gvisor-default","assets":1,"pauseImage":"registry.k8s.io/pause:3.10.2@sha256:f548e0e8e3dc1896ca956272154dde3314e8cc4fde0a57577ee9fa1c63f5baf4","duration":16288511427}
```

`assets=1` is the `gvisor.tar.zstd` above; `duration` is 16.3s. Emitted by
`cmd/atelet/sandbox_prewarm.go:137` and `:281`. The cache lands in
`/var/lib/ateom-gvisor` on the node — **327M** after one asset.

The gate asserts the `gvisor` part rather than just the prewarm. `"Sandbox
assets prewarmed"` contains no `gvisor`, so a grep for that string alone would
have passed on a microvm-only prewarm; the discriminator is the config name on
the same line, and a restore line naming the sandbox class corroborates it:

```console
    PASS  atelet prewarmed a gVisor sandbox config (SandboxConfig gvisor-default)
    PASS  atelet restored an actor on the gvisor sandbox class
    PASS  no crash-looping pods
```

**The gate is honest about what it did not run.** `AXLAB_SKIP_MUTATE=1` skips
checks 5 and 6, so it counts them and refuses to claim a full pass:

```console
$ AXLAB_SKIP_MUTATE=1 ./scripts/substrate-verify.sh
==> Summary
    passed:  8
    failed:  0
    skipped: 2

PARTIAL  2 check(s) skipped, so this is not a full pass:
  - 5/7 create + drive a real gVisor actor
  - 6/7 suspend and resume it with state intact
$ echo $?
3
```

Exit `3` is distinct from `1` (a real failure) so a caller can tell "partial"
from "broken". A full run is `passed: 10  failed: 0  skipped: 0`, exit `0`.

## The walkthrough: a real actor, suspended and resumed

### Create it

```console
$ kubectl ate create actor my-counter-1 -a ate-demo-counter --template counter
ATESPACE           NAME           TEMPLATE                   STATE                   WORKER POD   WORKER IP   VERSION   AGE
ate-demo-counter   my-counter-1   ate-demo-counter/counter   ACTOR_STATE_SUSPENDED   <none>                   1         0s
```

It is born **suspended**, from the template's golden snapshot. The golden was
built at install time — `hack/install-ate.sh:1249` (`create_demo_actor_template`)
blocks on it, because an `ActorTemplate` is immutable and its golden is what
every later actor starts from.

### Drive it

The router resolves the `ate-target-actor` header
(`internal/atenet/headers.go:29`) to an actor:

```console
$ kubectl port-forward -n ate-system svc/atenet-router 8000:80 &
$ for i in 1 2 3; do
    curl -sS -X POST -H "ate-target-actor: ate-demo-counter/my-counter-1" \
      http://localhost:8000
  done
hello from: 169.254.17.2 | preserved memory count: 1 | preserved file counter: 1
hello from: 169.254.17.2 | preserved memory count: 2 | preserved file counter: 2
hello from: 169.254.17.2 | preserved memory count: 3 | preserved file counter: 3
```

Two counters, and the difference matters. `demos/counter/counter.go:91-92`
increments a file in the `durableDir` **and** an `atomic.Int64` in process
memory; `:115` prints both. The memory count is the interesting one — it can
only survive if process memory was captured.

The first call took **0.14s** including the resume, because the router resumes
on demand: `cmd/atenet/internal/router/ingress/ingress.go:118-119` calls
`ResumeActor` on *every* request. You do not resume actors yourself.

### Suspend

```console
$ kubectl ate get actor -a ate-demo-counter
ATESPACE           NAME           TEMPLATE                   STATE                 WORKER POD                                  WORKER IP     VERSION   AGE
ate-demo-counter   my-counter-1   ate-demo-counter/counter   ACTOR_STATE_RUNNING   ate-demo-counter/counter-7dd86bcc6c-rfzdl   10.244.0.22   3         4m2s

$ kubectl ate suspend actor my-counter-1 -a ate-demo-counter
ATESPACE           NAME           TEMPLATE                   STATE                   WORKER POD   WORKER IP   VERSION   AGE
ate-demo-counter   my-counter-1   ate-demo-counter/counter   ACTOR_STATE_SUSPENDED   <none>                   5         0s
```

0.3s, and the worker is released. The workflow is
`cmd/ateapi/internal/controlapi/workflow_suspend.go:41`: take a lease, mark
suspending, checkpoint on the worker, detach volumes, finalize. The final step
clears the `WorkerAssignment`, which is why the pod column goes `<none>`.

What actually hit rustfs (from `atelet`'s log) — four objects, and note
`checkpoint.img.zstd`, which is the process memory:

```console
{"msg":"Compressed zstd upload","object":".../snapshots/2b1fdd6b-.../durable-dir.tar.zstd","logical_bytes":2560,"total":5505534}
{"msg":"Compressed zstd upload","object":".../snapshots/2b1fdd6b-.../pages_meta.img.zstd","logical_bytes":3482,"total":5791808}
{"msg":"Compressed zstd upload","object":".../snapshots/2b1fdd6b-.../checkpoint.img.zstd","logical_bytes":273968,"total":6815464}
{"msg":"Compressed zstd upload","object":".../snapshots/2b1fdd6b-.../pages.img.zstd","logical_bytes":6262784,"total":22974622}
{"msg":"Handle RPC","method":"/atelet.AteomHerder/Checkpoint","req":{...,"scope":1,...},"elapsed-time":"120.870107ms"}
```

and the actor carries the pointer:

```console
$ kubectl ate get actor my-counter-1 -a ate-demo-counter -o yaml | grep snapshotUri
    snapshotUri: gs://ate-snapshots/ate-demo-counter/atespaces/ate-demo-counter/actors/a5c50cfe-.../snapshots/f5b710a5-...
    contentScope: SNAPSHOT_CONTENT_SCOPE_FULL
```

`scope: 1` is `SNAPSHOT_CONTENT_SCOPE_FULL`, set by the template at
`demos/counter/counter-template.yaml.tmpl:57` (`onPause`) and `:63` (`onCommit`).
**This is the whole reason the tutorial counter survives.** The template comment
at `:58-62` says so outright. With `DATA` scope only the durable volumes would
be captured and the memory count would reset.

### Resume

Just hit it again — the router resumes on demand:

```console
$ curl -sS -X POST -H "ate-target-actor: ate-demo-counter/my-counter-1" http://localhost:8000
hello from: 169.254.17.2 | preserved memory count: 4 | preserved file counter: 4
```

`3 → 4`. The in-process counter continued, so a full snapshot round-tripped
through rustfs and back. `atelet` logged the restore:

```console
{"msg":"Restore timing breakdown","ate.actor.name":"my-counter-1","ate.snapshot.scope":"full",
 "ate.snapshot.kind":"latest","ate.sandbox.class":"gvisor",
 "ate.actor.restore.duration.download":0.008258341,"ate.actor.restore.duration.ateom_restore":0.124902296,
 "ate.actor.restore.duration.total":0.139869125}
```

**It can land on a different worker.** On the `substrate-verify.sh` run:

```
worker before suspend: ate-demo-counter/counter-7dd86bcc6c-rfzdl
worker after resume:   ate-demo-counter/counter-7dd86bcc6c-lvsks
resumed onto a DIFFERENT worker
```

with the counter still incrementing 3 → 4. The pool has 3 replicas, so this is
scheduling, not luck. When it does *not* move, that is the fast path: the
node-local snapshot was still on the node it was taken on. (The `169.254.17.2` in
the response is the gVisor sandbox's own IP, not the worker Pod's, so it does
not change when the worker does.)

## The one real gotcha: inotify

If you do nothing else from this page, take this.

On a busy host, **`atenet-router` crash-loops and every actor request fails.**
It is not an `ax` problem, not a Substrate bug, and not an Envoy bug. It is the
host's inotify limit.

`atenet-router`'s Envoy watches the podcertcontroller-issued credential bundles
as *files* over SDS. Creating that watcher calls `inotify_init()`, and the
inotify limits are **host-global and not namespaced** — a kind node inherits
whatever the host has set, and Envoy runs as **uid 0**, so its instances are
charged against the root bucket. This host ships
`fs.inotify.max_user_instances=128`, and Envoy's watcher init fails:

```
[2026-09-27 16:08:36.287][1][critical][assert] [source/common/filesystem/inotify/watcher_impl.cc:25] assert failure: inotify_fd_ >= 0. Details: Consider increasing value of fs.inotify.max_user_watches and/or fs.inotify.max_user_instances via sysctl
```

That line is **captured, not remembered** — the full excerpt, with the SDS
`initial fetch timed out` that precedes it, is in
[`docs/evidence/atenet-router-inotify-assert.log`](evidence/atenet-router-inotify-assert.log).
It comes from the Envoy 1.38.4 A/B run (below), which prints the assertion
plainly; the pinned 1.39.1 build instead let its crash handler segfault over
the message.

**Which knob, and why.** The assert names *both* `max_user_watches` and
`max_user_instances`, so which one mattered is not obvious from the text. Read
the asserted expression instead: `inotify_fd_` is the file descriptor returned
by **`inotify_init()`**. The failing call is therefore the *init* — the
**instance** quota. The watch quota is a different failure: `inotify_add_watch`
returns `ENOSPC` when you are out of watches, and there is no `inotify_fd_` to
assert on. So raising `max_user_watches` alone would not have fixed this.
`substrate-up.sh` raises both anyway, because both are cheap and the watch quota
is the one you hit later.

**On attribution.** `fs.inotify.max_user_instances` is charged **per-UID**.
Envoy's container has no `securityContext.runAsUser` and no `User` in the image
config, and the process confirms it:

```console
$ kubectl exec -n ate-system <router-pod> -c envoy -- cat /proc/1/status | grep Uid
Uid:	0	0	0	0
```

So its instances come out of the **root** bucket, alongside the other root-run
containers on this machine. Your desktop session is uid 1000 — a different
bucket entirely, and it cannot have contributed. A non-root process can only
count its own bucket anyway: scanning `/proc` as uid 1000 here reports 73
instances, all of them this user's own session, and the root-run containers are
invisible because they live in other PID namespaces. Any total you quote from an
unprivileged scan is meaningless for this assert. The load-bearing evidence is
the assertion itself plus the A/B test below, not a process count.

What makes this expensive to diagnose is the symptom under the pinned build.
Envoy 1.39.1 is
`envoyproxy/envoy:v1.39-latest@sha256:57e14a549d7bd43c8d3f6d03e8cfa653e037d4b38e133acd9b54f38c524401b4`
(confirmed from the running container:

```console
$ kubectl exec -n ate-system <router-pod> -c envoy -- /usr/local/bin/envoy --version
/usr/local/bin/envoy  version: b579d07d3ad7ee11d32b105e91a5a39ad24718d7/1.39.1/Clean/RELEASE/BoringSSL
```

) and it surfaces as `exit 139` with a backtrace full of `Dumping
corresponding downstream request for upstream stream 1`, which reads like a
segfault in the xDS/SDS path.

> ⚠ **That `exit 139` / `Dumping corresponding…` log is a reconstruction from
> memory, not a captured artifact.** The container has had 0 restarts since the
> limits were raised, so `kubectl logs --previous` no longer has it and it cannot
> be re-derived now. I am labelling it rather than pasting it as if it were
> evidence. The *assertion* above is captured; the crash-handler dump that hid
> it is not.

What the dump actually was: Envoy's *fatal-action crash handler* re-crashing
while dumping connection state, which **masks** the assertion that killed it.
Two things I tried first, both of which pointed the wrong way:

- Suspecting `upstream:debug` in the log level (that dump looks like a debug
  log) — no effect, and no wonder: it is the crash handler.
- Swapping Envoy 1.39.1 → 1.38.4 to test for a version regression. It aborted on
  the *same* assertion, which is what finally exposed it — and because 1.38.4
  prints the assert before its own handler runs, it also produced the captured
  evidence above.

Fix, the same way `hack/create-kind-cluster.sh:180` fixes `proxy_arp`:

```console
$ docker exec ax-lab-control-plane sysctl -w fs.inotify.max_user_instances=8192
fs.inotify.max_user_instances = 8192
$ docker exec ax-lab-control-plane sysctl -w fs.inotify.max_user_watches=524288
fs.inotify.max_user_watches = 524288
```

With it set, the pinned Envoy 1.39.1 ran 2 minutes with **0 restarts**, and the
tree is back to upstream's pinned manifests with no substitutions.
`scripts/substrate-up.sh` applies this on every run and prints the host's
before/after values while it does:

```console
    HOST KERNEL  fs.inotify.max_user_instances 128 -> 8192
    HOST KERNEL  fs.inotify.max_user_watches   65536 -> 524288
```

> ### ⚠ This changes your machine, not just the lab
>
> The `docker exec` above is **not** contained to the kind node. `/proc/sys/fs/inotify/*`
> is not namespaced and the kind node container runs in the host user namespace
> (`UsernsMode=""`), so that write lands on the **host** and applies to every
> process on it. Verified directly: writing `9000` from inside the node, the host
> immediately read `9000`.
>
> So after `scripts/substrate-up.sh` your machine is left with
> `max_user_instances=8192` / `max_user_watches=524288`, and deleting the cluster
> does **not** put them back. The limits are runtime state, so a reboot clears
> them, but nothing in a normal teardown does.
>
> **This is a deliberate, opt-out-able trade.** The alternative is a lab that
> cannot start: with the host's `128`, the data plane never comes up and no actor
> is reachable at all. But it is a host-wide change and you should know you made
> it.
>
> To put the host back:
>
> ```console
> $ AXLAB_RESTORE_INOTIFY=1 scripts/substrate-down.sh
> ```
>
> That is **opt-in on purpose.** If something else on your machine has
> legitimately raised these limits, an automatic restore on teardown would break
> *that* workload. Leaving a higher limit is harmless; lowering it underneath
> someone else is not. Pass `AXLAB_RESTORE_INOTIFY="128 65536"` to be explicit,
> and `AXLAB_DRY_RUN=1` to see what it would do first.
>
> The defaults it restores to, and where they come from:
>
> | value | why |
> |---|---|
> | `max_user_instances = 128` | the in-kernel default; no sysctl file on this host sets it (checked `/etc/sysctl.d/`, `/etc/sysctl.conf`, `/usr/lib/sysctl.d/`) |
> | `max_user_watches = 65536` | set deliberately by this distribution: `/usr/lib/sysctl.d/30-localsearch.conf` |
>
> One nuance worth knowing: restoring while the cluster is up is safe. Envoy
> calls `inotify_init()` once at startup, so an already-running `atenet-router`
> keeps working at `128` (verified: all 7 checks pass, 0 restarts). But a
> *restarted* router will crash again, so re-run `scripts/substrate-up.sh` after
> any router restart.

`atenet-egress` never hit this: same Envoy build, but it does not consume the
podcert SDS bundles unless you pass
`hack/experimental-additional-egress-extproc.sh`.

## Where upstream's docs are stale

Two, both verified against this pinned tree.

**S3 is listed as future work, but it ships and the kind install uses it.**
`docs/roadmap.md:54` lists "Support for S3 (via plugin)" under `### Storage`
alongside "incremental snapshots" and "ConfigMaps as volumes". But
`internal/objectstore/s3.go:52` implements `NewS3` against the AWS SDK, and the
kind overlay selects it: `manifests/ate-install/kind/kustomization.yaml:60`
sets `ATE_STORAGE_BACKEND: s3` for the API server and
`manifests/ate-install/kind/atelet/kustomization.yaml:46` does the same for
`atelet`. That is why the snapshots above land in `gs://ate-snapshots/...` and
why **no GCP credentials were needed** — `gs://` is just the URI scheme. The
endpoint is set at `manifests/ate-install/kind/kustomization.yaml:64-65`
(`AWS_ENDPOINT_URL: http://rustfs.ate-system.svc:9000`), and the Service it
points at is defined at `manifests/ate-install/kind/rustfs.yaml:28-37`
(`kind: Service`, `name: rustfs`, `port: 9000`). The roadmap is stale; the
`gs://` in the URI is a deliberate abstraction, not a signal that you need GCS.

**`create-kind-cluster.sh`'s `/dev/kvm` probe is weaker than it looks.**
`:78-85` decides micro-VM support with
`docker run --rm --device /dev/kvm busybox true`. On this host that probe
succeeded **correctly** — the device is real and working:

```console
$ ls -la /dev/kvm
crw-rw-rw-+ 1 root input 10, 232 /dev/kvm
$ ls -d /sys/module/kvm /sys/module/kvm_intel
/sys/module/kvm  /sys/module/kvm_intel
$ python3 -c "import os,fcntl; fd=os.open('/dev/kvm', os.O_RDWR); print(fcntl.ioctl(fd, 0xAE00, 0))"
12
```

so the script's "micro-VM support will be enabled" was accurate. (An earlier
draft of this page claimed the probe false-positived because `/dev/kvm` was
absent. That was wrong; the file, the modules and `KVM_GET_API_VERSION` are all
there.)

The real, narrower weakness: the probe only proves the daemon will
**bind-mount** the path. It never `open()`s the device and never checks for
`kvm_intel`, so on a host with a stale `/dev/kvm` node — present in `/dev` but
not backed by a working module — it would still report micro-VM as enabled, and
the bind-mount at `:94-102` would succeed while every micro-VM worker later
failed. Treat "micro-VM support will be enabled" as "the device node exists",
nothing stronger. We did not exercise the micro-VM path: gVisor is what this
phase needs and `--deploy-demo-counter-microvm` was never run.

## Teardown

```console
$ scripts/substrate-down.sh
```

Deletes the `ax-lab` kind cluster by name, drops the `kind-<name>` kubeconfig
context, removes the registry container **only** if it carries
`created-by=agent-substrate`, and prints the minikube namespace set before and
after so you can see it did not move. `AXLAB_KEEP_REGISTRY=1` keeps the registry.

Rehearse it first — `AXLAB_DRY_RUN=1` covers **every** destructive step (the
cluster delete, the kubeconfig context, the registry removal, and the inotify
restore), not just the sysctl:

```console
$ AXLAB_DRY_RUN=1 AXLAB_RESTORE_INOTIFY=1 scripts/substrate-down.sh
==> Deleting kind cluster 'ax-lab'
    DRY RUN  would run: kind delete cluster --name ax-lab
    DRY RUN  would remove kubeconfig context kind-ax-lab
==> Registry 'kind-registry' on port 5001
    DRY RUN  would remove kind-registry (it carries created-by=agent-substrate)
```

and the cluster, the registry and the context are all still there afterwards.
That is worth smoke-testing rather than assuming: the first version of this
script honoured `AXLAB_DRY_RUN` *only* inside the inotify restore, so control
fell straight through into a real delete and a real `docker rm -f`.

The registry guard is a real check, not decoration — it reads the label key
`created-by`, because docker stores `--label created-by=agent-substrate` as
`{"created-by":"agent-substrate"}`:

```console
$ docker inspect -f '{{index .Config.Labels "created-by"}}' kind-registry
agent-substrate
$ docker inspect -f '{{index .Config.Labels "created-by=agent-substrate"}}' kind-registry
                                     # empty -- the composite string is not a key
```

An earlier version indexed that composite string, so the guard never matched: it
under-deleted (safe) but leaked the registry and every image in it on every run.
A container *without* the label is still refused, verified against decoys.

## Phase 2 files

| File | What it is |
|---|---|
| `scripts/substrate-up.sh` | idempotent bring-up + health summary. **Raises host-global inotify sysctls** (see the gotcha below) |
| `scripts/substrate-down.sh` | teardown, scoped to this lab only. `AXLAB_RESTORE_INOTIFY=1` also puts the host inotify limits back |
| `scripts/substrate-verify.sh` | the 7 checks; **needs** the cluster, so not in `verify-all.sh` |

`substrate-verify.sh` is self-contained: it does not assume
`$(go env GOPATH)/bin` is on your `PATH`. It resolves `kubectl-ate` itself —
`AXLAB_KUBECTL_ATE_BIN`, then `$(go env GOBIN||GOPATH)/bin`, then `PATH` — and
calls it by absolute path, so a gate cannot report a false pass or a false
failure depending on whose shell you are in. It also never changes the ambient
context. Verified in a stripped environment:

```console
$ env -i HOME="$HOME" PATH=/snap/bin:/usr/bin:/bin:/home/linuxbrew/.linuxbrew/bin \
    KUBECONFIG="$HOME/.kube/config" ./scripts/substrate-verify.sh
    kubectl-ate: /home/hung1/go/bin/kubectl-ate
    ...
    passed: 8
    failed: 0
all checks passed
```

(`$HOME/go/bin` is deliberately absent from that `PATH`; the resolver finds the
binary via `go env GOBIN` anyway.)

Next: the live track — deploy `ax`'s control plane against this Substrate and
put a real task through the round trip.
