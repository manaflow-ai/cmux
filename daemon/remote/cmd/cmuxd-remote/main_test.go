package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"
)

type notifyingBuffer struct {
	mu     sync.Mutex
	buffer bytes.Buffer
	notify chan struct{}
}

type persistentTestFrameQueue struct {
	mu     sync.Mutex
	frames []map[string]any
}

var persistentTestPendingFrames sync.Map

func newNotifyingBuffer() *notifyingBuffer {
	return &notifyingBuffer{notify: make(chan struct{}, 1)}
}

func (b *notifyingBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	n, err := b.buffer.Write(p)
	if n > 0 {
		select {
		case b.notify <- struct{}{}:
		default:
		}
	}
	return n, err
}

func (b *notifyingBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buffer.String()
}

func startPersistentDaemonForTest(t *testing.T, token string) (string, func()) {
	return startPersistentDaemonWithVerifierForTest(t, persistentDaemonFixedTokenVerifier(token))
}

func startPersistentDaemonWithVerifierForTest(t *testing.T, verifier persistentDaemonTokenVerifier) (string, func()) {
	t.Helper()
	socketDir, err := os.MkdirTemp("/tmp", "cmuxd-remote-test-*")
	if err != nil {
		t.Fatalf("create short socket dir: %v", err)
	}
	t.Cleanup(func() {
		_ = os.RemoveAll(socketDir)
	})
	socketPath := filepath.Join(socketDir, "rpc.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}
	done := make(chan error, 1)
	go func() {
		done <- servePersistentDaemonWithVerifier(listener, verifier, io.Discard)
	}()
	stop := func() {
		_ = listener.Close()
		select {
		case err := <-done:
			if err != nil {
				t.Fatalf("persistent daemon exited with error: %v", err)
			}
		case <-time.After(2 * time.Second):
			t.Fatalf("persistent daemon did not stop")
		}
	}
	return socketPath, stop
}

func openPersistentTestClient(t *testing.T, socketPath string, token string) (net.Conn, *bufio.Reader, *bufio.Writer) {
	t.Helper()
	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		t.Fatalf("dial persistent daemon: %v", err)
	}
	reader := bufio.NewReader(conn)
	writer := bufio.NewWriter(conn)
	writePersistentTestFrame(t, writer, rpcRequest{
		ID:     "auth",
		Method: persistentDaemonAuthMethod,
		Params: map[string]any{"token": token},
	})
	frame := readPersistentTestFrame(t, conn, reader)
	if ok, _ := frame["ok"].(bool); !ok {
		_ = conn.Close()
		t.Fatalf("persistent daemon auth failed: %v", frame)
	}
	return conn, reader, writer
}

func persistentTestRPCCall(t *testing.T, conn net.Conn, reader *bufio.Reader, writer *bufio.Writer, req rpcRequest) map[string]any {
	t.Helper()
	writePersistentTestFrame(t, writer, req)
	for {
		frame := readPersistentTestFrame(t, conn, reader)
		if _, isEvent := frame["event"]; isEvent {
			enqueuePersistentTestFrame(conn, frame)
			continue
		}
		return frame
	}
}

func readPersistentTestEvent(t *testing.T, conn net.Conn, reader *bufio.Reader, matches func(map[string]any) bool) map[string]any {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	var last map[string]any
	for time.Now().Before(deadline) {
		if frame, ok := dequeuePersistentTestFrame(conn); ok {
			last = frame
			if _, isEvent := frame["event"]; isEvent && matches(frame) {
				return frame
			}
			continue
		}
		frame := readPersistentTestFrame(t, conn, reader)
		last = frame
		if _, isEvent := frame["event"]; isEvent && matches(frame) {
			return frame
		}
	}
	t.Fatalf("timed out waiting for persistent daemon event; last=%v", last)
	return nil
}

func enqueuePersistentTestFrame(conn net.Conn, frame map[string]any) {
	queue := persistentTestQueue(conn)
	queue.mu.Lock()
	queue.frames = append(queue.frames, frame)
	queue.mu.Unlock()
}

func dequeuePersistentTestFrame(conn net.Conn) (map[string]any, bool) {
	queue := persistentTestQueue(conn)
	queue.mu.Lock()
	defer queue.mu.Unlock()
	if len(queue.frames) == 0 {
		return nil, false
	}
	frame := queue.frames[0]
	queue.frames = queue.frames[1:]
	return frame, true
}

func persistentTestQueue(conn net.Conn) *persistentTestFrameQueue {
	if queue, ok := persistentTestPendingFrames.Load(conn); ok {
		return queue.(*persistentTestFrameQueue)
	}
	queue := &persistentTestFrameQueue{}
	actual, _ := persistentTestPendingFrames.LoadOrStore(conn, queue)
	return actual.(*persistentTestFrameQueue)
}

func writePersistentTestFrame(t *testing.T, writer *bufio.Writer, payload any) {
	t.Helper()
	data, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal test frame: %v", err)
	}
	if _, err := writer.Write(data); err != nil {
		t.Fatalf("write test frame: %v", err)
	}
	if err := writer.WriteByte('\n'); err != nil {
		t.Fatalf("write test newline: %v", err)
	}
	if err := writer.Flush(); err != nil {
		t.Fatalf("flush test frame: %v", err)
	}
}

func readPersistentTestFrame(t *testing.T, conn net.Conn, reader *bufio.Reader) map[string]any {
	t.Helper()
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	line, err := reader.ReadBytes('\n')
	_ = conn.SetReadDeadline(time.Time{})
	if err != nil {
		t.Fatalf("read persistent daemon frame: %v", err)
	}
	var frame map[string]any
	if err := json.Unmarshal(bytes.TrimSpace(line), &frame); err != nil {
		t.Fatalf("decode persistent daemon frame %q: %v", string(line), err)
	}
	return frame
}

type eofWithPayloadConn struct {
	payload  []byte
	readOnce bool
}

func (c *eofWithPayloadConn) Read(p []byte) (int, error) {
	if c.readOnce {
		return 0, io.EOF
	}
	c.readOnce = true
	n := copy(p, c.payload)
	return n, io.EOF
}

func (c *eofWithPayloadConn) Write(p []byte) (int, error) {
	return len(p), nil
}

func (c *eofWithPayloadConn) Close() error { return nil }
func (c *eofWithPayloadConn) LocalAddr() net.Addr {
	return &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 0}
}
func (c *eofWithPayloadConn) RemoteAddr() net.Addr {
	return &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 0}
}
func (c *eofWithPayloadConn) SetDeadline(time.Time) error      { return nil }
func (c *eofWithPayloadConn) SetReadDeadline(time.Time) error  { return nil }
func (c *eofWithPayloadConn) SetWriteDeadline(time.Time) error { return nil }

func TestRunVersion(t *testing.T) {
	var out bytes.Buffer
	code := run([]string{"version"}, strings.NewReader(""), &out, &bytes.Buffer{})
	if code != 0 {
		t.Fatalf("run version exit code = %d, want 0", code)
	}
	if strings.TrimSpace(out.String()) == "" {
		t.Fatalf("version output should not be empty")
	}
}

func TestWrapperBinaryDispatchesIntoCLI(t *testing.T) {
	if os.Getenv("CMUXD_REMOTE_MAIN_HELPER") == "1" {
		separator := 0
		for i, arg := range os.Args {
			if arg == "--" {
				separator = i
				break
			}
		}
		if separator == 0 {
			t.Fatal("helper process missing -- separator")
		}
		os.Args = append([]string{os.Args[0]}, os.Args[separator+1:]...)
		main()
		return
	}

	sockPath := startMockSocket(t, "PONG")
	wrapperPath := filepath.Join(t.TempDir(), "cmuxd-remote-current")
	if err := os.Symlink(os.Args[0], wrapperPath); err != nil {
		t.Fatalf("symlink wrapper path: %v", err)
	}

	cmd := exec.Command(
		wrapperPath,
		"-test.run=TestWrapperBinaryDispatchesIntoCLI",
		"--",
		"--socket", sockPath, "ping",
	)
	cmd.Env = append(os.Environ(), "CMUXD_REMOTE_MAIN_HELPER=1")
	output, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("wrapper invocation failed: %v\n%s", err, output)
	}

	if got := strings.TrimSpace(string(output)); got != "PONG" {
		t.Fatalf("wrapper invocation output = %q, want %q", got, "PONG")
	}
}

func TestRunStdioHelloAndPing(t *testing.T) {
	input := strings.NewReader(
		`{"id":1,"method":"hello","params":{}}` + "\n" +
			`{"id":2,"method":"ping","params":{}}` + "\n",
	)
	var out bytes.Buffer
	code := run([]string{"serve", "--stdio"}, input, &out, &bytes.Buffer{})
	if code != 0 {
		t.Fatalf("run serve exit code = %d, want 0", code)
	}

	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("got %d response lines, want 2: %q", len(lines), out.String())
	}

	var first map[string]any
	if err := json.Unmarshal([]byte(lines[0]), &first); err != nil {
		t.Fatalf("failed to decode first response: %v", err)
	}
	if ok, _ := first["ok"].(bool); !ok {
		t.Fatalf("first response should be ok=true: %v", first)
	}
	firstResult, _ := first["result"].(map[string]any)
	if firstResult == nil {
		t.Fatalf("first response missing result object: %v", first)
	}
	capabilities, _ := firstResult["capabilities"].([]any)
	if len(capabilities) < 2 {
		t.Fatalf("hello should return capabilities: %v", firstResult)
	}
	var sawPushCapability bool
	for _, capability := range capabilities {
		if capability == "proxy.stream.push" {
			sawPushCapability = true
			break
		}
	}
	if !sawPushCapability {
		t.Fatalf("hello should advertise proxy.stream.push: %v", firstResult)
	}
	var sawPersistentPTYCapability bool
	for _, capability := range capabilities {
		if capability == "pty.session.persistent_daemon" {
			sawPersistentPTYCapability = true
			break
		}
	}
	if !sawPersistentPTYCapability {
		t.Fatalf("hello should advertise pty.session.persistent_daemon: %v", firstResult)
	}
	var sawPTYWriteNotificationCapability bool
	for _, capability := range capabilities {
		if capability == "pty.write.notification" {
			sawPTYWriteNotificationCapability = true
			break
		}
	}
	if !sawPTYWriteNotificationCapability {
		t.Fatalf("hello should advertise pty.write.notification: %v", firstResult)
	}

	var second map[string]any
	if err := json.Unmarshal([]byte(lines[1]), &second); err != nil {
		t.Fatalf("failed to decode second response: %v", err)
	}
	if ok, _ := second["ok"].(bool); !ok {
		t.Fatalf("second response should be ok=true: %v", second)
	}
}

func TestRunStdioPTYWriteNotificationDoesNotEmitResponse(t *testing.T) {
	input := strings.NewReader(
		`{"method":"pty.write","params":{"session_id":"missing","attachment_id":"missing","client_attachment_token":"token","data_base64":"YQ=="}}` + "\n" +
			`{"id":2,"method":"ping","params":{}}` + "\n",
	)
	var out bytes.Buffer
	code := run([]string{"serve", "--stdio"}, input, &out, &bytes.Buffer{})
	if code != 0 {
		t.Fatalf("run serve exit code = %d, want 0", code)
	}

	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("got %d frame lines, want pty.error event plus ping response: %q", len(lines), out.String())
	}

	var event map[string]any
	if err := json.Unmarshal([]byte(lines[0]), &event); err != nil {
		t.Fatalf("failed to decode pty.write error event: %v", err)
	}
	if _, hasID := event["id"]; hasID {
		t.Fatalf("pty.write notification should not emit an RPC response id: %v", event)
	}
	if got := event["event"]; got != "pty.error" {
		t.Fatalf("first frame = %v, want pty.error event; payload=%v", got, event)
	}

	var response map[string]any
	if err := json.Unmarshal([]byte(lines[1]), &response); err != nil {
		t.Fatalf("failed to decode ping response: %v", err)
	}
	if got := response["id"]; got != float64(2) {
		t.Fatalf("response id = %v, want ping id 2; payload=%v", got, response)
	}
	if ok, _ := response["ok"].(bool); !ok {
		t.Fatalf("ping response should be ok=true after pty.write notification: %v", response)
	}
}

func TestRunStdioNoIDNonPTYRequestStillEmitsResponse(t *testing.T) {
	input := strings.NewReader(`{"method":"ping","params":{}}` + "\n")
	var out bytes.Buffer
	code := run([]string{"serve", "--stdio"}, input, &out, &bytes.Buffer{})
	if code != 0 {
		t.Fatalf("run serve exit code = %d, want 0", code)
	}

	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(lines) != 1 {
		t.Fatalf("got %d response lines, want ping response: %q", len(lines), out.String())
	}
	var response map[string]any
	if err := json.Unmarshal([]byte(lines[0]), &response); err != nil {
		t.Fatalf("failed to decode ping response: %v", err)
	}
	if ok, _ := response["ok"].(bool); !ok {
		t.Fatalf("no-id ping should still emit an ok response: %v", response)
	}
}

func TestRunStdioNullIDPTYWriteStillEmitsResponse(t *testing.T) {
	input := strings.NewReader(
		`{"id":null,"method":"pty.write","params":{"session_id":"missing","attachment_id":"missing","client_attachment_token":"token","data_base64":"YQ=="}}` + "\n" +
			`{"id":2,"method":"ping","params":{}}` + "\n",
	)
	var out bytes.Buffer
	code := run([]string{"serve", "--stdio"}, input, &out, &bytes.Buffer{})
	if code != 0 {
		t.Fatalf("run serve exit code = %d, want 0", code)
	}

	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("got %d frame lines, want pty.write response plus ping response: %q", len(lines), out.String())
	}

	var response map[string]any
	if err := json.Unmarshal([]byte(lines[0]), &response); err != nil {
		t.Fatalf("failed to decode pty.write response: %v", err)
	}
	if eventName, _ := response["event"].(string); eventName != "" {
		t.Fatalf("id:null pty.write should emit an RPC response, got event: %v", response)
	}
	if ok, _ := response["ok"].(bool); ok {
		t.Fatalf("missing pty.write target should fail: %v", response)
	}

	var ping map[string]any
	if err := json.Unmarshal([]byte(lines[1]), &ping); err != nil {
		t.Fatalf("failed to decode ping response: %v", err)
	}
	if got := ping["id"]; got != float64(2) {
		t.Fatalf("response id = %v, want ping id 2; payload=%v", got, ping)
	}
	if ok, _ := ping["ok"].(bool); !ok {
		t.Fatalf("ping response should be ok=true after id:null pty.write: %v", ping)
	}
}

func TestPersistentDaemonRejectsInvalidSlot(t *testing.T) {
	for _, slot := range []string{"", ".", "..", "../nope", "bad/slot", strings.Repeat("a", 129)} {
		if _, err := persistentDaemonPathsForSlot(slot); err == nil {
			t.Fatalf("persistentDaemonPathsForSlot(%q) succeeded, want error", slot)
		}
	}
}

func TestPersistentDaemonPathsUseShortSocketPath(t *testing.T) {
	rootBase := filepath.Join(
		t.TempDir(),
		strings.Repeat("long-path-segment-", 4),
		"daemon-root",
	)
	t.Setenv("CMUX_REMOTE_DAEMON_ROOT", rootBase)
	t.Setenv("CMUX_REMOTE_DAEMON_SOCKET_DIR", "")

	paths, err := persistentDaemonPathsForSlot(strings.Repeat("a", 128))
	if err != nil {
		t.Fatalf("persistentDaemonPathsForSlot returned error: %v", err)
	}
	if strings.HasPrefix(paths.socket, paths.root) {
		t.Fatalf("socket path should not live under long daemon root: socket=%q root=%q", paths.socket, paths.root)
	}
	if len(paths.socket) >= 100 {
		t.Fatalf("socket path length = %d, want < 100: %q", len(paths.socket), paths.socket)
	}
}

func TestPersistentDaemonPathsIncludeDaemonVersion(t *testing.T) {
	rootBase := filepath.Join(t.TempDir(), "daemon-root")
	t.Setenv("CMUX_REMOTE_DAEMON_ROOT", rootBase)
	t.Setenv("CMUX_REMOTE_DAEMON_SOCKET_DIR", "")
	oldVersion := version
	defer func() { version = oldVersion }()

	version = "v1.2.3"
	first, err := persistentDaemonPathsForSlot("versioned-slot")
	if err != nil {
		t.Fatalf("persistentDaemonPathsForSlot returned error: %v", err)
	}
	if !strings.Contains(first.root, string(filepath.Separator)+"v1.2.3"+string(filepath.Separator)) {
		t.Fatalf("root %q should include daemon version", first.root)
	}

	version = "v1.2.4"
	second, err := persistentDaemonPathsForSlot("versioned-slot")
	if err != nil {
		t.Fatalf("persistentDaemonPathsForSlot returned error: %v", err)
	}
	if first.root == second.root {
		t.Fatalf("root should change across versions: %q", first.root)
	}
	if first.socket == second.socket {
		t.Fatalf("socket should change across versions: %q", first.socket)
	}
	if first.lockFile == second.lockFile {
		t.Fatalf("lock file should change across versions: %q", first.lockFile)
	}
}

func TestPersistentDaemonSocketDirOverrideUsesPrivateChild(t *testing.T) {
	rootBase := filepath.Join(t.TempDir(), "daemon-root")
	socketParent := filepath.Join(t.TempDir(), "caller-socket-dir")
	if err := os.MkdirAll(socketParent, 0o755); err != nil {
		t.Fatalf("create socket parent: %v", err)
	}
	if err := os.Chmod(socketParent, 0o755); err != nil {
		t.Fatalf("chmod socket parent: %v", err)
	}
	t.Setenv("CMUX_REMOTE_DAEMON_ROOT", rootBase)
	t.Setenv("CMUX_REMOTE_DAEMON_SOCKET_DIR", socketParent)

	paths, err := persistentDaemonPathsForSlot("override-slot")
	if err != nil {
		t.Fatalf("persistentDaemonPathsForSlot returned error: %v", err)
	}
	socketDir := filepath.Dir(paths.socket)
	if socketDir == socketParent {
		t.Fatalf("socket dir should be a private child, got parent %q", socketParent)
	}
	if filepath.Dir(socketDir) != socketParent {
		t.Fatalf("socket dir parent = %q, want %q", filepath.Dir(socketDir), socketParent)
	}

	paths, err = ensurePersistentDaemonDirectory(paths)
	if err != nil {
		t.Fatalf("ensurePersistentDaemonDirectory returned error: %v", err)
	}
	parentInfo, err := os.Stat(socketParent)
	if err != nil {
		t.Fatalf("stat socket parent: %v", err)
	}
	if parentInfo.Mode().Perm() != 0o755 {
		t.Fatalf("socket parent mode = %o, want 755", parentInfo.Mode().Perm())
	}
	childInfo, err := os.Stat(socketDir)
	if err != nil {
		t.Fatalf("stat socket child: %v", err)
	}
	if childInfo.Mode().Perm() != 0o700 {
		t.Fatalf("socket child mode = %o, want 700", childInfo.Mode().Perm())
	}
}

func TestPersistentDaemonSocketDirFallsBackFromUnsafeSymlink(t *testing.T) {
	rootBase := filepath.Join(t.TempDir(), "daemon-root")
	socketParent := filepath.Join(t.TempDir(), "caller-socket-dir")
	if err := os.MkdirAll(socketParent, 0o755); err != nil {
		t.Fatalf("create socket parent: %v", err)
	}
	unsafeTarget := filepath.Join(t.TempDir(), "attacker-dir")
	if err := os.MkdirAll(unsafeTarget, 0o755); err != nil {
		t.Fatalf("create unsafe target: %v", err)
	}
	unsafeChild := filepath.Join(socketParent, fmt.Sprintf("cmuxd-remote-%d", os.Getuid()))
	if err := os.Symlink(unsafeTarget, unsafeChild); err != nil {
		t.Fatalf("create unsafe socket child symlink: %v", err)
	}
	t.Setenv("CMUX_REMOTE_DAEMON_ROOT", rootBase)
	t.Setenv("CMUX_REMOTE_DAEMON_SOCKET_DIR", socketParent)

	paths, err := persistentDaemonPathsForSlot("unsafe-socket-slot")
	if err != nil {
		t.Fatalf("persistentDaemonPathsForSlot returned error: %v", err)
	}
	unsafeSocketDir := filepath.Dir(paths.socket)
	if unsafeSocketDir != unsafeChild {
		t.Fatalf("precondition failed: socket dir = %q, want unsafe child %q", unsafeSocketDir, unsafeChild)
	}

	paths, err = ensurePersistentDaemonDirectory(paths)
	if err != nil {
		t.Fatalf("ensurePersistentDaemonDirectory returned error: %v", err)
	}
	socketDir := filepath.Dir(paths.socket)
	if socketDir == unsafeChild {
		t.Fatalf("socket dir still points at unsafe child %q", socketDir)
	}
	if filepath.Clean(filepath.Dir(socketDir)) != filepath.Clean(os.TempDir()) {
		t.Fatalf("fallback socket dir parent = %q, want %q", filepath.Dir(socketDir), os.TempDir())
	}
	info, err := os.Lstat(socketDir)
	if err != nil {
		t.Fatalf("stat fallback socket dir: %v", err)
	}
	if info.Mode()&os.ModeSymlink != 0 || !info.IsDir() {
		t.Fatalf("fallback socket dir should be a real directory, got mode %v", info.Mode())
	}
	if info.Mode().Perm() != 0o700 {
		t.Fatalf("fallback socket dir mode = %o, want 700", info.Mode().Perm())
	}
	storedSocketDir, err := readPersistentDaemonSocketDir(paths.root)
	if err != nil {
		t.Fatalf("read stored fallback socket dir: %v", err)
	}
	if storedSocketDir != socketDir {
		t.Fatalf("stored socket dir = %q, want %q", storedSocketDir, socketDir)
	}
}

func TestPersistentDaemonSocketDirReplacesInvalidStoredFallback(t *testing.T) {
	rootBase := filepath.Join(t.TempDir(), "daemon-root")
	socketParent := filepath.Join(t.TempDir(), "caller-socket-dir")
	if err := os.MkdirAll(socketParent, 0o755); err != nil {
		t.Fatalf("create socket parent: %v", err)
	}
	unsafeTarget := filepath.Join(t.TempDir(), "attacker-dir")
	if err := os.MkdirAll(unsafeTarget, 0o755); err != nil {
		t.Fatalf("create unsafe target: %v", err)
	}
	unsafeChild := filepath.Join(socketParent, fmt.Sprintf("cmuxd-remote-%d", os.Getuid()))
	if err := os.Symlink(unsafeTarget, unsafeChild); err != nil {
		t.Fatalf("create unsafe socket child symlink: %v", err)
	}
	t.Setenv("CMUX_REMOTE_DAEMON_ROOT", rootBase)
	t.Setenv("CMUX_REMOTE_DAEMON_SOCKET_DIR", socketParent)

	paths, err := persistentDaemonPathsForSlot("invalid-stored-fallback-slot")
	if err != nil {
		t.Fatalf("persistentDaemonPathsForSlot returned error: %v", err)
	}
	if err := os.MkdirAll(paths.root, 0o700); err != nil {
		t.Fatalf("create daemon root: %v", err)
	}
	invalidStoredSocketDir := filepath.Join(t.TempDir(), "invalid-stored-socket-dir")
	if err := os.WriteFile(invalidStoredSocketDir, []byte("not a directory"), 0o600); err != nil {
		t.Fatalf("create invalid stored socket path: %v", err)
	}
	if err := os.WriteFile(filepath.Join(paths.root, persistentDaemonSocketDirFile), []byte(invalidStoredSocketDir+"\n"), 0o600); err != nil {
		t.Fatalf("write invalid stored socket-dir metadata: %v", err)
	}

	paths, err = ensurePersistentDaemonDirectory(paths)
	if err != nil {
		t.Fatalf("ensurePersistentDaemonDirectory returned error: %v", err)
	}
	socketDir := filepath.Dir(paths.socket)
	if socketDir == unsafeChild {
		t.Fatalf("socket dir still points at unsafe child %q", socketDir)
	}
	if filepath.Clean(filepath.Dir(socketDir)) != filepath.Clean(os.TempDir()) {
		t.Fatalf("fallback socket dir parent = %q, want %q", filepath.Dir(socketDir), os.TempDir())
	}
	storedSocketDir, err := readPersistentDaemonSocketDir(paths.root)
	if err != nil {
		t.Fatalf("read stored replacement socket dir: %v", err)
	}
	if storedSocketDir != socketDir {
		t.Fatalf("stored socket dir = %q, want replacement %q", storedSocketDir, socketDir)
	}
}

func TestPersistentDaemonSocketDirReusesStoredFallback(t *testing.T) {
	rootBase := filepath.Join(t.TempDir(), "daemon-root")
	socketParent := filepath.Join(t.TempDir(), "caller-socket-dir")
	if err := os.MkdirAll(socketParent, 0o755); err != nil {
		t.Fatalf("create socket parent: %v", err)
	}
	unsafeChild := filepath.Join(socketParent, fmt.Sprintf("cmuxd-remote-%d", os.Getuid()))
	if err := os.WriteFile(unsafeChild, []byte("not a directory"), 0o600); err != nil {
		t.Fatalf("create unsafe socket child file: %v", err)
	}
	t.Setenv("CMUX_REMOTE_DAEMON_ROOT", rootBase)
	t.Setenv("CMUX_REMOTE_DAEMON_SOCKET_DIR", socketParent)

	paths, err := persistentDaemonPathsForSlot("stored-fallback-slot")
	if err != nil {
		t.Fatalf("persistentDaemonPathsForSlot returned error: %v", err)
	}
	paths, err = ensurePersistentDaemonDirectory(paths)
	if err != nil {
		t.Fatalf("ensurePersistentDaemonDirectory returned error: %v", err)
	}
	firstSocketDir := filepath.Dir(paths.socket)

	nextPaths, err := persistentDaemonPathsForSlot("stored-fallback-slot")
	if err != nil {
		t.Fatalf("persistentDaemonPathsForSlot returned error: %v", err)
	}
	nextPaths, err = ensurePersistentDaemonDirectory(nextPaths)
	if err != nil {
		t.Fatalf("second ensurePersistentDaemonDirectory returned error: %v", err)
	}
	if filepath.Dir(nextPaths.socket) != firstSocketDir {
		t.Fatalf("second socket dir = %q, want stored fallback %q", filepath.Dir(nextPaths.socket), firstSocketDir)
	}
}

func TestPersistentDaemonTokenConcurrentCreate(t *testing.T) {
	root := t.TempDir()
	paths := persistentDaemonPaths{
		root:      root,
		tokenFile: filepath.Join(root, "auth.token"),
	}
	if err := os.MkdirAll(filepath.Dir(paths.tokenFile), 0o700); err != nil {
		t.Fatalf("mkdir token dir: %v", err)
	}

	const workers = 12
	var wg sync.WaitGroup
	results := make(chan string, workers)
	errorsCh := make(chan error, workers)
	for i := 0; i < workers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			token, err := persistentDaemonToken(paths)
			if err != nil {
				errorsCh <- err
				return
			}
			results <- token
		}()
	}
	wg.Wait()
	close(results)
	close(errorsCh)
	for err := range errorsCh {
		t.Fatalf("persistentDaemonToken returned error: %v", err)
	}
	var first string
	for token := range results {
		if len(token) != 64 {
			t.Fatalf("token length = %d, want 64", len(token))
		}
		if first == "" {
			first = token
			continue
		}
		if token != first {
			t.Fatalf("concurrent token mismatch: got %q want %q", token, first)
		}
	}
	onDisk, err := os.ReadFile(paths.tokenFile)
	if err != nil {
		t.Fatalf("read token file: %v", err)
	}
	if strings.TrimSpace(string(onDisk)) != first {
		t.Fatalf("token file = %q, want %q", strings.TrimSpace(string(onDisk)), first)
	}
}

func TestPersistentDaemonRejectsBadToken(t *testing.T) {
	socketPath, stop := startPersistentDaemonForTest(t, "good-token")
	defer stop()

	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		t.Fatalf("dial persistent daemon: %v", err)
	}
	defer conn.Close()

	reader := bufio.NewReader(conn)
	writer := bufio.NewWriter(conn)
	writePersistentTestFrame(t, writer, rpcRequest{
		ID:     1,
		Method: persistentDaemonAuthMethod,
		Params: map[string]any{"token": "bad-token"},
	})
	frame := readPersistentTestFrame(t, conn, reader)
	if ok, _ := frame["ok"].(bool); ok {
		t.Fatalf("bad token auth should fail: %v", frame)
	}
	errObj, _ := frame["error"].(map[string]any)
	if got := errObj["code"]; got != "unauthorized" {
		t.Fatalf("bad token error code = %v, want unauthorized; frame=%v", got, frame)
	}
}

func TestDialPersistentDaemonBadTokenWrapsAuthFailure(t *testing.T) {
	socketPath, stop := startPersistentDaemonForTest(t, "good-token")
	defer stop()

	conn, err := dialPersistentDaemon(socketPath, "bad-token")
	if err == nil {
		_ = conn.Close()
		t.Fatalf("dialPersistentDaemon succeeded with bad token")
	}
	if !errors.Is(err, errPersistentDaemonAuthFailed) {
		t.Fatalf("dialPersistentDaemon error = %v, want errPersistentDaemonAuthFailed", err)
	}
}

func TestPersistentDaemonAcceptsRotatedTokenFile(t *testing.T) {
	tokenFile := filepath.Join(t.TempDir(), "auth.token")
	if err := os.WriteFile(tokenFile, []byte("old-token\n"), 0o600); err != nil {
		t.Fatalf("write initial token: %v", err)
	}
	socketPath, stop := startPersistentDaemonWithVerifierForTest(
		t,
		persistentDaemonFileTokenVerifier("old-token", tokenFile),
	)
	defer stop()

	if err := os.WriteFile(tokenFile, []byte("new-token\n"), 0o600); err != nil {
		t.Fatalf("rotate token: %v", err)
	}
	conn, _, _ := openPersistentTestClient(t, socketPath, "new-token")
	_ = conn.Close()
}

func TestPersistentDaemonPTYWriteNotificationDoesNotEmitResponse(t *testing.T) {
	socketPath, stop := startPersistentDaemonForTest(t, "good-token")
	defer stop()

	conn, reader, writer := openPersistentTestClient(t, socketPath, "good-token")
	defer conn.Close()

	writePersistentTestFrame(t, writer, map[string]any{
		"method": "pty.write",
		"params": map[string]any{
			"session_id":              "missing",
			"attachment_id":           "missing",
			"client_attachment_token": "token",
			"data_base64":             base64.StdEncoding.EncodeToString([]byte("a")),
		},
	})
	event := readPersistentTestFrame(t, conn, reader)
	if _, hasID := event["id"]; hasID {
		t.Fatalf("pty.write notification should not emit an RPC response id: %v", event)
	}
	if got := event["event"]; got != "pty.error" {
		t.Fatalf("first frame = %v, want pty.error event; payload=%v", got, event)
	}
	ping := persistentTestRPCCall(t, conn, reader, writer, rpcRequest{
		ID:     2,
		Method: "ping",
		Params: map[string]any{},
	})
	if got := ping["id"]; got != float64(2) {
		t.Fatalf("response id = %v, want ping id 2; payload=%v", got, ping)
	}
	if ok, _ := ping["ok"].(bool); !ok {
		t.Fatalf("ping response should be ok=true after pty.write notification: %v", ping)
	}
}

func TestAuthenticatePersistentDaemonClientReadDeadline(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()

	requestRead := make(chan error, 1)
	go func() {
		_, err := bufio.NewReader(server).ReadString('\n')
		requestRead <- err
	}()

	start := time.Now()
	err := authenticatePersistentDaemonClientWithTimeout(client, "token", 50*time.Millisecond)
	if err == nil {
		t.Fatalf("authenticatePersistentDaemonClientWithTimeout succeeded, want timeout error")
	}
	if elapsed := time.Since(start); elapsed > time.Second {
		t.Fatalf("authenticatePersistentDaemonClientWithTimeout took %s, want bounded deadline", elapsed)
	}
	select {
	case readErr := <-requestRead:
		if readErr != nil {
			t.Fatalf("server failed to read auth request: %v", readErr)
		}
	case <-time.After(time.Second):
		t.Fatalf("server did not receive auth request")
	}
}

func TestAuthenticatePersistentDaemonServerReadDeadline(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()

	hub := newWebSocketPTYHub(wsPTYServerConfig{}, io.Discard)
	defer hub.closeAll()

	done := make(chan struct{}, 1)
	go func() {
		handlePersistentDaemonConnWithAuthTimeout(server, persistentDaemonFixedTokenVerifier("token"), hub, 50*time.Millisecond)
		done <- struct{}{}
	}()

	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatalf("server auth handler did not return after deadline")
	}
}

func TestPersistentStdioProxyReturnsWhenDaemonClosesFirst(t *testing.T) {
	client, server := net.Pipe()
	stdinReader, stdinWriter := io.Pipe()
	defer stdinWriter.Close()

	done := make(chan error, 1)
	go func() {
		done <- proxyPersistentDaemonConn(stdinReader, io.Discard, client)
	}()

	_ = server.Close()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("proxyPersistentDaemonConn returned error: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatalf("proxyPersistentDaemonConn did not return after daemon side closed")
	}
	_ = stdinWriter.Close()
}

func TestPersistentDaemonPTYReattachSurvivesClientDisconnect(t *testing.T) {
	socketPath, stop := startPersistentDaemonForTest(t, "reattach-token")
	defer stop()

	conn1, reader1, writer1 := openPersistentTestClient(t, socketPath, "reattach-token")
	sessionID := "persistent-rpc"
	attach1 := persistentTestRPCCall(t, conn1, reader1, writer1, rpcRequest{
		ID:     1,
		Method: "pty.attach",
		Params: map[string]any{
			"session_id":              sessionID,
			"attachment_id":           "a1",
			"client_attachment_token": "token-a1",
			"cols":                    80,
			"rows":                    24,
			"command":                 "printf 'persistent-rpc-data\\n'; sleep 60",
		},
	})
	if ok, _ := attach1["ok"].(bool); !ok {
		t.Fatalf("first pty.attach failed: %v", attach1)
	}
	readPersistentTestEvent(t, conn1, reader1, func(frame map[string]any) bool {
		return frame["event"] == "pty.ready" && frame["attachment_id"] == "a1"
	})
	readPersistentTestEvent(t, conn1, reader1, func(frame map[string]any) bool {
		if frame["event"] != "pty.data" || frame["attachment_id"] != "a1" {
			return false
		}
		payload, err := base64.StdEncoding.DecodeString(frame["data_base64"].(string))
		return err == nil && strings.Contains(string(payload), "persistent-rpc-data")
	})
	_ = conn1.Close()

	conn2, reader2, writer2 := openPersistentTestClient(t, socketPath, "reattach-token")
	defer conn2.Close()
	attach2 := persistentTestRPCCall(t, conn2, reader2, writer2, rpcRequest{
		ID:     2,
		Method: "pty.attach",
		Params: map[string]any{
			"session_id":              sessionID,
			"attachment_id":           "a2",
			"client_attachment_token": "token-a2",
			"cols":                    100,
			"rows":                    30,
			"command":                 "printf 'should-not-run\\n'",
			"require_existing":        true,
		},
	})
	if ok, _ := attach2["ok"].(bool); !ok {
		t.Fatalf("second pty.attach failed: %v", attach2)
	}
	readPersistentTestEvent(t, conn2, reader2, func(frame map[string]any) bool {
		return frame["event"] == "pty.ready" && frame["attachment_id"] == "a2"
	})
	readPersistentTestEvent(t, conn2, reader2, func(frame map[string]any) bool {
		if frame["event"] != "pty.data" || frame["attachment_id"] != "a2" {
			return false
		}
		payload, err := base64.StdEncoding.DecodeString(frame["data_base64"].(string))
		return err == nil && strings.Contains(string(payload), "persistent-rpc-data")
	})

	list := persistentTestRPCCall(t, conn2, reader2, writer2, rpcRequest{
		ID:     3,
		Method: "pty.list",
		Params: map[string]any{},
	})
	if ok, _ := list["ok"].(bool); !ok {
		t.Fatalf("pty.list failed: %v", list)
	}
	result, _ := list["result"].(map[string]any)
	sessions, _ := result["sessions"].([]any)
	if len(sessions) != 1 {
		t.Fatalf("pty.list sessions = %v, want one", result["sessions"])
	}
	session, _ := sessions[0].(map[string]any)
	if got := session["session_id"]; got != sessionID {
		t.Fatalf("pty.list session_id = %v, want %s", got, sessionID)
	}

	closeResp := persistentTestRPCCall(t, conn2, reader2, writer2, rpcRequest{
		ID:     4,
		Method: "pty.close",
		Params: map[string]any{"session_id": sessionID},
	})
	if ok, _ := closeResp["ok"].(bool); !ok {
		t.Fatalf("pty.close failed: %v", closeResp)
	}
}

func TestPersistentDaemonReadySignalAllowsImmediateDial(t *testing.T) {
	socketDir, err := os.MkdirTemp("/tmp", "cmuxd-remote-ready-*")
	if err != nil {
		t.Fatalf("create short socket dir: %v", err)
	}
	defer os.RemoveAll(socketDir)
	socketPath := filepath.Join(socketDir, "rpc.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}

	readyReader, readyWriter, err := os.Pipe()
	if err != nil {
		_ = listener.Close()
		t.Fatalf("create ready pipe: %v", err)
	}
	defer readyReader.Close()
	readyFD, err := syscall.Dup(int(readyWriter.Fd()))
	if err != nil {
		_ = listener.Close()
		_ = readyWriter.Close()
		t.Fatalf("duplicate ready fd: %v", err)
	}
	t.Setenv(persistentDaemonReadyFDEnv, strconv.Itoa(readyFD))
	signalPersistentDaemonReady()
	_ = readyWriter.Close()
	line, err := bufio.NewReader(readyReader).ReadString('\n')
	if err != nil {
		_ = listener.Close()
		t.Fatalf("read ready signal: %v", err)
	}
	if strings.TrimSpace(line) != "ready" {
		_ = listener.Close()
		t.Fatalf("ready signal = %q, want ready", strings.TrimSpace(line))
	}

	done := make(chan error, 1)
	go func() {
		done <- servePersistentDaemonWithVerifier(listener, persistentDaemonFixedTokenVerifier("ready-token"), io.Discard)
	}()

	conn, err := dialPersistentDaemon(socketPath, "ready-token")
	if err != nil {
		_ = listener.Close()
		t.Fatalf("dial persistent daemon after ready signal: %v", err)
	}
	_ = conn.Close()

	_ = listener.Close()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("persistent daemon exited with error: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("persistent daemon did not stop")
	}
}

func TestPersistentDaemonServerExitsAfterEmptySlotIdleTimeout(t *testing.T) {
	socketDir, err := os.MkdirTemp("/tmp", "cmuxd-remote-idle-*")
	if err != nil {
		t.Fatalf("create short socket dir: %v", err)
	}
	defer os.RemoveAll(socketDir)
	socketPath := filepath.Join(socketDir, "rpc.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}

	done := make(chan error, 1)
	go func() {
		done <- servePersistentDaemonWithVerifierConfig(
			listener,
			persistentDaemonFixedTokenVerifier("idle-token"),
			io.Discard,
			persistentDaemonServerConfig{
				emptyIdleTimeout: 500 * time.Millisecond,
				acceptPollStep:   25 * time.Millisecond,
			},
		)
	}()

	conn, reader, writer := openPersistentTestClient(t, socketPath, "idle-token")
	attach := persistentTestRPCCall(t, conn, reader, writer, rpcRequest{
		ID:     1,
		Method: "pty.attach",
		Params: map[string]any{
			"session_id":              "idle-session",
			"attachment_id":           "idle-attachment",
			"client_attachment_token": "idle-attachment-token",
			"cols":                    80,
			"rows":                    24,
			"command":                 "sleep 60",
		},
	})
	if ok, _ := attach["ok"].(bool); !ok {
		t.Fatalf("pty.attach failed: %v", attach)
	}
	readPersistentTestEvent(t, conn, reader, func(frame map[string]any) bool {
		return frame["event"] == "pty.ready" && frame["attachment_id"] == "idle-attachment"
	})

	closeResp := persistentTestRPCCall(t, conn, reader, writer, rpcRequest{
		ID:     2,
		Method: "pty.close",
		Params: map[string]any{"session_id": "idle-session"},
	})
	if ok, _ := closeResp["ok"].(bool); !ok {
		t.Fatalf("pty.close failed: %v", closeResp)
	}
	_ = conn.Close()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("persistent daemon exited with error: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("persistent daemon did not stop after empty idle timeout")
	}
}

func TestRunStdioSlotRequiresPersistent(t *testing.T) {
	var stderr bytes.Buffer
	code := run([]string{"serve", "--stdio", "--slot", "slot-without-persistent"}, strings.NewReader(""), &bytes.Buffer{}, &stderr)
	if code != 2 {
		t.Fatalf("run serve exit code = %d, want 2", code)
	}
	if !strings.Contains(stderr.String(), "serve --slot requires --persistent") {
		t.Fatalf("stderr = %q, want --slot validation error", stderr.String())
	}
}

func TestRunStdioInvalidJSONAndUnknownMethod(t *testing.T) {
	input := strings.NewReader(
		`{"id":1,"method":"hello","params":{}` + "\n" +
			`{"id":2,"method":"unknown","params":{}}` + "\n",
	)
	var out bytes.Buffer
	code := run([]string{"serve", "--stdio"}, input, &out, &bytes.Buffer{})
	if code != 0 {
		t.Fatalf("run serve exit code = %d, want 0", code)
	}

	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("got %d response lines, want 2: %q", len(lines), out.String())
	}

	var first map[string]any
	if err := json.Unmarshal([]byte(lines[0]), &first); err != nil {
		t.Fatalf("failed to decode first response: %v", err)
	}
	if ok, _ := first["ok"].(bool); ok {
		t.Fatalf("first response should be ok=false for invalid JSON: %v", first)
	}
	firstError, _ := first["error"].(map[string]any)
	if got := firstError["code"]; got != "invalid_request" {
		t.Fatalf("invalid JSON should return invalid_request; got=%v payload=%v", got, first)
	}

	var second map[string]any
	if err := json.Unmarshal([]byte(lines[1]), &second); err != nil {
		t.Fatalf("failed to decode second response: %v", err)
	}
	if ok, _ := second["ok"].(bool); ok {
		t.Fatalf("second response should be ok=false for unknown method: %v", second)
	}
	secondError, _ := second["error"].(map[string]any)
	if got := secondError["code"]; got != "method_not_found" {
		t.Fatalf("unknown method should return method_not_found; got=%v payload=%v", got, second)
	}
}

func TestRunStdioSessionResizeFlow(t *testing.T) {
	input := strings.NewReader(
		`{"id":1,"method":"session.open","params":{"session_id":"sess-stdio"}}` + "\n" +
			`{"id":2,"method":"session.attach","params":{"session_id":"sess-stdio","attachment_id":"a1","cols":120,"rows":40}}` + "\n" +
			`{"id":3,"method":"session.attach","params":{"session_id":"sess-stdio","attachment_id":"a2","cols":90,"rows":30}}` + "\n" +
			`{"id":4,"method":"session.status","params":{"session_id":"sess-stdio"}}` + "\n",
	)
	var out bytes.Buffer
	code := run([]string{"serve", "--stdio"}, input, &out, &bytes.Buffer{})
	if code != 0 {
		t.Fatalf("run serve exit code = %d, want 0", code)
	}

	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(lines) != 4 {
		t.Fatalf("got %d response lines, want 4: %q", len(lines), out.String())
	}

	var status map[string]any
	if err := json.Unmarshal([]byte(lines[3]), &status); err != nil {
		t.Fatalf("failed to decode status response: %v", err)
	}
	if ok, _ := status["ok"].(bool); !ok {
		t.Fatalf("session.status should be ok=true: %v", status)
	}
	result, _ := status["result"].(map[string]any)
	if result == nil {
		t.Fatalf("session.status missing result object: %v", status)
	}
	effectiveCols, _ := result["effective_cols"].(float64)
	effectiveRows, _ := result["effective_rows"].(float64)
	if int(effectiveCols) != 90 || int(effectiveRows) != 30 {
		t.Fatalf("session smallest-wins effective size mismatch: got=%vx%v payload=%v", effectiveCols, effectiveRows, result)
	}
}

func TestProxyStreamRoundTrip(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen failed: %v", err)
	}
	defer listener.Close()

	done := make(chan struct{})
	go func() {
		defer close(done)
		conn, acceptErr := listener.Accept()
		if acceptErr != nil {
			return
		}
		defer conn.Close()

		buffer := make([]byte, 4)
		if _, readErr := io.ReadFull(conn, buffer); readErr != nil {
			return
		}
		if string(buffer) != "ping" {
			return
		}
		_, _ = conn.Write([]byte("pong"))
	}()

	eventOutput := newNotifyingBuffer()
	server := &rpcServer{
		nextStreamID:  1,
		nextSessionID: 1,
		streams:       map[string]*streamState{},
		sessions:      map[string]*sessionState{},
		frameWriter: &stdioFrameWriter{
			writer: bufio.NewWriter(eventOutput),
		},
	}
	defer server.closeAll()

	port := listener.Addr().(*net.TCPAddr).Port
	openResp := server.handleRequest(rpcRequest{
		ID:     1,
		Method: "proxy.open",
		Params: map[string]any{
			"host":       "127.0.0.1",
			"port":       port,
			"timeout_ms": 1000,
		},
	})
	if !openResp.OK {
		t.Fatalf("proxy.open failed: %+v", openResp)
	}
	openResult, _ := openResp.Result.(map[string]any)
	streamID, _ := openResult["stream_id"].(string)
	if streamID == "" {
		t.Fatalf("proxy.open missing stream_id: %+v", openResp)
	}

	writeResp := server.handleRequest(rpcRequest{
		ID:     2,
		Method: "proxy.write",
		Params: map[string]any{
			"stream_id":   streamID,
			"data_base64": base64.StdEncoding.EncodeToString([]byte("ping")),
		},
	})
	if !writeResp.OK {
		t.Fatalf("proxy.write failed: %+v", writeResp)
	}

	readResp := server.handleRequest(rpcRequest{
		ID:     3,
		Method: "proxy.stream.subscribe",
		Params: map[string]any{
			"stream_id": streamID,
		},
	})
	if !readResp.OK {
		t.Fatalf("proxy.stream.subscribe failed: %+v", readResp)
	}
	select {
	case <-eventOutput.notify:
	case <-time.After(2 * time.Second):
		t.Fatalf("timed out waiting for proxy.stream.data event")
	}

	lines := strings.Split(strings.TrimSpace(eventOutput.String()), "\n")
	if len(lines) == 0 || strings.TrimSpace(lines[0]) == "" {
		t.Fatalf("proxy.stream.data event output was empty")
	}

	var event map[string]any
	if err := json.Unmarshal([]byte(lines[0]), &event); err != nil {
		t.Fatalf("failed to decode stream event: %v", err)
	}
	if got := event["event"]; got != "proxy.stream.data" {
		t.Fatalf("unexpected stream event=%v payload=%v", got, event)
	}
	dataBase64, _ := event["data_base64"].(string)
	data, decodeErr := base64.StdEncoding.DecodeString(dataBase64)
	if decodeErr != nil {
		t.Fatalf("proxy.stream.data returned invalid base64: %v", decodeErr)
	}
	if string(data) != "pong" {
		t.Fatalf("proxy.stream.data payload=%q, want %q", string(data), "pong")
	}

	closeResp := server.handleRequest(rpcRequest{
		ID:     4,
		Method: "proxy.close",
		Params: map[string]any{
			"stream_id": streamID,
		},
	})
	if !closeResp.OK {
		t.Fatalf("proxy.close failed: %+v", closeResp)
	}

	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatalf("proxy test server goroutine did not finish")
	}
}

func TestProxyStreamEOFPayloadIsNotDuplicatedAcrossDataAndEOFEvents(t *testing.T) {
	eventOutput := newNotifyingBuffer()
	server := &rpcServer{
		nextStreamID:  1,
		nextSessionID: 1,
		streams: map[string]*streamState{
			"stream-1": {
				conn: &eofWithPayloadConn{payload: []byte("tail")},
			},
		},
		sessions: map[string]*sessionState{},
		frameWriter: &stdioFrameWriter{
			writer: bufio.NewWriter(eventOutput),
		},
	}
	defer server.closeAll()

	resp := server.handleRequest(rpcRequest{
		ID:     1,
		Method: "proxy.stream.subscribe",
		Params: map[string]any{"stream_id": "stream-1"},
	})
	if !resp.OK {
		t.Fatalf("proxy.stream.subscribe failed: %+v", resp)
	}

	deadline := time.Now().Add(2 * time.Second)
	for strings.Count(strings.TrimSpace(eventOutput.String()), "\n")+boolToInt(strings.TrimSpace(eventOutput.String()) != "") < 2 {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			t.Fatalf("timed out waiting for proxy stream events: %q", eventOutput.String())
		}
		select {
		case <-eventOutput.notify:
		case <-time.After(remaining):
			t.Fatalf("timed out waiting for proxy stream events: %q", eventOutput.String())
		}
	}

	lines := strings.Split(strings.TrimSpace(eventOutput.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("expected exactly 2 stream events, got %d: %q", len(lines), eventOutput.String())
	}

	var first map[string]any
	if err := json.Unmarshal([]byte(lines[0]), &first); err != nil {
		t.Fatalf("decode first event: %v", err)
	}
	var second map[string]any
	if err := json.Unmarshal([]byte(lines[1]), &second); err != nil {
		t.Fatalf("decode second event: %v", err)
	}

	if got := first["event"]; got != "proxy.stream.data" {
		t.Fatalf("first event = %v, want proxy.stream.data", got)
	}
	if got := second["event"]; got != "proxy.stream.eof" {
		t.Fatalf("second event = %v, want proxy.stream.eof", got)
	}

	firstPayload, err := base64.StdEncoding.DecodeString(first["data_base64"].(string))
	if err != nil {
		t.Fatalf("decode first payload: %v", err)
	}
	secondPayload, err := decodeOptionalBase64(second["data_base64"])
	if err != nil {
		t.Fatalf("decode second payload: %v", err)
	}

	if string(firstPayload) != "tail" {
		t.Fatalf("proxy.stream.data payload = %q, want %q", string(firstPayload), "tail")
	}
	if len(secondPayload) != 0 {
		t.Fatalf("proxy.stream.eof payload = %q, want empty payload after data event", string(secondPayload))
	}
}

func TestPTYRPCSessionReattachListAndClose(t *testing.T) {
	eventOutput := newNotifyingBuffer()
	server := &rpcServer{
		nextStreamID:  1,
		nextSessionID: 1,
		streams:       map[string]*streamState{},
		sessions:      map[string]*sessionState{},
		ptyHub: newWebSocketPTYHub(wsPTYServerConfig{
			ScrollbackLimit: 4096,
			SessionIdleTTL:  time.Hour,
		}, io.Discard),
		ownsPTYHub: true,
		frameWriter: &stdioFrameWriter{
			writer: bufio.NewWriter(eventOutput),
		},
	}
	defer server.closeAll()

	attachResp := server.handleRequest(rpcRequest{
		ID:     1,
		Method: "pty.attach",
		Params: map[string]any{
			"session_id":              "pty-rpc",
			"attachment_id":           "a1",
			"client_attachment_token": "token-a1",
			"cols":                    80,
			"rows":                    24,
			"command":                 "printf 'hello-rpc\\n'; sleep 60",
		},
	})
	if !attachResp.OK {
		t.Fatalf("pty.attach failed: %+v", attachResp)
	}

	ready := waitForRPCEvent(t, eventOutput, 0, func(event map[string]any) bool {
		return event["event"] == "pty.ready" && event["attachment_id"] == "a1"
	})
	if ready["session_id"] != "pty-rpc" {
		t.Fatalf("pty.ready session_id = %v, want pty-rpc", ready["session_id"])
	}
	waitForRPCEvent(t, eventOutput, 0, func(event map[string]any) bool {
		if event["event"] != "pty.data" || event["attachment_id"] != "a1" {
			return false
		}
		payload, err := base64.StdEncoding.DecodeString(event["data_base64"].(string))
		return err == nil && strings.Contains(string(payload), "hello-rpc")
	})

	listResp := server.handleRequest(rpcRequest{
		ID:     2,
		Method: "pty.list",
		Params: map[string]any{},
	})
	if !listResp.OK {
		t.Fatalf("pty.list failed: %+v", listResp)
	}
	listResult, _ := listResp.Result.(map[string]any)
	sessions, _ := listResult["sessions"].([]map[string]any)
	if len(sessions) != 1 {
		t.Fatalf("pty.list sessions = %v, want one session", listResult["sessions"])
	}
	if sessions[0]["session_id"] != "pty-rpc" {
		t.Fatalf("pty.list session_id = %v, want pty-rpc", sessions[0]["session_id"])
	}

	detachResp := server.handleRequest(rpcRequest{
		ID:     3,
		Method: "pty.detach",
		Params: map[string]any{
			"session_id":              "pty-rpc",
			"attachment_id":           "a1",
			"client_attachment_token": "token-a1",
		},
	})
	if !detachResp.OK {
		t.Fatalf("pty.detach failed: %+v", detachResp)
	}

	lineCountBeforeReattach := rpcEventLineCount(eventOutput)
	reattachResp := server.handleRequest(rpcRequest{
		ID:     4,
		Method: "pty.attach",
		Params: map[string]any{
			"session_id":              "pty-rpc",
			"attachment_id":           "a2",
			"client_attachment_token": "token-a2",
			"cols":                    100,
			"rows":                    30,
			"command":                 "printf 'should-not-run\\n'",
		},
	})
	if !reattachResp.OK {
		t.Fatalf("pty reattach failed: %+v", reattachResp)
	}
	waitForRPCEvent(t, eventOutput, lineCountBeforeReattach, func(event map[string]any) bool {
		if event["event"] != "pty.data" || event["attachment_id"] != "a2" {
			return false
		}
		payload, err := base64.StdEncoding.DecodeString(event["data_base64"].(string))
		return err == nil && strings.Contains(string(payload), "hello-rpc")
	})

	lineCountBeforeClose := rpcEventLineCount(eventOutput)
	closeResp := server.handleRequest(rpcRequest{
		ID:     5,
		Method: "pty.close",
		Params: map[string]any{
			"session_id": "pty-rpc",
		},
	})
	if !closeResp.OK {
		t.Fatalf("pty.close failed: %+v", closeResp)
	}
	waitForRPCEvent(t, eventOutput, lineCountBeforeClose, func(event map[string]any) bool {
		return event["event"] == "pty.exit" && event["attachment_id"] == "a2"
	})
	emptyListResp := server.handleRequest(rpcRequest{
		ID:     6,
		Method: "pty.list",
		Params: map[string]any{},
	})
	if !emptyListResp.OK {
		t.Fatalf("pty.list after close failed: %+v", emptyListResp)
	}
	emptyResult, _ := emptyListResp.Result.(map[string]any)
	emptySessions, _ := emptyResult["sessions"].([]map[string]any)
	if len(emptySessions) != 0 {
		t.Fatalf("pty.list after close sessions = %v, want none", emptyResult["sessions"])
	}
}

func TestPTYRPCCommandUsesPOSIXShellForConfiguredLoginShell(t *testing.T) {
	if _, err := os.Stat("/usr/bin/false"); err != nil {
		t.Skip("/usr/bin/false is not available")
	}
	eventOutput := newNotifyingBuffer()
	server := &rpcServer{
		nextStreamID:  1,
		nextSessionID: 1,
		streams:       map[string]*streamState{},
		sessions:      map[string]*sessionState{},
		ptyHub: newWebSocketPTYHub(wsPTYServerConfig{
			Shell:           "/usr/bin/false",
			ScrollbackLimit: 4096,
			SessionIdleTTL:  time.Hour,
		}, io.Discard),
		ownsPTYHub: true,
		frameWriter: &stdioFrameWriter{
			writer: bufio.NewWriter(eventOutput),
		},
	}
	defer server.closeAll()

	attachResp := server.handleRequest(rpcRequest{
		ID:     1,
		Method: "pty.attach",
		Params: map[string]any{
			"session_id":              "pty-posix-shell",
			"attachment_id":           "a1",
			"client_attachment_token": "token-a1",
			"cols":                    80,
			"rows":                    24,
			"command":                 "printf 'posix-shell-ok\\n'; sleep 60",
		},
	})
	if !attachResp.OK {
		t.Fatalf("pty.attach failed: %+v", attachResp)
	}
	waitForRPCEvent(t, eventOutput, 0, func(event map[string]any) bool {
		if event["event"] != "pty.data" || event["attachment_id"] != "a1" {
			return false
		}
		payload, err := base64.StdEncoding.DecodeString(event["data_base64"].(string))
		return err == nil && strings.Contains(string(payload), "posix-shell-ok")
	})
}

func TestPTYRPCRequireExistingFailsMissingSession(t *testing.T) {
	server := &rpcServer{
		nextStreamID:  1,
		nextSessionID: 1,
		streams:       map[string]*streamState{},
		sessions:      map[string]*sessionState{},
		ptyHub:        newWebSocketPTYHub(wsPTYServerConfig{}, io.Discard),
		ownsPTYHub:    true,
		frameWriter: &stdioFrameWriter{
			writer: bufio.NewWriter(io.Discard),
		},
	}
	defer server.closeAll()

	resp := server.handleRequest(rpcRequest{
		ID:     1,
		Method: "pty.attach",
		Params: map[string]any{
			"session_id":              "missing-session",
			"attachment_id":           "a1",
			"client_attachment_token": "token-a1",
			"cols":                    80,
			"rows":                    24,
			"require_existing":        true,
		},
	})
	if resp.OK {
		t.Fatalf("pty.attach require_existing unexpectedly succeeded: %+v", resp)
	}
	if resp.Error == nil || resp.Error.Code != "pty_session_not_found" {
		t.Fatalf("pty.attach require_existing error = %+v, want pty_session_not_found", resp.Error)
	}
	if sessions := server.ptyHub.sessionSnapshots(); len(sessions) != 0 {
		t.Fatalf("require_existing created sessions: %+v", sessions)
	}
}

func TestRPCServerCloseAllLeavesSharedPTYHubAlive(t *testing.T) {
	hub := newWebSocketPTYHub(wsPTYServerConfig{}, io.Discard)
	sessionKey := persistentPTYSessionKey("shared")
	canceled := false
	attachment := &wsPTYAttachment{
		sessionKey: sessionKey,
		id:         "a1",
		cols:       80,
		rows:       24,
		send:       make(chan wsPTYOutgoingFrame, defaultWebSocketWriteQueueCap),
		cancel: func() {
			canceled = true
		},
		persistent: true,
	}
	session := &wsPTYSession{
		id:            "shared",
		key:           sessionKey,
		attachments:   map[string]*wsPTYAttachment{"a1": attachment},
		effectiveCols: 80,
		effectiveRows: 24,
		lastKnownCols: 80,
		lastKnownRows: 24,
		done:          make(chan struct{}),
	}
	hub.sessions[sessionKey] = session
	server := &rpcServer{
		nextStreamID:   1,
		nextSessionID:  1,
		streams:        map[string]*streamState{},
		sessions:       map[string]*sessionState{},
		ptyHub:         hub,
		ownsPTYHub:     false,
		ptyAttachments: map[string]*wsPTYAttachment{rpcPTYAttachmentKey(attachment): attachment},
	}

	server.closeAll()
	if got := hub.activeSessionCount(); got != 1 {
		t.Fatalf("shared PTY hub session count = %d, want 1", got)
	}
	if len(session.attachments) != 0 {
		t.Fatalf("shared PTY hub attachment count = %d, want 0", len(session.attachments))
	}
	if !canceled {
		t.Fatalf("shared PTY attachment was not canceled")
	}
	hub.mu.Lock()
	delete(hub.sessions, sessionKey)
	hub.mu.Unlock()
}

func TestRPCServerUntrackPTYAttachmentKeepsNewerReattach(t *testing.T) {
	sessionKey := persistentPTYSessionKey("reattach")
	oldAttachment := &wsPTYAttachment{
		sessionKey:  sessionKey,
		id:          "same",
		clientToken: "old-token",
		send:        make(chan wsPTYOutgoingFrame, defaultWebSocketWriteQueueCap),
		persistent:  true,
	}
	newAttachment := &wsPTYAttachment{
		sessionKey:  sessionKey,
		id:          "same",
		clientToken: "new-token",
		send:        make(chan wsPTYOutgoingFrame, defaultWebSocketWriteQueueCap),
		persistent:  true,
	}
	server := &rpcServer{}

	server.trackPTYAttachment(oldAttachment)
	server.trackPTYAttachment(newAttachment)
	server.untrackPTYAttachment(oldAttachment)

	server.mu.Lock()
	tracked := server.ptyAttachments[rpcPTYAttachmentKey(newAttachment)]
	server.mu.Unlock()
	if tracked != newAttachment {
		t.Fatalf("tracked attachment = %p, want newer attachment %p", tracked, newAttachment)
	}

	server.untrackPTYAttachment(newAttachment)
	server.mu.Lock()
	_, exists := server.ptyAttachments[rpcPTYAttachmentKey(newAttachment)]
	server.mu.Unlock()
	if exists {
		t.Fatalf("newer attachment remained tracked after untrack")
	}
}

func TestPTYRPCPumpEmitsExitWhenAttachmentContextCanceled(t *testing.T) {
	eventOutput := newNotifyingBuffer()
	server := &rpcServer{
		frameWriter: &stdioFrameWriter{
			writer: bufio.NewWriter(eventOutput),
		},
	}
	sessionKey := persistentPTYSessionKey("replaced")
	attachment := &wsPTYAttachment{
		sessionKey:  sessionKey,
		id:          "same",
		clientToken: "old-token",
		send:        make(chan wsPTYOutgoingFrame, defaultWebSocketWriteQueueCap),
		persistent:  true,
	}
	ctx, cancel := context.WithCancel(context.Background())
	sessionDone := make(chan struct{})
	done := make(chan struct{})
	go func() {
		defer close(done)
		server.ptyAttachmentPump(ctx, attachment, sessionDone)
	}()

	cancel()
	waitForRPCEvent(t, eventOutput, 0, func(event map[string]any) bool {
		return event["event"] == "pty.exit" &&
			event["session_id"] == "replaced" &&
			event["attachment_id"] == "same" &&
			event["attachment_token"] == "old-token"
	})
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("PTY attachment pump did not stop after context cancellation")
	}
}

func TestPTYRPCTokenRejectsStaleAttachmentControl(t *testing.T) {
	eventOutput := newNotifyingBuffer()
	server := &rpcServer{
		nextStreamID:  1,
		nextSessionID: 1,
		streams:       map[string]*streamState{},
		sessions:      map[string]*sessionState{},
		ptyHub: newWebSocketPTYHub(wsPTYServerConfig{
			ScrollbackLimit: 4096,
			SessionIdleTTL:  time.Hour,
		}, io.Discard),
		ownsPTYHub: true,
		frameWriter: &stdioFrameWriter{
			writer: bufio.NewWriter(eventOutput),
		},
	}
	defer server.closeAll()

	attachOld := server.handleRequest(rpcRequest{
		ID:     1,
		Method: "pty.attach",
		Params: map[string]any{
			"session_id":              "token-race",
			"attachment_id":           "same",
			"client_attachment_token": "old-token",
			"cols":                    80,
			"rows":                    24,
			"command":                 "sleep 60",
		},
	})
	if !attachOld.OK {
		t.Fatalf("old pty.attach failed: %+v", attachOld)
	}
	waitForRPCEvent(t, eventOutput, 0, func(event map[string]any) bool {
		return event["event"] == "pty.ready" &&
			event["attachment_id"] == "same" &&
			event["attachment_token"] == "old-token"
	})

	attachNew := server.handleRequest(rpcRequest{
		ID:     2,
		Method: "pty.attach",
		Params: map[string]any{
			"session_id":              "token-race",
			"attachment_id":           "same",
			"client_attachment_token": "new-token",
			"cols":                    100,
			"rows":                    30,
			"require_existing":        true,
		},
	})
	if !attachNew.OK {
		t.Fatalf("new pty.attach failed: %+v", attachNew)
	}
	waitForRPCEvent(t, eventOutput, 0, func(event map[string]any) bool {
		return event["event"] == "pty.exit" &&
			event["attachment_id"] == "same" &&
			event["attachment_token"] == "old-token"
	})
	waitForRPCEvent(t, eventOutput, 0, func(event map[string]any) bool {
		return event["event"] == "pty.ready" &&
			event["attachment_id"] == "same" &&
			event["attachment_token"] == "new-token"
	})

	staleWrite := server.handleRequest(rpcRequest{
		ID:     3,
		Method: "pty.write",
		Params: map[string]any{
			"session_id":              "token-race",
			"attachment_id":           "same",
			"client_attachment_token": "old-token",
			"data_base64":             base64.StdEncoding.EncodeToString([]byte("stale")),
		},
	})
	if staleWrite.OK || staleWrite.Error == nil || staleWrite.Error.Code != "not_found" {
		t.Fatalf("stale pty.write = %+v, want not_found", staleWrite)
	}
	staleDetach := server.handleRequest(rpcRequest{
		ID:     4,
		Method: "pty.detach",
		Params: map[string]any{
			"session_id":              "token-race",
			"attachment_id":           "same",
			"client_attachment_token": "old-token",
		},
	})
	if staleDetach.OK || staleDetach.Error == nil || staleDetach.Error.Code != "not_found" {
		t.Fatalf("stale pty.detach = %+v, want not_found", staleDetach)
	}
	freshDetach := server.handleRequest(rpcRequest{
		ID:     5,
		Method: "pty.detach",
		Params: map[string]any{
			"session_id":              "token-race",
			"attachment_id":           "same",
			"client_attachment_token": "new-token",
		},
	})
	if !freshDetach.OK {
		t.Fatalf("fresh pty.detach failed: %+v", freshDetach)
	}
}

func TestPTYRPCRequiresAttachmentToken(t *testing.T) {
	eventOutput := newNotifyingBuffer()
	server := &rpcServer{
		nextStreamID:  1,
		nextSessionID: 1,
		streams:       map[string]*streamState{},
		sessions:      map[string]*sessionState{},
		ptyHub: newWebSocketPTYHub(wsPTYServerConfig{
			ScrollbackLimit: 4096,
			SessionIdleTTL:  time.Hour,
		}, io.Discard),
		ownsPTYHub: true,
		frameWriter: &stdioFrameWriter{
			writer: bufio.NewWriter(eventOutput),
		},
	}
	defer server.closeAll()

	expectMissingToken := func(method string, resp rpcResponse) {
		t.Helper()
		if resp.OK || resp.Error == nil || resp.Error.Code != "invalid_params" {
			t.Fatalf("%s response = %+v, want invalid_params", method, resp)
		}
		if !strings.Contains(resp.Error.Message, method+" requires client_attachment_token") {
			t.Fatalf("%s message = %q, want client_attachment_token requirement", method, resp.Error.Message)
		}
	}

	expectMissingToken("pty.attach", server.handleRequest(rpcRequest{
		ID:     1,
		Method: "pty.attach",
		Params: map[string]any{
			"session_id":    "token-required",
			"attachment_id": "same",
			"cols":          80,
			"rows":          24,
			"command":       "sleep 60",
		},
	}))

	attach := server.handleRequest(rpcRequest{
		ID:     2,
		Method: "pty.attach",
		Params: map[string]any{
			"session_id":              "token-required",
			"attachment_id":           "same",
			"client_attachment_token": "fresh-token",
			"cols":                    80,
			"rows":                    24,
			"command":                 "sleep 60",
		},
	})
	if !attach.OK {
		t.Fatalf("pty.attach failed: %+v", attach)
	}
	waitForRPCEvent(t, eventOutput, 0, func(event map[string]any) bool {
		return event["event"] == "pty.ready" &&
			event["session_id"] == "token-required" &&
			event["attachment_id"] == "same" &&
			event["attachment_token"] == "fresh-token"
	})

	expectMissingToken("pty.write", server.handleRequest(rpcRequest{
		ID:     3,
		Method: "pty.write",
		Params: map[string]any{
			"session_id":    "token-required",
			"attachment_id": "same",
			"data_base64":   base64.StdEncoding.EncodeToString([]byte("missing token")),
		},
	}))
	expectMissingToken("pty.resize", server.handleRequest(rpcRequest{
		ID:     4,
		Method: "pty.resize",
		Params: map[string]any{
			"session_id":              "token-required",
			"attachment_id":           "same",
			"client_attachment_token": "   ",
			"cols":                    100,
			"rows":                    30,
		},
	}))
	expectMissingToken("pty.detach", server.handleRequest(rpcRequest{
		ID:     5,
		Method: "pty.detach",
		Params: map[string]any{
			"session_id":    "token-required",
			"attachment_id": "same",
		},
	}))

	detach := server.handleRequest(rpcRequest{
		ID:     6,
		Method: "pty.detach",
		Params: map[string]any{
			"session_id":              "token-required",
			"attachment_id":           "same",
			"client_attachment_token": "fresh-token",
		},
	})
	if !detach.OK {
		t.Fatalf("tokened pty.detach failed: %+v", detach)
	}
}

func TestPTYReplayIsChunkedBelowRPCFrameBuffer(t *testing.T) {
	const swiftRPCMaxFrameBytes = 256 * 1024

	sessionKey := persistentPTYSessionKey("chunked")
	attachment := &wsPTYAttachment{
		sessionKey: sessionKey,
		id:         "att-chunked",
		send:       make(chan wsPTYOutgoingFrame, defaultWebSocketWriteQueueCap),
		cancel:     func() {},
		persistent: true,
	}
	replay := bytes.Repeat([]byte("x"), defaultWebSocketReplayChunkBytes*2+17)

	if ok := enqueuePTYReplay(attachment, replay); !ok {
		t.Fatalf("enqueuePTYReplay returned false")
	}

	var joined []byte
	frameCount := 0
	firstTwoEventBytes := 0
	for {
		select {
		case frame := <-attachment.send:
			frameCount++
			if len(frame.payload) > defaultWebSocketReplayChunkBytes {
				t.Fatalf("replay chunk length = %d, want <= %d", len(frame.payload), defaultWebSocketReplayChunkBytes)
			}
			event := rpcPTYEventForFrame(attachment, frame)
			if event.Event != "pty.data" {
				t.Fatalf("event = %q, want pty.data", event.Event)
			}
			eventLine, err := json.Marshal(event)
			if err != nil {
				t.Fatalf("marshal pty event: %v", err)
			}
			if len(eventLine)+1 >= swiftRPCMaxFrameBytes {
				t.Fatalf("event line length = %d, want < %d", len(eventLine)+1, swiftRPCMaxFrameBytes)
			}
			if frameCount <= 2 {
				firstTwoEventBytes += len(eventLine) + 1
				if firstTwoEventBytes >= swiftRPCMaxFrameBytes {
					t.Fatalf("first two replay event lines = %d bytes, want < %d", firstTwoEventBytes, swiftRPCMaxFrameBytes)
				}
			}
			decoded, err := base64.StdEncoding.DecodeString(event.DataBase64)
			if err != nil {
				t.Fatalf("decode pty event data: %v", err)
			}
			if !bytes.Equal(decoded, frame.payload) {
				t.Fatalf("event data did not match frame payload")
			}
			joined = append(joined, frame.payload...)
		default:
			if frameCount < 2 {
				t.Fatalf("frame count = %d, want multiple replay chunks", frameCount)
			}
			if !bytes.Equal(joined, replay) {
				t.Fatalf("rejoined replay length = %d, want %d", len(joined), len(replay))
			}
			return
		}
	}
}

func waitForRPCEvent(t *testing.T, buffer *notifyingBuffer, startLine int, matches func(map[string]any) bool) map[string]any {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for {
		lines := rpcEventLines(buffer)
		for _, line := range lines[min(startLine, len(lines)):] {
			var event map[string]any
			if err := json.Unmarshal([]byte(line), &event); err != nil {
				continue
			}
			if matches(event) {
				return event
			}
		}
		remaining := time.Until(deadline)
		if remaining <= 0 {
			t.Fatalf("timed out waiting for matching RPC event after line %d: %q", startLine, buffer.String())
		}
		select {
		case <-buffer.notify:
		case <-time.After(remaining):
			t.Fatalf("timed out waiting for matching RPC event after line %d: %q", startLine, buffer.String())
		}
	}
}

func rpcEventLineCount(buffer *notifyingBuffer) int {
	return len(rpcEventLines(buffer))
}

func rpcEventLines(buffer *notifyingBuffer) []string {
	trimmed := strings.TrimSpace(buffer.String())
	if trimmed == "" {
		return nil
	}
	return strings.Split(trimmed, "\n")
}

func boolToInt(value bool) int {
	if value {
		return 1
	}
	return 0
}

func decodeOptionalBase64(value any) ([]byte, error) {
	encoded, ok := value.(string)
	if !ok || encoded == "" {
		return nil, nil
	}
	return base64.StdEncoding.DecodeString(encoded)
}

func TestGetIntParamRejectsFractionalFloat64(t *testing.T) {
	params := map[string]any{
		"port":       80.9,
		"timeout_ms": 100.0,
	}

	if _, ok := getIntParam(params, "port"); ok {
		t.Fatalf("fractional float64 should be rejected")
	}

	timeout, ok := getIntParam(params, "timeout_ms")
	if !ok {
		t.Fatalf("integral float64 should be accepted")
	}
	if timeout != 100 {
		t.Fatalf("timeout_ms = %d, want 100", timeout)
	}
}

func TestRunStdioOversizedFrameContinuesServing(t *testing.T) {
	oversized := `{"id":1,"method":"ping","params":{"blob":"` + strings.Repeat("a", maxRPCFrameBytes) + `"}}`
	input := strings.NewReader(oversized + "\n" + `{"id":2,"method":"ping","params":{}}` + "\n")
	var out bytes.Buffer
	code := run([]string{"serve", "--stdio"}, input, &out, &bytes.Buffer{})
	if code != 0 {
		t.Fatalf("run serve exit code = %d, want 0", code)
	}

	lines := strings.Split(strings.TrimSpace(out.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("got %d response lines, want 2: %q", len(lines), out.String())
	}

	var first map[string]any
	if err := json.Unmarshal([]byte(lines[0]), &first); err != nil {
		t.Fatalf("failed to decode first response: %v", err)
	}
	if ok, _ := first["ok"].(bool); ok {
		t.Fatalf("first response should be oversized-frame error: %v", first)
	}
	firstError, _ := first["error"].(map[string]any)
	if got := firstError["code"]; got != "invalid_request" {
		t.Fatalf("oversized frame should return invalid_request; got=%v payload=%v", got, first)
	}

	var second map[string]any
	if err := json.Unmarshal([]byte(lines[1]), &second); err != nil {
		t.Fatalf("failed to decode second response: %v", err)
	}
	if ok, _ := second["ok"].(bool); !ok {
		t.Fatalf("second response should still be handled after oversized frame: %v", second)
	}
}

func TestProxyOpenInvalidParams(t *testing.T) {
	server := &rpcServer{
		nextStreamID:  1,
		nextSessionID: 1,
		streams:       map[string]*streamState{},
		sessions:      map[string]*sessionState{},
	}
	defer server.closeAll()

	resp := server.handleRequest(rpcRequest{
		ID:     1,
		Method: "proxy.open",
		Params: map[string]any{
			"host": "127.0.0.1",
			"port": strconv.Itoa(8080),
		},
	})
	if resp.OK {
		t.Fatalf("proxy.open with invalid port type should fail: %+v", resp)
	}
	errObj, _ := resp.Error, resp.Error
	if errObj == nil || errObj.Code != "invalid_params" {
		t.Fatalf("proxy.open invalid params should return invalid_params: %+v", resp)
	}
}

func TestSessionResizeCoordinator(t *testing.T) {
	server := &rpcServer{
		nextStreamID:  1,
		nextSessionID: 1,
		streams:       map[string]*streamState{},
		sessions:      map[string]*sessionState{},
	}
	defer server.closeAll()

	openResp := server.handleRequest(rpcRequest{
		ID:     1,
		Method: "session.open",
		Params: map[string]any{
			"session_id": "sess-rz",
		},
	})
	if !openResp.OK {
		t.Fatalf("session.open failed: %+v", openResp)
	}

	attachSmall := server.handleRequest(rpcRequest{
		ID:     2,
		Method: "session.attach",
		Params: map[string]any{
			"session_id":    "sess-rz",
			"attachment_id": "a-small",
			"cols":          90,
			"rows":          30,
		},
	})
	assertEffectiveSize(t, attachSmall, 90, 30)

	attachLarge := server.handleRequest(rpcRequest{
		ID:     3,
		Method: "session.attach",
		Params: map[string]any{
			"session_id":    "sess-rz",
			"attachment_id": "a-large",
			"cols":          120,
			"rows":          40,
		},
	})
	assertEffectiveSize(t, attachLarge, 90, 30) // RZ-001: smallest wins

	resizeLarge := server.handleRequest(rpcRequest{
		ID:     4,
		Method: "session.resize",
		Params: map[string]any{
			"session_id":    "sess-rz",
			"attachment_id": "a-large",
			"cols":          200,
			"rows":          60,
		},
	})
	assertEffectiveSize(t, resizeLarge, 90, 30) // RZ-002: still bounded by smallest

	detachSmall := server.handleRequest(rpcRequest{
		ID:     5,
		Method: "session.detach",
		Params: map[string]any{
			"session_id":    "sess-rz",
			"attachment_id": "a-small",
		},
	})
	assertEffectiveSize(t, detachSmall, 200, 60) // RZ-003: expands to next smallest

	detachLarge := server.handleRequest(rpcRequest{
		ID:     6,
		Method: "session.detach",
		Params: map[string]any{
			"session_id":    "sess-rz",
			"attachment_id": "a-large",
		},
	})
	assertEffectiveSize(t, detachLarge, 200, 60) // no attachments: keep last-known size
	assertAttachmentCount(t, detachLarge, 0)

	reattach := server.handleRequest(rpcRequest{
		ID:     7,
		Method: "session.attach",
		Params: map[string]any{
			"session_id":    "sess-rz",
			"attachment_id": "a-reconnect",
			"cols":          110,
			"rows":          50,
		},
	})
	assertEffectiveSize(t, reattach, 110, 50) // RZ-004: recompute from active attachments on reattach
}

func TestSessionInvalidParamsAndNotFound(t *testing.T) {
	server := &rpcServer{
		nextStreamID:  1,
		nextSessionID: 1,
		streams:       map[string]*streamState{},
		sessions:      map[string]*sessionState{},
	}
	defer server.closeAll()

	missingSession := server.handleRequest(rpcRequest{
		ID:     1,
		Method: "session.attach",
		Params: map[string]any{
			"session_id":    "missing",
			"attachment_id": "a1",
			"cols":          80,
			"rows":          24,
		},
	})
	if missingSession.OK || missingSession.Error == nil || missingSession.Error.Code != "not_found" {
		t.Fatalf("session.attach on missing session should return not_found: %+v", missingSession)
	}

	badSize := server.handleRequest(rpcRequest{
		ID:     2,
		Method: "session.attach",
		Params: map[string]any{
			"session_id":    "missing",
			"attachment_id": "a1",
			"cols":          0,
			"rows":          24,
		},
	})
	if badSize.OK || badSize.Error == nil || badSize.Error.Code != "invalid_params" {
		t.Fatalf("session.attach with cols=0 should return invalid_params: %+v", badSize)
	}
}

func assertEffectiveSize(t *testing.T, resp rpcResponse, wantCols, wantRows int) {
	t.Helper()
	if !resp.OK {
		t.Fatalf("expected ok response, got error: %+v", resp)
	}
	result, ok := resp.Result.(map[string]any)
	if !ok {
		t.Fatalf("response missing result map: %+v", resp)
	}
	gotCols := asInt(t, result["effective_cols"], "effective_cols")
	gotRows := asInt(t, result["effective_rows"], "effective_rows")
	if gotCols != wantCols || gotRows != wantRows {
		t.Fatalf("effective size = %dx%d, want %dx%d payload=%+v", gotCols, gotRows, wantCols, wantRows, result)
	}
}

func assertAttachmentCount(t *testing.T, resp rpcResponse, want int) {
	t.Helper()
	if !resp.OK {
		t.Fatalf("expected ok response, got error: %+v", resp)
	}
	result, ok := resp.Result.(map[string]any)
	if !ok {
		t.Fatalf("response missing result map: %+v", resp)
	}
	attachments, ok := result["attachments"].([]map[string]any)
	if ok {
		if len(attachments) != want {
			t.Fatalf("attachments len = %d, want %d payload=%+v", len(attachments), want, result)
		}
		return
	}
	attachmentsAny, ok := result["attachments"].([]any)
	if !ok {
		t.Fatalf("attachments field has unexpected type (%T) payload=%+v", result["attachments"], result)
	}
	if len(attachmentsAny) != want {
		t.Fatalf("attachments len = %d, want %d payload=%+v", len(attachmentsAny), want, result)
	}
}

func asInt(t *testing.T, value any, field string) int {
	t.Helper()
	switch typed := value.(type) {
	case int:
		return typed
	case int8:
		return int(typed)
	case int16:
		return int(typed)
	case int32:
		return int(typed)
	case int64:
		return int(typed)
	case uint:
		return int(typed)
	case uint8:
		return int(typed)
	case uint16:
		return int(typed)
	case uint32:
		return int(typed)
	case uint64:
		return int(typed)
	case float64:
		if typed != math.Trunc(typed) {
			t.Fatalf("%s should be integer-valued, got %v", field, typed)
		}
		return int(typed)
	default:
		t.Fatalf("%s has unexpected type %T (%v)", field, value, value)
		return 0
	}
}
