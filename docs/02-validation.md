# 02 — what the API server refuses, and the exact strings it uses

**Question.** Which mistakes does ax catch before it stores anything, and what
does the error actually look like when I get one wrong?

**Answer.** Five hand-written validators in `pkg/apis/v1alpha1/types.go`,
called by the server before every save. Plus one thing that is not a validator
at all: YAML decoding is strict, so a single misspelled key fails the whole
apply.

**Run it.**

```sh
./examples/02-validation/run.sh      # works from any cwd
```

Pure Go. No cluster, no Redis, no network.

**What to look for.** The program is negative-control-first. Every case marked
"must be rejected" is *asserted* to be rejected and its real error is printed;
if any of them started being accepted, the program exits non-zero and the
script reports `FAIL: 02-validation`. A `PASS` is therefore a statement about
behaviour, not a transcript.

1. The four documents in `upstream/google-ax/examples` — three in `task.yaml`
   (Task, Workspace, Model) and one in `simple.yaml` — all validate. The count
   is **asserted**, not just printed: the decode loop exits only on `io.EOF`, an
   unrecognised `kind` is a hard error rather than a skipped document, and
   `mustCount` fails the lesson if fewer than four documents were validated.
   Without those three, a `kind: Workspce` typo or a syntax error in a manifest
   would make the lesson check *fewer* things and still report success.

   ```sh
   # prove it, on a copy - the real clone is never touched
   cp -r upstream/google-ax /tmp/ax-doctored
   sed -i 's/^kind: Workspace$/kind: Workspce/' /tmp/ax-doctored/examples/task.yaml
   AXLAB_UPSTREAM=/tmp/ax-doctored ./examples/02-validation/run.sh
   # -> lesson 02 failed: document 2 of task.yaml has unsupported kind "Workspce"
   # -> FAIL: 02-validation   (exit 1)
   ```
2. `ValidateName` — the regexp is `^[a-z0-9]([-a-z0-9]*[a-z0-9])?$` with a
   63-character cap. Empty gets its own message:
   `must not be empty`. Everything else gets:
   `must be a lowercase RFC 1123 label: at most 63 lowercase alphanumeric
   characters or '-', starting and ending with an alphanumeric character`.
3. `ValidateObjectMeta` prefixes the field: `metadata.name: invalid value
   "Task_1": ...`, `metadata.atespace: invalid value "Bad NS": ...`. An empty
   atespace is fine; the server defaults it.
4. `ValidateWorkspace` adds `spec.files[i]: path is required`. A workspace with
   no spec at all is valid.
5. `ValidateModel` checks nothing but the name. A model with `provider: ""` and
   no `secretKey` is valid; the model client fills those in later.
6. `ValidateTask`'s workspace-binding rules, all four of them:
   `spec.workspaces[0]: name is required`,
   `spec.workspaces[1]: workspace "ws" is bound more than once`,
   `spec.workspaces[0]: path "srv/ws" must be absolute`,
   `spec.workspaces[1]: path "/srv/ws" is already used by workspace "one"`.
   The nastiest one is the last: a ref with no `path` defaults to
   `/workspace/<name>`, so `- name: one, path: /workspace/two` plus
   `- name: two` collide, and nothing in the YAML looks wrong. Trailing
   slashes are normalised away before comparison, so `/srv/ws` and `/srv/ws/`
   are the same path.
7. **The strict-decoder trap.** Seven bad documents, all rejected by
   `protojson` with a line and column: `unknown field "request"`,
   `unknown field "specx"`, `unknown field "lables"`, `invalid value for bool
   field debug: "true"`, `unknown field "brnach"`, `unknown field
   "secretkey"`, and `syntax error ... unexpected token 0.3` for a scalar where
   `parameters` (a `google.protobuf.Struct`) is expected. Two positive
   controls run first, so you can see the rejection is about the bad key and
   not about the document.
8. **Strict, except for three grandfathered shapes.** `spec.mcp` written as a
   bare list, `spec.secretKeyRef`, `spec.apiKey.secretKeyRef`, and a bare
   `spec.secretKey: my-secret` string are all rewritten before strict decoding
   (the last becomes `{name: my-secret, key: my-secret}`). This is why some
   "wrong-looking" YAML still works. Each is labelled by its **input shape** and
   the rewritten `secretKey` is asserted, so you can see which normalizer
   (`types.go:162-167`, `:172-191`) did the work.

**Source.**

| what | where |
| --- | --- |
| `protoUnmarshal` with no `DiscardUnknown` | `pkg/apis/v1alpha1/types.go:60` |
| `unmarshalYAML` (decode → normalise → JSON → protojson) | `pkg/apis/v1alpha1/types.go:75-88` |
| `MaxNameLength`, `nameRegexp` | `pkg/apis/v1alpha1/types.go:254-256` |
| `ValidateName` | `pkg/apis/v1alpha1/types.go:260-268` |
| `ValidateObjectMeta` | `pkg/apis/v1alpha1/types.go:272-282` |
| `ValidateWorkspace` | `pkg/apis/v1alpha1/types.go:286-299` |
| `ValidateModel` | `pkg/apis/v1alpha1/types.go:303-305` |
| `ValidateTask` | `pkg/apis/v1alpha1/types.go:309-343` |
| legacy normalizers | `pkg/apis/v1alpha1/types.go:162-191` |
| server calls them and wraps the message verbatim in `InvalidArgument` | `internal/server/server.go:116-117`, `:293-294`, `:359-360` |
