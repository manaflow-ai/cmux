package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

type fakeClock struct {
	now    time.Time
	sleeps []time.Duration
}

func (clock *fakeClock) Now() time.Time {
	return clock.now
}

func (clock *fakeClock) Sleep(ctx context.Context, delay time.Duration) error {
	select {
	case <-ctx.Done():
		return ctx.Err()
	default:
		clock.sleeps = append(clock.sleeps, delay)
		clock.now = clock.now.Add(delay)
		return nil
	}
}

func TestInvitationID(t *testing.T) {
	payload, err := json.Marshal(map[string]any{
		"id":     "invitation_123",
		"secret": "not-inspected-by-cli",
	})
	if err != nil {
		t.Fatal(err)
	}
	uri := "cmux://enroll/" + base64.RawURLEncoding.EncodeToString(payload)

	got, err := invitationID(uri)
	if err != nil {
		t.Fatal(err)
	}
	if got != "invitation_123" {
		t.Fatalf("invitationID() = %q", got)
	}
}

func TestInvitationIDRejectsMalformedValues(t *testing.T) {
	for _, value := range []string{
		"https://example.com",
		"cmux://enroll/not-base64!",
		"cmux://enroll/" + base64.RawURLEncoding.EncodeToString([]byte(`{"id":"bad id"}`)),
	} {
		if _, err := invitationID(value); err == nil {
			t.Fatalf("invitationID(%q) succeeded", value)
		}
	}
}

func TestEnrollmentURL(t *testing.T) {
	got, err := enrollmentURL("https://example.sprites.app/old?secret=no")
	if err != nil {
		t.Fatal(err)
	}
	if got != "wss://example.sprites.app/v1/link" {
		t.Fatalf("enrollmentURL() = %q", got)
	}
	if _, err := enrollmentURL("http://example.sprites.app"); err == nil {
		t.Fatal("insecure enrollment URL succeeded")
	}
}

func TestShellJoinQuotesArguments(t *testing.T) {
	got := shellJoin([]string{"printf", "%s", "hello; rm -rf /"})
	want := "'printf' '%s' 'hello; rm -rf /'"
	if got != want {
		t.Fatalf("shellJoin() = %q, want %q", got, want)
	}
}

func TestLoginPrintsCopyPasteCodeAndBindsClient(t *testing.T) {
	var startedClient string
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/api/vault/cli/auth/start":
			body, _ := io.ReadAll(request.Body)
			var value map[string]string
			_ = json.Unmarshal(body, &value)
			startedClient = value["client"]
			_ = json.NewEncoder(response).Encode(authStart{
				DeviceCode:       strings.Repeat("a", 64),
				UserCode:         "ABCD2345",
				VerificationURL:  "https://cmux.test/approve",
				ExpiresInSeconds: 60,
				IntervalSeconds:  1,
			})
		case "/api/vault/cli/auth/poll":
			_ = json.NewEncoder(response).Encode(authPoll{
				Status:       "approved",
				Client:       "cmux-sprites",
				AccessToken:  "access",
				RefreshToken: "refresh",
			})
		default:
			http.NotFound(response, request)
		}
	}))
	defer server.Close()

	var output strings.Builder
	clock := &fakeClock{now: time.Unix(0, 0)}
	got, err := loginWithClock(
		context.Background(),
		newClient(server.URL, nil),
		false,
		&output,
		clock,
	)
	if err != nil {
		t.Fatal(err)
	}
	if startedClient != "cmux-sprites" {
		t.Fatalf("start client = %q", startedClient)
	}
	if !strings.Contains(output.String(), "Copy and paste this code:\n  ABCD2345") {
		t.Fatalf("login output did not contain copy-paste code: %q", output.String())
	}
	if got.AccessToken != "access" || got.RefreshToken != "refresh" {
		t.Fatalf("login tokens = %#v", got)
	}
	if len(clock.sleeps) != 1 || clock.sleeps[0] != time.Second {
		t.Fatalf("login sleeps = %v", clock.sleeps)
	}
}

func TestLoginRejectsCredentialsMintedForAnotherClient(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		switch request.URL.Path {
		case "/api/vault/cli/auth/start":
			_ = json.NewEncoder(response).Encode(authStart{
				DeviceCode:       strings.Repeat("a", 64),
				UserCode:         "ABCD2345",
				VerificationURL:  "https://cmux.test/approve",
				ExpiresInSeconds: 60,
				IntervalSeconds:  1,
			})
		case "/api/vault/cli/auth/poll":
			_ = json.NewEncoder(response).Encode(authPoll{
				Status:       "approved",
				Client:       "cmux-vault",
				AccessToken:  "must-not-return",
				RefreshToken: "must-not-return",
			})
		default:
			http.NotFound(response, request)
		}
	}))
	defer server.Close()

	got, err := loginWithClock(
		context.Background(),
		newClient(server.URL, nil),
		false,
		io.Discard,
		&fakeClock{now: time.Unix(0, 0)},
	)
	if err == nil {
		t.Fatal("login accepted credentials for cmux-vault")
	}
	if got.AccessToken != "" || got.RefreshToken != "" {
		t.Fatalf("login returned mismatched tokens: %#v", got)
	}
}

func TestAPIClientRejectsInsecureRemoteBaseAndCrossOriginRedirects(t *testing.T) {
	insecure := newClient("http://example.com", &tokens{
		AccessToken:  "access",
		RefreshToken: "refresh",
	})
	if err := insecure.request(context.Background(), http.MethodGet, "/api/vm", nil, nil); err == nil {
		t.Fatal("insecure remote API base succeeded")
	}

	targetCalled := false
	target := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		targetCalled = true
		response.WriteHeader(http.StatusNoContent)
	}))
	defer target.Close()
	source := httptest.NewTLSServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		http.Redirect(response, request, target.URL, http.StatusTemporaryRedirect)
	}))
	defer source.Close()

	redirecting := newClient(source.URL, &tokens{
		AccessToken:  "access",
		RefreshToken: "refresh",
	})
	redirecting.http.Transport = source.Client().Transport
	err := redirecting.request(context.Background(), http.MethodGet, "/", nil, nil)
	if err == nil || !strings.Contains(err.Error(), "refusing cross-origin API redirect") {
		t.Fatalf("cross-origin redirect error = %v", err)
	}
	if targetCalled {
		t.Fatal("credential-bearing redirect reached the second origin")
	}
}

func TestCredentialedClientRequiresHTTPSEvenOnLoopback(t *testing.T) {
	client := newClient("http://127.0.0.1:4733", &tokens{
		AccessToken:  "access",
		RefreshToken: "refresh",
	})
	err := client.request(context.Background(), http.MethodGet, "/api/vm", nil, nil)
	if err == nil || !strings.Contains(err.Error(), "credentialed cmux API requests require HTTPS") {
		t.Fatalf("credentialed loopback HTTP error = %v", err)
	}
}

func TestAPIClientDoesNotExposeRawErrorBodies(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		response.WriteHeader(http.StatusBadGateway)
		_, _ = response.Write([]byte(`{"error":"vm_cloud_service_unavailable","details":{"providerMessage":"SPRITE_TOKEN secret-provider-detail"}}`))
	}))
	defer server.Close()

	err := newClient(server.URL, nil).request(
		context.Background(),
		http.MethodGet,
		"/api/vm",
		nil,
		nil,
	)
	if err == nil {
		t.Fatal("error response succeeded")
	}
	if strings.Contains(err.Error(), "SPRITE_TOKEN") ||
		strings.Contains(err.Error(), "secret-provider-detail") {
		t.Fatalf("raw API body leaked: %v", err)
	}
	if !strings.Contains(err.Error(), "code vm_cloud_service_unavailable") {
		t.Fatalf("safe error code missing: %v", err)
	}
}

type fakeEnrollmentExecutor struct {
	results  []execResult
	errors   []error
	timeouts []int
}

func (executor *fakeEnrollmentExecutor) execWithTimeout(
	_ context.Context,
	_ string,
	_ string,
	timeout int,
) (execResult, error) {
	executor.timeouts = append(executor.timeouts, timeout)
	index := len(executor.timeouts) - 1
	var result execResult
	if index < len(executor.results) {
		result = executor.results[index]
	}
	var err error
	if index < len(executor.errors) {
		err = executor.errors[index]
	}
	return result, err
}

func TestApproveEnrollmentUsesInjectedCancellationAwareRetry(t *testing.T) {
	executor := &fakeEnrollmentExecutor{
		results: []execResult{
			{ExitCode: 0, Stdout: "[]"},
			{ExitCode: 0, Stdout: `[{"invitation_id":"invite-1"}]`},
			{ExitCode: 0},
		},
	}
	clock := &fakeClock{now: time.Unix(0, 0)}

	err := approveEnrollmentWithClock(
		context.Background(),
		executor,
		"sprite-1",
		"invite-1",
		clock,
		10*time.Second,
	)
	if err != nil {
		t.Fatal(err)
	}
	if len(clock.sleeps) != 1 || clock.sleeps[0] != time.Second {
		t.Fatalf("retry sleeps = %v", clock.sleeps)
	}
	for _, timeout := range executor.timeouts {
		if timeout != 8_000 {
			t.Fatalf("exec timeout = %d", timeout)
		}
	}
}
