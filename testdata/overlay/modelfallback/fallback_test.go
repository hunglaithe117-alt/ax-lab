// Probe: what the model client does when there is no usable API key.
//
// NOT part of the axlab module. It lives under testdata/ so the Go tool never
// compiles it as part of this module (see testdata/overlay/README.md), and it
// is injected into the upstream module with `go test -overlay` so that its
// imports of github.com/google/ax/internal/model are legal.
//
// Every line printed with "CASE" below is EXECUTED behaviour of the real
// internal/model package. Nothing here is a re-implementation: it calls
// model.NewClient and Client.Generate and prints what comes back.
//
// The five cases map one-to-one onto internal/model/client.go:
//
//	no key at all            -> client.go:500  (DisableRemote || APIKey == "")
//	HTTP 401/403/429/503     -> client.go:563-567
//	HTTP 500 (contrast)      -> client.go:568  (returns an error instead)
//	HTTP 200 (positive ctl)  -> client.go:571-605 (real content)
//
// The canned text and the fake token counts come from
// internal/model/client.go:608-621 (fallbackResponse).
package model_test

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/google/ax/internal/model"
	"github.com/google/ax/pkg/apis/v1alpha1"
)

// fallbackText is client.go:610 verbatim. It is restated here only so the
// assertions below can tell "fabricated" apart from "some other canned string".
const fallbackText = "Synthesized plan using %s: Workspace environment configured " +
	"with development toolchain and dependencies matching declared goal."

func report(t *testing.T, name string, resp *model.GenerateResponse, err error) {
	t.Helper()
	if err != nil {
		fmt.Printf("CASE %-34s ERROR  %v\n", name, err)
		return
	}
	fmt.Printf("CASE %-34s model=%s\n", name, resp.Model)
	fmt.Printf("     content = %q\n", resp.Content)
	fmt.Printf("     usage   = prompt=%d completion=%d total=%d\n",
		resp.Usage.PromptTokens, resp.Usage.CompletionTokens, resp.Usage.TotalTokens)
	fmt.Printf("     looks fabricated = %v\n",
		strings.HasPrefix(resp.Content, "Synthesized plan using "))
}

// TestLabFallbackNoKey is the headline trap: a client with no API key returns a
// confident, plausible plan, nil error, and invented token counts.
func TestLabFallbackNoKey(t *testing.T) {
	// SecretKey is nil *and* Name is neither "" nor "default-model", so
	// NewClient (client.go:245-250) does not inject a default secret and
	// resolveAPIKey (client.go:271-298) returns "" without shelling out to
	// kubectl. The point of the case is the empty key, not the lookup.
	client := model.NewClient(model.Config{
		Name:       "lab-model",
		Atespace:   "default",
		Provider:   model.ProviderGoogle,
		Model:      model.DefaultModel,
		SecretKey:  nil,
		Parameters: map[string]any{"temperature": 0.2},
	})
	if got := client.Config().APIKey; got != "" {
		t.Fatalf("expected an empty API key, got %q", got)
	}
	prompt := "Synthesize an environment bootstrap and toolchain plan for workspace \"ws\" with goal \"ship it\"."
	resp, err := client.Generate(context.Background(), &model.GenerateRequest{
		Model:  model.DefaultModel,
		Prompt: prompt,
	})
	report(t, "no API key", resp, err)

	// The trap is that nothing signals failure.
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
	want := fmt.Sprintf(fallbackText, model.DefaultModel)
	if resp.Content != want {
		t.Fatalf("content = %q, want the canned fallback %q", resp.Content, want)
	}
	// Token counts are len(prompt)/4 and len(content)/4 - arithmetic on string
	// lengths, not a real API response (client.go:616-620).
	if resp.Usage.PromptTokens != len(prompt)/4 {
		t.Errorf("prompt tokens = %d, want len(prompt)/4 = %d", resp.Usage.PromptTokens, len(prompt)/4)
	}
	if resp.Usage.CompletionTokens != len(resp.Content)/4 {
		t.Errorf("completion tokens = %d, want len(content)/4 = %d", resp.Usage.CompletionTokens, len(resp.Content)/4)
	}
	if resp.Usage.TotalTokens != (len(prompt)+len(resp.Content))/4 {
		t.Errorf("total tokens = %d, want (len(prompt)+len(content))/4 = %d",
			resp.Usage.TotalTokens, (len(prompt)+len(resp.Content))/4)
	}
	fmt.Printf("     token counts are string arithmetic: len(prompt)/4=%d, len(content)/4=%d\n",
		len(prompt)/4, len(resp.Content)/4)
}

// TestLabFallbackOnHTTPStatus sweeps the exact status codes that trigger the
// fallback, plus two controls that must NOT fabricate.
func TestLabFallbackOnHTTPStatus(t *testing.T) {
	cases := []struct {
		status      int
		body        string
		wantContent string // "" means "must not be the canned fallback"
		label       string
	}{
		{401, `{"error":{"message":"API key not valid"}}`, "", "HTTP 401 (bad key)"},
		{403, `{"error":{"message":"permission denied"}}`, "", "HTTP 403"},
		{429, `{"error":{"message":"quota exceeded"}}`, "", "HTTP 429 (rate limited)"},
		{503, `{"error":{"message":"backend overloaded"}}`, "", "HTTP 503 (unavailable)"},
		{500, `{"error":{"message":"boom"}}`, "", "HTTP 500 (contrast)"},
		{400, `{"error":{"message":"bad request"}}`, "", "HTTP 400 (contrast)"},
		{200, `{"candidates":[{"content":{"parts":[{"text":"REAL ANSWER FROM THE SERVER"}]}}],` +
			`"usageMetadata":{"promptTokenCount":111,"candidatesTokenCount":222,"totalTokenCount":333}}`,
			"REAL ANSWER FROM THE SERVER", "HTTP 200 (positive control)"},
	}

	for _, tc := range cases {
		tc := tc
		srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(tc.status)
			_, _ = w.Write([]byte(tc.body))
		}))

		// A real (but fake) key plus a loopback base URL: the request really
		// goes out, and the status really decides the outcome. No egress.
		client := model.NewClient(model.Config{
			Provider: model.ProviderGoogle,
			Model:    model.DefaultModel,
		},
			model.WithAPIKey("not-a-real-key"),
			model.WithBaseURL(srv.URL),
		)
		resp, err := client.Generate(context.Background(), &model.GenerateRequest{
			Prompt: "Configure a Go workspace",
		})
		report(t, tc.label, resp, err)
		srv.Close()

		fabricated := err == nil && strings.HasPrefix(resp.Content, "Synthesized plan using ")
		switch {
		case tc.status == 200:
			if err != nil {
				t.Fatalf("%s: unexpected error %v", tc.label, err)
			}
			if resp.Content != tc.wantContent {
				t.Fatalf("%s: content = %q, want the server's own text", tc.label, resp.Content)
			}
			if resp.Usage.TotalTokens != 333 {
				t.Errorf("%s: total tokens = %d, want the server's 333", tc.label, resp.Usage.TotalTokens)
			}
			fmt.Printf("     -> real content, real token counts\n")
		case tc.status == 401 || tc.status == 403 || tc.status == 429 || tc.status == 503:
			// The trap: a rejected or throttled request is reported as success.
			if err != nil {
				t.Fatalf("%s: expected the fallback, got error %v", tc.label, err)
			}
			if !fabricated {
				t.Fatalf("%s: expected the canned fallback, got %q", tc.label, resp.Content)
			}
			fmt.Printf("     -> FABRICATED, err == nil: the caller cannot tell\n")
		default:
			// The control: not every failure is swallowed.
			if err == nil {
				t.Fatalf("%s: expected an error, got content %q", tc.label, resp.Content)
			}
			if !strings.Contains(err.Error(), fmt.Sprintf("gemini api error %d", tc.status)) {
				t.Errorf("%s: unexpected error text %q", tc.label, err.Error())
			}
			fmt.Printf("     -> propagated as an error, not swallowed\n")
		}
	}
}

// TestLabFallbackViaCRD shows the same trap reached the way the shipped code
// reaches it: from a Model resource, via the workspace planner.
func TestLabFallbackViaCRD(t *testing.T) {
	crd := &v1alpha1.Model{
		Metadata: &v1alpha1.ObjectMeta{Name: "default-model", Atespace: "default"},
		Spec: &v1alpha1.ModelSpec{
			Provider: model.ProviderGoogle,
			Model:    model.DefaultModel,
		},
	}
	// WithDisableRemote(true) is the client's own switch for "definitely do
	// not call out" (client.go:225-229), and generateGoogle short-circuits on
	// it before the API key is ever used (client.go:500).
	client := model.NewClientFromCRD(crd, model.WithDisableRemote(true))
	resp, err := client.Generate(context.Background(), &model.GenerateRequest{
		Prompt: "Bootstrap workspace",
	})
	report(t, "via Model CRD, remote off", resp, err)
	if err != nil {
		t.Fatalf("expected no error, got %v", err)
	}
}
