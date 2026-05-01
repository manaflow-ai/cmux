package compat

import (
	"encoding/base64"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestHelloFixtureAgainstBinary(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	resp := runJSONLFixture(t, bin, "serve", "--stdio", "testdata/hello.jsonl")

	if ok, _ := resp[0]["ok"].(bool); !ok {
		t.Fatalf("hello should succeed: %+v", resp[0])
	}
	if got := resp[0]["result"].(map[string]any)["name"]; got != "cmuxd-remote" {
		t.Fatalf("hello name = %v, want cmuxd-remote", got)
	}
	if ok, _ := resp[1]["ok"].(bool); !ok {
		t.Fatalf("ping should succeed: %+v", resp[1])
	}
}

func TestTerminalEchoFixtureAgainstBinary(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	run := runJSONLFixtureWithExitTimeout(t, bin, nil, 5*time.Second, "serve", "--stdio", "testdata/terminal_echo.jsonl")
	if run.TimedOut {
		t.Fatalf("stdio daemon hung after terminal echo fixture stdin closed\nstderr:\n%s", run.Stderr)
	}
	if run.ExitErr != nil {
		t.Fatalf("stdio daemon exited with error after terminal echo fixture: %v\nstderr:\n%s", run.ExitErr, run.Stderr)
	}
	resp := run.Responses

	if ok, _ := resp[0]["ok"].(bool); !ok {
		t.Fatalf("terminal.open should succeed: %+v", resp[0])
	}
	if got := decodeBase64Field(t, resp[1]["result"].(map[string]any), "data"); string(got) != "READY" {
		t.Fatalf("initial data = %q, want READY", string(got))
	}
	if ok, _ := resp[2]["ok"].(bool); !ok {
		t.Fatalf("terminal.write should succeed: %+v", resp[2])
	}
	if got := decodeBase64Field(t, resp[3]["result"].(map[string]any), "data"); string(got) != "hello\n" {
		t.Fatalf("echo data = %q, want %q", string(got), "hello\n")
	}
}

func TestTerminalOpenOnlyFixtureExitsOnEOF(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	fixture := writeCompatFixture(t,
		`{"id":1,"method":"terminal.open","params":{"command":"printf READY; stty raw -echo -onlcr; exec cat","cols":120,"rows":40}}`,
	)
	run := runJSONLFixtureWithExitTimeout(t, bin, nil, 5*time.Second, "serve", "--stdio", fixture)
	if run.TimedOut {
		t.Fatalf("stdio daemon hung after terminal.open-only fixture stdin closed\nstderr:\n%s", run.Stderr)
	}
	if run.ExitErr != nil {
		t.Fatalf("stdio daemon exited with error after terminal.open-only fixture: %v\nstderr:\n%s", run.ExitErr, run.Stderr)
	}
	if ok, _ := run.Responses[0]["ok"].(bool); !ok {
		t.Fatalf("terminal.open should succeed: %+v", run.Responses[0])
	}
}

func TestTerminalOpenReadFixtureExitsOnEOF(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	fixture := writeCompatFixture(t,
		`{"id":1,"method":"terminal.open","params":{"command":"printf READY; stty raw -echo -onlcr; exec cat","cols":120,"rows":40}}`,
		`{"id":2,"method":"terminal.read","params":{"session_id":"{{session_id}}","offset":0,"max_bytes":1024,"timeout_ms":1000}}`,
	)
	run := runJSONLFixtureWithExitTimeout(t, bin, nil, 5*time.Second, "serve", "--stdio", fixture)
	if run.TimedOut {
		t.Fatalf("stdio daemon hung after terminal.open + terminal.read fixture stdin closed\nstderr:\n%s", run.Stderr)
	}
	if run.ExitErr != nil {
		t.Fatalf("stdio daemon exited with error after terminal.open + terminal.read fixture: %v\nstderr:\n%s", run.ExitErr, run.Stderr)
	}
	if ok, _ := run.Responses[0]["ok"].(bool); !ok {
		t.Fatalf("terminal.open should succeed: %+v", run.Responses[0])
	}
	if ok, _ := run.Responses[1]["ok"].(bool); !ok {
		t.Fatalf("terminal.read should succeed: %+v", run.Responses[1])
	}
}

func TestSessionLifecycleFixtureAgainstBinary(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	resp := runJSONLFixture(t, bin, "serve", "--stdio", "testdata/session_lifecycle.jsonl")

	if ok, _ := resp[0]["ok"].(bool); !ok {
		t.Fatalf("session.open should succeed: %+v", resp[0])
	}
	if ok, _ := resp[1]["ok"].(bool); !ok {
		t.Fatalf("session.attach should succeed: %+v", resp[1])
	}
	statusResult, ok := resp[2]["result"].(map[string]any)
	if !ok {
		t.Fatalf("session.status result missing: %+v", resp[2])
	}
	if got := int(statusResult["effective_cols"].(float64)); got != 120 {
		t.Fatalf("effective_cols = %d, want 120", got)
	}
	if got := int(statusResult["effective_rows"].(float64)); got != 40 {
		t.Fatalf("effective_rows = %d, want 40", got)
	}
	if ok, _ := resp[3]["ok"].(bool); !ok {
		t.Fatalf("session.detach should succeed: %+v", resp[3])
	}
}

func TestProxyTCPFixtureAgainstBinary(t *testing.T) {
	t.Parallel()

	listener, port := startTCPEchoServer(t)
	defer listener.Close()

	bin := daemonBinary(t)
	resp := runJSONLFixtureWithVars(t, bin, map[string]string{
		"port": fmt.Sprintf("%d", port),
	}, "serve", "--stdio", "testdata/proxy_tcp_echo.jsonl")

	if ok, _ := resp[0]["ok"].(bool); !ok {
		t.Fatalf("proxy.open should succeed: %+v", resp[0])
	}
	if ok, _ := resp[1]["ok"].(bool); !ok {
		t.Fatalf("proxy.write should succeed: %+v", resp[1])
	}
	if got := decodeBase64Field(t, resp[2]["result"].(map[string]any), "data_base64"); string(got) != "hello\n" {
		t.Fatalf("proxy echo data = %q, want %q", string(got), "hello\n")
	}
	if ok, _ := resp[3]["ok"].(bool); !ok {
		t.Fatalf("proxy.close should succeed: %+v", resp[3])
	}
}

func TestCLICompat(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	usage := "Usage: cmux [--socket <path>] [--json] <command> [args...]"

	direct := exec.Command(bin, "cli", "--help")
	direct.Dir = daemonRemoteRoot()
	directOutput, err := direct.CombinedOutput()
	if err != nil {
		t.Fatalf("cmuxd-remote cli --help failed: %v\n%s", err, string(directOutput))
	}
	if !strings.Contains(string(directOutput), usage) {
		t.Fatalf("cmuxd-remote cli --help output missing usage:\n%s", string(directOutput))
	}

	linkDir := t.TempDir()
	linkPath := filepath.Join(linkDir, "cmux")
	if err := os.Symlink(bin, linkPath); err != nil {
		t.Fatalf("symlink cmux: %v", err)
	}

	busybox := exec.Command(linkPath, "--help")
	busybox.Dir = daemonRemoteRoot()
	busyboxOutput, err := busybox.CombinedOutput()
	if err != nil {
		t.Fatalf("cmux --help failed: %v\n%s", err, string(busyboxOutput))
	}
	if !strings.Contains(string(busyboxOutput), usage) {
		t.Fatalf("cmux --help output missing usage:\n%s", string(busyboxOutput))
	}
}

func TestInvalidJSONRequestAgainstBinary(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	fixture := writeCompatFixture(t,
		`not json at all`,
		`{"id":1,"method":"ping","params":{}}`,
	)
	resp := runJSONLFixture(t, bin, "serve", "--stdio", fixture)

	if ok, _ := resp[0]["ok"].(bool); ok {
		t.Fatalf("invalid JSON request should fail: %+v", resp[0])
	}
	errObj := resp[0]["error"].(map[string]any)
	if got := errObj["message"].(string); got != "invalid JSON request" {
		t.Fatalf("invalid JSON error = %q, want %q", got, "invalid JSON request")
	}
	if ok, _ := resp[1]["ok"].(bool); !ok {
		t.Fatalf("ping after invalid JSON should succeed: %+v", resp[1])
	}
}

func TestUnknownMethodAgainstBinary(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	fixture := writeCompatFixture(t,
		`{"id":1,"method":"definitely.unknown","params":{}}`,
	)
	resp := runJSONLFixture(t, bin, "serve", "--stdio", fixture)

	if ok, _ := resp[0]["ok"].(bool); ok {
		t.Fatalf("unknown method should fail: %+v", resp[0])
	}
	errObj := resp[0]["error"].(map[string]any)
	if got := errObj["code"].(string); got != "method_not_found" {
		t.Fatalf("unknown method code = %q, want %q", got, "method_not_found")
	}
}

func TestTerminalWriteRejectsInvalidBase64AgainstBinary(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	fixture := writeCompatFixture(t,
		`{"id":1,"method":"terminal.open","params":{"command":"cat","cols":80,"rows":24}}`,
		`{"id":2,"method":"terminal.write","params":{"session_id":"{{session_id}}","data":"%%%not-base64%%%"}}`,
	)
	resp := runJSONLFixture(t, bin, "serve", "--stdio", fixture)

	if ok, _ := resp[0]["ok"].(bool); !ok {
		t.Fatalf("terminal.open should succeed: %+v", resp[0])
	}
	if ok, _ := resp[1]["ok"].(bool); ok {
		t.Fatalf("terminal.write with invalid base64 should fail: %+v", resp[1])
	}
	errObj := resp[1]["error"].(map[string]any)
	if got := errObj["message"].(string); got != "terminal.write data must be base64" {
		t.Fatalf("terminal.write invalid base64 error = %q, want %q", got, "terminal.write data must be base64")
	}
}

func decodeBase64Field(t *testing.T, payload map[string]any, key string) []byte {
	t.Helper()

	encoded, _ := payload[key].(string)
	if encoded == "" {
		t.Fatalf("missing %s field in %+v", key, payload)
	}
	data, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		t.Fatalf("decode %s: %v", key, err)
	}
	return data
}

func startTCPEchoServer(t *testing.T) (net.Listener, int) {
	t.Helper()

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen echo server: %v", err)
	}

	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				buffer := make([]byte, 32*1024)
				for {
					n, readErr := conn.Read(buffer)
					if n > 0 {
						if _, writeErr := conn.Write(buffer[:n]); writeErr != nil {
							return
						}
					}
					if readErr != nil {
						return
					}
				}
			}(conn)
		}
	}()

	return listener, listener.Addr().(*net.TCPAddr).Port
}

func writeCompatFixture(t *testing.T, lines ...string) string {
	t.Helper()

	path := filepath.Join(t.TempDir(), "fixture.jsonl")
	content := strings.Join(lines, "\n") + "\n"
	if err := os.WriteFile(path, []byte(content), 0o600); err != nil {
		t.Fatalf("write compat fixture: %v", err)
	}
	return path
}
