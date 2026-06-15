package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/creack/pty"
	"nhooyr.io/websocket"
)

func newTestWebSocketPTYServer(t *testing.T, leasePath string) (*httptest.Server, *wsPTYHub) {
	t.Helper()
	stderr := &bytes.Buffer{}
	hub := newWebSocketPTYHub(wsPTYServerConfig{
		Shell:           "/bin/sh",
		ScrollbackLimit: 64 * 1024,
	}, stderr)
	server := httptest.NewServer(newWebSocketPTYHandler(wsPTYServerConfig{
		PTYAuthLeaseFile: leasePath,
		Shell:            "/bin/sh",
		PTYHub:           hub,
		ScrollbackLimit:  64 * 1024,
	}, stderr))
	t.Cleanup(func() {
		server.Close()
		hub.closeAll()
		if t.Failed() && stderr.Len() > 0 {
			t.Logf("ws pty stderr:\n%s", stderr.String())
		}
	})
	return server, hub
}

// TestAttachRPCSurfacesPTYAllocationFailure pins the contract that a remote PTY
// allocation failure (e.g. a hardened devpts mounted ptmxmode=000 where
// /dev/ptmx cannot be opened) is reported loudly: the error returned to the
// client names the failing device and explains the devpts cause, and the daemon
// records the failure instead of leaving a 0-byte log. This is the regression
// for https://github.com/manaflow-ai/cmux/issues/5185, where the failure
// collapsed into a generic "remote PTY attach failed" with an empty daemon log.
func TestAttachRPCSurfacesPTYAllocationFailure(t *testing.T) {
	stderr := &bytes.Buffer{}
	hub := newWebSocketPTYHub(wsPTYServerConfig{Shell: "/bin/sh"}, stderr)
	t.Cleanup(hub.closeAll)

	denied := &os.PathError{Op: "open", Path: "/dev/ptmx", Err: syscall.EACCES}
	hub.openPTY = func() (*os.File, *os.File, error) {
		return nil, nil, denied
	}

	_, _, _, err := hub.attachRPC(context.Background(), "sess-1", "att-1", 80, 24, "", "", false)
	if err == nil {
		t.Fatalf("expected attachRPC to fail when PTY allocation is denied")
	}

	msg := err.Error()
	lowered := strings.ToLower(msg)
	// Pin the stable marker the Swift clients key their passthrough off of: a
	// daemon wording change that dropped it would silently break client-side
	// preservation of this diagnostic without failing any other assertion. Match
	// case-insensitively, exactly as Sources/Workspace.swift does.
	if !strings.Contains(lowered, "could not allocate a remote pty") {
		t.Fatalf("error must preserve the stable PTY-allocation marker the clients key off: %q", msg)
	}
	if !strings.Contains(msg, "/dev/ptmx") {
		t.Fatalf("error should name the device that could not be opened: %q", msg)
	}
	// The EACCES remediation hint is appended for any permission-denied failure
	// independent of /proc/self/mountinfo, so these assertions hold even in a
	// container/sandbox without a real devpts mount (describeDevPTS may add
	// nothing there). Key off the hint, not the optional mount summary.
	if !strings.Contains(lowered, "ptmxmode") || !strings.Contains(lowered, "remount") {
		t.Fatalf("error should explain the hardened devpts cause and remediation: %q", msg)
	}

	if stderr.Len() == 0 {
		t.Fatalf("PTY allocation failure must be logged to the daemon log, not swallowed")
	}
	if !strings.Contains(stderr.String(), "/dev/ptmx") {
		t.Fatalf("daemon log should include the allocation failure detail: %q", stderr.String())
	}
}

func TestServeWSRequiresExplicitLeaseFile(t *testing.T) {
	var stderr bytes.Buffer
	code := run([]string{"serve", "--ws", "--listen", "127.0.0.1:0"}, strings.NewReader(""), &bytes.Buffer{}, &stderr)
	if code != 2 {
		t.Fatalf("serve --ws without lease file exit = %d, want 2 stderr=%q", code, stderr.String())
	}
	if !strings.Contains(stderr.String(), "requires --auth-lease-file") {
		t.Fatalf("stderr should explain missing lease file: %q", stderr.String())
	}
}

func TestWebSocketPTYHealthIsAvailableWhenLocked(t *testing.T) {
	leasePath := filepath.Join(t.TempDir(), "lease.json")
	server, _ := newTestWebSocketPTYServer(t, leasePath)

	resp, err := http.Get(server.URL + "/healthz")
	if err != nil {
		t.Fatalf("GET /healthz failed: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("/healthz status = %d, want 200", resp.StatusCode)
	}
	var body map[string]any
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode health body: %v", err)
	}
	if body["ok"] != true || body["locked"] != true {
		t.Fatalf("unexpected health body: %v", body)
	}
}

func TestWebSocketPTYRejectsMissingAndWrongLease(t *testing.T) {
	leasePath := filepath.Join(t.TempDir(), "lease.json")
	server, _ := newTestWebSocketPTYServer(t, leasePath)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn := dialPTY(t, ctx, server.URL)
	sendAuth(t, ctx, conn, "missing", "sess-missing", 80, 24)
	_, _, err := conn.Read(ctx)
	if websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("missing lease should close with policy violation, got err=%v status=%v", err, websocket.CloseStatus(err))
	}

	writeTestLease(t, leasePath, "correct-token", "sess-wrong", true, time.Now().Add(time.Minute))
	conn = dialPTY(t, ctx, server.URL)
	sendAuth(t, ctx, conn, "wrong-token", "sess-wrong", 80, 24)
	_, _, err = conn.Read(ctx)
	if websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("wrong token should close with policy violation, got err=%v status=%v", err, websocket.CloseStatus(err))
	}
	if _, statErr := os.Stat(leasePath); statErr != nil {
		t.Fatalf("wrong-token attempt should not consume lease: %v", statErr)
	}

	writeTestLease(t, leasePath, "expired-token", "sess-expired", true, time.Now().Add(-time.Minute))
	conn = dialPTY(t, ctx, server.URL)
	sendAuth(t, ctx, conn, "expired-token", "sess-expired", 80, 24)
	_, _, err = conn.Read(ctx)
	if websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("expired token should close with policy violation, got err=%v status=%v", err, websocket.CloseStatus(err))
	}
}

func TestWebSocketPTYRequiresSessionMatchAndConsumesLeaseOnce(t *testing.T) {
	leasePath := filepath.Join(t.TempDir(), "lease.json")
	server, _ := newTestWebSocketPTYServer(t, leasePath)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	writeTestLease(t, leasePath, "cmux-secret", "sess-good", true, time.Now().Add(time.Minute))
	conn := dialPTY(t, ctx, server.URL)
	sendAuth(t, ctx, conn, "cmux-secret", "sess-other", 80, 24)
	_, _, err := conn.Read(ctx)
	if websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("wrong session should close with policy violation, got err=%v status=%v", err, websocket.CloseStatus(err))
	}
	if _, statErr := os.Stat(leasePath); statErr != nil {
		t.Fatalf("wrong-session attempt should not consume lease: %v", statErr)
	}

	conn = dialPTY(t, ctx, server.URL)
	sendAuth(t, ctx, conn, "cmux-secret", "sess-good", 100, 30)
	msgType, payload, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("read ready: %v", err)
	}
	if msgType != websocket.MessageText || !strings.Contains(string(payload), `"ready"`) {
		t.Fatalf("first frame should be ready text, type=%v payload=%q", msgType, string(payload))
	}
	if _, statErr := os.Stat(leasePath); !os.IsNotExist(statErr) {
		t.Fatalf("successful auth should consume lease, stat err=%v", statErr)
	}
	_ = conn.Close(websocket.StatusNormalClosure, "done")

	conn = dialPTY(t, ctx, server.URL)
	sendAuth(t, ctx, conn, "cmux-secret", "sess-good", 100, 30)
	_, _, err = conn.Read(ctx)
	if websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("replay should close with policy violation, got err=%v status=%v", err, websocket.CloseStatus(err))
	}
}

func TestWebSocketPTYAcceptsSignedTokenAndRejectsReplay(t *testing.T) {
	useTempSignedLeaseUsedDir(t)
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	audienceFile := writeSignedAudienceFile(t, "vm-test")
	stderr := &bytes.Buffer{}
	hub := newWebSocketPTYHub(wsPTYServerConfig{
		Shell:           "/bin/sh",
		ScrollbackLimit: 64 * 1024,
	}, stderr)
	server := httptest.NewServer(newWebSocketPTYHandler(wsPTYServerConfig{
		PTYAuthLeaseFile:       filepath.Join(t.TempDir(), "missing-pty-lease.json"),
		SignedAuthPublicKey:    base64.StdEncoding.EncodeToString(publicKey),
		SignedAuthAudienceFile: audienceFile,
		Shell:                  "/bin/sh",
		PTYHub:                 hub,
		ScrollbackLimit:        64 * 1024,
	}, stderr))
	t.Cleanup(func() {
		server.Close()
		hub.closeAll()
	})

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	token := signedTestToken(t, privateKey, "pty", "vm-test", "sess-signed", true, time.Now().Add(time.Minute), "jti-pty-1")
	conn := dialPTY(t, ctx, server.URL)
	sendAuth(t, ctx, conn, token, "sess-signed", 100, 30)
	msgType, payload, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("read ready: %v", err)
	}
	if msgType != websocket.MessageText || !strings.Contains(string(payload), `"ready"`) {
		t.Fatalf("first frame should be ready text, type=%v payload=%q", msgType, string(payload))
	}
	_ = conn.Close(websocket.StatusNormalClosure, "done")

	conn = dialPTY(t, ctx, server.URL)
	sendAuth(t, ctx, conn, token, "sess-signed", 100, 30)
	_, _, err = conn.Read(ctx)
	if websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("signed token replay should close with policy violation, got err=%v status=%v", err, websocket.CloseStatus(err))
	}
}

func TestWebSocketPTYRejectsSignedTokenForWrongKind(t *testing.T) {
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	audienceFile := writeSignedAudienceFile(t, "vm-test")
	stderr := &bytes.Buffer{}
	hub := newWebSocketPTYHub(wsPTYServerConfig{Shell: "/bin/sh"}, stderr)
	server := httptest.NewServer(newWebSocketPTYHandler(wsPTYServerConfig{
		PTYAuthLeaseFile:       filepath.Join(t.TempDir(), "missing-pty-lease.json"),
		SignedAuthPublicKey:    base64.StdEncoding.EncodeToString(publicKey),
		SignedAuthAudienceFile: audienceFile,
		Shell:                  "/bin/sh",
		PTYHub:                 hub,
	}, stderr))
	t.Cleanup(func() {
		server.Close()
		hub.closeAll()
	})

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	token := signedTestToken(t, privateKey, "rpc", "vm-test", "sess-wrong-kind", false, time.Now().Add(time.Minute), "jti-rpc-1")
	conn := dialPTY(t, ctx, server.URL)
	sendAuth(t, ctx, conn, token, "sess-wrong-kind", 100, 30)
	_, _, err = conn.Read(ctx)
	if websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("wrong signed token kind should close with policy violation, got err=%v status=%v", err, websocket.CloseStatus(err))
	}
}

func TestWebSocketPTYRejectsSignedTokenForWrongAudience(t *testing.T) {
	useTempSignedLeaseUsedDir(t)
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	audienceFile := writeSignedAudienceFile(t, "vm-test")
	stderr := &bytes.Buffer{}
	hub := newWebSocketPTYHub(wsPTYServerConfig{Shell: "/bin/sh"}, stderr)
	server := httptest.NewServer(newWebSocketPTYHandler(wsPTYServerConfig{
		PTYAuthLeaseFile:       filepath.Join(t.TempDir(), "missing-pty-lease.json"),
		SignedAuthPublicKey:    base64.StdEncoding.EncodeToString(publicKey),
		SignedAuthAudienceFile: audienceFile,
		Shell:                  "/bin/sh",
		PTYHub:                 hub,
	}, stderr))
	t.Cleanup(func() {
		server.Close()
		hub.closeAll()
	})

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	token := signedTestToken(t, privateKey, "pty", "other-vm", "sess-wrong-audience", true, time.Now().Add(time.Minute), "jti-wrong-audience")
	conn := dialPTY(t, ctx, server.URL)
	sendAuth(t, ctx, conn, token, "sess-wrong-audience", 100, 30)
	_, _, err = conn.Read(ctx)
	if websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("wrong signed token audience should close with policy violation, got err=%v status=%v", err, websocket.CloseStatus(err))
	}
}

func TestParseSignedAuthPublicKeyAcceptsPaddedBase64URL(t *testing.T) {
	raw := bytes.Repeat([]byte{0xff}, ed25519.PublicKeySize)
	encodings := map[string]string{
		"padded base64url": base64.URLEncoding.EncodeToString(raw),
		"unpadded base64":  base64.RawStdEncoding.EncodeToString(raw),
	}
	for name, encoded := range encodings {
		parsed, err := parseSignedAuthPublicKey(encoded)
		if err != nil {
			t.Fatalf("parse %s public key: %v", name, err)
		}
		if !bytes.Equal(parsed, raw) {
			t.Fatalf("%s parsed public key = %x, want %x", name, []byte(parsed), raw)
		}
	}
}

func TestConsumeSignedLeaseJTIDurableReplay(t *testing.T) {
	useTempSignedLeaseUsedDir(t)
	expiry := time.Now().Add(time.Minute).Unix()
	if err := consumeSignedLeaseJTI("durable-jti", expiry); err != nil {
		t.Fatalf("first consume signed JTI: %v", err)
	}
	if err := consumeSignedLeaseJTI("durable-jti", expiry); !errors.Is(err, errWSSignedLeaseInvalid) {
		t.Fatalf("second consume signed JTI error = %v, want %v", err, errWSSignedLeaseInvalid)
	}
}

func TestCleanupExpiredSignedLeaseJTIBuckets(t *testing.T) {
	useTempSignedLeaseUsedDir(t)
	now := time.Now()
	expiredAt := now.Add(-time.Minute).Unix()
	futureAt := now.Add(time.Minute).Unix()
	expiredDir := signedLeaseJTIBucketDir(expiredAt)
	futureDir := signedLeaseJTIBucketDir(futureAt)
	if err := os.MkdirAll(expiredDir, 0o700); err != nil {
		t.Fatalf("create expired JTI bucket: %v", err)
	}
	if err := os.MkdirAll(futureDir, 0o700); err != nil {
		t.Fatalf("create future JTI bucket: %v", err)
	}
	if err := os.WriteFile(filepath.Join(expiredDir, "expired"), []byte("1\n"), 0o600); err != nil {
		t.Fatalf("write expired JTI marker: %v", err)
	}
	if err := os.WriteFile(filepath.Join(futureDir, "future"), []byte("1\n"), 0o600); err != nil {
		t.Fatalf("write future JTI marker: %v", err)
	}

	cleanupExpiredSignedLeaseJTIBuckets(now.Unix())

	if _, err := os.Stat(expiredDir); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("expired JTI bucket stat error = %v, want not exist", err)
	}
	if _, err := os.Stat(futureDir); err != nil {
		t.Fatalf("future JTI bucket stat error = %v", err)
	}
}

func TestWebSocketPTYRunsShellOverBinaryFrames(t *testing.T) {
	leasePath := filepath.Join(t.TempDir(), "lease.json")
	server, _ := newTestWebSocketPTYServer(t, leasePath)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	writeTestLease(t, leasePath, "terminal-token", "sess-shell", true, time.Now().Add(time.Minute))
	conn := dialPTY(t, ctx, server.URL)
	defer conn.Close(websocket.StatusNormalClosure, "done")
	sendAuth(t, ctx, conn, "terminal-token", "sess-shell", 80, 24)
	msgType, payload, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("read ready: %v", err)
	}
	if msgType != websocket.MessageText || !strings.Contains(string(payload), `"ready"`) {
		t.Fatalf("first frame should be ready text, type=%v payload=%q", msgType, string(payload))
	}

	if err := conn.Write(ctx, websocket.MessageBinary, []byte("printf '%b\\n' '\\103\\115\\125\\130\\137\\127\\123\\137\\117\\113'; exit\r")); err != nil {
		t.Fatalf("write terminal command: %v", err)
	}

	output := waitForBinaryContains(t, ctx, conn, "CMUX_WS_OK", 15*time.Second)
	waitForNormalCloseWithOutput(t, ctx, conn, 10*time.Second, output)
}

func TestWebSocketPTYReconnectKeepsSessionProcess(t *testing.T) {
	leasePath := filepath.Join(t.TempDir(), "lease.json")
	server, hub := newTestWebSocketPTYServer(t, leasePath)

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	writeTestLease(t, leasePath, "first-token", "sess-reconnect", true, time.Now().Add(time.Minute))
	conn := dialPTY(t, ctx, server.URL)
	sendAuthWithAttachment(t, ctx, conn, "first-token", "sess-reconnect", "same", 80, 24)
	readReady(t, ctx, conn)
	if err := conn.Write(ctx, websocket.MessageBinary, []byte("CMUX_RECONNECT_MARKER=alive; export CMUX_RECONNECT_MARKER; printf 'first-ready\\n'\r")); err != nil {
		t.Fatalf("write first command: %v", err)
	}
	waitForBinaryContains(t, ctx, conn, "first-ready", 5*time.Second)
	_ = conn.Close(websocket.StatusNormalClosure, "detach")

	writeTestLease(t, leasePath, "second-token", "sess-reconnect", true, time.Now().Add(time.Minute))
	conn = dialPTY(t, ctx, server.URL)
	defer conn.Close(websocket.StatusNormalClosure, "done")
	sendAuthWithAttachment(t, ctx, conn, "second-token", "sess-reconnect", "same", 80, 24)
	readReady(t, ctx, conn)
	if err := conn.Write(ctx, websocket.MessageBinary, []byte("printf '%s\\n' \"$CMUX_RECONNECT_MARKER\"; exit\r")); err != nil {
		t.Fatalf("write reconnect command: %v", err)
	}
	waitForBinaryContains(t, ctx, conn, "alive", 5*time.Second)
	waitForHubSessionCount(t, hub, 0, 5*time.Second)
}

func TestWebSocketPTYReplacedAttachmentCannotWriteInput(t *testing.T) {
	leasePath := filepath.Join(t.TempDir(), "lease.json")
	server, hub := newTestWebSocketPTYServer(t, leasePath)

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	writeTestLease(t, leasePath, "old-token", "sess-replace", true, time.Now().Add(time.Minute))
	oldConn := dialPTY(t, ctx, server.URL)
	sendAuthWithAttachment(t, ctx, oldConn, "old-token", "sess-replace", "same", 120, 40)
	readReady(t, ctx, oldConn)

	writeTestLease(t, leasePath, "new-token", "sess-replace", true, time.Now().Add(time.Minute))
	newConn := dialPTY(t, ctx, server.URL)
	defer newConn.Close(websocket.StatusNormalClosure, "done")
	sendAuthWithAttachment(t, ctx, newConn, "new-token", "sess-replace", "same", 90, 30)
	readReady(t, ctx, newConn)
	waitForHubSessionSize(t, hub, "sess-replace", 1, 90, 30, 5*time.Second)

	_ = oldConn.Write(ctx, websocket.MessageBinary, []byte("printf 'STALE_INPUT\\n'\r"))
	resizePayload, err := json.Marshal(wsPTYControlFrame{Type: "resize", Cols: 100, Rows: 35})
	if err != nil {
		t.Fatalf("marshal stale resize: %v", err)
	}
	_ = oldConn.Write(ctx, websocket.MessageText, resizePayload)
	_ = oldConn.Close(websocket.StatusNormalClosure, "stale detach")
	waitForHubSessionSize(t, hub, "sess-replace", 1, 90, 30, 5*time.Second)
	waitForHubPTYSize(t, hub, "sess-replace", 90, 30, 5*time.Second)

	if err := newConn.Write(ctx, websocket.MessageBinary, []byte("printf 'SIZE:'; stty size; printf '%b\\n' '\\106\\122\\105\\123\\110\\137\\111\\116\\120\\125\\124'; exit\r")); err != nil {
		t.Fatalf("write fresh command: %v", err)
	}
	output := waitForBinaryContains(t, ctx, newConn, "FRESH_INPUT", 5*time.Second)
	if !strings.Contains(output, "SIZE:30 90") {
		t.Fatalf("replaced attachment changed terminal size, output=%q", output)
	}
	if strings.Contains(output, "STALE_INPUT") {
		t.Fatalf("replaced attachment wrote input, output=%q", output)
	}
	waitForNormalCloseWithOutput(t, ctx, newConn, 5*time.Second, output)
	waitForHubSessionCount(t, hub, 0, 5*time.Second)
}

func TestWebSocketPTYMultiAttachUsesSmallestResize(t *testing.T) {
	leasePath := filepath.Join(t.TempDir(), "lease.json")
	server, hub := newTestWebSocketPTYServer(t, leasePath)

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	writeTestLease(t, leasePath, "a-token", "sess-resize", true, time.Now().Add(time.Minute))
	a := dialPTY(t, ctx, server.URL)
	defer a.Close(websocket.StatusNormalClosure, "done")
	sendAuthWithAttachment(t, ctx, a, "a-token", "sess-resize", "a", 120, 40)
	readReady(t, ctx, a)

	writeTestLease(t, leasePath, "b-token", "sess-resize", true, time.Now().Add(time.Minute))
	b := dialPTY(t, ctx, server.URL)
	defer b.Close(websocket.StatusNormalClosure, "done")
	sendAuthWithAttachment(t, ctx, b, "b-token", "sess-resize", "b", 90, 30)
	readReady(t, ctx, b)
	waitForHubPTYSize(t, hub, "sess-resize", 90, 30, 5*time.Second)

	invalidResizePayload, err := json.Marshal(wsPTYControlFrame{Type: "resize", Cols: 0, Rows: 0})
	if err != nil {
		t.Fatalf("marshal invalid resize: %v", err)
	}
	if err := b.Write(ctx, websocket.MessageText, invalidResizePayload); err != nil {
		t.Fatalf("write invalid resize: %v", err)
	}
	if err := b.Write(ctx, websocket.MessageBinary, []byte("printf 'BADSIZE:'; stty size\r")); err != nil {
		t.Fatalf("write bad resize stty size: %v", err)
	}
	waitForBinaryContains(t, ctx, a, "BADSIZE:30 90", 5*time.Second)
	waitForHubSessionSize(t, hub, "sess-resize", 2, 90, 30, 5*time.Second)
	waitForHubPTYSize(t, hub, "sess-resize", 90, 30, 5*time.Second)

	if err := a.Write(ctx, websocket.MessageBinary, []byte("stty size\r")); err != nil {
		t.Fatalf("write stty size: %v", err)
	}
	waitForBinaryContains(t, ctx, a, "30 90", 5*time.Second)

	resizePayload, err := json.Marshal(wsPTYControlFrame{Type: "resize", Cols: 100, Rows: 35})
	if err != nil {
		t.Fatalf("marshal resize: %v", err)
	}
	if err := b.Write(ctx, websocket.MessageText, resizePayload); err != nil {
		t.Fatalf("write resize: %v", err)
	}
	waitForHubSessionSize(t, hub, "sess-resize", 2, 100, 35, 5*time.Second)
	waitForHubPTYSize(t, hub, "sess-resize", 100, 35, 5*time.Second)
	if err := a.Write(ctx, websocket.MessageBinary, []byte("printf 'SIZE2:'; stty size\r")); err != nil {
		t.Fatalf("write second stty size: %v", err)
	}
	waitForBinaryContains(t, ctx, a, "SIZE2:35 100", 5*time.Second)

	_ = b.Close(websocket.StatusNormalClosure, "detach b")
	waitForHubSessionSize(t, hub, "sess-resize", 1, 120, 40, 5*time.Second)
	waitForHubPTYSize(t, hub, "sess-resize", 120, 40, 5*time.Second)
	if err := a.Write(ctx, websocket.MessageBinary, []byte("printf 'SIZE3:'; stty size\r")); err != nil {
		t.Fatalf("write third stty size: %v", err)
	}
	waitForBinaryContains(t, ctx, a, "SIZE3:40 120", 5*time.Second)
	if err := a.Write(ctx, websocket.MessageBinary, []byte("exit\r")); err != nil {
		t.Fatalf("write final exit: %v", err)
	}
	waitForHubSessionCount(t, hub, 0, 5*time.Second)
}

func TestWebSocketPTYStressSessionCleanupAndBoundedScrollback(t *testing.T) {
	leasePath := filepath.Join(t.TempDir(), "lease.json")
	hub := newWebSocketPTYHub(wsPTYServerConfig{
		Shell:           "/bin/sh",
		ScrollbackLimit: 4096,
	}, &bytes.Buffer{})
	server := httptest.NewServer(newWebSocketPTYHandler(wsPTYServerConfig{
		PTYAuthLeaseFile: leasePath,
		Shell:            "/bin/sh",
		PTYHub:           hub,
		ScrollbackLimit:  4096,
	}, &bytes.Buffer{}))
	defer server.Close()
	defer hub.closeAll()

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	baseGoroutines := runtime.NumGoroutine()

	for i := 0; i < 25; i++ {
		sessionID := "stress-" + strconv.Itoa(i)
		token := "token-" + strconv.Itoa(i)
		writeTestLease(t, leasePath, token, sessionID, true, time.Now().Add(time.Minute))
		conn := dialPTY(t, ctx, server.URL)
		sendAuth(t, ctx, conn, token, sessionID, 80+i, 24)
		readReady(t, ctx, conn)
		if err := conn.Write(ctx, websocket.MessageBinary, []byte("printf '%8192s\\n' x; printf '%b\\n' '\\103\\115\\125\\130\\137\\110\\117\\114\\104'; read line; exit\r")); err != nil {
			t.Fatalf("write stress command %d: %v", i, err)
		}
		waitForBinaryContainsLabel(t, ctx, conn, "stress session "+sessionID+" hold marker", "CMUX_HOLD", 10*time.Second)
		if got := hub.maxScrollbackBytes(); got != 4096 {
			t.Fatalf("scrollback bytes = %d, want cap 4096", got)
		}
		if err := conn.Write(ctx, websocket.MessageBinary, []byte("\r")); err != nil {
			t.Fatalf("release stress command %d: %v", i, err)
		}
		waitForNormalClose(t, ctx, conn, 5*time.Second)
		waitForHubSessionCount(t, hub, 0, 5*time.Second)
	}
	waitForGoroutineCeiling(t, baseGoroutines+8, 5*time.Second)
}

func TestWebSocketPTYAnonymousDetachTerminatesSession(t *testing.T) {
	leasePath := filepath.Join(t.TempDir(), "lease.json")
	server, hub := newTestWebSocketPTYServer(t, leasePath)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	writeTestLease(t, leasePath, "anon-token", "sess-anon", true, time.Now().Add(time.Minute))
	conn := dialPTY(t, ctx, server.URL)
	sendAuth(t, ctx, conn, "anon-token", "sess-anon", 80, 24)
	readReady(t, ctx, conn)
	if err := conn.Write(ctx, websocket.MessageBinary, []byte("printf 'ANON_READY\\n'\r")); err != nil {
		t.Fatalf("write anonymous marker: %v", err)
	}
	waitForBinaryContains(t, ctx, conn, "ANON_READY", 5*time.Second)
	_ = conn.Close(websocket.StatusNormalClosure, "detach")

	waitForHubSessionCount(t, hub, 0, 5*time.Second)
}

func TestWebSocketPTYAnonymousAttachesAreIsolated(t *testing.T) {
	leasePath := filepath.Join(t.TempDir(), "lease.json")
	server, hub := newTestWebSocketPTYServer(t, leasePath)

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	writeTestLease(t, leasePath, "anon-a-token", "sess-anon-shared", true, time.Now().Add(time.Minute))
	a := dialPTY(t, ctx, server.URL)
	defer a.Close(websocket.StatusNormalClosure, "done")
	sendAuth(t, ctx, a, "anon-a-token", "sess-anon-shared", 80, 24)
	readReady(t, ctx, a)
	if err := a.Write(ctx, websocket.MessageBinary, []byte("CMUX_ANON_MARK=one; export CMUX_ANON_MARK; printf 'A_READY\\n'\r")); err != nil {
		t.Fatalf("write anonymous A marker: %v", err)
	}
	waitForBinaryContains(t, ctx, a, "A_READY", 5*time.Second)

	writeTestLease(t, leasePath, "anon-b-token", "sess-anon-shared", true, time.Now().Add(time.Minute))
	b := dialPTY(t, ctx, server.URL)
	defer b.Close(websocket.StatusNormalClosure, "done")
	sendAuth(t, ctx, b, "anon-b-token", "sess-anon-shared", 80, 24)
	readReady(t, ctx, b)
	if err := b.Write(ctx, websocket.MessageBinary, []byte("printf 'B_MARK:%s\\n' \"${CMUX_ANON_MARK-unset}\"; exit\r")); err != nil {
		t.Fatalf("write anonymous B marker: %v", err)
	}
	output := waitForBinaryContains(t, ctx, b, "B_MARK:unset", 5*time.Second)
	if strings.Contains(output, "B_MARK:one") {
		t.Fatalf("anonymous attach reused another shell, output=%q", output)
	}
	waitForHubSessionCount(t, hub, 1, 5*time.Second)
	_ = a.Close(websocket.StatusNormalClosure, "done")
	waitForHubSessionCount(t, hub, 0, 5*time.Second)
}

func TestWebSocketPTYAnonymousSessionKeyCannotBeForged(t *testing.T) {
	leasePath := filepath.Join(t.TempDir(), "lease.json")
	server, hub := newTestWebSocketPTYServer(t, leasePath)

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	writeTestLease(t, leasePath, "anon-forge-token", "sess-forge", true, time.Now().Add(time.Minute))
	anon := dialPTY(t, ctx, server.URL)
	defer anon.Close(websocket.StatusNormalClosure, "done")
	sendAuth(t, ctx, anon, "anon-forge-token", "sess-forge", 80, 24)
	readReady(t, ctx, anon)
	if err := anon.Write(ctx, websocket.MessageBinary, []byte("CMUX_FORGE_MARK=anon; export CMUX_FORGE_MARK; printf 'ANON_FORGE_READY\\n'\r")); err != nil {
		t.Fatalf("write anonymous forge marker: %v", err)
	}
	waitForBinaryContains(t, ctx, anon, "ANON_FORGE_READY", 5*time.Second)

	writeTestLease(t, leasePath, "persistent-forge-token", "sess-forge:anon-0", true, time.Now().Add(time.Minute))
	persistent := dialPTY(t, ctx, server.URL)
	defer persistent.Close(websocket.StatusNormalClosure, "done")
	sendAuthWithAttachment(t, ctx, persistent, "persistent-forge-token", "sess-forge:anon-0", "persist", 80, 24)
	readReady(t, ctx, persistent)
	if err := persistent.Write(ctx, websocket.MessageBinary, []byte("printf 'PERSISTENT_FORGE:%s\\n' \"${CMUX_FORGE_MARK-unset}\"; exit\r")); err != nil {
		t.Fatalf("write persistent forge probe: %v", err)
	}
	output := waitForBinaryContains(t, ctx, persistent, "PERSISTENT_FORGE:unset", 5*time.Second)
	if strings.Contains(output, "PERSISTENT_FORGE:anon") {
		t.Fatalf("persistent attach reused anonymous shell, output=%q", output)
	}
	waitForHubSessionCount(t, hub, 1, 5*time.Second)
	_ = anon.Close(websocket.StatusNormalClosure, "done")
	waitForHubSessionCount(t, hub, 0, 5*time.Second)
}

func TestWebSocketPTYAttachmentWithoutSessionIDIsAnonymous(t *testing.T) {
	leasePath := filepath.Join(t.TempDir(), "lease.json")
	server, hub := newTestWebSocketPTYServer(t, leasePath)

	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()

	writeTestLease(t, leasePath, "no-session-a-token", "", true, time.Now().Add(time.Minute))
	a := dialPTY(t, ctx, server.URL)
	defer a.Close(websocket.StatusNormalClosure, "done")
	sendAuthWithAttachment(t, ctx, a, "no-session-a-token", "", "same", 80, 24)
	readReady(t, ctx, a)
	if err := a.Write(ctx, websocket.MessageBinary, []byte("CMUX_NO_SESSION_MARK=one; export CMUX_NO_SESSION_MARK; printf 'NO_SESSION_A_READY\\n'\r")); err != nil {
		t.Fatalf("write no-session A marker: %v", err)
	}
	waitForBinaryContains(t, ctx, a, "NO_SESSION_A_READY", 5*time.Second)

	writeTestLease(t, leasePath, "no-session-b-token", "", true, time.Now().Add(time.Minute))
	b := dialPTY(t, ctx, server.URL)
	defer b.Close(websocket.StatusNormalClosure, "done")
	sendAuthWithAttachment(t, ctx, b, "no-session-b-token", "", "same", 80, 24)
	readReady(t, ctx, b)
	if err := b.Write(ctx, websocket.MessageBinary, []byte("printf 'NO_SESSION_B:%s\\n' \"${CMUX_NO_SESSION_MARK-unset}\"; exit\r")); err != nil {
		t.Fatalf("write no-session B probe: %v", err)
	}
	output := waitForBinaryContains(t, ctx, b, "NO_SESSION_B:unset", 5*time.Second)
	if strings.Contains(output, "NO_SESSION_B:one") {
		t.Fatalf("attachment without session_id reused another shell, output=%q", output)
	}
	waitForHubSessionCount(t, hub, 1, 5*time.Second)
	_ = a.Close(websocket.StatusNormalClosure, "done")
	waitForHubSessionCount(t, hub, 0, 5*time.Second)
}

func TestWebSocketPTYDropsBackpressuredAttachment(t *testing.T) {
	hub := newWebSocketPTYHub(wsPTYServerConfig{
		Shell:           "/bin/sh",
		ScrollbackLimit: 4096,
	}, &bytes.Buffer{})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	sessionKey := persistentPTYSessionKey("sess-backpressure")
	attachment := &wsPTYAttachment{
		sessionKey: sessionKey,
		id:         "slow",
		cols:       80,
		rows:       24,
		send:       make(chan wsPTYOutgoingFrame, 1),
		cancel:     cancel,
		persistent: true,
	}
	attachment.send <- wsPTYOutgoingFrame{
		messageType: websocket.MessageBinary,
		payload:     []byte("already queued"),
	}
	session := &wsPTYSession{
		id:            "sess-backpressure",
		key:           sessionKey,
		attachments:   map[string]*wsPTYAttachment{"slow": attachment},
		effectiveCols: 80,
		effectiveRows: 24,
		lastKnownCols: 80,
		lastKnownRows: 24,
	}

	hub.mu.Lock()
	hub.sessions[session.key] = session
	hub.mu.Unlock()

	hub.recordAndBroadcast(session, []byte("overflow"))
	if attachments, _, _, ok := hub.sessionDebugSnapshot(session.id); !ok || attachments != 0 {
		t.Fatalf("backpressured session state = ok:%v attachments:%d, want ok:true attachments:0", ok, attachments)
	}
	select {
	case <-ctx.Done():
	default:
		t.Fatal("backpressured attachment context was not canceled")
	}
}

func TestWebSocketPTYInputBackpressureDoesNotBlockHub(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatalf("pipe: %v", err)
	}
	defer reader.Close()

	stderr := &bytes.Buffer{}
	hub := newWebSocketPTYHub(wsPTYServerConfig{
		Shell:           "/bin/sh",
		ScrollbackLimit: 4096,
	}, stderr)
	sessionKey := persistentPTYSessionKey("sess-input-backpressure")
	sessionDone := make(chan struct{})
	attachment := &wsPTYAttachment{
		sessionKey: sessionKey,
		id:         "att-input",
		cols:       80,
		rows:       24,
		send:       make(chan wsPTYOutgoingFrame, defaultWebSocketWriteQueueCap),
		cancel:     func() {},
		persistent: true,
	}
	session := &wsPTYSession{
		id:            "sess-input-backpressure",
		key:           sessionKey,
		ptyFile:       writer,
		attachments:   map[string]*wsPTYAttachment{attachment.id: attachment},
		effectiveCols: 80,
		effectiveRows: 24,
		lastKnownCols: 80,
		lastKnownRows: 24,
		input:         make(chan wsPTYInputChunk, defaultPTYInputQueueCap),
		done:          sessionDone,
	}
	defer func() {
		_ = writer.Close()
		close(sessionDone)
	}()

	hub.mu.Lock()
	hub.sessions[session.key] = session
	hub.mu.Unlock()
	go hub.writeInputLoop(session)

	payload := bytes.Repeat([]byte("x"), 64*1024)
	writesDone := make(chan struct{})
	go func() {
		defer close(writesDone)
		for i := 0; i < defaultPTYInputQueueCap*4; i++ {
			_ = hub.writeInputByID(session.id, attachment.id, "", payload)
		}
	}()

	select {
	case <-writesDone:
	case <-time.After(2 * time.Second):
		t.Fatal("writeInputByID blocked behind a full PTY writer")
	}

	closeDone := make(chan bool, 1)
	go func() {
		closeDone <- hub.closeSessionByID(session.id)
	}()
	select {
	case ok := <-closeDone:
		if !ok {
			t.Fatal("closeSessionByID returned false")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("closeSessionByID blocked behind a full PTY writer")
	}
}

func TestWebSocketPTYWriteFailureClosesConnectionAndReapsAttachment(t *testing.T) {
	leasePath := filepath.Join(t.TempDir(), "lease.json")
	stderr := &bytes.Buffer{}
	hub := newWebSocketPTYHub(wsPTYServerConfig{
		Shell:           "/bin/sh",
		ScrollbackLimit: 4096,
		SessionIdleTTL:  20 * time.Millisecond,
	}, stderr)
	server := httptest.NewServer(newWebSocketPTYHandler(wsPTYServerConfig{
		PTYAuthLeaseFile: leasePath,
		Shell:            "/bin/sh",
		PTYHub:           hub,
		ScrollbackLimit:  4096,
		SessionIdleTTL:   20 * time.Millisecond,
	}, stderr))
	defer server.Close()
	defer hub.closeAll()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	writeTestLease(t, leasePath, "write-fail-token", "sess-write-fail", true, time.Now().Add(time.Minute))
	conn := dialPTY(t, ctx, server.URL)
	sendAuthWithAttachment(t, ctx, conn, "write-fail-token", "sess-write-fail", "persist", 80, 24)
	readReady(t, ctx, conn)
	waitForHubSessionSize(t, hub, "sess-write-fail", 1, 80, 24, 5*time.Second)

	attachment := hub.debugAttachment("sess-write-fail", "persist")
	if attachment == nil {
		t.Fatal("attachment was not registered")
	}
	cancelWriteCtx, cancelWrite := context.WithCancel(ctx)
	cancelWrite()
	if attachment.writeFrame(cancelWriteCtx, attachment.conn, wsPTYOutgoingFrame{
		messageType: websocket.MessageBinary,
		payload:     []byte("will fail"),
	}) {
		t.Fatal("writeFrame unexpectedly succeeded with a canceled context")
	}

	waitForHubSessionCount(t, hub, 0, 5*time.Second)
	closeCtx, cancelClose := context.WithTimeout(ctx, 5*time.Second)
	defer cancelClose()
	for {
		_, _, err := conn.Read(closeCtx)
		if err == nil {
			continue
		}
		if errors.Is(err, context.DeadlineExceeded) {
			t.Fatal("client connection stayed open after server write failure")
		}
		break
	}
}

func TestWebSocketPTYInputBackpressureRejectsWholePayload(t *testing.T) {
	stderr := &bytes.Buffer{}
	hub := newWebSocketPTYHub(wsPTYServerConfig{
		Shell:           "/bin/sh",
		ScrollbackLimit: 4096,
	}, stderr)
	sessionKey := persistentPTYSessionKey("sess-input-atomic")
	sessionDone := make(chan struct{})
	attachment := &wsPTYAttachment{
		sessionKey: sessionKey,
		id:         "att-input",
		cols:       80,
		rows:       24,
		send:       make(chan wsPTYOutgoingFrame, defaultWebSocketWriteQueueCap),
		cancel:     func() {},
		persistent: true,
	}
	session := &wsPTYSession{
		id:            "sess-input-atomic",
		key:           sessionKey,
		attachments:   map[string]*wsPTYAttachment{attachment.id: attachment},
		effectiveCols: 80,
		effectiveRows: 24,
		lastKnownCols: 80,
		lastKnownRows: 24,
		input:         make(chan wsPTYInputChunk, defaultPTYInputQueueCap),
		done:          sessionDone,
	}
	defer close(sessionDone)

	hub.mu.Lock()
	hub.sessions[session.key] = session
	hub.mu.Unlock()

	for i := 0; i < defaultPTYInputQueueCap-1; i++ {
		session.input <- wsPTYInputChunk{
			attachmentID: attachment.id,
			attachment:   attachment,
			payload:      []byte("queued"),
		}
	}

	payload := append(
		bytes.Repeat([]byte("x"), defaultPTYInputChunkBytes),
		'y',
	)
	if status := hub.writeInputByID(session.id, attachment.id, "", payload); status != wsPTYInputWriteQueueFull {
		t.Fatalf("writeInputByID status = %v, want queue full", status)
	}
	if len(session.input) == defaultPTYInputQueueCap {
		t.Fatal("writeInputByID unexpectedly accepted a two-chunk payload with one queue slot free")
	}
	if got := len(session.input); got != defaultPTYInputQueueCap-1 {
		t.Fatalf("input queue length = %d, want unchanged %d", got, defaultPTYInputQueueCap-1)
	}
	for len(session.input) > 0 {
		chunk := <-session.input
		if bytes.Contains(chunk.payload, []byte("x")) || bytes.Contains(chunk.payload, []byte("y")) {
			t.Fatalf("rejected payload chunk was partially enqueued: %q", string(chunk.payload))
		}
	}
	if !strings.Contains(stderr.String(), "ws pty input queue full") {
		t.Fatalf("stderr should report input queue backpressure, got %q", stderr.String())
	}
}

func TestWebSocketPTYReapsDetachedIdleSession(t *testing.T) {
	leasePath := filepath.Join(t.TempDir(), "lease.json")
	stderr := &bytes.Buffer{}
	hub := newWebSocketPTYHub(wsPTYServerConfig{
		Shell:           "/bin/sh",
		ScrollbackLimit: 4096,
		SessionIdleTTL:  20 * time.Millisecond,
	}, stderr)
	server := httptest.NewServer(newWebSocketPTYHandler(wsPTYServerConfig{
		PTYAuthLeaseFile: leasePath,
		Shell:            "/bin/sh",
		PTYHub:           hub,
		ScrollbackLimit:  4096,
		SessionIdleTTL:   20 * time.Millisecond,
	}, stderr))
	defer server.Close()
	defer hub.closeAll()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	writeTestLease(t, leasePath, "idle-token", "sess-idle", true, time.Now().Add(time.Minute))
	conn := dialPTY(t, ctx, server.URL)
	sendAuthWithAttachment(t, ctx, conn, "idle-token", "sess-idle", "persist", 80, 24)
	readReady(t, ctx, conn)
	if err := conn.Write(ctx, websocket.MessageBinary, []byte("printf 'IDLE_READY\\n'\r")); err != nil {
		t.Fatalf("write idle marker: %v", err)
	}
	waitForBinaryContains(t, ctx, conn, "IDLE_READY", 5*time.Second)
	_ = conn.Close(websocket.StatusNormalClosure, "detach")

	waitForHubSessionCount(t, hub, 0, 5*time.Second)
}

func TestWebSocketPTYScrollbackDoesNotRetainOversizedChunks(t *testing.T) {
	hub := newWebSocketPTYHub(wsPTYServerConfig{
		Shell:           "/bin/sh",
		ScrollbackLimit: 4096,
	}, &bytes.Buffer{})
	session := &wsPTYSession{id: "scrollback"}

	hub.mu.Lock()
	hub.appendScrollbackLocked(session, bytes.Repeat([]byte("x"), 1<<20))
	hub.mu.Unlock()
	if got := len(session.scrollback); got != 4096 {
		t.Fatalf("scrollback len = %d, want 4096", got)
	}
	if got := cap(session.scrollback); got > 4096 {
		t.Fatalf("scrollback cap = %d, want <= 4096", got)
	}

	hub.mu.Lock()
	hub.appendScrollbackLocked(session, []byte("tail"))
	hub.mu.Unlock()
	if got := len(session.scrollback); got != 4096 {
		t.Fatalf("scrollback len after append = %d, want 4096", got)
	}
	if got := cap(session.scrollback); got > 4096 {
		t.Fatalf("scrollback cap after append = %d, want <= 4096", got)
	}
	if !strings.HasSuffix(string(session.scrollback), "tail") {
		t.Fatalf("scrollback should retain newest output, got suffix %q", string(session.scrollback[len(session.scrollback)-16:]))
	}
}

func TestWebSocketPTYSeedsUTF8LocaleAndTerminalEnv(t *testing.T) {
	leasePath := filepath.Join(t.TempDir(), "lease.json")
	server, _ := newTestWebSocketPTYServer(t, leasePath)

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	writeTestLease(t, leasePath, "env-token", "sess-env", true, time.Now().Add(time.Minute))
	conn := dialPTY(t, ctx, server.URL)
	defer conn.Close(websocket.StatusNormalClosure, "done")
	sendAuth(t, ctx, conn, "env-token", "sess-env", 80, 24)
	msgType, payload, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("read ready: %v", err)
	}
	if msgType != websocket.MessageText || !strings.Contains(string(payload), `"ready"`) {
		t.Fatalf("first frame should be ready text, type=%v payload=%q", msgType, string(payload))
	}

	command := "printf '%s\\n' \"$LANG|$LC_CTYPE|$LC_ALL|$TERM|$COLORTERM|$TERM_PROGRAM|$CMUX_REMOTE_TRANSPORT\"; locale charmap; exit\r"
	if err := conn.Write(ctx, websocket.MessageBinary, []byte(command)); err != nil {
		t.Fatalf("write terminal command: %v", err)
	}

	var output strings.Builder
	wantTerminalEnv := "|xterm-256color|truecolor|ghostty|ws"
	wantCharmap := "UTF-8"
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		readCtx, cancelRead := context.WithTimeout(ctx, time.Until(deadline))
		msgType, payload, err = conn.Read(readCtx)
		cancelRead()
		if err != nil {
			t.Fatalf("read terminal env: %v output=%q", err, output.String())
		}
		if msgType != websocket.MessageBinary {
			continue
		}
		output.Write(payload)
		if strings.Contains(output.String(), wantTerminalEnv) && strings.Contains(output.String(), wantCharmap) {
			return
		}
	}
	t.Fatalf("timed out waiting for terminal env, got %q", output.String())
}

func dialPTY(t *testing.T, ctx context.Context, serverURL string) *websocket.Conn {
	t.Helper()
	wsURL := "ws" + strings.TrimPrefix(serverURL, "http") + "/terminal"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("dial %s: %v", wsURL, err)
	}
	return conn
}

func sendAuth(t *testing.T, ctx context.Context, conn *websocket.Conn, token, sessionID string, cols, rows int) {
	t.Helper()
	sendAuthWithAttachment(t, ctx, conn, token, sessionID, "", cols, rows)
}

func sendAuthWithAttachment(t *testing.T, ctx context.Context, conn *websocket.Conn, token, sessionID string, attachmentID string, cols, rows int) {
	t.Helper()
	payload, err := json.Marshal(wsPTYAuthFrame{
		Type:         "auth",
		Token:        token,
		SessionID:    sessionID,
		AttachmentID: attachmentID,
		Cols:         cols,
		Rows:         rows,
	})
	if err != nil {
		t.Fatalf("marshal auth: %v", err)
	}
	if err := conn.Write(ctx, websocket.MessageText, payload); err != nil {
		t.Fatalf("write auth: %v", err)
	}
}

func writeTestLease(t *testing.T, path, token, sessionID string, singleUse bool, expiresAt time.Time) {
	t.Helper()
	sum := sha256.Sum256([]byte(token))
	lease := wsPTYLease{
		Version:       1,
		TokenSHA256:   hex.EncodeToString(sum[:]),
		ExpiresAtUnix: expiresAt.Unix(),
		SessionID:     sessionID,
		SingleUse:     singleUse,
	}
	data, err := json.Marshal(lease)
	if err != nil {
		t.Fatalf("marshal lease: %v", err)
	}
	if err := os.WriteFile(path, data, 0o600); err != nil {
		t.Fatalf("write lease: %v", err)
	}
}

func signedTestToken(t *testing.T, privateKey ed25519.PrivateKey, kind, audience, sessionID string, singleUse bool, expiresAt time.Time, jti string) string {
	t.Helper()
	claims := wsSignedLeaseClaims{
		Version:       1,
		Kind:          kind,
		Audience:      audience,
		SessionID:     sessionID,
		ExpiresAtUnix: expiresAt.Unix(),
		SingleUse:     singleUse,
		JTI:           jti,
	}
	payload, err := json.Marshal(claims)
	if err != nil {
		t.Fatalf("marshal signed token claims: %v", err)
	}
	payloadPart := base64.RawURLEncoding.EncodeToString(payload)
	signature := ed25519.Sign(privateKey, []byte(payloadPart))
	return payloadPart + "." + base64.RawURLEncoding.EncodeToString(signature)
}

func writeSignedAudienceFile(t *testing.T, audience string) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "signed-audience")
	if err := os.WriteFile(path, []byte(audience+"\n"), 0o600); err != nil {
		t.Fatalf("write signed audience: %v", err)
	}
	return path
}

func useTempSignedLeaseUsedDir(t *testing.T) {
	t.Helper()
	old := wsSignedLeaseUsedDir
	wsSignedLeaseUsedDir = t.TempDir()
	t.Cleanup(func() {
		wsSignedLeaseUsedDir = old
	})
}

func readReady(t *testing.T, ctx context.Context, conn *websocket.Conn) {
	t.Helper()
	msgType, payload, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("read ready: %v", err)
	}
	if msgType != websocket.MessageText || !strings.Contains(string(payload), `"ready"`) {
		t.Fatalf("first frame should be ready text, type=%v payload=%q", msgType, string(payload))
	}
}

func waitForBinaryContains(t *testing.T, ctx context.Context, conn *websocket.Conn, needle string, timeout time.Duration) string {
	t.Helper()
	return waitForBinaryContainsLabel(t, ctx, conn, needle, needle, timeout)
}

func waitForBinaryContainsLabel(t *testing.T, ctx context.Context, conn *websocket.Conn, label string, needle string, timeout time.Duration) string {
	t.Helper()
	var output strings.Builder
	deadline := time.Now().Add(timeout)
	closeOnTimeout := time.AfterFunc(timeout, func() {
		_ = conn.Close(websocket.StatusNormalClosure, "test read timeout")
	})
	defer closeOnTimeout.Stop()
	for time.Now().Before(deadline) {
		readCtx, cancelRead := context.WithTimeout(ctx, time.Until(deadline))
		msgType, payload, err := conn.Read(readCtx)
		cancelRead()
		if err != nil {
			t.Fatalf("read terminal output while waiting for %s: %v output=%q", label, err, output.String())
		}
		if msgType != websocket.MessageBinary {
			continue
		}
		output.Write(payload)
		if strings.Contains(output.String(), needle) {
			return output.String()
		}
	}
	t.Fatalf("timed out waiting for %s (%q), got %q", label, needle, output.String())
	return output.String()
}

func waitForNormalClose(t *testing.T, ctx context.Context, conn *websocket.Conn, timeout time.Duration) {
	t.Helper()
	waitForNormalCloseWithOutput(t, ctx, conn, timeout, "")
}

func waitForNormalCloseWithOutput(t *testing.T, ctx context.Context, conn *websocket.Conn, timeout time.Duration, output string) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		readCtx, cancelRead := context.WithTimeout(ctx, time.Until(deadline))
		_, _, err := conn.Read(readCtx)
		cancelRead()
		if err == nil {
			continue
		}
		if websocket.CloseStatus(err) != websocket.StatusNormalClosure {
			t.Fatalf("expected normal close, got err=%v status=%v output=%q", err, websocket.CloseStatus(err), output)
		}
		return
	}
	t.Fatalf("timed out waiting for normal close output=%q", output)
}

func waitForHubSessionCount(t *testing.T, hub *wsPTYHub, want int, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if got := hub.activeSessionCount(); got == want {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("hub session count = %d, want %d", hub.activeSessionCount(), want)
}

func waitForHubSessionSize(t *testing.T, hub *wsPTYHub, sessionID string, wantAttachments int, wantCols int, wantRows int, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		attachments, cols, rows, ok := hub.sessionDebugSnapshot(sessionID)
		if ok && attachments == wantAttachments && cols == wantCols && rows == wantRows {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	attachments, cols, rows, ok := hub.sessionDebugSnapshot(sessionID)
	t.Fatalf(
		"hub session %s state = ok:%v attachments:%d size:%dx%d, want attachments:%d size:%dx%d",
		sessionID,
		ok,
		attachments,
		cols,
		rows,
		wantAttachments,
		wantCols,
		wantRows,
	)
}

func waitForHubPTYSize(t *testing.T, hub *wsPTYHub, sessionID string, wantCols int, wantRows int, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		cols, rows, ok, err := hub.sessionPTYSize(sessionID)
		if err != nil {
			t.Fatalf("read pty size for %s: %v", sessionID, err)
		}
		if ok && cols == wantCols && rows == wantRows {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	cols, rows, ok, err := hub.sessionPTYSize(sessionID)
	t.Fatalf("hub session %s pty size = ok:%v size:%dx%d err:%v, want %dx%d", sessionID, ok, cols, rows, err, wantCols, wantRows)
}

func waitForGoroutineCeiling(t *testing.T, ceiling int, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		runtime.GC()
		if got := runtime.NumGoroutine(); got <= ceiling {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("goroutine count = %d, want <= %d", runtime.NumGoroutine(), ceiling)
}

func (h *wsPTYHub) sessionDebugSnapshot(sessionID string) (attachments int, effectiveCols int, effectiveRows int, ok bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	session := h.sessions[persistentPTYSessionKey(sessionID)]
	if session == nil {
		return 0, 0, 0, false
	}
	return len(session.attachments), session.effectiveCols, session.effectiveRows, true
}

func (h *wsPTYHub) debugAttachment(sessionID string, attachmentID string) *wsPTYAttachment {
	h.mu.Lock()
	defer h.mu.Unlock()
	session := h.sessions[persistentPTYSessionKey(sessionID)]
	if session == nil {
		return nil
	}
	return session.attachments[attachmentID]
}

func (h *wsPTYHub) sessionPTYSize(sessionID string) (cols int, rows int, ok bool, err error) {
	h.mu.Lock()
	session := h.sessions[persistentPTYSessionKey(sessionID)]
	if session == nil {
		h.mu.Unlock()
		return 0, 0, false, nil
	}
	h.mu.Unlock()

	session.ptyWriteMu.Lock()
	defer session.ptyWriteMu.Unlock()
	sizeFile := session.ptyFile

	size, err := pty.GetsizeFull(sizeFile)
	if err != nil {
		return 0, 0, true, err
	}
	return int(size.Cols), int(size.Rows), true, nil
}
