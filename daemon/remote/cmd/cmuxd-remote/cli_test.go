package main

import (
	"bufio"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
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

func captureStdout(t *testing.T, fn func()) string {
	t.Helper()
	original := os.Stdout
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe stdout: %v", err)
	}
	os.Stdout = writer
	defer func() {
		os.Stdout = original
	}()

	fn()

	if err := writer.Close(); err != nil {
		t.Fatalf("close stdout writer: %v", err)
	}
	output, err := io.ReadAll(reader)
	if err != nil {
		t.Fatalf("read stdout: %v", err)
	}
	if err := reader.Close(); err != nil {
		t.Fatalf("close stdout reader: %v", err)
	}
	return string(output)
}

func captureStderr(t *testing.T, fn func()) string {
	t.Helper()
	original := os.Stderr
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe stderr: %v", err)
	}
	os.Stderr = writer
	defer func() {
		os.Stderr = original
	}()

	fn()

	if err := writer.Close(); err != nil {
		t.Fatalf("close stderr writer: %v", err)
	}
	output, err := io.ReadAll(reader)
	if err != nil {
		t.Fatalf("read stderr: %v", err)
	}
	if err := reader.Close(); err != nil {
		t.Fatalf("close stderr reader: %v", err)
	}
	return string(output)
}

func withStdin(t *testing.T, input string, fn func()) {
	t.Helper()
	original := os.Stdin
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe stdin: %v", err)
	}
	if _, err := writer.WriteString(input); err != nil {
		t.Fatalf("write stdin: %v", err)
	}
	if err := writer.Close(); err != nil {
		t.Fatalf("close stdin writer: %v", err)
	}
	os.Stdin = reader
	defer func() {
		os.Stdin = original
		_ = reader.Close()
	}()

	fn()
}

func makeShortUnixSocketPath(t *testing.T) string {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "cmuxd-")
	if err != nil {
		t.Fatalf("mkdtemp: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return filepath.Join(dir, "cmux.sock")
}

// startMockSocket creates a Unix socket that accepts one connection,
// reads a line, and responds with the given canned response.
func startMockSocket(t *testing.T, response string) string {
	t.Helper()
	sockPath := makeShortUnixSocketPath(t)

	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatalf("failed to listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			buf := make([]byte, 4096)
			n, _ := conn.Read(buf)
			_ = n // consume request
			conn.Write([]byte(response + "\n"))
			conn.Close()
		}
	}()

	return sockPath
}

// startMockV2Socket creates a Unix socket that echoes the received request's method
// back as a successful JSON-RPC response with the method name in the result.
func startMockV2Socket(t *testing.T) string {
	t.Helper()
	sockPath := makeShortUnixSocketPath(t)

	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatalf("failed to listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			buf := make([]byte, 4096)
			n, _ := conn.Read(buf)
			if n > 0 {
				var req map[string]any
				if err := json.Unmarshal(buf[:n], &req); err == nil {
					resp := map[string]any{
						"id":     req["id"],
						"ok":     true,
						"result": map[string]any{"method": req["method"], "params": req["params"]},
					}
					payload, _ := json.Marshal(resp)
					conn.Write(append(payload, '\n'))
				} else {
					conn.Write([]byte(`{"ok":false,"error":{"code":"parse","message":"bad json"}}` + "\n"))
				}
			}
			conn.Close()
		}
	}()

	return sockPath
}

func startMockV2SocketWithRequestCapture(t *testing.T) (string, <-chan map[string]any) {
	t.Helper()
	sockPath := makeShortUnixSocketPath(t)
	requests := make(chan map[string]any, 8)

	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatalf("failed to listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				buf := make([]byte, 4096)
				n, _ := conn.Read(buf)
				if n == 0 {
					return
				}
				var req map[string]any
				if err := json.Unmarshal(buf[:n], &req); err != nil {
					_, _ = conn.Write([]byte(`{"ok":false,"error":{"code":"parse","message":"bad json"}}` + "\n"))
					return
				}
				requests <- req
				resp := map[string]any{
					"id":     req["id"],
					"ok":     true,
					"result": map[string]any{"method": req["method"], "params": req["params"]},
				}
				payload, _ := json.Marshal(resp)
				_, _ = conn.Write(append(payload, '\n'))
			}(conn)
		}
	}()

	return sockPath, requests
}

func startMockV2TCPSocketWithResult(t *testing.T, result any) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("failed to listen on TCP: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				buf := make([]byte, 4096)
				n, _ := conn.Read(buf)
				if n == 0 {
					return
				}
				var req map[string]any
				if err := json.Unmarshal(buf[:n], &req); err != nil {
					_, _ = conn.Write([]byte(`{"ok":false,"error":{"code":"parse","message":"bad json"}}` + "\n"))
					return
				}
				resp := map[string]any{
					"id":     req["id"],
					"ok":     true,
					"result": result,
				}
				payload, _ := json.Marshal(resp)
				_, _ = conn.Write(append(payload, '\n'))
			}(conn)
		}
	}()

	return ln.Addr().String()
}

// startMockTCPSocket creates a TCP listener that responds with a canned response.
func startMockTCPSocket(t *testing.T, response string) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("failed to listen on TCP: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			buf := make([]byte, 4096)
			n, _ := conn.Read(buf)
			_ = n
			conn.Write([]byte(response + "\n"))
			conn.Close()
		}
	}()

	return ln.Addr().String()
}

func startMockAuthenticatedTCPSocket(t *testing.T, relayID, relayToken, response string) string {
	t.Helper()
	relayTokenBytes := mustHex(t, relayToken)
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("failed to listen on TCP: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				nonce := "testnonce"
				challenge, _ := json.Marshal(map[string]any{
					"protocol": "cmux-relay-auth",
					"version":  1,
					"relay_id": relayID,
					"nonce":    nonce,
				})
				_, _ = conn.Write(append(challenge, '\n'))

				reader := bufio.NewReader(conn)
				line, err := reader.ReadString('\n')
				if err != nil {
					return
				}
				var authResp map[string]any
				if err := json.Unmarshal([]byte(line), &authResp); err != nil {
					_, _ = conn.Write([]byte(`{"ok":false}` + "\n"))
					return
				}
				macHex, _ := authResp["mac"].(string)
				receivedMAC, err := hex.DecodeString(macHex)
				if err != nil {
					_, _ = conn.Write([]byte(`{"ok":false}` + "\n"))
					return
				}

				h := hmac.New(sha256.New, relayTokenBytes)
				_, _ = io.WriteString(h, fmt.Sprintf("relay_id=%s\nnonce=%s\nversion=%d", relayID, nonce, 1))
				expectedMAC := h.Sum(nil)
				if !hmac.Equal(receivedMAC, expectedMAC) {
					_, _ = conn.Write([]byte(`{"ok":false}` + "\n"))
					return
				}

				_, _ = conn.Write([]byte(`{"ok":true}` + "\n"))
				buf := make([]byte, 4096)
				n, _ := conn.Read(buf)
				_, _ = conn.Write([]byte(response))
				if n > 0 && !strings.HasSuffix(response, "\n") {
					_, _ = conn.Write([]byte("\n"))
				}
			}(conn)
		}
	}()

	return ln.Addr().String()
}

func mustHex(t *testing.T, value string) []byte {
	t.Helper()
	data, err := hex.DecodeString(value)
	if err != nil {
		t.Fatalf("decode hex: %v", err)
	}
	return data
}

func TestDialSocketRefreshesToUpdatedTCPAddressWithoutPolling(t *testing.T) {
	staleListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen stale: %v", err)
	}
	staleAddr := staleListener.Addr().String()
	staleListener.Close()

	readyListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen ready: %v", err)
	}
	defer readyListener.Close()

	accepted := make(chan struct{})
	go func() {
		defer close(accepted)
		conn, acceptErr := readyListener.Accept()
		if acceptErr != nil {
			return
		}
		conn.Close()
	}()

	refreshCalls := 0
	start := time.Now()
	conn, err := dialSocket(staleAddr, func() string {
		refreshCalls++
		return readyListener.Addr().String()
	})
	elapsed := time.Since(start)
	if err != nil {
		t.Fatalf("dialSocket should refresh to updated address, got: %v", err)
	}
	conn.Close()
	<-accepted
	if refreshCalls != 1 {
		t.Fatalf("refreshAddr should be called once, got %d", refreshCalls)
	}
	if elapsed > 500*time.Millisecond {
		t.Fatalf("dialSocket should fail over without polling, took %v", elapsed)
	}
}

func TestDialSocketFailsFastWhenTCPAddressStaysStale(t *testing.T) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()

	refreshCalls := 0
	start := time.Now()
	_, err = dialSocket(addr, func() string {
		refreshCalls++
		return addr
	})
	elapsed := time.Since(start)
	if err == nil {
		t.Fatal("dialSocket should fail when the relay address stays stale")
	}
	if refreshCalls != 1 {
		t.Fatalf("refreshAddr should be called once on stale TCP failure, got %d", refreshCalls)
	}
	if elapsed > 500*time.Millisecond {
		t.Fatalf("dialSocket should fail fast without polling, took %v", elapsed)
	}
}

func TestCLIPingV1(t *testing.T) {
	sockPath := startMockSocket(t, "pong")
	code := runCLI([]string{"--socket", sockPath, "ping"})
	if code != 0 {
		t.Fatalf("ping should return 0, got %d", code)
	}
}

func TestCLIPingV1OverTCP(t *testing.T) {
	addr := startMockTCPSocket(t, "pong")
	code := runCLI([]string{"--socket", addr, "ping"})
	if code != 0 {
		t.Fatalf("ping over TCP should return 0, got %d", code)
	}
}

func TestCLIPingV1OverAuthenticatedTCPWithEnv(t *testing.T) {
	relayID := "relay-1"
	relayToken := strings.Repeat("a1", 32)
	addr := startMockAuthenticatedTCPSocket(t, relayID, relayToken, "pong")
	t.Setenv("CMUX_RELAY_ID", relayID)
	t.Setenv("CMUX_RELAY_TOKEN", relayToken)

	code := runCLI([]string{"--socket", addr, "ping"})
	if code != 0 {
		t.Fatalf("ping over authenticated TCP should return 0, got %d", code)
	}
}

func TestCLIPingV1OverAuthenticatedTCPWithRelayFile(t *testing.T) {
	relayID := "relay-2"
	relayToken := strings.Repeat("b2", 32)
	addr := startMockAuthenticatedTCPSocket(t, relayID, relayToken, "pong")
	_, port, err := net.SplitHostPort(addr)
	if err != nil {
		t.Fatalf("split host port: %v", err)
	}

	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CMUX_RELAY_ID", "")
	t.Setenv("CMUX_RELAY_TOKEN", "")
	relayDir := filepath.Join(home, ".cmux", "relay")
	if err := os.MkdirAll(relayDir, 0o700); err != nil {
		t.Fatalf("mkdir relay dir: %v", err)
	}
	authPayload, _ := json.Marshal(relayAuthState{RelayID: relayID, RelayToken: relayToken})
	if err := os.WriteFile(filepath.Join(relayDir, port+".auth"), authPayload, 0o600); err != nil {
		t.Fatalf("write auth file: %v", err)
	}

	code := runCLI([]string{"--socket", addr, "ping"})
	if code != 0 {
		t.Fatalf("ping over authenticated TCP file relay should return 0, got %d", code)
	}
}

func TestDialSocketDetection(t *testing.T) {
	// Unix socket paths should attempt Unix dial
	for _, path := range []string{"/tmp/cmux-nonexistent-test-99999.sock", "/var/run/cmux-nonexistent.sock"} {
		conn, err := dialSocket(path, nil)
		if conn != nil {
			conn.Close()
		}
		// We expect a connection error (not found), not a panic
		if err == nil {
			t.Fatalf("dialSocket(%q) should fail for non-existent path", path)
		}
	}

	// TCP addresses should attempt TCP dial
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	defer ln.Close()

	go func() {
		conn, _ := ln.Accept()
		if conn != nil {
			conn.Close()
		}
	}()

	conn, err := dialSocket(ln.Addr().String(), nil)
	if err != nil {
		t.Fatalf("dialSocket(%q) should succeed for TCP: %v", ln.Addr().String(), err)
	}
	conn.Close()
}

func TestCLINewWindowV1(t *testing.T) {
	sockPath := startMockSocket(t, "OK window_id=abc123")
	code := runCLI([]string{"--socket", sockPath, "new-window"})
	if code != 0 {
		t.Fatalf("new-window should return 0, got %d", code)
	}
}

func TestSocketRoundTripReadsFullMultilineV1Response(t *testing.T) {
	addr := startMockTCPSocket(t, "window:alpha\nwindow:beta\nwindow:gamma")
	resp, err := socketRoundTrip(addr, "list_windows", nil)
	if err != nil {
		t.Fatalf("socketRoundTrip should succeed, got error: %v", err)
	}
	want := "window:alpha\nwindow:beta\nwindow:gamma"
	if resp != want {
		t.Fatalf("socketRoundTrip truncated v1 response: got %q want %q", resp, want)
	}
}

func TestCLICloseWindowV1(t *testing.T) {
	// Verify that the flag value is appended to the v1 command
	dir := t.TempDir()
	sockPath := filepath.Join(dir, "cmux.sock")

	receivedCh := make(chan string, 1)
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		buf := make([]byte, 4096)
		n, _ := conn.Read(buf)
		receivedCh <- strings.TrimSpace(string(buf[:n]))
		conn.Write([]byte("OK\n"))
		conn.Close()
	}()

	code := runCLI([]string{"--socket", sockPath, "close-window", "--window", "win-42"})
	if code != 0 {
		t.Fatalf("close-window should return 0, got %d", code)
	}
	select {
	case received := <-receivedCh:
		if received != "close_window win-42" {
			t.Fatalf("expected 'close_window win-42', got %q", received)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for close-window payload")
	}
}

func TestCLIListWorkspacesV2(t *testing.T) {
	sockPath := startMockV2Socket(t)
	code := runCLI([]string{"--socket", sockPath, "--json", "list-workspaces"})
	if code != 0 {
		t.Fatalf("list-workspaces should return 0, got %d", code)
	}
}

func TestCLIListWorkspacesV2DefaultOutputShowsResult(t *testing.T) {
	sockPath := startMockV2TCPSocketWithResult(t, map[string]any{"method": "workspace.list", "params": map[string]any{}})
	output := captureStdout(t, func() {
		code := runCLI([]string{"--socket", sockPath, "list-workspaces"})
		if code != 0 {
			t.Fatalf("list-workspaces should return 0, got %d", code)
		}
	})
	if !strings.Contains(output, "\"method\": \"workspace.list\"") {
		t.Fatalf("expected default output to include result payload, got %q", output)
	}
}

func TestCLINotifyDefaultOutputPrintsOKForEmptyResult(t *testing.T) {
	sockPath := startMockV2TCPSocketWithResult(t, map[string]any{})
	output := captureStdout(t, func() {
		code := runCLI([]string{"--socket", sockPath, "notify", "--body", "hi"})
		if code != 0 {
			t.Fatalf("notify should return 0, got %d", code)
		}
	})
	if strings.TrimSpace(output) != "OK" {
		t.Fatalf("expected empty-result command to print OK, got %q", output)
	}
}

func TestCLIRPCPassthrough(t *testing.T) {
	sockPath := startMockV2Socket(t)
	code := runCLI([]string{"--socket", sockPath, "rpc", "system.capabilities"})
	if code != 0 {
		t.Fatalf("rpc should return 0, got %d", code)
	}
}

func TestCLIRPCWithParams(t *testing.T) {
	sockPath := startMockV2Socket(t)
	code := runCLI([]string{"--socket", sockPath, "rpc", "workspace.create", `{"title":"test"}`})
	if code != 0 {
		t.Fatalf("rpc with params should return 0, got %d", code)
	}
}

func TestCLIUnknownCommand(t *testing.T) {
	code := runCLI([]string{"--socket", "/dev/null", "does-not-exist"})
	if code != 2 {
		t.Fatalf("unknown command should return 2, got %d", code)
	}
}

func TestCLINoSocket(t *testing.T) {
	// Without CMUX_SOCKET_PATH set, should fail
	os.Unsetenv("CMUX_SOCKET_PATH")
	code := runCLI([]string{"ping"})
	if code != 1 {
		t.Fatalf("missing socket should return 1, got %d", code)
	}
}

func TestCLICodexInstallHooksDoesNotRequireSocket(t *testing.T) {
	codexHome := filepath.Join(t.TempDir(), "codex-home")
	t.Setenv("CODEX_HOME", codexHome)
	t.Setenv("CMUX_SOCKET_PATH", "")

	code := runCLI([]string{"codex", "install-hooks", "--yes"})
	if code != 0 {
		t.Fatalf("codex install-hooks should return 0, got %d", code)
	}

	hooksContent, err := os.ReadFile(filepath.Join(codexHome, "hooks.json"))
	if err != nil {
		t.Fatalf("read hooks.json: %v", err)
	}
	if !strings.Contains(string(hooksContent), "cmux codex-hook stop") {
		t.Fatalf("expected hooks.json to install cmux-owned stop hook, got %q", string(hooksContent))
	}

	configContent, err := os.ReadFile(filepath.Join(codexHome, "config.toml"))
	if err != nil {
		t.Fatalf("read config.toml: %v", err)
	}
	if !strings.Contains(string(configContent), "codex_hooks = true") {
		t.Fatalf("expected config.toml to enable codex_hooks, got %q", string(configContent))
	}

	hooksInfo, err := os.Stat(filepath.Join(codexHome, "hooks.json"))
	if err != nil {
		t.Fatalf("stat hooks.json: %v", err)
	}
	if hooksInfo.Mode().Perm() != 0o600 {
		t.Fatalf("expected hooks.json mode 0600, got %#o", hooksInfo.Mode().Perm())
	}
	configInfo, err := os.Stat(filepath.Join(codexHome, "config.toml"))
	if err != nil {
		t.Fatalf("stat config.toml: %v", err)
	}
	if configInfo.Mode().Perm() != 0o600 {
		t.Fatalf("expected config.toml mode 0600, got %#o", configInfo.Mode().Perm())
	}
	dirInfo, err := os.Stat(codexHome)
	if err != nil {
		t.Fatalf("stat codex home: %v", err)
	}
	if dirInfo.Mode().Perm() != 0o700 {
		t.Fatalf("expected codex home mode 0700, got %#o", dirInfo.Mode().Perm())
	}
}

func TestCLICodexHookWithoutSurfaceNoOpsWithoutSocket(t *testing.T) {
	t.Setenv("CMUX_SURFACE_ID", "")
	t.Setenv("CMUX_SOCKET_PATH", "")

	output := captureStdout(t, func() {
		code := runCLI([]string{"codex-hook", "stop"})
		if code != 0 {
			t.Fatalf("codex-hook should no-op outside cmux, got %d", code)
		}
	})

	if strings.TrimSpace(output) != "{}" {
		t.Fatalf("expected codex-hook no-op output, got %q", output)
	}
}

func TestCLISocketEnvVar(t *testing.T) {
	sockPath := startMockSocket(t, "pong")
	os.Setenv("CMUX_SOCKET_PATH", sockPath)
	defer os.Unsetenv("CMUX_SOCKET_PATH")

	code := runCLI([]string{"ping"})
	if code != 0 {
		t.Fatalf("ping with env socket should return 0, got %d", code)
	}
}

func TestCLICodexHookStopNotifiesTargetSurfaceAndSetsIdleStatus(t *testing.T) {
	sockPath := makeShortUnixSocketPath(t)
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

	received := make(chan string, 4)
	go func() {
		for i := 0; i < 2; i++ {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				buf := make([]byte, 4096)
				n, _ := conn.Read(buf)
				payload := strings.TrimSpace(string(buf[:n]))
				received <- payload

				if strings.HasPrefix(payload, "{") {
					var req map[string]any
					_ = json.Unmarshal(buf[:n], &req)
					resp := map[string]any{"id": req["id"], "ok": true, "result": map[string]any{}}
					encoded, _ := json.Marshal(resp)
					_, _ = conn.Write(append(encoded, '\n'))
					return
				}

				_, _ = conn.Write([]byte("OK\n"))
			}(conn)
		}
	}()

	t.Setenv("CMUX_SOCKET_PATH", sockPath)
	t.Setenv("CMUX_WORKSPACE_ID", "workspace-1")
	t.Setenv("CMUX_SURFACE_ID", "surface-1")

	withStdin(t, `{"session_id":"sess-1","cwd":"/tmp/research-proj","last_assistant_message":"Need your approval on the final patch."}`, func() {
		output := captureStdout(t, func() {
			code := runCLI([]string{"codex-hook", "stop"})
			if code != 0 {
				t.Fatalf("codex-hook stop should return 0, got %d", code)
			}
		})
		if strings.TrimSpace(output) != "{}" {
			t.Fatalf("expected codex-hook stop to print {}, got %q", output)
		}
	})

	readReceived := func() string {
		t.Helper()
		select {
		case payload := <-received:
			return payload
		case <-time.After(2 * time.Second):
			t.Fatal("timed out waiting for codex-hook socket payload")
			return ""
		}
	}

	first := readReceived()
	second := readReceived()

	var requestPayload string
	var statusPayload string
	if strings.HasPrefix(first, "{") {
		requestPayload = first
		statusPayload = second
	} else {
		requestPayload = second
		statusPayload = first
	}

	var request map[string]any
	if err := json.Unmarshal([]byte(requestPayload), &request); err != nil {
		t.Fatalf("decode notification request: %v", err)
	}
	if got := request["method"]; got != "notification.create_for_target" {
		t.Fatalf("expected notification.create_for_target, got %v", got)
	}
	params, _ := request["params"].(map[string]any)
	if got := params["workspace_id"]; got != "workspace-1" {
		t.Fatalf("expected workspace_id workspace-1, got %v", got)
	}
	if got := params["surface_id"]; got != "surface-1" {
		t.Fatalf("expected surface_id surface-1, got %v", got)
	}
	if got := params["title"]; got != "Codex" {
		t.Fatalf("expected title Codex, got %v", got)
	}
	if got := params["subtitle"]; got != "Completed in research-proj" {
		t.Fatalf("expected project subtitle, got %v", got)
	}
	if got := params["body"]; got != "Need your approval on the final patch." {
		t.Fatalf("expected last assistant message body, got %v", got)
	}
	if statusPayload != "set_status codex Idle --icon=pause.circle.fill --color=#8E8E93 --tab=workspace-1" {
		t.Fatalf("unexpected status payload: %q", statusPayload)
	}
}

func TestCLICodexHookHelpDoesNotReadStdin(t *testing.T) {
	t.Setenv("CMUX_SURFACE_ID", "surface-1")
	stderr := captureStderr(t, func() {
		code := runCLI([]string{"codex-hook", "--help"})
		if code != 0 {
			t.Fatalf("codex-hook help should return 0, got %d", code)
		}
	})
	if !strings.Contains(stderr, "Usage: cmux codex-hook") {
		t.Fatalf("expected help output, got %q", stderr)
	}
}

func TestBuildCodexHooksContentRejectsMalformedJSON(t *testing.T) {
	if _, err := buildCodexHooksContent("{not-json"); err == nil {
		t.Fatal("expected malformed hooks.json to return an error")
	}
}

func TestBuildCodexHooksContentPreservesUserManagedCompoundHooks(t *testing.T) {
	existing := `{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "cmux codex-hook stop && my-notifier"
          }
        ]
      }
    ]
  }
}`
	updated, err := buildCodexHooksContent(existing)
	if err != nil {
		t.Fatalf("build hooks content: %v", err)
	}
	if !strings.Contains(updated, "cmux codex-hook stop && my-notifier") {
		t.Fatalf("expected user-managed hook to be preserved, got %q", updated)
	}
}

func TestBuildConfigWithCodexHooksRemoteTouchesOnlyFeaturesSection(t *testing.T) {
	content := strings.Join([]string{
		"[model]",
		`codex_hooks = false`,
		"",
		"[features]",
		`other = true`,
		"",
	}, "\n")
	updated := buildConfigWithCodexHooksRemote(content)
	if !strings.Contains(updated, "[model]\ncodex_hooks = false") {
		t.Fatalf("expected non-features codex_hooks to stay unchanged, got %q", updated)
	}
	if !strings.Contains(updated, "[features]\ncodex_hooks = true\nother = true") {
		t.Fatalf("expected features section to gain codex_hooks, got %q", updated)
	}
}

func TestBuildConfigWithoutCodexHooksRemoteTouchesOnlyFeaturesSection(t *testing.T) {
	content := strings.Join([]string{
		"[model]",
		`codex_hooks = false`,
		"",
		"[features]",
		`codex_hooks = true`,
		`other = true`,
		"",
	}, "\n")
	updated := buildConfigWithoutCodexHooksRemote(content)
	if !strings.Contains(updated, "[model]\ncodex_hooks = false") {
		t.Fatalf("expected non-features codex_hooks to stay unchanged, got %q", updated)
	}
	if strings.Contains(updated, "[features]\ncodex_hooks = true") {
		t.Fatalf("expected features codex_hooks to be removed, got %q", updated)
	}
}

func TestCodexHookSessionStoreLoadRejectsCorruptJSON(t *testing.T) {
	statePath := filepath.Join(t.TempDir(), "codex-hook-sessions.json")
	if err := os.WriteFile(statePath, []byte("{oops"), 0o600); err != nil {
		t.Fatalf("write corrupt state: %v", err)
	}
	store := &codexHookSessionStore{statePath: statePath}
	if _, err := store.load(); err == nil {
		t.Fatal("expected corrupt state to return an error")
	}
}

func TestCLIV2FlagMapping(t *testing.T) {
	// Verify that --workspace gets mapped to workspace_id in params
	dir := t.TempDir()
	sockPath := filepath.Join(dir, "cmux.sock")

	receivedParamsCh := make(chan map[string]any, 1)
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		buf := make([]byte, 4096)
		n, _ := conn.Read(buf)
		var req map[string]any
		json.Unmarshal(buf[:n], &req)
		receivedParams, _ := req["params"].(map[string]any)
		receivedParamsCh <- receivedParams
		resp := map[string]any{"id": req["id"], "ok": true, "result": map[string]any{}}
		payload, _ := json.Marshal(resp)
		conn.Write(append(payload, '\n'))
		conn.Close()
	}()

	code := runCLI([]string{"--socket", sockPath, "--json", "close-workspace", "--workspace", "ws-abc"})
	if code != 0 {
		t.Fatalf("close-workspace should return 0, got %d", code)
	}
	select {
	case receivedParams := <-receivedParamsCh:
		if receivedParams["workspace_id"] != "ws-abc" {
			t.Fatalf("expected workspace_id=ws-abc, got %v", receivedParams)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for close-workspace payload")
	}
}

func TestBusyboxArgv0Detection(t *testing.T) {
	// Verify that when argv[0] base is "cmux", we enter CLI mode
	base := filepath.Base("cmux")
	if base != "cmux" {
		t.Fatalf("expected base 'cmux', got %q", base)
	}
	base2 := filepath.Base("/home/user/.cmux/bin/cmux")
	if base2 != "cmux" {
		t.Fatalf("expected base 'cmux', got %q", base2)
	}
	base3 := filepath.Base("cmuxd-remote")
	if base3 == "cmux" {
		t.Fatalf("cmuxd-remote should not match cmux")
	}
}

func TestCLIBrowserSubcommand(t *testing.T) {
	sockPath := startMockV2Socket(t)
	code := runCLI([]string{"--socket", sockPath, "--json", "browser", "open", "--url", "https://example.com"})
	if code != 0 {
		t.Fatalf("browser open should return 0, got %d", code)
	}
}

func TestCLINewPaneDefaultsDirectionAndForwardsExtraFlags(t *testing.T) {
	sockPath, requests := startMockV2SocketWithRequestCapture(t)
	code := runCLI([]string{
		"--socket", sockPath, "--json",
		"new-pane",
		"--workspace", "ws-1",
		"--type", "browser",
		"--url", "https://example.com",
	})
	if code != 0 {
		t.Fatalf("new-pane should return 0, got %d", code)
	}

	select {
	case req := <-requests:
		if got := req["method"]; got != "pane.create" {
			t.Fatalf("expected pane.create, got %v", got)
		}
		params, _ := req["params"].(map[string]any)
		if got := params["workspace_id"]; got != "ws-1" {
			t.Fatalf("expected workspace_id ws-1, got %v", got)
		}
		if got := params["direction"]; got != "right" {
			t.Fatalf("expected default direction right, got %v", got)
		}
		if got := params["type"]; got != "browser" {
			t.Fatalf("expected type browser, got %v", got)
		}
		if got := params["url"]; got != "https://example.com" {
			t.Fatalf("expected url to be forwarded, got %v", got)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for new-pane request")
	}
}

func TestCLIListPanelsUsesSurfaceList(t *testing.T) {
	sockPath, requests := startMockV2SocketWithRequestCapture(t)
	code := runCLI([]string{"--socket", sockPath, "--json", "list-panels", "--workspace", "ws-1"})
	if code != 0 {
		t.Fatalf("list-panels should return 0, got %d", code)
	}

	select {
	case req := <-requests:
		if got := req["method"]; got != "surface.list" {
			t.Fatalf("expected surface.list, got %v", got)
		}
		params, _ := req["params"].(map[string]any)
		if got := params["workspace_id"]; got != "ws-1" {
			t.Fatalf("expected workspace_id ws-1, got %v", got)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for list-panels request")
	}
}

func TestCLIFocusPanelUsesSurfaceFocus(t *testing.T) {
	sockPath, requests := startMockV2SocketWithRequestCapture(t)
	code := runCLI([]string{"--socket", sockPath, "--json", "focus-panel", "--workspace", "ws-1", "--panel", "surface-1"})
	if code != 0 {
		t.Fatalf("focus-panel should return 0, got %d", code)
	}

	select {
	case req := <-requests:
		if got := req["method"]; got != "surface.focus" {
			t.Fatalf("expected surface.focus, got %v", got)
		}
		params, _ := req["params"].(map[string]any)
		if got := params["workspace_id"]; got != "ws-1" {
			t.Fatalf("expected workspace_id ws-1, got %v", got)
		}
		if got := params["surface_id"]; got != "surface-1" {
			t.Fatalf("expected surface_id surface-1, got %v", got)
		}
		if _, ok := params["panel_id"]; ok {
			t.Fatalf("did not expect panel_id in params: %v", params)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for focus-panel request")
	}
}

func TestCLIBrowserOpenUsesOpenSplitAndWorkspaceEnv(t *testing.T) {
	sockPath, requests := startMockV2SocketWithRequestCapture(t)
	t.Setenv("CMUX_WORKSPACE_ID", "env-ws")
	code := runCLI([]string{"--socket", sockPath, "--json", "browser", "open", "https://example.com"})
	if code != 0 {
		t.Fatalf("browser open should return 0, got %d", code)
	}

	select {
	case req := <-requests:
		if got := req["method"]; got != "browser.open_split" {
			t.Fatalf("expected browser.open_split, got %v", got)
		}
		params, _ := req["params"].(map[string]any)
		if got := params["workspace_id"]; got != "env-ws" {
			t.Fatalf("expected workspace_id env-ws, got %v", got)
		}
		if got := params["url"]; got != "https://example.com" {
			t.Fatalf("expected positional url to be forwarded, got %v", got)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for browser open request")
	}
}

func TestCLIBrowserGetURLUsesCurrentMethodAndSurfaceEnv(t *testing.T) {
	sockPath, requests := startMockV2SocketWithRequestCapture(t)
	t.Setenv("CMUX_SURFACE_ID", "env-sf")
	code := runCLI([]string{"--socket", sockPath, "--json", "browser", "get-url"})
	if code != 0 {
		t.Fatalf("browser get-url should return 0, got %d", code)
	}

	select {
	case req := <-requests:
		if got := req["method"]; got != "browser.url.get" {
			t.Fatalf("expected browser.url.get, got %v", got)
		}
		params, _ := req["params"].(map[string]any)
		if got := params["surface_id"]; got != "env-sf" {
			t.Fatalf("expected surface_id env-sf, got %v", got)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for browser get-url request")
	}
}

func TestCLINoArgs(t *testing.T) {
	code := runCLI([]string{})
	if code != 2 {
		t.Fatalf("no args should return 2, got %d", code)
	}
}

func TestCLIHelpFlag(t *testing.T) {
	code := runCLI([]string{"--help"})
	if code != 0 {
		t.Fatalf("--help should return 0, got %d", code)
	}
}

func TestCLIHelpCommand(t *testing.T) {
	code := runCLI([]string{"help"})
	if code != 0 {
		t.Fatalf("help should return 0, got %d", code)
	}
}

func TestFlagToParamKey(t *testing.T) {
	tests := []struct {
		input, expected string
	}{
		{"workspace", "workspace_id"},
		{"surface", "surface_id"},
		{"panel", "panel_id"},
		{"pane", "pane_id"},
		{"window", "window_id"},
		{"command", "initial_command"},
		{"name", "title"},
		{"working-directory", "working_directory"},
		{"title", "title"},
		{"url", "url"},
		{"direction", "direction"},
	}
	for _, tc := range tests {
		got := flagToParamKey(tc.input)
		if got != tc.expected {
			t.Errorf("flagToParamKey(%q) = %q, want %q", tc.input, got, tc.expected)
		}
	}
}

func TestParseFlags(t *testing.T) {
	args := []string{"positional-cmd", "--workspace", "ws-1", "--surface", "sf-2", "--unknown", "val"}
	_, err := parseFlags(args, []string{"workspace", "surface"})
	if err == nil {
		t.Fatal("parseFlags should reject unknown flags")
	}
}

func TestParseFlagsCollectsKnownFlagsAndPositionalArgs(t *testing.T) {
	args := []string{"positional-cmd", "--workspace", "ws-1", "--surface", "sf-2"}
	result, err := parseFlags(args, []string{"workspace", "surface"})
	if err != nil {
		t.Fatalf("parseFlags should succeed for known flags: %v", err)
	}
	if result.flags["workspace"] != "ws-1" {
		t.Errorf("expected workspace=ws-1, got %q", result.flags["workspace"])
	}
	if result.flags["surface"] != "sf-2" {
		t.Errorf("expected surface=sf-2, got %q", result.flags["surface"])
	}
	if len(result.positional) == 0 || result.positional[0] != "positional-cmd" {
		t.Errorf("expected first positional=positional-cmd, got %v", result.positional)
	}
}

func TestCLIEnvVarDefaults(t *testing.T) {
	// Test that CMUX_WORKSPACE_ID and CMUX_SURFACE_ID are used as defaults
	dir := t.TempDir()
	sockPath := filepath.Join(dir, "cmux.sock")

	receivedParamsCh := make(chan map[string]any, 1)
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

	go func() {
		conn, err := ln.Accept()
		if err != nil {
			return
		}
		buf := make([]byte, 4096)
		n, _ := conn.Read(buf)
		var req map[string]any
		json.Unmarshal(buf[:n], &req)
		receivedParams, _ := req["params"].(map[string]any)
		receivedParamsCh <- receivedParams
		resp := map[string]any{"id": req["id"], "ok": true, "result": map[string]any{}}
		payload, _ := json.Marshal(resp)
		conn.Write(append(payload, '\n'))
		conn.Close()
	}()

	os.Setenv("CMUX_WORKSPACE_ID", "env-ws-id")
	os.Setenv("CMUX_SURFACE_ID", "env-sf-id")
	defer os.Unsetenv("CMUX_WORKSPACE_ID")
	defer os.Unsetenv("CMUX_SURFACE_ID")

	code := runCLI([]string{"--socket", sockPath, "--json", "close-surface"})
	if code != 0 {
		t.Fatalf("close-surface should return 0, got %d", code)
	}
	select {
	case receivedParams := <-receivedParamsCh:
		if receivedParams["workspace_id"] != "env-ws-id" {
			t.Errorf("expected workspace_id from env, got %v", receivedParams["workspace_id"])
		}
		if receivedParams["surface_id"] != "env-sf-id" {
			t.Errorf("expected surface_id from env, got %v", receivedParams["surface_id"])
		}
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for close-surface payload")
	}
}
