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
)

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
	got, err := login(context.Background(), newClient(server.URL, nil), false, &output)
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

	got, err := login(context.Background(), newClient(server.URL, nil), false, io.Discard)
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
	target := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		targetCalled = true
		response.WriteHeader(http.StatusNoContent)
	}))
	defer target.Close()
	source := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		http.Redirect(response, request, target.URL, http.StatusTemporaryRedirect)
	}))
	defer source.Close()

	redirecting := newClient(source.URL, &tokens{
		AccessToken:  "access",
		RefreshToken: "refresh",
	})
	err := redirecting.request(context.Background(), http.MethodGet, "/", nil, nil)
	if err == nil || !strings.Contains(err.Error(), "refusing cross-origin API redirect") {
		t.Fatalf("cross-origin redirect error = %v", err)
	}
	if targetCalled {
		t.Fatal("credential-bearing redirect reached the second origin")
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
