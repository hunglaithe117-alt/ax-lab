// Lesson 01 - the manifest schema is a protobuf, not a Go struct.
//
// Everything this program prints comes from the real upstream source at
// ../upstream/google-ax. Nothing is re-implemented here: the only ax import is
// the public API package
//
//	github.com/google/ax/pkg/apis/v1alpha1   types.go + the generated protobuf
//
// alongside google.golang.org/protobuf and gopkg.in/yaml.v3. The whole data
// model is read out of the compiled-in file descriptor. Source citations:
//
//	pkg/apis/v1alpha1/types.go:32-43   API version / kind constants
//	pkg/apis/v1alpha1/types.go:45-61   the YAML<->protojson bridge
//	pkg/apis/v1alpha1/types.go:67-88   marshalYAML / unmarshalYAML helpers
//	pkg/apis/v1alpha1/types.go:193-203 the hand-written per-kind YAML methods
//	pkg/apis/v1alpha1/ax.pb.go:2559    the generated FileDescriptor variable
package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"

	"github.com/google/ax/pkg/apis/v1alpha1"
	"google.golang.org/protobuf/reflect/protoreflect"
	"gopkg.in/yaml.v3"
)

// The three numbers docs/01-schema.md quotes. They are asserted against the
// compiled-in descriptor (see showDescriptorIdentity) so the doc cannot drift
// away from the program without the lesson failing.
const (
	expectedMessages = 45
	expectedServices = 1
	expectedRPCs     = 15
)

// countRPCs totals the methods across every service in the descriptor.
func countRPCs(fd protoreflect.FileDescriptor) int {
	n := 0
	svcs := fd.Services()
	for i := 0; i < svcs.Len(); i++ {
		n += svcs.Get(i).Methods().Len()
	}
	return n
}

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "lesson 01 failed: %v\n", err)
		os.Exit(1)
	}
}

func run() error {
	examplesDir := upstreamExamplesDir()
	fmt.Printf("== ax lesson 01: the manifest schema is a protobuf ==\n")
	fmt.Printf("upstream examples: %s\n\n", examplesDir)

	if err := showConstants(); err != nil {
		return err
	}
	if err := showDescriptorIdentity(); err != nil {
		return err
	}
	if err := parseExample(examplesDir, "task.yaml"); err != nil {
		return err
	}
	if err := parseExample(examplesDir, "simple.yaml"); err != nil {
		return err
	}
	if err := showRoundTrip(examplesDir); err != nil {
		return err
	}
	return dumpDataModel()
}

// upstreamExamplesDir resolves upstream/google-ax/examples relative to this
// source file, so the program works from any cwd.
func upstreamExamplesDir() string {
	if v := os.Getenv("AX_UPSTREAM"); v != "" {
		return filepath.Join(v, "examples")
	}
	// walk up from the working directory looking for upstream/google-ax
	if wd, err := os.Getwd(); err == nil {
		dir := wd
		for i := 0; i < 8; i++ {
			cand := filepath.Join(dir, "upstream", "google-ax", "examples")
			if st, err := os.Stat(cand); err == nil && st.IsDir() {
				return cand
			}
			parent := filepath.Dir(dir)
			if parent == dir {
				break
			}
			dir = parent
		}
	}
	return "upstream/google-ax/examples"
}

// showConstants prints the API group/version and kind constants. These are
// hand-written Go constants, not proto enums - they live in types.go, not in
// the descriptor. That split is the first thing worth noticing about ax.
func showConstants() error {
	fmt.Println("-- API version / kind constants (pkg/apis/v1alpha1/types.go:32-43) --")
	fmt.Printf("  APIVersion        = %q\n", v1alpha1.APIVersion)
	fmt.Printf("  KindTask          = %q\n", v1alpha1.KindTask)
	fmt.Printf("  KindWorkspace     = %q\n", v1alpha1.KindWorkspace)
	fmt.Printf("  KindModel         = %q\n", v1alpha1.KindModel)
	fmt.Printf("  DefaultTaskImage  = %q\n", v1alpha1.DefaultTaskImage)
	fmt.Printf("  PhaseTerminating  = %q\n", v1alpha1.PhaseTerminating)
	fmt.Printf("  DefaultWorkspacePath = %q (types.go:213)\n", v1alpha1.DefaultWorkspacePath)
	fmt.Printf("  MaxNameLength     = %d (types.go:254)\n", v1alpha1.MaxNameLength)
	if v1alpha1.APIVersion != "ax.io/v1alpha1" {
		return fmt.Errorf("APIVersion changed: got %q", v1alpha1.APIVersion)
	}
	fmt.Println("  note: these are Go constants. The *shape* of a manifest is the proto")
	fmt.Println("        descriptor; the group/version/kind strings are not in it.")
	fmt.Println()
	return nil
}

// showDescriptorIdentity proves the schema really is a compiled-in protobuf
// FileDescriptor and not a Go struct. The variable is
// v1alpha1.File_pkg_apis_v1alpha1_ax_proto, declared at ax.pb.go:2559 and
// assigned in file_pkg_apis_v1alpha1_ax_proto_init (ax.pb.go:2897-2915).
func showDescriptorIdentity() error {
	fd := v1alpha1.File_pkg_apis_v1alpha1_ax_proto
	if fd == nil {
		return errors.New("File_pkg_apis_v1alpha1_ax_proto is nil (ax.pb.go:2559)")
	}
	fmt.Println("-- the generated file descriptor (ax.pb.go:2559) --")
	fmt.Printf("  var name          = v1alpha1.File_pkg_apis_v1alpha1_ax_proto\n")
	fmt.Printf("  descriptor path   = %s   <- the .proto this was generated from\n", fd.Path())
	fmt.Printf("  proto package     = %s\n", fd.Package())
	fmt.Printf("  syntax            = %v\n", fd.Syntax())
	deps := make([]string, 0, fd.Imports().Len())
	for i := 0; i < fd.Imports().Len(); i++ {
		deps = append(deps, string(fd.Imports().Get(i).Path()))
	}
	sort.Strings(deps)
	fmt.Printf("  imports           = %s\n", strings.Join(deps, ", "))
	fmt.Printf("  messages          = %d\n", fd.Messages().Len())
	fmt.Printf("  services          = %d\n", fd.Services().Len())

	// The doc quotes these three numbers, so they are asserted here rather than
	// merely printed. Without an assertion they can only ever drift silently
	// away from the prose, which is exactly the failure this lesson is about.
	if got := fd.Messages().Len(); got != expectedMessages {
		return fmt.Errorf("descriptor has %d messages, but docs/01-schema.md says %d", got, expectedMessages)
	}
	if got := fd.Services().Len(); got != expectedServices {
		return fmt.Errorf("descriptor has %d services, but docs/01-schema.md says %d", got, expectedServices)
	}
	if got := countRPCs(fd); got != expectedRPCs {
		return fmt.Errorf("descriptor has %d RPCs, but docs/01-schema.md says %d", got, expectedRPCs)
	}
	fmt.Printf("  => asserted: %d messages, %d service(s), %d RPCs (what docs/01-schema.md quotes)\n",
		expectedMessages, expectedServices, expectedRPCs)

	// Task is a generated Go struct, but it is also a proto message. The
	// descriptor is the thing that decides what YAML keys are legal.
	taskDesc := fd.Messages().ByName("Task")
	if taskDesc == nil {
		return errors.New("descriptor has no Task message")
	}
	f0 := taskDesc.Fields().ByName("api_version")
	if f0 == nil {
		return errors.New("Task has no api_version field")
	}
	fmt.Printf("  Task.api_version  = number %d, proto name %q, JSON name %q\n",
		f0.Number(), f0.Name(), f0.JSONName())
	if f0.JSONName() != "apiVersion" {
		return fmt.Errorf("expected apiVersion JSON name, got %q", f0.JSONName())
	}
	fmt.Println("  => the YAML key is apiVersion, the Go field is ApiVersion, and the")
	fmt.Println("     proto field is api_version. protojson owns all three.")
	fmt.Println()
	return nil
}

// parseExample streams a possibly multi-document YAML file exactly the way
// `ax apply` does (cmd/ax/main.go:227-252) and decodes each document by its
// `kind` into the corresponding proto message.
func parseExample(examplesDir, name string) error {
	path := filepath.Join(examplesDir, name)
	data, err := os.ReadFile(path)
	if err != nil {
		return fmt.Errorf("reading %s: %w", path, err)
	}

	fmt.Printf("-- parsing %s through the hand-written YAML bridge (types.go:196-203) --\n", name)
	dec := yaml.NewDecoder(bytes.NewReader(data))
	for i := 1; ; i++ {
		var doc yaml.Node
		if err := dec.Decode(&doc); err != nil {
			if errors.Is(err, io.EOF) {
				break
			}
			return fmt.Errorf("decoding document %d of %s: %w", i, name, err)
		}
		if doc.Kind != yaml.DocumentNode || len(doc.Content) == 0 {
			continue
		}
		var head struct {
			Kind string `yaml:"kind"`
		}
		if err := doc.Content[0].Decode(&head); err != nil {
			return fmt.Errorf("reading kind of document %d: %w", i, err)
		}
		switch head.Kind {
		case v1alpha1.KindTask:
			var t v1alpha1.Task
			if err := doc.Content[0].Decode(&t); err != nil {
				return fmt.Errorf("decoding Task: %w", err)
			}
			fmt.Printf("  doc %d: kind=%s -> %T  apiVersion=%q name=%q atespace=%q\n",
				i, head.Kind, &t, t.GetApiVersion(), t.GetMetadata().GetName(), t.GetMetadata().GetAtespace())
			fmt.Printf("        image=%s\n", t.GetSpec().GetImage())
			fmt.Printf("        debug=%v  env=%d  command=%v\n",
				t.GetSpec().GetDebug(), len(t.GetSpec().GetEnv()), t.GetSpec().GetCommand())
			for _, ref := range t.GetSpec().WorkspaceRefs() {
				fmt.Printf("        workspace ref name=%q path=%q goal=%q\n", ref.GetName(), ref.GetPath(), ref.GetGoal())
			}
			// WorkspacePaths is hand-written Go (types.go:233-244): a ref with no
			// explicit path lands at /workspace/<name>.
			fmt.Printf("        WorkspacePaths() = %v (DefaultWorkspacePath=%q)\n",
				t.GetSpec().WorkspacePaths(), v1alpha1.DefaultWorkspacePath)
			if t.GetMetadata().GetName() == "" {
				return errors.New("decoded Task has no metadata.name")
			}
		case v1alpha1.KindWorkspace:
			var w v1alpha1.Workspace
			if err := doc.Content[0].Decode(&w); err != nil {
				return fmt.Errorf("decoding Workspace: %w", err)
			}
			fmt.Printf("  doc %d: kind=%s -> %T  name=%q atespace=%q\n",
				i, head.Kind, &w, w.GetMetadata().GetName(), w.GetMetadata().GetAtespace())
			for _, g := range w.GetSpec().GetGit() {
				fmt.Printf("        git name=%q repo=%q branch=%q dir=%q depth=%d\n",
					g.GetName(), g.GetRepo(), g.GetBranch(), g.GetDir(), g.GetDepth())
			}
			for _, r := range w.GetSpec().GetMcp().GetRegistries() {
				fmt.Printf("        mcp registry provider=%q query=%q servers=%d\n", r.GetProvider(), r.GetQuery(), len(r.GetServers()))
			}
			for _, s := range w.GetSpec().GetMcp().GetServers() {
				fmt.Printf("        mcp server name=%q endpoint=%q\n", s.GetName(), s.GetEndpoint())
			}
			for _, r := range w.GetSpec().GetSkills().GetRegistries() {
				fmt.Printf("        skills registry provider=%q query=%q\n", r.GetProvider(), r.GetQuery())
			}
			fmt.Printf("        skills path=%q files=%d\n", w.GetSpec().GetSkills().GetPath(), len(w.GetSpec().GetFiles()))
		case v1alpha1.KindModel:
			var m v1alpha1.Model
			if err := doc.Content[0].Decode(&m); err != nil {
				return fmt.Errorf("decoding Model: %w", err)
			}
			fmt.Printf("  doc %d: kind=%s -> %T  name=%q\n", i, head.Kind, &m, m.GetMetadata().GetName())
			fmt.Printf("        provider=%q model=%q secretKey={name:%q key:%q}\n",
				m.GetSpec().GetProvider(), m.GetSpec().GetModel(),
				m.GetSpec().GetSecretKey().GetName(), m.GetSpec().GetSecretKey().GetKey())
		default:
			return fmt.Errorf("document %d of %s has unsupported kind %q", i, name, head.Kind)
		}
	}
	fmt.Println()
	return nil
}

// showRoundTrip re-encodes a decoded Task through MarshalYAML (types.go:196),
// which is protojson.Marshal rendered as a yaml.Node (types.go:67-73,
// 90-157). Field order follows the proto definition, not alphabetical order,
// and only non-default fields are emitted.
func showRoundTrip(examplesDir string) error {
	path := filepath.Join(examplesDir, "simple.yaml")
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	var t v1alpha1.Task
	if err := yaml.Unmarshal(data, &t); err != nil {
		return fmt.Errorf("decoding simple.yaml: %w", err)
	}
	out, err := yaml.Marshal(&t)
	if err != nil {
		return fmt.Errorf("re-encoding simple.yaml: %w", err)
	}
	fmt.Println("-- round trip: decode simple.yaml, then MarshalYAML (types.go:196) --")
	fmt.Println("   field order follows the proto descriptor; unset fields are dropped")
	fmt.Println("   (protojson.MarshalOptions{} with no EmitUnpopulated, types.go:59):")
	for _, line := range strings.Split(strings.TrimRight(string(out), "\n"), "\n") {
		if strings.TrimSpace(line) == "" || strings.HasPrefix(line, "#") {
			continue
		}
		fmt.Printf("   %s\n", line)
	}
	if !bytes.Contains(out, []byte("apiVersion:")) {
		return errors.New("round trip lost apiVersion")
	}
	fmt.Println()
	return nil
}

// dumpDataModel prints every message and field in the descriptor. This is the
// complete ax data model in one place - there is no other doc that can be
// trusted more, because it is the compiled schema itself.
func dumpDataModel() error {
	fd := v1alpha1.File_pkg_apis_v1alpha1_ax_proto
	msgs := fd.Messages()
	fmt.Println("-- the entire data model, straight out of the descriptor --")
	for i := 0; i < msgs.Len(); i++ {
		md := msgs.Get(i)
		if md.IsMapEntry() {
			continue
		}
		fmt.Printf("  message %s {\n", md.Name())
		for j := 0; j < md.Fields().Len(); j++ {
			f := md.Fields().Get(j)
			label := f.Cardinality().String()
			typeName := f.Kind().String()
			if f.Message() != nil {
				typeName = string(f.Message().FullName())
			} else if f.Kind() == protoreflect.EnumKind {
				typeName = string(f.Enum().FullName())
			}
			if f.IsMap() {
				typeName = fmt.Sprintf("map<%s, %s>", f.MapKey().Kind(), f.MapValue().Message().FullName())
			}
			fmt.Printf("    %2d  %-24s json=%-22s %-9s %s\n",
				f.Number(), f.Name(), f.JSONName(), label, typeName)
		}
		// protoreflect.FieldRanges.Get returns [start, end) - start inclusive,
		// end exclusive (protoreflect/proto.go:397).
		if rr := md.ReservedRanges(); rr.Len() > 0 {
			for j := 0; j < rr.Len(); j++ {
				r := rr.Get(j)
				fmt.Printf("    -- reserved field numbers [%d, %d)\n", r[0], r[1])
			}
		}
		if rn := md.ReservedNames(); rn.Len() > 0 {
			for j := 0; j < rn.Len(); j++ {
				fmt.Printf("    -- reserved name %q\n", rn.Get(j))
			}
		}
		fmt.Println("  }")
	}

	// Negative control for the claim in the lesson text: ModelSpec really does
	// carry reserved field numbers, and they are 3-5.
	ms := msgs.ByName("ModelSpec")
	if ms == nil {
		return errors.New("descriptor has no ModelSpec message")
	}
	got := make([]string, 0, 2)
	if rr := ms.ReservedRanges(); rr.Len() > 0 {
		for j := 0; j < rr.Len(); j++ {
			r := rr.Get(j)
			got = append(got, fmt.Sprintf("%d-%d", r[0], r[1]))
		}
	}
	fmt.Printf("\n  ModelSpec field numbers actually in use: ")
	nums := make([]int, 0, ms.Fields().Len())
	for j := 0; j < ms.Fields().Len(); j++ {
		nums = append(nums, int(ms.Fields().Get(j).Number()))
	}
	fmt.Printf("%v\n", nums)
	fmt.Printf("  ModelSpec reserved ranges (end-exclusive): [%s)\n", strings.Join(got, "), ["))
	// The proto says `reserved 3, 4, 5;`, which protoc encodes as one
	// single-number range per number. Check the set really is {3,4,5}: those
	// field numbers can never come back, which is why secret_key is number 6.
	rr := ms.ReservedRanges()
	for _, n := range []int32{3, 4, 5} {
		if !rr.Has(protoreflect.FieldNumber(n)) {
			return fmt.Errorf("expected ModelSpec field number %d to be reserved", n)
		}
	}
	for _, n := range []int32{1, 2, 6, 7} {
		if rr.Has(protoreflect.FieldNumber(n)) {
			return fmt.Errorf("ModelSpec reserves field number %d, but the message uses it", n)
		}
	}
	fmt.Println("  => field numbers 3, 4, 5 are burned; secret_key had to move to 6.")
	if rn := ms.ReservedNames(); rn.Len() > 0 {
		names := make([]string, 0, rn.Len())
		for j := 0; j < rn.Len(); j++ {
			names = append(names, string(rn.Get(j)))
		}
		fmt.Printf("  ModelSpec reserved names (old parameter spellings): %v\n", names)
	}

	// The service is part of the same descriptor, and is what `ax` and
	// `ax-server` actually speak. Print it so lesson 03/04 have a reference.
	svcs := fd.Services()
	fmt.Println()
	for i := 0; i < svcs.Len(); i++ {
		sd := svcs.Get(i)
		fmt.Printf("  service %s {\n", sd.FullName())
		for j := 0; j < sd.Methods().Len(); j++ {
			m := sd.Methods().Get(j)
			stream := ""
			if m.IsStreamingClient() || m.IsStreamingServer() {
				stream = " (stream)"
			}
			fmt.Printf("    rpc %s(%s) returns (%s)%s\n", m.Name(), m.Input().FullName(), m.Output().FullName(), stream)
		}
		fmt.Println("  }")
	}
	return nil
}
