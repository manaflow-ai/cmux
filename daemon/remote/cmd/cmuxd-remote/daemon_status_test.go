package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRunStdioDaemonStatus(t *testing.T) {
	input := strings.NewReader(`{"id":1,"method":"daemon.status","params":{}}` + "\n")
	var out bytes.Buffer
	code := run([]string{"serve", "--stdio"}, input, &out, &bytes.Buffer{})
	if code != 0 {
		t.Fatalf("run serve exit code = %d, want 0", code)
	}

	var response map[string]any
	if err := json.Unmarshal([]byte(strings.TrimSpace(out.String())), &response); err != nil {
		t.Fatalf("failed to decode daemon.status response: %v", err)
	}
	if ok, _ := response["ok"].(bool); !ok {
		t.Fatalf("daemon.status should be ok=true: %v", response)
	}
	result, _ := response["result"].(map[string]any)
	if result == nil {
		t.Fatalf("daemon.status result missing: %v", response)
	}
	if got := result["name"]; got != "cmuxd-remote" {
		t.Fatalf("daemon.status name = %v, want cmuxd-remote", got)
	}
	if got := result["version"]; got != version {
		t.Fatalf("daemon.status version = %v, want %q", got, version)
	}
	pid, ok := result["pid"].(float64)
	if !ok || pid <= 0 {
		t.Fatalf("daemon.status pid = %v, want > 0", result["pid"])
	}
	startedAt, ok := result["started_at_unix"].(float64)
	if !ok || startedAt <= 0 {
		t.Fatalf("daemon.status started_at_unix = %v, want > 0", result["started_at_unix"])
	}
	uptime, ok := result["uptime_seconds"].(float64)
	if !ok || uptime < 0 {
		t.Fatalf("daemon.status uptime_seconds = %v, want >= 0", result["uptime_seconds"])
	}
	sessions, ok := result["pty_sessions"].(float64)
	if !ok || sessions != 0 {
		t.Fatalf("daemon.status pty_sessions = %v, want 0", result["pty_sessions"])
	}
}

func TestHelloCapabilitiesIncludeDaemonStatus(t *testing.T) {
	input := strings.NewReader(`{"id":1,"method":"hello","params":{}}` + "\n")
	var out bytes.Buffer
	code := run([]string{"serve", "--stdio"}, input, &out, &bytes.Buffer{})
	if code != 0 {
		t.Fatalf("run serve exit code = %d, want 0", code)
	}

	var response map[string]any
	if err := json.Unmarshal([]byte(strings.TrimSpace(out.String())), &response); err != nil {
		t.Fatalf("failed to decode hello response: %v", err)
	}
	result, _ := response["result"].(map[string]any)
	capabilities, _ := result["capabilities"].([]any)
	for _, capability := range capabilities {
		if capability == "daemon.status" {
			return
		}
	}
	t.Fatalf("hello capabilities missing daemon.status: %v", result)
}

func TestResolvePersistentDaemonIdleTimeout(t *testing.T) {
	cases := []struct {
		name    string
		seconds int
		want    time.Duration
	}{
		{name: "negative uses default", seconds: -1, want: persistentDaemonEmptyIdleTimeout},
		{name: "zero disables idle exit", seconds: 0, want: 0},
		{name: "positive uses seconds", seconds: 7, want: 7 * time.Second},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := resolvePersistentDaemonIdleTimeout(tc.seconds); got != tc.want {
				t.Fatalf("resolvePersistentDaemonIdleTimeout(%d) = %v, want %v", tc.seconds, got, tc.want)
			}
		})
	}
}

func TestRunStdioIdleTimeoutRequiresPersistentServer(t *testing.T) {
	var stderr bytes.Buffer
	code := run([]string{"serve", "--stdio", "--idle-timeout", "30"}, strings.NewReader(""), &bytes.Buffer{}, &stderr)
	if code != 2 {
		t.Fatalf("run serve exit code = %d, want 2", code)
	}
	if !strings.Contains(stderr.String(), "serve --idle-timeout requires --persistent-server") {
		t.Fatalf("stderr = %q, want --idle-timeout validation error", stderr.String())
	}
}

func TestRunIdleTimeoutRejectsOutOfRangeValues(t *testing.T) {
	for _, args := range [][]string{
		{"serve", "--persistent-server", "--slot", "vps", "--idle-timeout", "-2"},
		{"serve", "--persistent-server", "--slot", "vps", "--idle-timeout", "315360001"},
	} {
		var stderr bytes.Buffer
		code := run(args, strings.NewReader(""), &bytes.Buffer{}, &stderr)
		if code != 2 {
			t.Fatalf("run %v exit code = %d, want 2", args, code)
		}
		if !strings.Contains(stderr.String(), "--idle-timeout must be between") {
			t.Fatalf("stderr = %q, want idle-timeout range error", stderr.String())
		}
	}
}

func TestDaemonStatusCommandRequiresSlot(t *testing.T) {
	var stderr bytes.Buffer
	code := run([]string{"daemon-status", "--json"}, strings.NewReader(""), &bytes.Buffer{}, &stderr)
	if code != 2 {
		t.Fatalf("daemon-status exit code = %d, want 2", code)
	}
	if !strings.Contains(stderr.String(), "--slot") {
		t.Fatalf("stderr = %q, want missing --slot error", stderr.String())
	}
}

func TestDaemonStatusCommandReportsEmptyDaemonsList(t *testing.T) {
	rootBase := filepath.Join(t.TempDir(), "daemon-root")
	t.Setenv("CMUX_REMOTE_DAEMON_ROOT", rootBase)
	t.Setenv("CMUX_REMOTE_DAEMON_SOCKET_DIR", "")

	var out bytes.Buffer
	code := run([]string{"daemon-status", "--slot", "empty-status-slot", "--json"}, strings.NewReader(""), &out, &bytes.Buffer{})
	if code != 0 {
		t.Fatalf("daemon-status exit code = %d, want 0", code)
	}

	output := decodeDaemonStatusOutput(t, out.String())
	if got := output["binary_version"]; got != version {
		t.Fatalf("binary_version = %v, want %q", got, version)
	}
	if got := output["slot"]; got != "empty-status-slot" {
		t.Fatalf("slot = %v, want empty-status-slot", got)
	}
	if got := output["root"]; got != rootBase {
		t.Fatalf("root = %v, want %q", got, rootBase)
	}
	daemons, ok := output["daemons"].([]any)
	if !ok || len(daemons) != 0 {
		t.Fatalf("daemons = %v, want empty list", output["daemons"])
	}
}

func TestDaemonStatusCommandReportsRunningAndStaleDaemons(t *testing.T) {
	const slot = "status-e2e-slot"
	rootBase := filepath.Join(t.TempDir(), "daemon-root")
	socketParent, err := os.MkdirTemp("/tmp", "cmuxd-status-*")
	if err != nil {
		t.Fatalf("create short socket dir: %v", err)
	}
	t.Cleanup(func() {
		_ = os.RemoveAll(socketParent)
	})
	t.Setenv("CMUX_REMOTE_DAEMON_ROOT", rootBase)
	t.Setenv("CMUX_REMOTE_DAEMON_SOCKET_DIR", socketParent)

	staleRoot := filepath.Join(rootBase, "v0.0.1-stale", slot)
	if err := os.MkdirAll(staleRoot, 0o700); err != nil {
		t.Fatalf("create stale daemon root: %v", err)
	}
	if err := os.WriteFile(filepath.Join(staleRoot, "auth.token"), []byte("stale-token\n"), 0o600); err != nil {
		t.Fatalf("write stale token: %v", err)
	}

	paths, err := persistentDaemonPathsForSlot(slot)
	if err != nil {
		t.Fatalf("persistentDaemonPathsForSlot returned error: %v", err)
	}
	paths, err = ensurePersistentDaemonDirectory(paths)
	if err != nil {
		t.Fatalf("ensurePersistentDaemonDirectory returned error: %v", err)
	}
	token, err := persistentDaemonToken(paths)
	if err != nil {
		t.Fatalf("persistentDaemonToken returned error: %v", err)
	}
	listener, err := net.Listen("unix", paths.socket)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}
	done := make(chan error, 1)
	go func() {
		done <- servePersistentDaemonWithVerifier(listener, persistentDaemonFileTokenVerifier(token, paths.tokenFile), io.Discard)
	}()
	t.Cleanup(func() {
		_ = listener.Close()
		select {
		case err := <-done:
			if err != nil {
				t.Errorf("persistent daemon exited with error: %v", err)
			}
		case <-time.After(2 * time.Second):
			t.Errorf("persistent daemon did not stop")
		}
	})
	waitDaemonStatusSocketDialable(t, paths.socket, token)

	var out bytes.Buffer
	code := run([]string{"daemon-status", "--slot", slot, "--json"}, strings.NewReader(""), &out, &bytes.Buffer{})
	if code != 0 {
		t.Fatalf("daemon-status exit code = %d, want 0", code)
	}

	output := decodeDaemonStatusOutput(t, out.String())
	daemons, ok := output["daemons"].([]any)
	if !ok || len(daemons) != 2 {
		t.Fatalf("daemons = %v, want 2 entries", output["daemons"])
	}

	running := daemonStatusEntryByVersionDir(t, daemons, persistentDaemonVersionComponent())
	if got, _ := running["running"].(bool); !got {
		t.Fatalf("running daemon entry should report running=true: %v", running)
	}
	if got := running["version"]; got != version {
		t.Fatalf("running daemon version = %v, want %q", got, version)
	}
	sessions, ok := running["pty_sessions"].(float64)
	if !ok || sessions != 0 {
		t.Fatalf("running daemon pty_sessions = %v, want 0", running["pty_sessions"])
	}
	pid, ok := running["pid"].(float64)
	if !ok || int(pid) != os.Getpid() {
		t.Fatalf("running daemon pid = %v, want %d", running["pid"], os.Getpid())
	}
	if got := running["socket"]; got != paths.socket {
		t.Fatalf("running daemon socket = %v, want %q", got, paths.socket)
	}

	stale := daemonStatusEntryByVersionDir(t, daemons, "v0.0.1-stale")
	if got, _ := stale["running"].(bool); got {
		t.Fatalf("stale daemon entry should report running=false: %v", stale)
	}
	if got, hasError := stale["error"]; hasError {
		t.Fatalf("stale daemon entry should not report an error, got %v", got)
	}
}

func TestPopulateDaemonStatusFromConnFallsBackForOldDaemons(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer clientConn.Close()
	serverDone := make(chan error, 1)
	go func() {
		serverDone <- serveDaemonStatusFallbackFake(serverConn)
	}()

	entry := daemonStatusEntry{VersionDir: "v0.0.1-old"}
	populateDaemonStatusFromConn(clientConn, &entry)
	_ = clientConn.Close()
	if err := <-serverDone; err != nil {
		t.Fatalf("fake old daemon failed: %v", err)
	}

	if entry.Error != "" {
		t.Fatalf("fallback entry error = %q, want empty", entry.Error)
	}
	if !entry.Running {
		t.Fatalf("fallback entry should report running=true: %+v", entry)
	}
	if entry.Version != "v0.0.1" {
		t.Fatalf("fallback entry version = %q, want v0.0.1", entry.Version)
	}
	if entry.PTYSessions == nil || *entry.PTYSessions != 2 {
		t.Fatalf("fallback entry pty_sessions = %v, want 2", entry.PTYSessions)
	}
}

func serveDaemonStatusFallbackFake(conn net.Conn) error {
	defer conn.Close()
	reader := bufio.NewReader(conn)
	writer := &stdioFrameWriter{writer: bufio.NewWriter(conn)}
	for {
		line, err := reader.ReadBytes('\n')
		if err != nil {
			if err == io.EOF {
				return nil
			}
			return nil
		}
		var req rpcRequest
		if err := json.Unmarshal(bytes.TrimSpace(line), &req); err != nil {
			return err
		}
		switch req.Method {
		case "daemon.status":
			if err := writer.writeResponse(rpcResponse{
				ID: req.ID,
				OK: false,
				Error: &rpcError{
					Code:    "method_not_found",
					Message: `unknown method "daemon.status"`,
				},
			}); err != nil {
				return err
			}
		case "hello":
			if err := writer.writeResponse(rpcResponse{
				ID: req.ID,
				OK: true,
				Result: map[string]any{
					"name":    "cmuxd-remote",
					"version": "v0.0.1",
				},
			}); err != nil {
				return err
			}
		case "pty.list":
			if err := writer.writeResponse(rpcResponse{
				ID: req.ID,
				OK: true,
				Result: map[string]any{
					"sessions": []map[string]any{
						{"session_id": "one"},
						{"session_id": "two"},
					},
				},
			}); err != nil {
				return err
			}
		default:
			return fmt.Errorf("unexpected method %q", req.Method)
		}
	}
}

func waitDaemonStatusSocketDialable(t *testing.T, socketPath string, token string) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	var lastErr error
	for time.Now().Before(deadline) {
		conn, err := dialPersistentDaemon(socketPath, token)
		if err == nil {
			_ = conn.Close()
			return
		}
		lastErr = err
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("persistent daemon never became dialable: %v", lastErr)
}

func decodeDaemonStatusOutput(t *testing.T, raw string) map[string]any {
	t.Helper()
	var output map[string]any
	if err := json.Unmarshal([]byte(strings.TrimSpace(raw)), &output); err != nil {
		t.Fatalf("failed to decode daemon-status output %q: %v", raw, err)
	}
	return output
}

func daemonStatusEntryByVersionDir(t *testing.T, daemons []any, versionDir string) map[string]any {
	t.Helper()
	for _, raw := range daemons {
		entry, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		if entry["version_dir"] == versionDir {
			return entry
		}
	}
	t.Fatalf("no daemon entry with version_dir %q in %v", versionDir, daemons)
	return nil
}
