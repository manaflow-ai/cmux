package main

import (
	"bufio"
	"bytes"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"syscall"
	"testing"
	"time"
)

func TestPersistentDaemonShutdownStopsSlotWithActivePTY(t *testing.T) {
	socketDir, err := os.MkdirTemp("/tmp", "cmuxd-remote-shutdown-*")
	if err != nil {
		t.Fatalf("create short socket dir: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(socketDir) })
	socketPath := filepath.Join(socketDir, "rpc.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}

	done := make(chan error, 1)
	go func() {
		done <- servePersistentDaemonWithVerifier(
			listener,
			persistentDaemonFixedTokenVerifier("shutdown-token"),
			io.Discard,
		)
	}()
	serverExited := false
	defer func() {
		_ = listener.Close()
		if serverExited {
			return
		}
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			t.Errorf("persistent daemon did not stop during test cleanup")
		}
	}()

	conn, reader, writer := openPersistentTestClient(t, socketPath, "shutdown-token")
	defer conn.Close()
	attach := persistentTestRPCCall(t, conn, reader, writer, rpcRequest{
		ID:     1,
		Method: "pty.attach",
		Params: map[string]any{
			"session_id":              "shutdown-session",
			"attachment_id":           "shutdown-attachment",
			"client_attachment_token": "shutdown-attachment-token",
			"cols":                    80,
			"rows":                    24,
			"command":                 "sleep 60",
		},
	})
	if ok, _ := attach["ok"].(bool); !ok {
		t.Fatalf("pty.attach failed: %v", attach)
	}
	readPersistentTestEvent(t, conn, reader, func(frame map[string]any) bool {
		return frame["event"] == "pty.ready" && frame["attachment_id"] == "shutdown-attachment"
	})

	shutdown := persistentTestRPCCall(t, conn, reader, writer, rpcRequest{
		ID:     2,
		Method: "daemon.shutdown",
		Params: map[string]any{},
	})
	if ok, _ := shutdown["ok"].(bool); !ok {
		t.Fatalf("daemon.shutdown failed: %v", shutdown)
	}

	select {
	case err := <-done:
		serverExited = true
		if err != nil {
			t.Fatalf("persistent daemon exited with error: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("persistent daemon did not stop after daemon.shutdown")
	}
}

func TestRunPersistentStopUsesSlotControlPlane(t *testing.T) {
	rootBase := t.TempDir()
	socketBase, err := os.MkdirTemp("/tmp", "cmuxd-remote-stop-command-*")
	if err != nil {
		t.Fatalf("create short socket base: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(socketBase) })
	t.Setenv("CMUX_REMOTE_DAEMON_ROOT", rootBase)
	t.Setenv("CMUX_REMOTE_DAEMON_SOCKET_DIR", socketBase)

	paths, err := persistentDaemonPathsForSlot("stop-command-slot")
	if err != nil {
		t.Fatalf("resolve persistent daemon paths: %v", err)
	}
	paths, err = ensurePersistentDaemonDirectory(paths)
	if err != nil {
		t.Fatalf("create persistent daemon directories: %v", err)
	}
	token, err := persistentDaemonToken(paths)
	if err != nil {
		t.Fatalf("create persistent daemon token: %v", err)
	}
	listener, err := net.Listen("unix", paths.socket)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}
	done := make(chan error, 1)
	go func() {
		done <- servePersistentDaemonWithVerifier(
			listener,
			persistentDaemonFixedTokenVerifier(token),
			io.Discard,
		)
	}()
	serverExited := false
	defer func() {
		_ = listener.Close()
		if serverExited {
			return
		}
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			t.Errorf("persistent daemon did not stop during test cleanup")
		}
	}()

	conn, reader, writer := openPersistentTestClient(t, paths.socket, token)
	attach := persistentTestRPCCall(t, conn, reader, writer, rpcRequest{
		ID:     1,
		Method: "pty.attach",
		Params: map[string]any{
			"session_id":              "stop-command-session",
			"attachment_id":           "stop-command-attachment",
			"client_attachment_token": "stop-command-attachment-token",
			"cols":                    80,
			"rows":                    24,
			"command":                 "sleep 60",
		},
	})
	if ok, _ := attach["ok"].(bool); !ok {
		t.Fatalf("pty.attach failed: %v", attach)
	}
	readPersistentTestEvent(t, conn, reader, func(frame map[string]any) bool {
		return frame["event"] == "pty.ready" && frame["attachment_id"] == "stop-command-attachment"
	})
	_ = conn.Close()

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	code := run(
		[]string{"serve", "--persistent-stop", "--slot", "stop-command-slot"},
		strings.NewReader(""),
		&stdout,
		&stderr,
	)
	if code != 0 {
		t.Fatalf("serve --persistent-stop exit code = %d, stderr = %q", code, stderr.String())
	}

	select {
	case err := <-done:
		serverExited = true
		if err != nil {
			t.Fatalf("persistent daemon exited with error: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("persistent daemon did not stop after serve --persistent-stop")
	}
}

func TestPersistentDaemonShutdownRejectionDoesNotExposeRemoteMessage(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	done := make(chan error, 1)
	go func() {
		defer server.Close()
		reader := bufio.NewReader(server)
		if _, err := reader.ReadBytes('\n'); err != nil {
			done <- err
			return
		}
		_, err := io.WriteString(server, `{"id":"shutdown","ok":false,"error":{"code":"internal","message":"private remote detail"}}`+"\n")
		done <- err
	}()

	err := requestPersistentDaemonShutdown(client)
	if err == nil || err.Error() != "persistent daemon shutdown rejected" {
		t.Fatalf("shutdown error = %q, want generic rejection", err)
	}
	if serverErr := <-done; serverErr != nil {
		t.Fatalf("serve rejection response: %v", serverErr)
	}
}

func TestRunPersistentLeasePortValidation(t *testing.T) {
	for _, args := range [][]string{
		{"serve", "--stdio", "--persistent", "--slot", "slot", "--persistent-lease-port", "70000"},
		{"serve", "--persistent-stop", "--slot", "slot", "--persistent-lease-port", "64008"},
		{"serve", "--stdio", "--persistent-lease-port", "64008"},
	} {
		var stdout bytes.Buffer
		var stderr bytes.Buffer
		if code := run(args, strings.NewReader(""), &stdout, &stderr); code != 2 {
			t.Fatalf("run(%q) exit code = %d, stderr = %q; want usage error", args, code, stderr.String())
		}
	}
}

func TestStopPersistentDaemonWaitsForSlotLockWhenSocketIsAbsent(t *testing.T) {
	rootBase := t.TempDir()
	socketBase, err := os.MkdirTemp("/tmp", "cmuxd-remote-stop-lock-*")
	if err != nil {
		t.Fatalf("create short socket base: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(socketBase) })
	t.Setenv("CMUX_REMOTE_DAEMON_ROOT", rootBase)
	t.Setenv("CMUX_REMOTE_DAEMON_SOCKET_DIR", socketBase)

	paths, err := persistentDaemonPathsForSlot("stop-lock-slot")
	if err != nil {
		t.Fatalf("resolve persistent daemon paths: %v", err)
	}
	paths, err = ensurePersistentDaemonDirectory(paths)
	if err != nil {
		t.Fatalf("create persistent daemon directories: %v", err)
	}
	lockFile, err := os.OpenFile(paths.lockFile, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		t.Fatalf("open persistent daemon lock: %v", err)
	}
	defer lockFile.Close()
	if err := syscall.Flock(int(lockFile.Fd()), syscall.LOCK_EX); err != nil {
		t.Fatalf("hold persistent daemon lock: %v", err)
	}

	done := make(chan error, 1)
	go func() {
		done <- stopPersistentDaemon("stop-lock-slot")
	}()
	select {
	case err := <-done:
		t.Fatalf("persistent stop returned before slot ownership released: %v", err)
	case <-time.After(50 * time.Millisecond):
	}
	if err := syscall.Flock(int(lockFile.Fd()), syscall.LOCK_UN); err != nil {
		t.Fatalf("release persistent daemon lock: %v", err)
	}
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("persistent stop failed after slot ownership released: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("persistent stop did not finish after slot ownership released")
	}
}

func TestStopPersistentDaemonHandlesMissingStoredSocketDirectory(t *testing.T) {
	rootBase := t.TempDir()
	t.Setenv("CMUX_REMOTE_DAEMON_ROOT", rootBase)
	paths, err := persistentDaemonPathsForSlot("missing-socket-directory")
	if err != nil {
		t.Fatalf("resolve persistent daemon paths: %v", err)
	}
	if err := os.MkdirAll(paths.root, 0o700); err != nil {
		t.Fatalf("create persistent daemon root: %v", err)
	}
	storedSocketDirectory, err := os.MkdirTemp("/tmp", "cmuxd-remote-missing-socket-*")
	if err != nil {
		t.Fatalf("create stored socket directory: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(storedSocketDirectory) })
	if err := writePersistentDaemonSocketDir(paths.root, storedSocketDirectory); err != nil {
		t.Fatalf("record socket directory: %v", err)
	}
	if _, err := persistentDaemonToken(paths); err != nil {
		t.Fatalf("create persistent daemon token: %v", err)
	}
	if err := os.RemoveAll(storedSocketDirectory); err != nil {
		t.Fatalf("remove stored socket directory: %v", err)
	}

	if err := stopPersistentDaemon(paths.slot); err != nil {
		t.Fatalf("stop with missing stored socket directory: %v", err)
	}
}

func TestStopPersistentDaemonRemovesStaleSocketOnlyAfterLockReleased(t *testing.T) {
	rootBase := t.TempDir()
	t.Setenv("CMUX_REMOTE_DAEMON_ROOT", rootBase)
	paths, err := persistentDaemonPathsForSlot("missing-token")
	if err != nil {
		t.Fatalf("resolve persistent daemon paths: %v", err)
	}
	if err := os.MkdirAll(paths.root, 0o700); err != nil {
		t.Fatalf("create persistent daemon root: %v", err)
	}
	storedSocketDirectory := t.TempDir()
	if err := writePersistentDaemonSocketDir(paths.root, storedSocketDirectory); err != nil {
		t.Fatalf("record socket directory: %v", err)
	}
	paths.socket = filepath.Join(storedSocketDirectory, filepath.Base(paths.socket))
	if err := os.WriteFile(paths.socket, []byte("stale"), 0o600); err != nil {
		t.Fatalf("write stale socket: %v", err)
	}

	if err := stopPersistentDaemon(paths.slot); err != nil {
		t.Fatalf("stop with missing token: %v", err)
	}
	if _, err := os.Lstat(paths.socket); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("stale socket still exists: %v", err)
	}
}

func TestWaitForPersistentDaemonStopTimesOutWhenOwnershipDoesNotRelease(t *testing.T) {
	lockPath := filepath.Join(t.TempDir(), "daemon.lock")
	lockFile, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		t.Fatalf("open persistent daemon lock: %v", err)
	}
	defer lockFile.Close()
	if err := syscall.Flock(int(lockFile.Fd()), syscall.LOCK_EX); err != nil {
		t.Fatalf("hold persistent daemon lock: %v", err)
	}
	defer syscall.Flock(int(lockFile.Fd()), syscall.LOCK_UN)

	err = waitForPersistentDaemonStopWithTimeout(lockPath, 50*time.Millisecond, 5*time.Millisecond)
	if err == nil || !strings.Contains(err.Error(), "timed out waiting") {
		t.Fatalf("wait error = %v, want bounded timeout", err)
	}
}

func TestPersistentDaemonPreservesActivePTYAfterObservedSlotLeaseDisappears(t *testing.T) {
	socketDir, err := os.MkdirTemp("/tmp", "cmuxd-remote-lease-reap-*")
	if err != nil {
		t.Fatalf("create short socket dir: %v", err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(socketDir) })
	socketPath := filepath.Join(socketDir, "rpc.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}

	var leasePresent atomic.Bool
	leasePresent.Store(true)
	leaseChecked := make(chan bool, 1)
	leaseRemoved := make(chan struct{}, 1)
	var stderr bytes.Buffer
	done := make(chan error, 1)
	go func() {
		done <- servePersistentDaemonWithVerifierConfig(
			listener,
			persistentDaemonFixedTokenVerifier("lease-token"),
			&stderr,
			persistentDaemonServerConfig{
				acceptPollStep: 10 * time.Millisecond,
				slotLeasePresent: func() (bool, error) {
					present := leasePresent.Load()
					select {
					case leaseChecked <- present:
					default:
					}
					return present, nil
				},
				slotLeaseRemoved: func() {
					select {
					case leaseRemoved <- struct{}{}:
					default:
					}
				},
			},
		)
	}()
	serverExited := false
	defer func() {
		_ = listener.Close()
		if serverExited {
			return
		}
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			t.Errorf("persistent daemon did not stop during test cleanup")
		}
	}()

	select {
	case present := <-leaseChecked:
		if !present {
			t.Fatalf("persistent daemon observed an absent initial slot lease")
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("persistent daemon did not inspect the slot lease")
	}
	conn, reader, writer := openPersistentTestClient(t, socketPath, "lease-token")
	attach := persistentTestRPCCall(t, conn, reader, writer, rpcRequest{
		ID:     1,
		Method: "pty.attach",
		Params: map[string]any{
			"session_id":              "lease-session",
			"attachment_id":           "lease-attachment",
			"client_attachment_token": "lease-attachment-token",
			"cols":                    80,
			"rows":                    24,
			"command":                 "sleep 60",
		},
	})
	if ok, _ := attach["ok"].(bool); !ok {
		t.Fatalf("pty.attach failed: %v", attach)
	}
	readPersistentTestEvent(t, conn, reader, func(frame map[string]any) bool {
		return frame["event"] == "pty.ready" && frame["attachment_id"] == "lease-attachment"
	})
	for {
		select {
		case <-leaseChecked:
			continue
		default:
			goto leaseChecksDrained
		}
	}

leaseChecksDrained:
	_ = conn.Close()
	for checkedAfterDisconnect := 0; checkedAfterDisconnect < 5; {
		select {
		case present := <-leaseChecked:
			if present {
				checkedAfterDisconnect++
			}
		case err := <-done:
			serverExited = true
			t.Fatalf("persistent daemon exited before its slot lease disappeared: %v", err)
		case <-time.After(2 * time.Second):
			t.Fatalf("persistent daemon did not continue checking its slot lease after disconnect")
		}
	}
	leasePresent.Store(false)

	for absentChecks := 0; absentChecks < 3; {
		select {
		case present := <-leaseChecked:
			if !present {
				absentChecks++
			}
		case <-leaseRemoved:
			t.Fatalf("persistent daemon retired while its detached PTY was still active")
		case err := <-done:
			serverExited = true
			t.Fatalf("persistent daemon exited while its detached PTY was still active: %v", err)
		case <-time.After(2 * time.Second):
			t.Fatalf("persistent daemon did not continue checking the absent slot lease")
		}
	}

	reconnect, reconnectReader, reconnectWriter := openPersistentTestClient(t, socketPath, "lease-token")
	reattach := persistentTestRPCCall(t, reconnect, reconnectReader, reconnectWriter, rpcRequest{
		ID:     2,
		Method: "pty.attach",
		Params: map[string]any{
			"session_id":              "lease-session",
			"attachment_id":           "lease-reattachment",
			"client_attachment_token": "lease-reattachment-token",
			"cols":                    100,
			"rows":                    30,
			"command":                 "printf 'replacement command must not run\\n'",
			"require_existing":        true,
		},
	})
	if ok, _ := reattach["ok"].(bool); !ok {
		t.Fatalf("reattach after slot lease removal failed: %v", reattach)
	}
	readPersistentTestEvent(t, reconnect, reconnectReader, func(frame map[string]any) bool {
		return frame["event"] == "pty.ready" && frame["attachment_id"] == "lease-reattachment"
	})
	closePTY := persistentTestRPCCall(t, reconnect, reconnectReader, reconnectWriter, rpcRequest{
		ID:     3,
		Method: "pty.close",
		Params: map[string]any{"session_id": "lease-session"},
	})
	if ok, _ := closePTY["ok"].(bool); !ok {
		t.Fatalf("pty.close after lease removal failed: %v", closePTY)
	}
	_ = reconnect.Close()

	select {
	case err := <-done:
		serverExited = true
		if err != nil {
			t.Fatalf("persistent daemon exited with error after its final PTY closed: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("persistent daemon did not retire after its absent lease and final PTY close")
	}
	requirePersistentDaemonAutomaticExitLog(
		t,
		stderr.String(),
		persistentDaemonExitSlotLeaseRemoved,
	)
}

func requirePersistentDaemonAutomaticExitLog(
	t *testing.T,
	logOutput string,
	reason persistentDaemonExitReason,
) {
	t.Helper()
	wantActivity := "reason=" + string(reason) + " active_connections=0 active_sessions=0"
	for _, line := range strings.Split(logOutput, "\n") {
		if !strings.Contains(line, wantActivity) {
			continue
		}
		for _, field := range strings.Fields(line) {
			if !strings.HasPrefix(field, "time=") {
				continue
			}
			timestamp := strings.TrimPrefix(field, "time=")
			if _, err := time.Parse(time.RFC3339Nano, timestamp); err != nil {
				t.Fatalf("persistent daemon exit log timestamp %q is not RFC3339Nano: %v", timestamp, err)
			}
			return
		}
		t.Fatalf("persistent daemon exit log line %q has no time field", line)
	}
	t.Fatalf("persistent daemon exit log = %q, want %q", logOutput, wantActivity)
}

func TestPersistentDaemonSlotLeasePresentMatchesExactRelayPortAndSlot(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	present, err := persistentDaemonSlotLeasePresent("target-slot", 64008)
	if err != nil {
		t.Fatalf("inspect absent relay lease: %v", err)
	}
	if present {
		t.Fatalf("absent relay lease reported a matching slot")
	}

	relayDirectory := filepath.Join(home, ".cmux", "relay")
	if err := os.MkdirAll(relayDirectory, 0o700); err != nil {
		t.Fatalf("create relay directory: %v", err)
	}
	if err := os.WriteFile(filepath.Join(relayDirectory, "64008.slot"), []byte("other-slot\n"), 0o600); err != nil {
		t.Fatalf("write other relay slot: %v", err)
	}
	if err := os.WriteFile(filepath.Join(relayDirectory, "64009.slot"), []byte("target-slot\n"), 0o600); err != nil {
		t.Fatalf("write target slot at another port: %v", err)
	}
	present, err = persistentDaemonSlotLeasePresent("target-slot", 64008)
	if err != nil {
		t.Fatalf("inspect nonmatching relay lease: %v", err)
	}
	if present {
		t.Fatalf("matching slot at a different port satisfied the lease")
	}

	if err := os.WriteFile(filepath.Join(relayDirectory, "64008.slot"), []byte("target-slot\n"), 0o600); err != nil {
		t.Fatalf("write matching relay slot: %v", err)
	}
	present, err = persistentDaemonSlotLeasePresent("target-slot", 64008)
	if err != nil {
		t.Fatalf("inspect matching relay slot: %v", err)
	}
	if !present {
		t.Fatalf("matching relay slot was not observed")
	}
}

func TestPersistentDaemonServerArgumentsCarryValidatedLeasePort(t *testing.T) {
	withLease := persistentDaemonServerArguments("target-slot", 64008)
	want := []string{
		"serve", "--persistent-server", "--slot", "target-slot",
		"--persistent-lease-port", "64008",
	}
	if strings.Join(withLease, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("server arguments = %q, want %q", withLease, want)
	}

	withoutLease := persistentDaemonServerArguments("target-slot", 0)
	if strings.Contains(strings.Join(withoutLease, " "), "persistent-lease-port") {
		t.Fatalf("backward-compatible server arguments unexpectedly contain a lease: %q", withoutLease)
	}
}

func TestPersistentDaemonRelayShellCleanupPreservesReplacementLease(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	relayDirectory := filepath.Join(home, ".cmux", "relay")
	shellDirectory := filepath.Join(relayDirectory, "64008.shell")
	if err := os.MkdirAll(shellDirectory, 0o700); err != nil {
		t.Fatalf("create relay shell directory: %v", err)
	}
	leasePath := filepath.Join(relayDirectory, "64008.slot")
	if err := os.WriteFile(leasePath, []byte("replacement-slot\n"), 0o600); err != nil {
		t.Fatalf("write replacement lease: %v", err)
	}
	if err := removePersistentDaemonRelayShellDirectoryIfUnleased(64008); err != nil {
		t.Fatalf("preserve leased shell directory: %v", err)
	}
	if _, err := os.Stat(shellDirectory); err != nil {
		t.Fatalf("replacement owner's shell directory was removed: %v", err)
	}

	if err := os.Remove(leasePath); err != nil {
		t.Fatalf("remove relay lease: %v", err)
	}
	if err := removePersistentDaemonRelayShellDirectoryIfUnleased(64008); err != nil {
		t.Fatalf("remove unleased shell directory: %v", err)
	}
	if _, err := os.Stat(shellDirectory); !errors.Is(err, os.ErrNotExist) {
		t.Fatalf("unleased shell directory still exists: %v", err)
	}
}
