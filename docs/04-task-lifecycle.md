# 04 — the task lifecycle, and the two traps

**Question.** I applied a task. Nothing happened. Also, re-applying my file
failed, and the model client confidently told me a plan I know it could not
have produced. What is going on?

**Run it.**

```sh
./examples/04-task-lifecycle/run.sh    # works from any cwd
```

Same harness as lesson 03: throwaway Redis, prebuilt `ax-server`, prebuilt
`ax` — both from `ax-lab/bin/`, the directory `scripts/setup.sh` installs into
and `scripts/verify-all.sh` checks — teardown on exit. **No `ax-controller`
runs**, on purpose — that is what makes "Suspended with no actor" legible
instead of ambiguous, and it is also why the conditions section below finds
none.

Ports default to 16390 / 18091 for the same reason as lesson 03; force the
brief's with `AXLAB_REDIS_PORT=16379 AXLAB_SERVER_ADDR=127.0.0.1:18081`.

---

## A new task does nothing until you resume it

`ax apply` prints `task.ax.io/lab-task created`, and then:

```
NAME       ATESPACE   PHASE       ACTOR    WORKER-IP   AGE
lab-task   default    Suspended   <none>   <none>      0s
```

`CreateTask` hardcodes `task.Status.Phase = "Suspended"` and stops there. It
never sets an actor or a worker IP — only the controller does, and the
controller is not running. So:

* `ax describe task` prints `Actor:` and `Worker IP:` as *empty lines*. The
  `<none>` you see in `ax get` is a table-only substitution
  (`cmd/ax/main.go:365-370`), which is worth knowing before you go looking for a
  bug.
* `timeout 6 ax watch task lab-task` prints the header and **exactly one**
  line, then nothing. The server sends the current state once as action
  `INITIAL` (`internal/server/server.go:232-236`) and then blocks on a Redis
  pub/sub channel. The script asserts the line count is 1, so if a future
  change started emitting heartbeats the lesson would fail rather than quietly
  mislead.
* `ax watch` is not a completion tool: it also exits as soon as the phase is
  `Running`, `Failed` or `Completed` (`cmd/ax/main.go:715-718`). It stops long
  before the task is done.
* `ax resume task lab-task` flips the phase to `Running` and nothing else
  (`internal/server/server.go:192-215`). The actor is still empty. **A task in
  `Running` with no actor is a stuck task, not a running one.**

## Conditions: the other half of `TaskStatus` — and why there are none

`TaskStatus.conditions` is field 7 (`pkg/apis/v1alpha1/ax.proto:112`), a
repeated `Condition{type, status, lastTransitionTime, reason, message}`
(`ax.proto:126-132`). ax defines exactly **two** condition types, and both
live in the controller: `Ready` and `WorkspaceReady`
(`internal/controller/reconciler.go:302-309`). Upstream's own README advertises
`ax watch task task123  # stream phase and condition changes live`
(`README.md:101`, `:137`), so it is fair to ask what a task actually carries.

The answer, demonstrated with the real CLI against the real `ax-server`:
**zero.**

* `ax describe task lab-task` prints no `Conditions:` block — and that is a
  real observation, not a display bug. `cmd/ax/main.go:658-666` renders the
  table only when `len(conditions) > 0`. The lesson asserts the block's
  *absence* with a `refute`, so if a condition ever appeared the lesson would
  fail rather than quietly keep claiming emptiness.
* The same fact from the store instead of the CLI: the stored value is decoded
  with `jq -e` (so "it is protojson" is a check, not prose), `.status.phase` is
  asserted to be `Running`, and `.status.conditions` is asserted to be
  `absent`. protojson omits an empty repeated field, so *absent* is the correct
  encoding of *zero conditions*.
* Why: `grep -rn 'Status\.Conditions' --include='*.go'` over the whole module,
  minus tests, hits exactly two files — `internal/controller/reconciler.go`
  (the writer) and `cmd/ax/main.go:630` (the describe table) — and the lesson
  **fails** if any third file ever appears. `ax-server` is not among them, so
  it cannot write a condition: `CreateTask` hardcodes `phase="Suspended"`
  (`server.go:141`) and `ResumeTask` only flips the phase. That is exactly why
  the table is still empty after the resume above.

Which conditions are reachable **without** a controller? None. Being precise
about each one:

| condition | set at | reachable in Phase 1? |
| --- | --- | --- |
| `Ready=False` / `TaskSuspended` | `reconciler.go:201` | no — inside the reconcile loop |
| `Ready=False` / `AtespaceCreationFailed` | `reconciler.go:121` | no — needs a Substrate atespace |
| `Ready=False` / `WorkspaceInitializing` | `reconciler.go:288` | no — needs a live actor |
| `WorkspaceReady=False` / `Initializing` | `reconciler.go:287` | no — needs a live actor |
| `WorkspaceReady=True` / `SetupComplete` | `reconciler.go:283` | no — needs workspace setup to finish |
| `Ready=True` / `TaskRunning` | `reconciler.go:285` | no — needs `WorkspaceReady=True` first |

So the lesson does not simulate a `Running` condition to make the section look
complete; it prints the two source lines that would create the ones you asked
about and says plainly that they cannot run here. The task runner's own
workspace-ready signal is *not* a condition — it is a readiness endpoint the
controller polls, and turning it into a `Condition` is the controller's step
(lesson 05 runs that endpoint for real).

## Trap: a Task is immutable — including a byte-identical re-apply

```
$ ax apply -f task.yaml          # the same file, unchanged
Error: applying document 1: rpc error: code = FailedPrecondition desc =
  task default/lab-task already exists and is immutable
```

Both cases are asserted, and the script fails if either is accepted:

* re-applying the **unchanged** file → rejected, exit 1
* re-applying a **changed** file → rejected, exit 1

The check is on *existence*, not on a diff (`internal/server/server.go:127-133`:
`GetTask`, and anything that does not return `ErrNotFound` is fatal). That is
why the identical re-apply fails too, and why the lesson's real advice is: you
cannot edit a task, you can only delete and recreate it — and
`ax delete task` is a two-phase operation that needs a controller to finish the
teardown (`MarkTaskDeleting` publishes a `delete` event; the record survives
until something calls `DeleteTask`). Without a controller, `ax delete task`
blocks for its 5-minute timeout and then errors. The lesson therefore never
deletes a task.

The contrast, on the same server with the same files:

```
workspace.ax.io/lab-workspace unchanged     # re-applied as-is
workspace.ax.io/lab-workspace configured    # content changed -> accepted, and stored
model.ax.io/lab-model configured            # parameters added -> accepted
```

`unchanged` vs `configured` is the CLI comparing the incoming spec against the
stored one (`cmd/ax/main.go:315-326`). Only Workspace and Model reach that
code: Task goes to `CreateTask`, a create-only RPC
(`cmd/ax/main.go:266-276`). There is no `UpdateTask` in the service at all.

## Trap: the model client fabricates its output

*This section is a self-contained detour, unrelated to the phases, conditions
and immutability rule above. You can skip it and lose nothing from the
lifecycle story. It is here because the model client is the one part of ax that
fails silently.*

`internal/model/client.go` falls back to a canned "plan" and invents token
counts, returning `err == nil`, when:

* the API key is empty, or `DisableRemote` is set (`client.go:500`)
* the request itself fails to go out (`client.go:558-560`)
* the API answers **401, 403, 429 or 503** (`client.go:563-567`)

The canned text is `client.go:608-621`:

```go
"Synthesized plan using %s: Workspace environment configured with development
 toolchain and dependencies matching declared goal."
```

and the usage is pure string arithmetic: `len(prompt)/4`, `len(content)/4`.

**Executed, not just described.** The lesson compiles a test into the upstream
module with `go test -count=1 -overlay` (see `testdata/overlay/README.md`; the
clone is asserted untouched afterwards) and runs the real
`internal/model` code. It prints, for every case, the returned content and the
returned usage:

| case | outcome |
| --- | --- |
| no API key | canned plan, `err == nil`, `usage = prompt=23 completion=35 total=58` |
| HTTP 401 | canned plan, `err == nil` |
| HTTP 403 | canned plan, `err == nil` |
| HTTP 429 | canned plan, `err == nil` |
| HTTP 503 | canned plan, `err == nil` |
| **HTTP 500** (control) | `gemini api error 500: ...` — *not* swallowed |
| **HTTP 400** (control) | `gemini api error 400: ...` — *not* swallowed |
| **HTTP 200** (control) | real content, real `usageMetadata` counts |

The two controls matter: 500 and 400 prove the fallback is a deliberate,
narrow list rather than "any error fabricates", and 200 proves the loopback
test server is actually reachable — so 401/429/503 are not just "the harness is
broken". A `PASS` here asserts all seven outcomes: the per-status-code
assertions are the probe's own `t.Fatalf`/`t.Errorf` per case plus the
`go test` exit code, and the shell's greps are deliberately one per *distinct*
needle rather than one per status code (a needle like `FABRICATED, err == nil`
matches all four of 401/403/429/503, so four greps of it would read like four
checks while being one).

**Is this reachable from a task run? No — not in this revision.** The lesson
greps the call graph and asserts the answer:

* the only non-test caller of `Client.Generate` is
  `internal/workspace/planner.go:94`
* the only non-test definition of `PlanEnvironment` is
  `internal/workspace/planner.go:68`, and **nothing** calls it

So no shipped binary can reach `fallbackResponse` today. The behaviour is real
and is demonstrated above, but the call site is missing, which means the lab
brief's claim that "a task run with no key produces a fake plan and exits 0"
does not hold for this revision. What *is* demonstrated, executed: the moment
anything calls the planner, the failure is silent — a plausible plan, invented
token counts, and `err == nil`.

The lesson ends by printing the source for both traps
(`client.go:498-502`, `:563-569`, `:608-621`; `server.go:127-133`, `:138-142`)
labelled **READ, not executed**, each line printed with the number it actually
has in the file, so you can check the claims.

**Source.**

| what | where |
| --- | --- |
| `TaskStatus.conditions` is field 7 | `pkg/apis/v1alpha1/ax.proto:112` |
| the `Condition` message | `pkg/apis/v1alpha1/ax.proto:126-132` |
| the only two condition types, `Ready` / `WorkspaceReady` | `internal/controller/reconciler.go:302-309` |
| every write of a condition (all six call sites) | `internal/controller/reconciler.go:121`, `:201`, `:283`, `:285`, `:287`, `:288` |
| the CLI renders `Conditions:` only when non-empty | `cmd/ax/main.go:658-666` |
| upstream README's "stream phase and condition changes" | `README.md:101`, `:137` |
| `CreateTask` sets `Suspended`, then rejects any existing name | `internal/server/server.go:111-146` |
| the immutability check is existence, not diff | `internal/server/server.go:127-133` |
| two-phase delete needs a controller | `internal/server/server.go:148-165`, `internal/store/redis/store.go:284-333` |
| `SuspendTask` / `ResumeTask` only touch the phase | `internal/server/server.go:167-215` |
| `WatchTask` sends `INITIAL` then relays pub/sub | `internal/server/server.go:217-254` |
| CLI: create-only Task apply | `cmd/ax/main.go:266-276` |
| CLI: `unchanged` / `configured` | `cmd/ax/main.go:315-326` |
| CLI: `<none>` substitution | `cmd/ax/main.go:365-370` |
| CLI: `ax watch` stops at `Running` | `cmd/ax/main.go:709-718` |
| model: empty key / DisableRemote | `internal/model/client.go:498-502` |
| model: transport failure swallowed | `internal/model/client.go:557-560` |
| model: 401/403/429/503 swallowed, everything else returned | `internal/model/client.go:563-569` |
| model: the canned text and fake usage | `internal/model/client.go:608-621` |
| model: where an API key comes from | `internal/model/client.go:263-298` |
| the only bridge to the planner, and its one caller | `internal/workspace/planner.go:68-113` |
