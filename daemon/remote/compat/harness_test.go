package compat

import (
	"bufio"
	"bytes"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"io"
	"math/big"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

var (
	buildOnce       sync.Once
	builtBinaryPath string
	buildBinaryErr  error
	daemonRegistry  = struct {
		sync.Mutex
		byEndpoint map[string]func() string
	}{
		byEndpoint: map[string]func() string{},
	}
)

func daemonBinary(t *testing.T) string {
	t.Helper()

	if override := os.Getenv("CMUX_REMOTE_DAEMON_BIN"); override != "" {
		return override
	}

	buildOnce.Do(func() {
		builtBinaryPath = filepath.Join(daemonRemoteRoot(), "rust", "target", "debug", "cmuxd-remote")
		repoRoot := filepath.Clean(filepath.Join(daemonRemoteRoot(), "../.."))
		cmd := exec.Command("cargo", "build", "--manifest-path", "./rust/Cargo.toml")
		cmd.Dir = daemonRemoteRoot()
		cmd.Env = append(os.Environ(), "GHOSTTY_SOURCE_DIR="+filepath.Join(repoRoot, "ghostty"))
		output, err := cmd.CombinedOutput()
		if err != nil {
			buildBinaryErr = fmt.Errorf("cargo build failed: %w\n%s", err, strings.TrimSpace(string(output)))
			return
		}
	})

	if buildBinaryErr != nil {
		t.Fatalf("build daemon binary: %v", buildBinaryErr)
	}
	return builtBinaryPath
}

func runJSONLFixture(t *testing.T, bin string, args ...string) []map[string]any {
	t.Helper()
	result := runJSONLFixtureDetailed(t, bin, nil, 0, args...)
	if result.TimedOut {
		t.Fatalf("daemon did not exit after stdin closed\nstderr:\n%s", result.Stderr)
	}
	if result.ExitErr != nil {
		t.Fatalf("daemon exited with error: %v\nstderr:\n%s", result.ExitErr, result.Stderr)
	}
	return result.Responses
}

func runJSONLFixtureWithVars(t *testing.T, bin string, initialVars map[string]string, args ...string) []map[string]any {
	t.Helper()
	result := runJSONLFixtureDetailed(t, bin, initialVars, 0, args...)
	if result.TimedOut {
		t.Fatalf("daemon did not exit after stdin closed\nstderr:\n%s", result.Stderr)
	}
	if result.ExitErr != nil {
		t.Fatalf("daemon exited with error: %v\nstderr:\n%s", result.ExitErr, result.Stderr)
	}
	return result.Responses
}

type jsonlFixtureResult struct {
	Responses []map[string]any
	Stderr    string
	ExitErr   error
	TimedOut  bool
}

func runJSONLFixtureWithExitTimeout(t *testing.T, bin string, initialVars map[string]string, exitTimeout time.Duration, args ...string) jsonlFixtureResult {
	t.Helper()
	return runJSONLFixtureDetailed(t, bin, initialVars, exitTimeout, args...)
}

func runJSONLFixtureDetailed(t *testing.T, bin string, initialVars map[string]string, exitTimeout time.Duration, args ...string) jsonlFixtureResult {
	t.Helper()

	if len(args) == 0 {
		t.Fatal("runJSONLFixture requires daemon args and a fixture path")
	}
	fixturePath := args[len(args)-1]
	daemonArgs := args[:len(args)-1]

	cmd := exec.Command(bin, daemonArgs...)
	cmd.Dir = daemonRemoteRoot()

	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatalf("stdin pipe: %v", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatalf("stdout pipe: %v", err)
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	if err := cmd.Start(); err != nil {
		t.Fatalf("start daemon: %v", err)
	}

	reader := bufio.NewReader(stdout)
	vars := map[string]string{}
	for key, value := range initialVars {
		vars[key] = value
	}
	var responses []map[string]any

	for _, rawLine := range readFixtureLines(t, fixturePath) {
		line := substitutePlaceholders(t, rawLine, vars)
		if _, err := io.WriteString(stdin, line+"\n"); err != nil {
			t.Fatalf("write request %q: %v", line, err)
		}

		respLine, err := reader.ReadString('\n')
		if err != nil {
			t.Fatalf("read response for %q: %v\nstderr:\n%s", line, err, stderr.String())
		}

		var payload map[string]any
		if err := json.Unmarshal([]byte(respLine), &payload); err != nil {
			t.Fatalf("decode response %q: %v", strings.TrimSpace(respLine), err)
		}
		captureResponseVars(payload, vars)
		responses = append(responses, payload)
	}

	if err := stdin.Close(); err != nil {
		t.Fatalf("close stdin: %v", err)
	}

	if exitTimeout <= 0 {
		return jsonlFixtureResult{
			Responses: responses,
			Stderr:    stderr.String(),
			ExitErr:   cmd.Wait(),
		}
	}

	waitCh := make(chan error, 1)
	go func() {
		waitCh <- cmd.Wait()
	}()

	select {
	case err := <-waitCh:
		return jsonlFixtureResult{
			Responses: responses,
			Stderr:    stderr.String(),
			ExitErr:   err,
		}
	case <-time.After(exitTimeout):
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		<-waitCh
		return jsonlFixtureResult{
			Responses: responses,
			Stderr:    stderr.String(),
			TimedOut:  true,
		}
	}
}

func readFixtureLines(t *testing.T, fixturePath string) []string {
	t.Helper()

	path := fixturePath
	if !filepath.IsAbs(path) {
		path = filepath.Join(compatPackageDir(), fixturePath)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read fixture %q: %v", fixturePath, err)
	}

	var lines []string
	for _, line := range strings.Split(string(data), "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" {
			continue
		}
		lines = append(lines, trimmed)
	}
	return lines
}

func substitutePlaceholders(t *testing.T, input string, vars map[string]string) string {
	t.Helper()

	output := input
	for {
		start := strings.Index(output, "{{")
		if start == -1 {
			return output
		}
		end := strings.Index(output[start+2:], "}}")
		if end == -1 {
			t.Fatalf("unterminated placeholder in %q", input)
		}

		key := output[start+2 : start+2+end]
		value, ok := vars[key]
		if !ok {
			t.Fatalf("missing placeholder %q for fixture line %q", key, input)
		}
		output = output[:start] + value + output[start+2+end+2:]
	}
}

func captureResponseVars(payload map[string]any, vars map[string]string) {
	result, _ := payload["result"].(map[string]any)
	if result == nil {
		return
	}

	for _, key := range []string{"session_id", "attachment_id", "stream_id"} {
		if value, ok := result[key].(string); ok && value != "" {
			vars[key] = value
		}
	}
	if value, ok := result["offset"].(float64); ok {
		vars["offset"] = fmt.Sprintf("%.0f", value)
	}
}

func daemonRemoteRoot() string {
	_, file, _, _ := runtime.Caller(0)
	return filepath.Dir(filepath.Dir(file))
}

func compatPackageDir() string {
	_, file, _, _ := runtime.Caller(0)
	return filepath.Dir(file)
}

type unixDaemonServer struct {
	SocketPath string
	process    daemonProcess
}

func startUnixDaemon(t *testing.T, bin string) string {
	t.Helper()

	socketDir, err := os.MkdirTemp("", "cmuxd-unix-")
	if err != nil {
		t.Fatalf("mkdir temp socket dir: %v", err)
	}
	shortDir := filepath.Join(os.TempDir(), filepath.Base(socketDir))
	if renameErr := os.Rename(socketDir, shortDir); renameErr == nil {
		socketDir = shortDir
	}
	t.Cleanup(func() {
		_ = os.RemoveAll(socketDir)
	})

	socketPath := filepath.Join(socketDir, "s.sock")
	server := &unixDaemonServer{
		SocketPath: socketPath,
	}
	cmd := exec.Command(
		bin,
		"serve",
		"--unix",
		"--socket", server.SocketPath,
	)
	cmd.Dir = daemonRemoteRoot()
	server.process.start(t, cmd, "start unix daemon")
	registerDaemonDiagnostics(server.SocketPath, server.process.diagnostics)

	t.Cleanup(func() {
		unregisterDaemonDiagnostics(server.SocketPath)
		server.process.stop()
	})

	waitForUnixSocket(t, server)
	return server.SocketPath
}

func startUnixDaemonWithWS(t *testing.T, bin string, wsSecret string) (socketPath string, wsAddr string) {
	t.Helper()

	socketDir, err := os.MkdirTemp("", "cmuxd-unix-")
	if err != nil {
		t.Fatalf("mkdir temp socket dir: %v", err)
	}
	shortDir := filepath.Join(os.TempDir(), filepath.Base(socketDir))
	if renameErr := os.Rename(socketDir, shortDir); renameErr == nil {
		socketDir = shortDir
	}
	t.Cleanup(func() {
		_ = os.RemoveAll(socketDir)
	})

	socketPath = filepath.Join(socketDir, "s.sock")
	wsAddr = freeTCPAddress(t)
	_, wsPort, err := net.SplitHostPort(wsAddr)
	if err != nil {
		t.Fatalf("split websocket addr %q: %v", wsAddr, err)
	}

	server := &unixDaemonServer{
		SocketPath: socketPath,
	}
	cmd := exec.Command(
		bin,
		"serve",
		"--unix",
		"--socket", server.SocketPath,
		"--ws-port", wsPort,
		"--ws-secret", wsSecret,
	)
	cmd.Dir = daemonRemoteRoot()
	server.process.start(t, cmd, "start unix daemon with websocket")
	registerDaemonDiagnostics(server.SocketPath, server.process.diagnostics)

	t.Cleanup(func() {
		unregisterDaemonDiagnostics(server.SocketPath)
		server.process.stop()
	})

	waitForUnixSocket(t, server)
	registerDaemonDiagnostics(wsAddr, server.process.diagnostics)
	t.Cleanup(func() {
		unregisterDaemonDiagnostics(wsAddr)
	})
	waitForTCPServer(t, wsAddr, &server.process.stderr)
	return socketPath, wsAddr
}

type unixJSONRPCClient struct {
	conn   net.Conn
	reader *bufio.Reader
}

func newUnixJSONRPCClient(t *testing.T, socketPath string) *unixJSONRPCClient {
	t.Helper()

	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		t.Fatalf("dial unix socket %s: %v%s", socketPath, err, daemonDiagnosticsForEndpoint(socketPath))
	}
	t.Cleanup(func() {
		_ = conn.Close()
	})

	return &unixJSONRPCClient{
		conn:   conn,
		reader: bufio.NewReader(conn),
	}
}

func (c *unixJSONRPCClient) Call(t *testing.T, payload map[string]any) map[string]any {
	t.Helper()
	return writeAndReadJSONWithReader(t, c.conn, c.reader, payload)
}

func (c *unixJSONRPCClient) Close() error {
	if c == nil || c.conn == nil {
		return nil
	}
	err := c.conn.Close()
	c.conn = nil
	c.reader = nil
	return err
}

type tlsDaemonServer struct {
	Addr         string
	ServerID     string
	TicketSecret []byte

	process daemonProcess
}

func startTLSServer(t *testing.T, bin string) *tlsDaemonServer {
	t.Helper()

	tempDir := t.TempDir()
	certFile, keyFile := writeSelfSignedCert(t, tempDir)
	addr := freeTCPAddress(t)

	server := &tlsDaemonServer{
		Addr:         addr,
		ServerID:     "cmux-macmini",
		TicketSecret: []byte("compat-secret"),
	}
	cmd := exec.Command(
		bin,
		"serve",
		"--tls",
		"--listen", server.Addr,
		"--server-id", server.ServerID,
		"--ticket-secret", string(server.TicketSecret),
		"--cert-file", certFile,
		"--key-file", keyFile,
	)
	cmd.Dir = daemonRemoteRoot()
	server.process.start(t, cmd, "start tls daemon")
	registerDaemonDiagnostics(server.Addr, server.process.diagnostics)

	t.Cleanup(func() {
		unregisterDaemonDiagnostics(server.Addr)
		server.process.stop()
	})

	waitForTLSServer(t, server)
	return server
}

func runDirectTLSHandshake(t *testing.T, server *tlsDaemonServer, token string) map[string]any {
	t.Helper()

	conn := dialTLSServer(t, server)
	defer conn.Close()

	return writeAndReadJSON(t, conn, map[string]any{
		"ticket": token,
	})
}

func runDirectTLSHandshakeAndRequest(
	t *testing.T,
	server *tlsDaemonServer,
	token string,
	firstReq map[string]any,
	secondReq func(map[string]any) map[string]any,
) (map[string]any, map[string]any) {
	t.Helper()

	conn := dialTLSServer(t, server)
	defer conn.Close()

	handshake := writeAndReadJSON(t, conn, map[string]any{
		"ticket": token,
	})
	if ok, _ := handshake["ok"].(bool); !ok {
		t.Fatalf("tls handshake failed: %+v", handshake)
	}

	firstResp := writeAndReadJSON(t, conn, firstReq)
	secondResp := writeAndReadJSON(t, conn, secondReq(firstResp))
	return firstResp, secondResp
}

func dialTLSServer(t *testing.T, server *tlsDaemonServer) *tls.Conn {
	t.Helper()

	conn, err := tls.Dial("tcp", server.Addr, &tls.Config{
		MinVersion:         tls.VersionTLS13,
		InsecureSkipVerify: true,
	})
	if err != nil {
		t.Fatalf("dial tls server %s: %v%s", server.Addr, err, server.process.diagnostics())
	}
	return conn
}

func writeAndReadJSON(t *testing.T, conn net.Conn, payload map[string]any) map[string]any {
	t.Helper()
	return writeAndReadJSONWithReader(t, conn, bufio.NewReader(conn), payload)
}

func writeAndReadJSONWithReader(t *testing.T, conn net.Conn, reader *bufio.Reader, payload map[string]any) map[string]any {
	t.Helper()

	if err := conn.SetDeadline(time.Now().Add(3 * time.Second)); err != nil {
		t.Fatalf("set conn deadline: %v", err)
	}

	encoded, err := json.Marshal(payload)
	if err != nil {
		t.Fatalf("marshal payload: %v", err)
	}
	if _, err := conn.Write(append(encoded, '\n')); err != nil {
		t.Fatalf("write payload %q: %v", string(encoded), err)
	}

	line, err := reader.ReadString('\n')
	if err != nil {
		t.Fatalf("read response: %v%s", err, daemonDiagnosticsForConn(conn))
	}

	var response map[string]any
	if err := json.Unmarshal([]byte(line), &response); err != nil {
		t.Fatalf("decode response %q: %v", strings.TrimSpace(line), err)
	}
	return response
}

func waitForUnixSocket(t *testing.T, server *unixDaemonServer) {
	t.Helper()

	deadline := time.Now().Add(3 * time.Second)
	for {
		info, err := os.Stat(server.SocketPath)
		if err == nil && info.Mode()&os.ModeSocket != 0 {
			conn, dialErr := net.DialTimeout("unix", server.SocketPath, 100*time.Millisecond)
			if dialErr == nil {
				_ = conn.Close()
				return
			}
			err = dialErr
		}
		if time.Now().After(deadline) {
			t.Fatalf("unix daemon did not start on %s: %v%s", server.SocketPath, err, server.process.diagnostics())
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func waitForTLSServer(t *testing.T, server *tlsDaemonServer) {
	t.Helper()

	deadline := time.Now().Add(3 * time.Second)
	for {
		conn, err := tls.Dial("tcp", server.Addr, &tls.Config{
			MinVersion:         tls.VersionTLS13,
			InsecureSkipVerify: true,
		})
		if err == nil {
			_ = conn.Close()
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("tls daemon did not start on %s: %v%s", server.Addr, err, server.process.diagnostics())
		}
		time.Sleep(20 * time.Millisecond)
	}
}

func waitForTCPServer(t *testing.T, addr string, stderr *bytes.Buffer) {
	t.Helper()

	deadline := time.Now().Add(3 * time.Second)
	for {
		conn, err := net.DialTimeout("tcp", addr, 100*time.Millisecond)
		if err == nil {
			_ = conn.Close()
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("tcp server did not start on %s: %v\nstderr:\n%s", addr, err, stderr.String())
		}
		time.Sleep(20 * time.Millisecond)
	}
}

type daemonProcess struct {
	cmd    *exec.Cmd
	stderr bytes.Buffer

	mu      sync.Mutex
	exited  bool
	exitErr error
	done    chan struct{}
}

func (p *daemonProcess) start(t *testing.T, cmd *exec.Cmd, startMessage string) {
	t.Helper()

	p.cmd = cmd
	p.done = make(chan struct{})
	p.cmd.Stderr = &p.stderr

	if err := p.cmd.Start(); err != nil {
		t.Fatalf("%s: %v", startMessage, err)
	}

	go func() {
		err := p.cmd.Wait()
		p.mu.Lock()
		p.exited = true
		p.exitErr = err
		p.mu.Unlock()
		close(p.done)
	}()
}

func (p *daemonProcess) stop() {
	if p == nil || p.cmd == nil {
		return
	}
	if p.cmd.Process != nil {
		_ = p.cmd.Process.Kill()
	}
	if p.done != nil {
		<-p.done
	}
}

func (p *daemonProcess) diagnostics() string {
	if p == nil {
		return ""
	}

	p.mu.Lock()
	exited := p.exited
	exitErr := p.exitErr
	p.mu.Unlock()

	stderr := strings.TrimSpace(p.stderr.String())
	var details []string
	if exited {
		details = append(details, fmt.Sprintf("process exit: %v", exitErr))
	} else {
		details = append(details, "process state: still running")
	}
	if stderr != "" {
		details = append(details, fmt.Sprintf("stderr:\n%s", stderr))
	}
	if len(details) == 0 {
		return ""
	}
	return "\n" + strings.Join(details, "\n")
}

func registerDaemonDiagnostics(endpoint string, fn func() string) {
	daemonRegistry.Lock()
	defer daemonRegistry.Unlock()
	daemonRegistry.byEndpoint[endpoint] = fn
}

func unregisterDaemonDiagnostics(endpoint string) {
	daemonRegistry.Lock()
	defer daemonRegistry.Unlock()
	delete(daemonRegistry.byEndpoint, endpoint)
}

func daemonDiagnosticsForConn(conn net.Conn) string {
	if conn == nil {
		return ""
	}
	return daemonDiagnosticsForEndpoint(conn.RemoteAddr().String())
}

func daemonDiagnosticsForEndpoint(endpoint string) string {
	daemonRegistry.Lock()
	fn := daemonRegistry.byEndpoint[endpoint]
	daemonRegistry.Unlock()
	if fn == nil {
		return ""
	}
	return fn()
}

func freeTCPAddress(t *testing.T) string {
	t.Helper()

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("allocate tcp address: %v", err)
	}
	defer listener.Close()
	return listener.Addr().String()
}

func writeSelfSignedCert(t *testing.T, dir string) (certFile string, keyFile string) {
	t.Helper()

	privateKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatalf("generate private key: %v", err)
	}

	template := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject: pkix.Name{
			CommonName: "cmuxd-remote-compat",
		},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		DNSNames:              []string{"localhost"},
		IPAddresses:           []net.IP{net.ParseIP("127.0.0.1")},
	}

	der, err := x509.CreateCertificate(rand.Reader, template, template, privateKey.Public(), privateKey)
	if err != nil {
		t.Fatalf("create certificate: %v", err)
	}

	certFile = filepath.Join(dir, "server.crt")
	keyFile = filepath.Join(dir, "server.key")

	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	privateDER, err := x509.MarshalECPrivateKey(privateKey)
	if err != nil {
		t.Fatalf("marshal private key: %v", err)
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: privateDER})

	if err := os.WriteFile(certFile, certPEM, 0o600); err != nil {
		t.Fatalf("write cert: %v", err)
	}
	if err := os.WriteFile(keyFile, keyPEM, 0o600); err != nil {
		t.Fatalf("write key: %v", err)
	}

	return certFile, keyFile
}
