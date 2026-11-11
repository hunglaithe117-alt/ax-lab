# `testdata/overlay/` — why these files are here and not in `examples/`

These Go files are **not** part of the `axlab` module and are never compiled by
`go build ./...` or `go vet ./...`. The Go tool ignores any directory named
`testdata` when expanding `./...` patterns.

They have to live outside the module because each one imports a package under
`github.com/google/ax/internal/…`, and Go's internal rule makes that illegal
from any module other than `github.com/google/ax`. That is the whole reason the
lab cannot re-implement or directly exercise ax's internals.

To run them anyway — without writing a single byte into the upstream clone —
the lessons use the Go toolchain's `-overlay` flag. An overlay JSON maps a
*virtual* path to a real file:

```json
{"Replace": {
  "<upstream>/internal/model/zz_lab_fallback_test.go": "<lab>/testdata/overlay/modelfallback/fallback_test.go"
}}
```

`go test -overlay …` / `go run -overlay …` then compile the file as if it lived
at the virtual path. The virtual path is inside the upstream module, so its
`internal/…` imports are legal, and the file is compiled by the *upstream*
module — which still never sees a modified file on disk.

```sh
cd upstream/google-ax
go run -overlay /path/to/storeprobe-overlay.json ./cmd/labstoreprobe
```

Two scripts generate those overlay files on the fly:
`examples/03-apiserver-store/run.sh` and `examples/04-task-lifecycle/run.sh`.
