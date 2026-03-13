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

// startMockSocket creates a Unix socket that accepts one connection,
// reads a line, and responds with the given canned response.
func startMockSocket(t *testing.T, response string) string {
	t.Helper()
	dir := t.TempDir()
	sockPath := filepath.Join(dir, "cmux.sock")

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
	dir := t.TempDir()
	sockPath := filepath.Join(dir, "cmux.sock")

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

func TestDialTCPRetrySuccess(t *testing.T) {
	// Get a free port, then close the listener so connection is refused initially.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()

	// Start a listener after a delay so the retry logic finds it.
	go func() {
		time.Sleep(400 * time.Millisecond)
		ln2, err := net.Listen("tcp", addr)
		if err != nil {
			return
		}
		defer ln2.Close()
		conn, err := ln2.Accept()
		if err != nil {
			return
		}
		conn.Close()
	}()

	conn, _, err := dialTCPRetry(addr, 3*time.Second, nil)
	if err != nil {
		t.Fatalf("dialTCPRetry should succeed after retry, got: %v", err)
	}
	conn.Close()
}

func TestDialTCPRetryTimeout(t *testing.T) {
	// Get a free port and close it — nothing will ever listen.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := ln.Addr().String()
	ln.Close()

	start := time.Now()
	_, _, err = dialTCPRetry(addr, 600*time.Millisecond, nil)
	elapsed := time.Since(start)
	if err == nil {
		t.Fatal("dialTCPRetry should fail when nothing is listening")
	}
	if elapsed < 500*time.Millisecond {
		t.Fatalf("should have retried for ~600ms, only took %v", elapsed)
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

func TestCLISocketEnvVar(t *testing.T) {
	sockPath := startMockSocket(t, "pong")
	os.Setenv("CMUX_SOCKET_PATH", sockPath)
	defer os.Unsetenv("CMUX_SOCKET_PATH")

	code := runCLI([]string{"ping"})
	if code != 0 {
		t.Fatalf("ping with env socket should return 0, got %d", code)
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
