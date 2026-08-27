package resume

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/klauspost/compress/zstd"
	"github.com/manaflow-ai/cmux/vault/internal/agentdirs"
	"github.com/manaflow-ai/cmux/vault/internal/api"
	"github.com/manaflow-ai/cmux/vault/internal/authstore"
)

func TestResumeRestoresDeletedCodexSessionAndRefusesOverwrite(t *testing.T) {
	home := t.TempDir()
	sessionID := "11111111-1111-4111-8111-111111111111"
	relPath := "sessions/2026/07/04/rollout-2026-07-04T00-00-00-" + sessionID + ".jsonl"
	plain := []byte(`{"type":"session_meta","payload":{"id":"` + sessionID + `","cwd":"/repo"}}` + "\n")
	compressed := compressZstd(t, plain)

	blobServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(compressed)
	}))
	defer blobServer.Close()

	apiServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("content-type", "application/json")
		switch {
		case r.URL.Path == "/api/vault/sessions":
			_ = json.NewEncoder(w).Encode(api.SessionsResponse{Sessions: []api.Session{{
				ID:             "cloud-session",
				Agent:          "codex",
				AgentSessionID: sessionID,
				RelPath:        relPath,
				CWD:            "/repo",
			}}})
		case r.URL.Path == "/api/vault/sessions/cloud-session":
			_ = json.NewEncoder(w).Encode(api.SessionDetail{
				Session: api.Session{
					ID:             "cloud-session",
					Agent:          "codex",
					AgentSessionID: sessionID,
					RelPath:        relPath,
					CWD:            "/repo",
					DownloadURL:    blobServer.URL + "/object",
				},
			})
		default:
			http.NotFound(w, r)
		}
	}))
	defer apiServer.Close()

	restorer := Restorer{
		Env:    agentdirs.Environ{HomeDir: home, Vars: map[string]string{}},
		Client: api.New(apiServer.URL, &authstore.Tokens{AccessToken: "access", RefreshToken: "refresh"}),
	}
	hint, err := restorer.Resume(context.Background(), sessionID, Options{Agent: "codex"})
	if err != nil {
		t.Fatal(err)
	}
	if hint != "codex resume "+sessionID {
		t.Fatalf("hint = %q", hint)
	}
	restoredPath := filepath.Join(home, ".codex", filepath.FromSlash(relPath))
	got, err := os.ReadFile(restoredPath)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, plain) {
		t.Fatalf("restored bytes = %q", got)
	}

	overwriteSessionID := "22222222-2222-4222-8222-222222222222"
	overwriteRelPath := "sessions/2026/07/04/not-a-discovered-session.jsonl"
	writeResumeFile(t, filepath.Join(home, ".codex", filepath.FromSlash(overwriteRelPath)), []byte("existing\n"))
	apiServer.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("content-type", "application/json")
		switch {
		case r.URL.Path == "/api/vault/sessions":
			_ = json.NewEncoder(w).Encode(api.SessionsResponse{Sessions: []api.Session{{
				ID:             "cloud-overwrite",
				Agent:          "codex",
				AgentSessionID: overwriteSessionID,
				RelPath:        overwriteRelPath,
				CWD:            "/repo",
			}}})
		case r.URL.Path == "/api/vault/sessions/cloud-overwrite":
			_ = json.NewEncoder(w).Encode(api.SessionDetail{
				Session: api.Session{
					ID:             "cloud-overwrite",
					Agent:          "codex",
					AgentSessionID: overwriteSessionID,
					RelPath:        overwriteRelPath,
					CWD:            "/repo",
					DownloadURL:    blobServer.URL + "/object",
				},
			})
		default:
			http.NotFound(w, r)
		}
	})
	_, err = restorer.Resume(context.Background(), overwriteSessionID, Options{Agent: "codex"})
	if err == nil || !strings.Contains(err.Error(), "already exists") {
		t.Fatalf("expected overwrite refusal, got %v", err)
	}
}

func compressZstd(t *testing.T, data []byte) []byte {
	t.Helper()
	var buf bytes.Buffer
	encoder, err := zstd.NewWriter(&buf)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := encoder.Write(data); err != nil {
		t.Fatal(err)
	}
	if err := encoder.Close(); err != nil {
		t.Fatal(err)
	}
	return buf.Bytes()
}

func writeResumeFile(t *testing.T, path string, data []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
}
