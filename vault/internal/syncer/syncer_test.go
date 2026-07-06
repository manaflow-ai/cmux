package syncer

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/klauspost/compress/zstd"
	"github.com/manaflow-ai/cmux/vault/internal/agentdirs"
	"github.com/manaflow-ai/cmux/vault/internal/api"
	"github.com/manaflow-ai/cmux/vault/internal/authstore"
	"github.com/manaflow-ai/cmux/vault/internal/state"
)

func TestSyncerUploadsIncrementallyAndCompresses(t *testing.T) {
	home := t.TempDir()
	sessionRel := filepath.Join("sessions", "2026", "07", "04", "rollout-2026-07-04T00-00-00-11111111-1111-4111-8111-111111111111.jsonl")
	sessionPath := filepath.Join(home, ".codex", sessionRel)
	original := []byte(`{"type":"session_meta","payload":{"id":"11111111-1111-4111-8111-111111111111","cwd":"/repo"}}` + "\n" + `{"message":"hello"}` + "\n")
	writeTestFile(t, sessionPath, original)

	var mu sync.Mutex
	blobs := map[string][]byte{}
	committed := map[string]string{}

	blobServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		key := r.URL.Query().Get("key")
		if r.Method != "PUT" || key == "" {
			http.Error(w, "bad blob request", http.StatusBadRequest)
			return
		}
		data, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		mu.Lock()
		blobs[key] = data
		mu.Unlock()
		w.WriteHeader(http.StatusOK)
	}))
	defer blobServer.Close()

	apiServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("content-type", "application/json")
		switch r.URL.Path {
		case "/api/vault/uploads":
			var body struct {
				Items []api.UploadItem `json:"items"`
			}
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
			var items []api.UploadResult
			mu.Lock()
			for _, item := range body.Items {
				key := item.Agent + "/" + item.RelPath
				if committed[key] == item.SHA256 {
					items = append(items, api.UploadResult{Agent: item.Agent, AgentSessionID: item.AgentSessionID, RelPath: item.RelPath, Status: "unchanged"})
				} else {
					items = append(items, api.UploadResult{
						Agent:          item.Agent,
						AgentSessionID: item.AgentSessionID,
						RelPath:        item.RelPath,
						Status:         "upload",
						ObjectKey:      key,
						PutURL:         blobServer.URL + "/put?key=" + key,
					})
				}
			}
			mu.Unlock()
			_ = json.NewEncoder(w).Encode(api.UploadsResponse{Items: items})
		case "/api/vault/sessions/commit":
			var body struct {
				Items []api.UploadItem `json:"items"`
			}
			if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
				http.Error(w, err.Error(), http.StatusBadRequest)
				return
			}
			var items []api.CommitResult
			mu.Lock()
			for _, item := range body.Items {
				key := item.Agent + "/" + item.RelPath
				if _, ok := blobs[key]; !ok {
					items = append(items, api.CommitResult{Agent: item.Agent, AgentSessionID: item.AgentSessionID, RelPath: item.RelPath, Status: "error", Error: "object_missing"})
					continue
				}
				committed[key] = item.SHA256
				items = append(items, api.CommitResult{Agent: item.Agent, AgentSessionID: item.AgentSessionID, RelPath: item.RelPath, Status: "committed", SessionID: "session-row"})
			}
			mu.Unlock()
			_ = json.NewEncoder(w).Encode(api.CommitResponse{Items: items})
		default:
			http.NotFound(w, r)
		}
	}))
	defer apiServer.Close()

	store, err := state.Load(home, map[string]string{"CMUX_VAULT_STATE_DIR": filepath.Join(home, "state")})
	if err != nil {
		t.Fatal(err)
	}
	engine := Engine{
		Env:     agentdirs.Environ{HomeDir: home, Vars: map[string]string{}},
		State:   store,
		Client:  api.New(apiServer.URL, &authstore.Tokens{AccessToken: "access", RefreshToken: "refresh"}),
		TempDir: filepath.Join(home, "tmp"),
	}

	first, err := engine.Sync(context.Background(), Options{Agent: "codex"})
	if err != nil {
		t.Fatal(err)
	}
	if first.Uploaded != 1 || first.Skipped != 0 || first.Failed != 0 {
		t.Fatalf("first summary = %#v", first)
	}
	key := "codex/" + filepath.ToSlash(sessionRel)
	mu.Lock()
	compressed := append([]byte(nil), blobs[key]...)
	mu.Unlock()
	if len(compressed) == 0 {
		t.Fatal("missing compressed upload")
	}
	if got := decompressZstd(t, compressed); !bytes.Equal(got, original) {
		t.Fatalf("decompressed upload mismatch\n got: %q\nwant: %q", got, original)
	}

	second, err := engine.Sync(context.Background(), Options{Agent: "codex"})
	if err != nil {
		t.Fatal(err)
	}
	if second.Uploaded != 0 || second.Skipped != 1 || second.Failed != 0 {
		t.Fatalf("second summary = %#v", second)
	}

	updated := append(original, []byte(`{"message":"updated"}`+"\n")...)
	writeTestFile(t, sessionPath, updated)
	future := time.Now().Add(2 * time.Second)
	if err := os.Chtimes(sessionPath, future, future); err != nil {
		t.Fatal(err)
	}
	third, err := engine.Sync(context.Background(), Options{Agent: "codex"})
	if err != nil {
		t.Fatal(err)
	}
	if third.Uploaded != 1 || third.Failed != 0 {
		t.Fatalf("third summary = %#v", third)
	}
}

func writeTestFile(t *testing.T, path string, data []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatal(err)
	}
}

func decompressZstd(t *testing.T, data []byte) []byte {
	t.Helper()
	decoder, err := zstd.NewReader(bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	defer decoder.Close()
	got, err := io.ReadAll(decoder)
	if err != nil {
		t.Fatal(err)
	}
	return got
}
