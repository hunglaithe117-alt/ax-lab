# 01 — the manifest schema is a protobuf, not a Go struct

**Question.** If `Task`, `Workspace` and `Model` are Go structs, what exactly
decides which YAML keys are legal? And where do I look for the whole data
model?

**Answer.** The schema is `pkg/apis/v1alpha1/ax.proto`, compiled into a
`protoreflect.FileDescriptor`. The Go structs are generated from it. The YAML
keys are decided by `protojson`, not by struct tags, and `types.go` bridges
YAML to protojson by hand.

**Run it.**

```sh
./examples/01-schema/run.sh          # works from any cwd
```

No cluster, no Redis, no network. It builds one Go program and runs it.

**What to look for.**

1. `descriptor path = pkg/apis/v1alpha1/ax.proto` — the descriptor knows the
   file it was generated from. `messages = 45`, `services = 1`, and 15 RPCs
   across the one service. **Those three numbers are asserted, not just
   printed** (`expectedMessages` / `expectedServices` / `expectedRPCs` in
   `examples/01-schema/main.go`): if upstream adds a message, the lesson fails
   rather than leaving this page quietly wrong.
2. `Task.api_version = number 1, proto name "api_version", JSON name
   "apiVersion"` — three different spellings of one field. The YAML key is
   `apiVersion`. `protojson` owns that mapping; nothing in the Go struct
   decides it.
3. The parsed output for `examples/task.yaml` and `examples/simple.yaml`:
   `WorkspacePaths() = [/workspace]` for the explicit path, `= []` for the
   task with no workspaces. That method is hand-written Go, not proto.
4. The round trip: re-encoding `simple.yaml` through `MarshalYAML` keeps
   descriptor field order (`apiVersion, kind, metadata, spec`) and drops every
   unset field.
5. The full dump: every message, every field with its number, proto name, JSON
   name, cardinality and type — plus the `AX` service and all 15 RPCs.
6. `ModelSpec` reserved field numbers. Fields in use are `1, 2, 6, 7`; `3, 4,
   5` are burned (`reserved 3, 4, 5;` in the proto, encoded as three
   end-exclusive ranges `[3,4) [4,5) [5,6)`). That is why `secret_key` is field
   6 and not 3. `ModelSpec` also reserves the *names* `temperature`,
   `max_tokens` and `system_instruction` — they moved into the free-form
   `parameters` Struct.
7. The API version and kind constants are plain Go constants, and they are
   **not** in the descriptor: `APIVersion = "ax.io/v1alpha1"`, `KindTask`,
   `KindWorkspace`, `KindModel`, `PhaseTerminating`, `MaxNameLength = 63`,
   `DefaultWorkspacePath = "/workspace"`.

**Source.**

| what | where |
| --- | --- |
| API group/version + kind constants | `pkg/apis/v1alpha1/types.go:32-43` |
| the YAML ↔ protojson bridge, and why | `pkg/apis/v1alpha1/types.go:45-61` |
| `marshalYAML` / `unmarshalYAML` | `pkg/apis/v1alpha1/types.go:67-88` |
| per-kind `MarshalYAML`/`UnmarshalYAML` | `pkg/apis/v1alpha1/types.go:196-203` |
| legacy manifest normalizers | `pkg/apis/v1alpha1/types.go:162-191` |
| `WorkspaceRefs` / `WorkspacePaths` | `pkg/apis/v1alpha1/types.go:217-244` |
| the generated `FileDescriptor` variable | `pkg/apis/v1alpha1/ax.pb.go:2559` |
| descriptor built at init | `pkg/apis/v1alpha1/ax.pb.go:2897-2915` |

**If this lesson breaks.** It exits non-zero if `APIVersion` is no longer
`ax.io/v1alpha1`, if the descriptor is nil, if the message / service / RPC
counts above stop matching this page, if `ModelSpec` stops reserving `3, 4, 5`,
or if the shipped examples stop decoding. A `PASS: 01-schema` line means all of
that still holds.
