// Lesson 02 - validation: what the API server refuses before it stores
// anything, and the exact strings it refuses with.
//
// Every function called here is the real one from
// github.com/google/ax/pkg/apis/v1alpha1:
//
//	ValidateName(s string) error                      types.go:260
//	ValidateObjectMeta(*ObjectMeta) error             types.go:272
//	ValidateWorkspace(*Workspace) error               types.go:286
//	ValidateModel(*Model) error                       types.go:303
//	ValidateTask(*Task) error                         types.go:309
//
// The API server calls exactly these before saving anything
// (internal/server/server.go:116, 293, 359) and converts the returned error
// into gRPC status InvalidArgument with the message passed through verbatim,
// so the strings printed below are what `ax apply` puts on stderr.
//
// The lesson is negative-control-first: every "must be rejected" case is
// checked to actually be rejected, and every "must be accepted" case is
// checked to actually be accepted. If upstream ever loosens a rule, this
// program fails instead of quietly printing a stale claim.
package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/google/ax/pkg/apis/v1alpha1"
	"gopkg.in/yaml.v3"
)

var failures int

func main() {
	if err := run(); err != nil {
		fmt.Fprintf(os.Stderr, "lesson 02 failed: %v\n", err)
		os.Exit(1)
	}
	if failures > 0 {
		fmt.Fprintf(os.Stderr, "lesson 02 failed: %d expectation(s) did not hold\n", failures)
		os.Exit(1)
	}
}

func run() error {
	examplesDir := upstreamExamplesDir()
	fmt.Println("== ax lesson 02: validation and the strict decoder ==")

	if err := validExamples(examplesDir); err != nil {
		return err
	}
	if err := nameRules(); err != nil {
		return err
	}
	if err := objectMetaRules(); err != nil {
		return err
	}
	if err := workspaceRules(); err != nil {
		return err
	}
	if err := modelRules(); err != nil {
		return err
	}
	if err := taskRules(); err != nil {
		return err
	}
	if err := strictDecoding(); err != nil {
		return err
	}
	if err := legacyShapes(); err != nil {
		return err
	}

	fmt.Printf("\nall expectations held\n")
	return nil
}

func upstreamExamplesDir() string {
	if v := os.Getenv("AX_UPSTREAM"); v != "" {
		return filepath.Join(v, "examples")
	}
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

// ---------------------------------------------------------------------------
// expectations
// ---------------------------------------------------------------------------

// mustAccept asserts the call returned no error.
func mustAccept(what string, err error) {
	if err != nil {
		failures++
		fmt.Printf("  FAIL  %-58s got error: %v\n", what, err)
		return
	}
	fmt.Printf("  ok    %-58s accepted\n", what)
}

// mustReject asserts the call returned an error containing want, and prints
// the real message so the learner sees the actual string, not a paraphrase.
func mustReject(what, want string, err error) {
	if err == nil {
		failures++
		fmt.Printf("  FAIL  %-58s ACCEPTED but should have been rejected\n", what)
		return
	}
	got := err.Error()
	status := "ok   "
	if want != "" && !strings.Contains(got, want) {
		failures++
		status = "FAIL "
	}
	fmt.Printf("  %s %-58s rejected: %s\n", status, what, got)
}

// mustEqual asserts something about a decoded value rather than about an
// error: `got` must be exactly `want`.
func mustEqual(what, want, got string) {
	if got != want {
		failures++
		fmt.Printf("  FAIL  %-58s got %q, want %q\n", what, got, want)
		return
	}
	fmt.Printf("  ok    %-58s %q\n", what, got)
}

// mustCount is the counted assertion: without it, a document that quietly
// stops being decoded (a broken file, an unrecognised `kind`) would just make
// this lesson check *fewer* things and still report success. `what` is only
// printed as ok when got and want agree.
func mustCount(what string, want, got int) {
	if got != want {
		failures++
		fmt.Printf("  FAIL  %-58s got %d, want %d\n", what, got, want)
		return
	}
	fmt.Printf("  ok    %-58s %d\n", what, got)
}

// ---------------------------------------------------------------------------
// 1. the shipped examples are valid
// ---------------------------------------------------------------------------

// expectedDocs is how many manifest documents the two shipped example files
// contain between them: three in task.yaml (Task, Workspace, Model) and one in
// simple.yaml (Task). Every one of them is validated, and mustCount proves it,
// so skipping one fails the lesson instead of quietly reducing its coverage.
const expectedDocs = 4

// validExamples streams each shipped example the way `ax apply` does and runs
// the real validator over every document it finds.
//
// The three rules below are the point of this function, and each one exists
// because its absence was a way for this lesson to pass while checking nothing:
//
//  1. the decode loop stops only on io.EOF. Any other error is a real failure
//     and is returned, not swallowed by a bare `break`.
//  2. the kind switch has a default arm, so a `kind:` this program has never
//     heard of is a hard error instead of a skipped document.
//  3. the number of documents actually validated is counted and compared
//     against expectedDocs.
func validExamples(dir string) error {
	fmt.Println("\n-- the manifests upstream ships must pass validation --")
	total := 0
	for _, name := range []string{"task.yaml", "simple.yaml"} {
		data, err := os.ReadFile(filepath.Join(dir, name))
		if err != nil {
			return fmt.Errorf("reading %s: %w", name, err)
		}
		dec := yaml.NewDecoder(bytes.NewReader(data))
		docs := 0
		for i := 1; ; i++ {
			var doc yaml.Node
			if err := dec.Decode(&doc); err != nil {
				// io.EOF is the only way out of this loop. Anything else is a
				// syntax error in the file, and it must fail the lesson.
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
				return fmt.Errorf("reading kind of document %d of %s: %w", i, name, err)
			}
			switch head.Kind {
			case v1alpha1.KindTask:
				var t v1alpha1.Task
				if err := doc.Content[0].Decode(&t); err != nil {
					return fmt.Errorf("decoding Task in document %d of %s: %w", i, name, err)
				}
				mustAccept(fmt.Sprintf("%s %q ValidateTask", name, t.GetMetadata().GetName()), v1alpha1.ValidateTask(&t))
			case v1alpha1.KindWorkspace:
				var w v1alpha1.Workspace
				if err := doc.Content[0].Decode(&w); err != nil {
					return fmt.Errorf("decoding Workspace in document %d of %s: %w", i, name, err)
				}
				mustAccept(fmt.Sprintf("%s %q ValidateWorkspace", name, w.GetMetadata().GetName()), v1alpha1.ValidateWorkspace(&w))
			case v1alpha1.KindModel:
				var m v1alpha1.Model
				if err := doc.Content[0].Decode(&m); err != nil {
					return fmt.Errorf("decoding Model in document %d of %s: %w", i, name, err)
				}
				mustAccept(fmt.Sprintf("%s %q ValidateModel", name, m.GetMetadata().GetName()), v1alpha1.ValidateModel(&m))
			default:
				// Without this arm an unknown `kind:` decodes into nothing at
				// all: zero expectations, zero output, exit 0.
				return fmt.Errorf("document %d of %s has unsupported kind %q", i, name, head.Kind)
			}
			docs++
		}
		fmt.Printf("        %s contributed %d validated document(s)\n", name, docs)
		total += docs
	}
	mustCount("shipped example documents validated", expectedDocs, total)
	return nil
}

// ---------------------------------------------------------------------------
// 2. ValidateName: lowercase RFC 1123 label, at most MaxNameLength (63)
// ---------------------------------------------------------------------------

func nameRules() error {
	fmt.Println("\n-- ValidateName: ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$, max 63 chars (types.go:256-268) --")
	tooLong := strings.Repeat("a", v1alpha1.MaxNameLength+1)
	for _, tc := range []struct{ name, label string }{
		{"task123", "valid"},
		{"default-workspace", "valid"},
		{"a", "valid"},
		{"9lives", "valid"},
		{"", "empty"}, // types.go:261-263 has its own message, not the regexp one
		{"Task123", "uppercase"},
		{"task_123", "underscore"},
		{"-task", "leading dash"},
		{"task-", "trailing dash"},
		{"my task", "space"},
		{"task.123", "dot"},
		{tooLong, "64 characters"},
	} {
		label := fmt.Sprintf("ValidateName(%q) %s", truncate(tc.name), tc.label)
		if tc.label == "valid" {
			mustAccept(label, v1alpha1.ValidateName(tc.name))
		} else {
			want := "must be a lowercase RFC 1123 label"
			if tc.name == "" {
				want = "must not be empty"
			}
			mustReject(label, want, v1alpha1.ValidateName(tc.name))
		}
	}
	return nil
}

func truncate(s string) string {
	if len(s) > 20 {
		return s[:17] + "..."
	}
	return s
}

// ---------------------------------------------------------------------------
// 3. ValidateObjectMeta wraps ValidateName and reports the offending field
// ---------------------------------------------------------------------------

func objectMetaRules() error {
	fmt.Println("\n-- ValidateObjectMeta: prefixes the message with the field path (types.go:272-282) --")
	for _, tc := range []struct {
		name     string
		meta     *v1alpha1.ObjectMeta
		want     string
		accepted bool
	}{
		{"ok name + atespace", &v1alpha1.ObjectMeta{Name: "task123", Atespace: "default"}, "", true},
		{"empty atespace is fine (server defaults it)", &v1alpha1.ObjectMeta{Name: "task123"}, "", true},
		{"nil meta -> empty name", nil, "metadata.name", false},
		{"bad name", &v1alpha1.ObjectMeta{Name: "Task_1"}, "metadata.name: invalid value \"Task_1\"", false},
		{"bad atespace", &v1alpha1.ObjectMeta{Name: "task123", Atespace: "Bad NS"}, "metadata.atespace: invalid value \"Bad NS\"", false},
	} {
		label := "ValidateObjectMeta " + tc.name
		err := v1alpha1.ValidateObjectMeta(tc.meta)
		if tc.accepted {
			mustAccept(label, err)
		} else {
			mustReject(label, tc.want, err)
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// 4. ValidateWorkspace: metadata plus "every spec.files[i].path is required"
// ---------------------------------------------------------------------------

func workspaceRules() error {
	fmt.Println("\n-- ValidateWorkspace: metadata, then spec.files[i].path is required (types.go:286-299) --")
	good := &v1alpha1.Workspace{
		Metadata: &v1alpha1.ObjectMeta{Name: "ws", Atespace: "default"},
		Spec: &v1alpha1.WorkspaceSpec{
			Files: []*v1alpha1.File{{Path: "/etc/hosts", Content: "x"}},
		},
	}
	mustAccept("ValidateWorkspace with one good file", v1alpha1.ValidateWorkspace(good))

	noPath := &v1alpha1.Workspace{
		Metadata: &v1alpha1.ObjectMeta{Name: "ws", Atespace: "default"},
		Spec:     &v1alpha1.WorkspaceSpec{Files: []*v1alpha1.File{{Content: "orphan"}}},
	}
	mustReject("ValidateWorkspace file without a path", "spec.files[0]: path is required", v1alpha1.ValidateWorkspace(noPath))

	nilEntry := &v1alpha1.Workspace{
		Metadata: &v1alpha1.ObjectMeta{Name: "ws", Atespace: "default"},
		Spec:     &v1alpha1.WorkspaceSpec{Files: []*v1alpha1.File{nil}},
	}
	mustReject("ValidateWorkspace nil file entry", "spec.files[0]: path is required", v1alpha1.ValidateWorkspace(nilEntry))

	// A workspace with no spec at all is legal: the spec is optional.
	mustAccept("ValidateWorkspace with nil spec", v1alpha1.ValidateWorkspace(&v1alpha1.Workspace{
		Metadata: &v1alpha1.ObjectMeta{Name: "ws", Atespace: "default"},
	}))

	mustReject("ValidateWorkspace with a bad name", "metadata.name", v1alpha1.ValidateWorkspace(&v1alpha1.Workspace{
		Metadata: &v1alpha1.ObjectMeta{Name: "WS"},
	}))
	return nil
}

// ---------------------------------------------------------------------------
// 5. ValidateModel is just ValidateObjectMeta
// ---------------------------------------------------------------------------

func modelRules() error {
	fmt.Println("\n-- ValidateModel: no spec checks at all, only the name (types.go:303-305) --")
	mustAccept("ValidateModel with an empty spec", v1alpha1.ValidateModel(&v1alpha1.Model{
		Metadata: &v1alpha1.ObjectMeta{Name: "default-model", Atespace: "default"},
	}))
	mustReject("ValidateModel with a bad name", "metadata.name", v1alpha1.ValidateModel(&v1alpha1.Model{
		Metadata: &v1alpha1.ObjectMeta{Name: "Default_Model"},
	}))
	fmt.Println("  note: a Model with provider \"\" or a missing secretKey is still valid.")
	fmt.Println("        The model client fills those in later (internal/model/client.go:76-95, 232-250).")
	return nil
}

// ---------------------------------------------------------------------------
// 6. ValidateTask: the workspace binding rules
// ---------------------------------------------------------------------------

func taskRules() error {
	fmt.Println("\n-- ValidateTask: workspace bindings (types.go:309-343) --")

	// The path actually used for a ref: explicit path wins, otherwise
	// /workspace/<name> (types.go:233-244).
	showPaths := &v1alpha1.Task{
		Metadata: &v1alpha1.ObjectMeta{Name: "t", Atespace: "default"},
		Spec: &v1alpha1.TaskSpec{Workspaces: []*v1alpha1.WorkspaceRef{
			{Name: "alpha", Path: "/srv/alpha"},
			{Name: "beta"},
		}},
	}
	fmt.Printf("  WorkspaceRefs  = %d, WorkspacePaths = %v\n",
		len(showPaths.GetSpec().WorkspaceRefs()), showPaths.GetSpec().WorkspacePaths())
	mustAccept("distinct explicit and defaulted paths", v1alpha1.ValidateTask(showPaths))

	for _, tc := range []struct {
		label string
		spec  *v1alpha1.TaskSpec
		want  string
	}{
		{
			"ref without a name",
			&v1alpha1.TaskSpec{Workspaces: []*v1alpha1.WorkspaceRef{{Path: "/srv"}}},
			"spec.workspaces[0]: name is required",
		},
		{
			"same workspace bound twice",
			&v1alpha1.TaskSpec{Workspaces: []*v1alpha1.WorkspaceRef{{Name: "ws"}, {Name: "ws"}}},
			"spec.workspaces[1]: workspace \"ws\" is bound more than once",
		},
		{
			"relative path",
			&v1alpha1.TaskSpec{Workspaces: []*v1alpha1.WorkspaceRef{{Name: "ws", Path: "srv/ws"}}},
			"spec.workspaces[0]: path \"srv/ws\" must be absolute",
		},
		{
			"two refs, same explicit path",
			&v1alpha1.TaskSpec{Workspaces: []*v1alpha1.WorkspaceRef{
				{Name: "one", Path: "/srv/ws"}, {Name: "two", Path: "/srv/ws"}}},
			"spec.workspaces[1]: path \"/srv/ws\" is already used by workspace \"one\"",
		},
		{
			"two refs, same path modulo trailing slash",
			&v1alpha1.TaskSpec{Workspaces: []*v1alpha1.WorkspaceRef{
				{Name: "one", Path: "/srv/ws/"}, {Name: "two", Path: "/srv/ws"}}},
			"is already used by workspace \"one\"",
		},
		{
			"explicit path collides with another ref's defaulted path",
			&v1alpha1.TaskSpec{Workspaces: []*v1alpha1.WorkspaceRef{
				{Name: "one", Path: "/workspace/two"}, {Name: "two"}}},
			"is already used by workspace \"one\"",
		},
	} {
		task := &v1alpha1.Task{
			Metadata: &v1alpha1.ObjectMeta{Name: "lab-task", Atespace: "default"},
			Spec:     tc.spec,
		}
		mustReject("ValidateTask "+tc.label, tc.want, v1alpha1.ValidateTask(task))
	}

	// The trap case above needs the defaults to line up, so show them.
	collide := &v1alpha1.TaskSpec{Workspaces: []*v1alpha1.WorkspaceRef{
		{Name: "one", Path: "/workspace/two"}, {Name: "two"}}}
	fmt.Printf("  colliding case resolves to paths %v (ref \"two\" has no path, so it\n"+
		"  defaults to %q per types.go:240) - the collision is invisible in the YAML.\n",
		collide.WorkspacePaths(), v1alpha1.DefaultWorkspacePath+"/two")

	mustReject("ValidateTask with a bad metadata.name", "metadata.name", v1alpha1.ValidateTask(&v1alpha1.Task{
		Metadata: &v1alpha1.ObjectMeta{Name: "Lab_Task"},
	}))
	mustAccept("ValidateTask with a nil spec", v1alpha1.ValidateTask(&v1alpha1.Task{
		Metadata: &v1alpha1.ObjectMeta{Name: "lab-task", Atespace: "default"},
	}))
	return nil
}

// ---------------------------------------------------------------------------
// 7. TRAP: decoding is strict - an unknown field is an error
// ---------------------------------------------------------------------------

func strictDecoding() error {
	fmt.Println("\n-- TRAP: YAML decoding is strict (types.go:60, 75-88) --")
	fmt.Println("  protojson.UnmarshalOptions{} is used with no DiscardUnknown, so a single")
	fmt.Println("  misspelled key fails the whole apply. No partial application.")

	// Positive control first: the correct spelling decodes.
	okTask := `apiVersion: ax.io/v1alpha1
kind: Task
metadata:
  name: lab-task
  atespace: default
spec:
  image: example/image
  debug: true
`
	var t v1alpha1.Task
	if err := yaml.Unmarshal([]byte(okTask), &t); err != nil {
		return fmt.Errorf("positive control failed to decode: %w", err)
	}
	fmt.Printf("  ok    positive control: image=%q debug=%v\n", t.GetSpec().GetImage(), t.GetSpec().GetDebug())

	// Positive control for the google.protobuf.Struct field: a mapping is fine.
	var pm v1alpha1.Model
	if err := yaml.Unmarshal([]byte(`apiVersion: ax.io/v1alpha1
kind: Model
metadata: {name: m, atespace: default}
spec:
  provider: google
  parameters:
    temperature: 0.3
    maxOutputTokens: 1024
`), &pm); err != nil {
		return fmt.Errorf("parameters-as-mapping should decode: %w", err)
	}
	fmt.Printf("  ok    positive control: parameters -> %v (google.protobuf.Struct)\n",
		pm.GetSpec().GetParameters().AsMap())

	for _, tc := range []struct {
		label string
		doc   string
		// want is a substring of the error the real decoder must produce.
		want string
	}{
		{
			label: "Task: spec.resources.request (should be requests)",
			want:  `unknown field "request"`,
			doc: `apiVersion: ax.io/v1alpha1
kind: Task
metadata: {name: lab-task, atespace: default}
spec:
  resources:
    request:
      cpu: "500m"
`,
		},
		{
			label: "Task: unknown top-level key specx",
			want:  `unknown field "specx"`,
			doc: `apiVersion: ax.io/v1alpha1
kind: Task
metadata: {name: lab-task, atespace: default}
specx: true
`,
		},
		{
			label: "Task: metadata.lables (ax has no labels)",
			want:  `unknown field "lables"`,
			doc: `apiVersion: ax.io/v1alpha1
kind: Task
metadata: {name: lab-task, atespace: default, lables: {app: x}}
`,
		},
		{
			label: "Task: spec.debug as a string, not a bool",
			want:  `invalid value for bool field debug`,
			doc: `apiVersion: ax.io/v1alpha1
kind: Task
metadata: {name: lab-task, atespace: default}
spec:
  debug: "true"
`,
		},
		{
			label: "Workspace: spec.git[].brnach (should be branch)",
			want:  `unknown field "brnach"`,
			doc: `apiVersion: ax.io/v1alpha1
kind: Workspace
metadata: {name: ws, atespace: default}
spec:
  git:
    - name: origin
      repo: https://example.com/x.git
      brnach: main
`,
		},
		{
			label: "Model: spec.secretkey (lower k) instead of secretKey",
			want:  `unknown field "secretkey"`,
			doc: `apiVersion: ax.io/v1alpha1
kind: Model
metadata: {name: m, atespace: default}
spec:
  provider: google
  model: gemini-3.8-flash
  secretkey: {name: s, key: K}
`,
		},
		{
			label: "Model: parameters is a Struct, so a scalar is rejected",
			want:  "syntax error",
			doc: `apiVersion: ax.io/v1alpha1
kind: Model
metadata: {name: m, atespace: default}
spec:
  provider: google
  parameters: 0.3
`,
		},
	} {
		kind := kindOf(tc.doc)
		var err error
		switch kind {
		case v1alpha1.KindTask:
			var m v1alpha1.Task
			err = yaml.Unmarshal([]byte(tc.doc), &m)
		case v1alpha1.KindWorkspace:
			var m v1alpha1.Workspace
			err = yaml.Unmarshal([]byte(tc.doc), &m)
		default:
			var m v1alpha1.Model
			err = yaml.Unmarshal([]byte(tc.doc), &m)
		}
		mustReject("strict decode: "+tc.label, tc.want, err)
	}
	return nil
}

func kindOf(doc string) string {
	for _, k := range []string{v1alpha1.KindTask, v1alpha1.KindWorkspace, v1alpha1.KindModel} {
		if strings.Contains(doc, "kind: "+k) {
			return k
		}
	}
	return ""
}

// ---------------------------------------------------------------------------
// 8. strict, except for three grandfathered shapes
// ---------------------------------------------------------------------------

func legacyShapes() error {
	fmt.Println("\n-- but three legacy shapes are rewritten before strict decoding --")
	fmt.Println("  (types.go:55-56, 162-191) - the reason some 'wrong' YAML still works:")

	var w v1alpha1.Workspace
	if err := yaml.Unmarshal([]byte(`apiVersion: ax.io/v1alpha1
kind: Workspace
metadata: {name: ws, atespace: default}
spec:
  mcp:
    - name: git-tools
      endpoint: http://127.0.0.1:9/mcp
`), &w); err != nil {
		return fmt.Errorf("legacy mcp-as-list should be accepted: %w", err)
	}
	// The bare list is not merely tolerated, it is rewritten to mcp.servers
	// (types.go:162-167). The `if err != nil` above is the accept check; the
	// real assertion is that the rewrite actually landed, which a
	// mustAccept(label, nil) could never tell us.
	servers := w.GetSpec().GetMcp().GetServers()
	if len(servers) != 1 {
		failures++
		fmt.Printf("  FAIL  %-58s got %d server(s), want 1\n",
			"Workspace spec.mcp list -> mcp.servers", len(servers))
		return nil
	}
	fmt.Printf("  ok    %-58s accepted\n", "Workspace spec.mcp written as a bare list")
	mustEqual("  rewritten to mcp.servers[0].name", "git-tools", servers[0].GetName())
	mustEqual("  rewritten to mcp.servers[0].endpoint", "http://127.0.0.1:9/mcp", servers[0].GetEndpoint())

	for _, tc := range []struct {
		shape    string
		wantName string
		wantKey  string
		doc      string
	}{
		{
			shape:    "spec.secretKeyRef: {name, key}",
			wantName: "my-secret",
			wantKey:  "MY_KEY",
			doc: `apiVersion: ax.io/v1alpha1
kind: Model
metadata: {name: m, atespace: default}
spec:
  provider: google
  secretKeyRef: {name: my-secret, key: MY_KEY}
`,
		},
		{
			shape:    "spec.apiKey.secretKeyRef: {name, key}",
			wantName: "my-secret",
			wantKey:  "MY_KEY",
			doc: `apiVersion: ax.io/v1alpha1
kind: Model
metadata: {name: m, atespace: default}
spec:
  provider: google
  apiKey: {secretKeyRef: {name: my-secret, key: MY_KEY}}
`,
		},
		{
			// types.go:188-190: a bare string becomes {name: s, key: s}, so
			// the key defaults to the name.
			shape:    "spec.secretKey: <bare string>",
			wantName: "my-secret",
			wantKey:  "my-secret",
			doc: `apiVersion: ax.io/v1alpha1
kind: Model
metadata: {name: m, atespace: default}
spec:
  provider: google
  secretKey: my-secret
`,
		},
	} {
		var m v1alpha1.Model
		if err := yaml.Unmarshal([]byte(tc.doc), &m); err != nil {
			failures++
			fmt.Printf("  FAIL  %-58s rejected: %v\n", "legacy Model "+tc.shape, err)
			continue
		}
		fmt.Printf("  ok    %-58s accepted\n", "legacy Model "+tc.shape)
		mustEqual("  rewritten to secretKey.name", tc.wantName, m.GetSpec().GetSecretKey().GetName())
		mustEqual("  rewritten to secretKey.key", tc.wantKey, m.GetSpec().GetSecretKey().GetKey())
	}
	return nil
}
