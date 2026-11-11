// Probe: does the in-memory store satisfy the same interface as the Redis one?
//
// This file is NOT part of the axlab module. It lives under testdata/ so the Go
// tool ignores it (module-wide ./... patterns skip directories named
// testdata), and it is never compiled by `go build ./...` or `go vet ./...`.
//
// It cannot be part of the module either: it imports
// github.com/google/ax/internal/store/memory, and Go's internal rule makes
// github.com/google/ax/internal/... unimportable from any module other than
// github.com/google/ax itself.
//
// So lesson 03 hands it to the upstream module with `go run -overlay`, which
// synthesises the file at a path *inside* the upstream module without writing
// anything to the upstream clone. See 03-apiserver-store/run.sh and
// testdata/overlay/README.md.
package main

import (
	"context"
	"fmt"
	"os"

	"github.com/google/ax/internal/store"
	"github.com/google/ax/internal/store/memory"
	"github.com/google/ax/pkg/apis/v1alpha1"
)

// The whole point of this probe: the coupling between ax-server and Redis is
// *wiring*, not interface. memory.MemoryStore satisfies store.Store, so the
// server would work unchanged if something constructed it that way.
var _ store.Store = (*memory.MemoryStore)(nil)

func main() {
	ctx := context.Background()
	s := memory.NewStore()

	task := &v1alpha1.Task{
		Metadata: &v1alpha1.ObjectMeta{Name: "probe-task", Atespace: "default"},
		Spec:     &v1alpha1.TaskSpec{Image: "example/image"},
		Status:   &v1alpha1.TaskStatus{Phase: "Suspended"},
	}
	fmt.Printf("  SaveTask            -> err=%v\n", s.SaveTask(ctx, task))
	got, err := s.GetTask(ctx, "default", "probe-task")
	fmt.Printf("  GetTask             -> name=%q phase=%q err=%v\n",
		got.GetMetadata().GetName(), got.GetStatus().GetPhase(), err)
	_, err = s.GetTask(ctx, "default", "does-not-exist")
	fmt.Printf("  GetTask(missing)    -> err=%v (errors.Is(err, store.ErrNotFound) = %v)\n",
		err, err == store.ErrNotFound)
	list, err := s.ListTasks(ctx, "default", 50, 0)
	fmt.Printf("  ListTasks           -> %d task(s), err=%v\n", len(list), err)

	// The server is what enforces the Task immutability rule, not the store
	// (internal/server/server.go:127-130). Prove the store itself is happy to
	// overwrite, so "immutable" is a server policy and not a storage property.
	changed := &v1alpha1.Task{
		Metadata: &v1alpha1.ObjectMeta{Name: "probe-task", Atespace: "default"},
		Spec:     &v1alpha1.TaskSpec{Image: "example/different-image"},
	}
	fmt.Printf("  SaveTask (same name, different spec) -> err=%v\n", s.SaveTask(ctx, changed))
	again, _ := s.GetTask(ctx, "default", "probe-task")
	fmt.Printf("  GetTask after overwrite -> image=%q  <- the store allowed it\n",
		again.GetSpec().GetImage())

	if again.GetSpec().GetImage() != "example/different-image" {
		fmt.Fprintln(os.Stderr, "memory store probe: unexpected behaviour")
		os.Exit(1)
	}
	fmt.Println("  => the in-memory store is complete and correct; ax-server simply")
	fmt.Println("     never constructs one (cmd/ax-server/main.go:59-66).")
}
