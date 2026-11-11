# ax-lab — learn Google's `ax` by running it

A hands-on track for [github.com/google/ax](https://github.com/google/ax): a declarative,
Kubernetes-native orchestrator for running autonomous agent workloads. Every lesson here is a
program or manifest you **run**, not a summary of the docs.

Upstream ships only two example YAML files, and both are unrunnable as published (see
[Things that will bite you](#things-that-will-bite-you)). So this track builds its own examples
against the real source, and drives the real binaries.

## What ax actually is

You declare what you want in YAML. A control plane reconciles it and runs each task as an
isolated sandbox on [Agent Substrate](https://github.com/agent-substrate/substrate).

```
ax CLI ──gRPC──> ax-server ──> Redis <── ax-controller ── Agent Substrate ──> ax-task-runner (PID 1)
```

Three primitives, all `ax.io/v1alpha1`:

| Kind | What it is |
|---|---|
| `Task` | one sandboxed agent run — image, command, env, resources, workspaces |
| `Workspace` | the pre-wired starting state: git repos, MCP servers, skill packages |
| `Model` | which LLM the platform uses, with credentials from a Kubernetes secret |

Two design decisions worth knowing before you read any code:

- **State lives in Redis, not in CRDs.** `DESIGN.md` is explicit: millions of short-lived tasks as
  Kubernetes objects would push etcd past its storage and write-rate limits. Redis Streams is the
  work queue between the API server and a horizontally scaled pool of controllers. This is why the
  `ax` CLI speaks gRPC to `ax-server` instead of talking to the Kubernetes API.
- **The CLI is deliberately kubectl-shaped** — `apply`, `get`, `describe`, `watch`, `delete`, plus
  `suspend` / `resume` / `ssh`. If Kubernetes feels familiar, ax mostly will.

## Quick start

```bash
./scripts/setup.sh        # clone ax if needed, build the binaries, smoke-check them
./scripts/verify-all.sh   # run every lesson, print PASS/FAIL, exit non-zero on any failure
./examples/01-schema/run.sh   # or run one lesson on its own
```

No cluster, no Kubernetes, no API keys, no root. Each lesson is self-contained, runs from any
working directory, and is safe to re-run.

### Gate options

`verify-all.sh` exits `0` only if every discovered lesson passed *and* printed its own
`PASS: <id>` line — a lesson that crashes before reaching a verdict cannot pass. Exit `1` means a
failure, exit `2` a harness problem.

| Variable | Effect |
|---|---|
| `AXLAB_REQUIRE_LESSONS="01 02 03 04 05"` | Treat a **missing** lesson as a failure. Unset by default so an in-progress track still passes; **set it in CI**, otherwise a deleted lesson directory yields `PASS (partial)` with exit `0`. |
| `AXLAB_LESSON_TIMEOUT=300` | Seconds per lesson. |
| `AXLAB_KEEP_RUNNING=1` | Skip the pre-run cleanup of leftover processes. |
| `AXLAB_CONTAINERS=0` | Never touch containers at all. |
| `AXLAB_REAP_RUNNING_CONTAINERS=1` | Also remove *running* lab containers, not just stopped ones. Off by default so it can never kill a container another lesson is using. |

A failing run leaves its own logs in `.work/verify-all/` and rotates the previous run's logs to
`.work/prev-verify-all/`, so a failure never destroys the last known-good evidence.

## The lessons

Read them in order; each one earns the next.

| # | Question it answers |
|---|---|
| [01-schema](docs/01-schema.md) | What is the actual data model? (It's a protobuf — `ax.proto` is the whole schema in 318 lines.) |
| [02-validation](docs/02-validation.md) | What does ax refuse to accept, and with what error? |
| [03-apiserver-store](docs/03-apiserver-store.md) | Where does state really live, and what survives an API-server restart? |
| [04-task-lifecycle](docs/04-task-lifecycle.md) | Why is my task doing nothing? (Phases, conditions, and the immutability rule.) |
| [05-runner-sandbox](docs/05-runner-sandbox.md) | What happens *inside* a task container, and why does the runner outlive your command? |

## Things that will bite you

Each of these is demonstrated in the lessons, with a control that must fail — not just described.

- **A new task is `Suspended`, not running.** You must `ax resume task <name>`. The README's own
  quickstart omits this step, so "nothing happens" is the default first experience.
- **`Task` is immutable; `Workspace` and `Model` are not.** Re-applying a changed `Task` fails with
  `FailedPrecondition` — and the check is on *existence*, not on a diff. There is also no
  `UpdateTask` RPC at all, so the only way to change a task is to delete and recreate it.
- **YAML decoding is strict.** One typo'd field and `ax apply` fails outright.
- **The runner stays alive as PID 1 after your command exits.** That is deliberate: it is what keeps
  `ax ssh` usable after the work is done. It also means a finished task still holds its sandbox.
- **`spec.command` runs against the host when you run `ax-task-runner` directly** — not inside the
  image from `spec.image`. Lesson 05 is explicit about this so you are not misled when running
  outside a cluster.
- **Local gotcha:** the default workspace path `/workspace` is not writable as a non-root user, and
  because that path is the command's working directory, the failure is fatal rather than a delay.
- **Latent, not live:** ax's model client *can* fabricate a confident, plausible answer with fake
  token counts instead of erroring (on an empty key or an HTTP 401/403/429/503). But the only
  non-test caller of that code path is `PlanEnvironment`, which nothing calls — so no shipped
  binary reaches it today. Lesson 04 proves that with the call graph rather than pretending to
  demonstrate a live run. Worth knowing if you ever wire the model client up yourself.

## What Phase 1 does *not* cover

Stated in one place so you don't go looking for it:

- **The controller.** Nothing here reconciles a Task into a running actor — that is
  `ax-controller`, and it needs Agent Substrate. That is Phase 3.
- **Real sandboxing.** Phase 1 runs the task runner as a normal host process. It is not a gVisor
  sandbox, and `spec.image` is never used. See lesson 05's "PROVEN NOT A CONTAINER" assertions.
- **`ax ssh`.** The guest gRPC services need a live sandbox to talk to.
- **Model calls.** No lesson calls an LLM, and none can: the code path that would reach the model
  client is dead (see the fabrication note above). You will need a real key and a code change.
- **Workspace setup that actually persists.** The maiden-run marker directory is not writable
  outside a sandbox, so setup re-runs on every boot locally.

## Repo layout

```
ax-lab/
  examples/       one directory per lesson: run.sh + sources
  docs/           one short page per lesson
  scripts/        setup.sh, verify-all.sh, shared harness
  testdata/       Go probes compiled into the upstream module (internal/ is not importable)
  upstream/       read-only clones: google/ax, agent-substrate/substrate
  go.mod          module axlab, with a replace -> ./upstream/google-ax
```

The `replace` directive points at the local clone on purpose: examples build against the real
source, and IDE go-to-definition lands in ax's actual code instead of a copy that can drift.

## Live cluster track

Phase 1 above needs no cluster and covers most of ax's logic. The remaining phases stand up a real
sandbox and are built on a **separate kind cluster**, so nothing here touches your existing
minikube cluster or its projects.

- [x] **Phase 1** — schema, validation, store, API server, CLI, runner (no cluster).
- [x] **Phase 2** — Agent Substrate on kind, with a real gVisor actor that can be suspended and resumed.
      → `docs/06-substrate-on-kind.md`; `scripts/substrate-{up,down,verify}.sh`.
      Cluster `kind-ax-lab`, registry on 5001. Verify needs the cluster, so it is
      deliberately *not* part of `verify-all.sh`.

      > **Phase 2 changes one thing outside the cluster, read this before running it.**
      > `substrate-up.sh` raises two **host-global** kernel sysctls,
      > `fs.inotify.max_user_instances` and `fs.inotify.max_user_watches` (128→8192 and
      > 65536→524288 here). The write goes through the kind node, but
      > `/proc/sys/fs/inotify/*` is not namespaced, so it lands on the **host** and
      > affects every process on it. It is not undone by `substrate-down.sh`; pass
      > `AXLAB_RESTORE_INOTIFY=1` to put it back. The reason is in the gotcha section of
      > the page: without it `atenet-router` cannot start and no actor is reachable.
      > `upstream/substrate` is also not cloned by `setup.sh` — the page's step 0 has
      > the pinned `git clone` + `git checkout 672533541dbf…`.

- [x] **Phase 3** — ax's own control plane on that cluster, driving a real `Task` to a running actor.
      → `docs/07-ax-control-plane.md`; `scripts/ax-{up,verify,down}.sh`.
      Namespace `ax-system`, images in the same local registry. Needs Phase 2 up. Verify needs
      the cluster, so it is deliberately *not* part of `verify-all.sh`.
      `make deploy` **cannot run as shipped**; three undocumented gaps are the work of this
      phase: ax's task image is private (401/403), ax never creates a Substrate `WorkerPool`
      (so nothing schedules), and the snapshot bucket points at a private GCS path. The page
      also covers a fourth: the per-task `ActorTemplate` is immutable, so a Workspace applied
      after the Task is silently never delivered — while still reporting `WorkspaceReady=True`.

      > **Phase 3 runs on the Phase 2 host-kernel change and does not add another one.**
      > It needs `fs.inotify.max_user_instances` raised (at 128, `atenet-router` crash-loops on
      > restart, and Phase 3 restarts pods), so `ax-up.sh` warns and points at
      > `substrate-up.sh` rather than writing the sysctl itself. **The host is currently left at
      > `8192`/`524288` while the lab is up** — restore with
      > `AXLAB_RESTORE_INOTIFY=1 scripts/substrate-down.sh`. Two other side effects the page
      > discloses: `ax-up.sh` writes `bin/linux_amd64/` into the read-only ax clone (gitignored,
      > so the clone stays pristine), and the `ax` CLI auto-starts a background port-forward on
      > an ephemeral high port, which `ax-down.sh` stops.

- [ ] **Phase 4** — stretch: a genuinely sandboxed task you can `ax ssh` into. Mostly delivered in
      Phase 3 already: `ax ssh` runs in a real gVisor sandbox there
      (`uname` → `Linux 4.19.0-gvisor`). Phase 4 makes it the exercise rather than a check.

## Things that will bite you

Recorded as they were actually hit, not as a list of warnings:

- **ax's task image is private.** `gcr.io/ax-substrate/ate-images/ax-task-runner@sha256:3a0dea6a…`
  returns 401/403, so both shipped example manifests are unrunnable as shipped. Build your own
  (`make build-task-runner`) and push it somewhere you control.
- **ax never creates a Substrate `WorkerPool`.** `grep -rni workerpool --include='*.go'` over the ax
  Go sources returns zero hits. With no pool of your own there are no worker pods and every task
  stays unschedulable forever. Worse, the template carries no `workerSelector`, so placement is
  *random across the whole fleet* — your task can land on another pool's worker.
- **The snapshot bucket is a private GCS path** (`AX_SNAPSHOTS_BUCKET`, and
  `internal/substrate/client.go:208`). On the kind path storage is in-cluster rustfs over S3, so
  every suspend/resume fails until you repoint it.
- **`WorkspaceReady` is a liveness signal, not a correctness one.** `SetupWorkspace` returns an
  error on only one path (the mkdir), and a *failed git clone* returns nil — so ax reports
  `WorkspaceReady=True/SetupComplete` for a task whose workspace was never set up. Nothing in the
  status will tell you. Check the filesystem.
- **A success-shaped failure when the Workspace arrives late.** The per-task `ActorTemplate` bakes
  the Workspace spec into an env var. Apply the Task before the Workspace exists and you get a
  template with no `AX_WORKSPACES_YAML` — and a re-reconcile cannot repair it, because
  `taskTemplateName` mints a *new* template that is then orphaned: `EnsureActor` gets
  `AlreadyExists` and returns the existing actor, still bound to the old template. The actor has to
  be deleted first. Apply the Workspace before the Task.
- **`ko apply` does not take a kubectl context.** It uses the *ambient* one, so on a machine with
  two clusters it will try to apply into whatever `current-context` says. Pass `-- --context=…`
  after `--`, or use `ko resolve | kubectl apply --context`.
- **A gate that trusts `PATH` is a gate that lies.** Resolve every binary to an absolute path and
  test the gate from a clean `env -i`.

## Prerequisites for the cluster phases

- **`kubectl-ate` is required by both gates and no script installs it.** `substrate-verify.sh` and
  `ax-verify.sh` exit **2** without it rather than skipping the checks that need it. Install with
  `cd upstream/substrate && go install ./cmd/kubectl-ate` (`substrate-up.sh` does *not*).
- **Citations were verified against specific commits.** Substrate is pinned at `67253354` — the
  exact commit `ax/go.mod` depends on. The **ax** clone is a `--depth 1` clone of whatever `HEAD` was
  when it was made, here `d0bc38bc`; it is *not* pinned to a release. Line references in these
  pages are for those two revisions, so re-verify anything load-bearing if you re-clone ax.
- `shellcheck` (0.11.0) is the linter for these scripts; it is not installed on this host by
  default.

## Upstream is pre-1.0

The ax README warns that core concepts, protocols, and specs will break before a stable release.
Learn the model and the lifecycle here; don't build anything that assumes the YAML surface is
stable.
