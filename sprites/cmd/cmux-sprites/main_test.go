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
