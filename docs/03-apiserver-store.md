# 03 — the API server is a stateless shim over Redis

**Question.** Where does state actually live, and what does that mean for
testing?

**Answer.** Entirely in Redis. `ax-server` keeps nothing. And the in-memory
store that exists in the tree is not reachable from the shipped binary.

**Run it.**

```sh
./examples/03-apiserver-store/run.sh    # works from any cwd
```

It starts a throwaway `redis:7-alpine` container, starts the prebuilt
`ax-server` from `ax-lab/bin/`, drives it with the prebuilt `ax` CLI from the
same directory, kills and restarts `ax-server`, and tears everything down on
exit (including on failure). It uses `ax-lab/bin/`, not
`upstream/google-ax/bin/`, because that is the directory `scripts/setup.sh`
installs into and `scripts/verify-all.sh` checks — so a `MISSING ax-lab/bin/ax`
in the gate is a real signal. No cluster, no kube context, no egress beyond
loopback. The CLI is pointed at the server with `AX_SERVER`, which
`internal/tunnel/tunnel.go:185-187` checks before it would ever look at
Kubernetes.

**Ports.** The lab brief asked for host port 16379 and API port 18081. Both
are contended on this machine (another project publishes 16379; another lesson
in this track binds 18081, and either can be torn down mid-run), so the
defaults are the lab-owned **16390** and **18091**, chosen from a list of free
ports. Force the brief's ports with:

```sh
AXLAB_REDIS_PORT=16379 AXLAB_SERVER_ADDR=127.0.0.1:18081 ./examples/03-apiserver-store/run.sh
```

**What to look for.**

1. One `ax apply -f examples/task.yaml` produces three lines — `task123`,
   `default-workspace`, `default-model` — because the CLI splits the
   multi-document file and sends one typed RPC per document. The server never
   sees YAML.
2. `ax get tasks` / `get workspaces` / `get models` / `describe task task123`.
   The task is `Suspended` with an empty actor; that is `CreateTask`
   hardcoding the phase, not a failure.
3. `redis-cli keys 'ax:*'` — ten keys, and the task record is
   `ax:task:default:task123` holding a single line of protojson. The value goes
   through `jq -e` so "it is protojson" is a check, not prose. The ten keys are
   three shapes, and the lesson names each one with its constructor in
   `internal/store/redis/store.go`:
   * **the object** — one string per resource (`taskKey` :81-83, `wsKey`
     :98-100, `modelKey` :86-88);
   * **the indexes** — `ax:tasks:index` and `ax:tasks:atespace:default`
     (:110-116), plus the same pair for workspaces and models (:90-108), so
     listing is a `ZRANGE` and not a `KEYS` scan. `DeleteTask` is a `DEL` plus
     a `ZREM` from each index (:319-333);
   * **the work queue** — `ax:stream:tasks`, the Redis stream every `SaveTask`
     `XADD`s a reconcile event to (`defaultStreamName` :32, used at :161 and
     :305), consumed by the controller (`Subscribe` :590-655).

   There is also a per-task pub/sub channel (`taskPubSubChannel` :118-120) that
   `ax watch` subscribes to — pub/sub channels are not keys, so it is not in
   that listing.
4. **The proof.** It records the task's `creationTimestamp`, sleeps two
   seconds, kills the server, asserts the PID is gone, starts a *new* server
   process (asserting a different PID), and lists everything again. The stored
   bytes are byte-identical, the `creationTimestamp` is unchanged, and the
   `AGE` column has gone `0s -> 2s` — across a process that did not exist when
   the task was created. `ax` computes `AGE` from the record's own timestamp,
   so a re-creating server would show `0s`. The script fails if `AGE` does
   *not* advance, because then the check would prove nothing.
5. **Section 5 is labelled `READ, not executed`** — it is grep and `go test`
   over source, not ax-server behaviour, and says so. `grep -n
   'internal/store' cmd/ax-server/main.go` shows one import:
   `internal/store/redis`, and `redis.NewStore` is called unconditionally at
   `cmd/ax-server/main.go:65-66`. The claim is deliberately **scoped**: the
   three flags are `-addr`, `-redis-addr`, `-redis-password` (:39-41), the env
   overrides are `ADDR`, `REDIS_ADDR`, `REDIS_PASSWORD` (:44-52), and there is
   no branch around the `NewStore` call — so no flag or env var *in that file*
   chooses a store. What one file cannot rule out is a build tag or a store
   constructed elsewhere, so the lesson closes both gaps explicitly:
   `grep -rln 'internal/store/memory'` is module-wide and must return only
   `_test.go` files, and `grep -rn '^//go:build'` over `internal/store` and
   `cmd/ax-server` must return nothing.
6. `grep -rln 'internal/store/memory' --include='*.go'` lists five files, and
   the script fails if any of them is not a `_test.go`. That module-wide
   listing is what the claim actually rests on: nothing outside the test
   binaries imports the in-memory store.
7. `go test ./internal/store/...` **reports "no test files" for all three
   packages.** The lab brief expected this to be supporting evidence; it is
   not — neither the memory store nor the redis store has any test. The import
   graph is the evidence.
8. A real demonstration, compiled into the upstream module with
   `go run -overlay` (nothing written to the clone, asserted afterwards):
   `memory.MemoryStore` satisfies `store.Store`, saves and reads a task, returns
   `store.ErrNotFound` for a missing one, lists, and happily overwrites a task
   in place.

**What it means for an in-memory test harness.** The server's logic is
store-agnostic — only the *wiring* is not. But you cannot point the shipped
`ax-server` at memory: its only three flags are `-addr`, `-redis-addr` and
`-redis-password` (`cmd/ax-server/main.go:39-41`), its only env overrides are
`ADDR`, `REDIS_ADDR` and `REDIS_PASSWORD` (`:44-52`), `NewStore` is called
unconditionally (`:65`), there is no build constraint anywhere under
`internal/store` or `cmd/ax-server`, and no non-test file outside the test
binaries even imports `internal/store/memory`. You also cannot import it from
your own module, because Go blocks imports of `internal/...` from outside
`github.com/google/ax`. An in-process harness therefore means either
contributing a test inside the ax module or running the same Redis the shipped
server uses. That is exactly why lessons 03 and 04 run a real Redis.

**Source.**

| what | where |
| --- | --- |
| the three flags and their defaults | `cmd/ax-server/main.go:39-41` |
| the three env overrides | `cmd/ax-server/main.go:44-52` |
| redis store constructed unconditionally | `cmd/ax-server/main.go:59-66` |
| gRPC + `/healthz` on one port | `internal/server/server.go:54-67` |
| redis key layout | `internal/store/redis/store.go:81-121` |
| `protojson.Marshal` on save | `internal/store/redis/store.go:146` |
| the reconcile stream | `internal/store/redis/store.go:32`, `:161`, `:305`, `:590-655` |
| a delete is DEL + two ZREMs | `internal/store/redis/store.go:319-333` |
| watch = redis pub/sub per task | `internal/store/redis/store.go:683-706` |
| the in-memory store | `internal/store/memory/store.go` |
| the interface both satisfy | `internal/store/store.go:55-88` |
| `AX_SERVER` short-circuits the tunnel | `internal/tunnel/tunnel.go:181-188` |
| CLI applies one kind per RPC | `cmd/ax/main.go:258-309` |
| `AGE` comes from `creationTimestamp` | `cmd/ax/main.go:371-380` |
