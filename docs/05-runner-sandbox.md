# 05 — What actually happens inside a task container

## The question

Your agent command is running somewhere. **What is holding that container open, and
what can still answer when your agent is done?**

The short answer: `ax-task-runner` is PID 1, it starts your command as a child, and
then it *keeps running* after that child exits. That is the whole reason `ax ssh`
can reach a sandbox after the work is over.

**Run it.**

```sh
./examples/05-runner-sandbox/run.sh      # works from any cwd
```

The one-time prerequisite is `./scripts/setup.sh`, which builds the
`ax-task-runner` binary this lesson drives.

No cluster, no internet, no sudo. The lesson boots the real `ax-task-runner`
binary locally, five times — once each in sections 1, 2, 3, 6 and 7; sections 4,
5 and 8 reuse the section-3 process — and checks real HTTP status codes against
it.

## What to look for

| In the output | It means | Source |
|---|---|---|
| `msg="metadata and guest server started"` **before** any setup | the HTTP surface comes up first, so a failure below is observable | `runner/runner.go:146-149` |
| `msg="executing workspace maiden run setup"` | the workspace "maiden run" | `internal/workspace/setup.go:107` |
| `msg="wrote inlined workspace file" path=…/from-maiden-run.txt` | `Workspace.spec.files` materialized | `internal/workspace/setup.go:380-400` |
| `msg="failed to write initialized marker file" path=/ax/initialized-…` | the boot marker, and why it is missing here | `internal/workspace/setup.go:126`, `:336-357` |
| `msg="workspace maiden run setup marked ready"` → `/readyz` flips to `200` | readiness is *setup*, not "the port is open" | `runner/runner.go:162-165`, `internal/metadata/server.go:190-193` |
| `msg="started task command" pid=…` | only now is `spec.command` exec'd | `runner/runner.go:174-187` |
| `msg="task command exited with error" exitCode=7`, then **`/healthz` still `200`** three times in a row | the invariant. The runner outlived its command | `runner/runner.go:192-199` |
| `msg="task command did not exit within grace period; killing" gracePeriod=10s` | SIGTERM → 10s → SIGKILL, proven with a command that traps TERM to nothing | `runner/runner.go:205-220` |

The four HTTP endpoints and the codes they actually return:

| Endpoint | Ready | Not ready / unbound |
|---|---|---|
| `GET /healthz` | `200` `ok` | `200` `ok` — always |
| `GET /readyz` | `200` `ok` | `503` `workspace initializing` |
| `GET /metadata/v1alpha1/ax/task` | `200` `application/yaml` | `200` (the Task is known even when setup failed) |
| `GET /metadata/v1alpha1/ax/workspaces` | `200` YAML stream | `404` `workspace metadata not available` |

## Two gotchas the lesson reproduces instead of hiding

1. **`/workspace` is not writable as non-root.** `DefaultWorkspacePath` is `/workspace`
   (`pkg/apis/v1alpha1/types.go:213`). On a laptop that `mkdir` fails, and because
   `cmd.Dir` *is* that path (`runner/runner.go:175`), the command cannot even start —
   `exec.Cmd.Start` fails its `chdir` and the runner exits 1. In the container
   `/workspace` is a mounted volume, so this never happens there.
2. **`/ax` is not writable either, so the maiden run re-runs on every boot.**
   `AXDir` is the constant `"/ax"` (`internal/workspace/setup.go:33`, `:64`) and both
   its `mkdir` and the marker write are warn-only (`:97-99`, `:355`). So the
   once-only setup silently repeats forever. The lesson boots twice and shows the
   second boot taking the maiden-run branch again, and checks the marker name against
   `MarkerName()` (`:336-345`).

## The caveat that matters most

Running the binary directly means **there is no container**. `spec.command` is exec'd
against *this host's* PATH and filesystem, as *this user*. The lesson proves it
(section 5: the command reports a non-zero uid — 1000 on this host — sees the
lab's own directory tree, and `ax-task-runner` is not on its PATH). Everything the
runner does is real; the isolation around it is not.

## Not demonstrated

The marker's **skip** branch (`setup.go:103`, `workspace already initialized`) is
unreachable here — writing `/ax` needs root, and this host has neither sudo nor user
namespaces (`unshare -r` → `EPERM`). The lesson checks the marker *name* and the
*failure* branch instead, and says so rather than claiming coverage.
