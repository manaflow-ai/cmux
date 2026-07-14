package main

import (
	"bytes"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
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

func TestPersistentDaemonReapsActivePTYAfterObservedSlotLeaseDisappears(t *testing.T) {
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
	leaseChecked := make(chan struct{}, 1)
	done := make(chan error, 1)
	go func() {
		done <- servePersistentDaemonWithVerifierConfig(
			listener,
			persistentDaemonFixedTokenVerifier("lease-token"),
			io.Discard,
			persistentDaemonServerConfig{
				acceptPollStep: 10 * time.Millisecond,
				slotLeasePresent: func() (bool, error) {
					select {
					case leaseChecked <- struct{}{}:
					default:
					}
					return leasePresent.Load(), nil
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
	case <-leaseChecked:
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
	_ = conn.Close()
	leasePresent.Store(false)

	select {
	case err := <-done:
		serverExited = true
		if err != nil {
			t.Fatalf("persistent daemon exited with error: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("persistent daemon did not stop after its observed slot lease disappeared")
	}
}

func TestPersistentDaemonSlotLeasePresentMatchesExactRelaySlot(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	present, err := persistentDaemonSlotLeasePresent("target-slot")
	if err != nil {
		t.Fatalf("inspect absent relay directory: %v", err)
	}
	if present {
		t.Fatalf("absent relay directory reported a matching slot")
	}

	relayDirectory := filepath.Join(home, ".cmux", "relay")
	if err := os.MkdirAll(relayDirectory, 0o700); err != nil {
		t.Fatalf("create relay directory: %v", err)
	}
	if err := os.WriteFile(filepath.Join(relayDirectory, "64008.slot"), []byte("other-slot\n"), 0o600); err != nil {
		t.Fatalf("write other relay slot: %v", err)
	}
	if err := os.WriteFile(filepath.Join(relayDirectory, "not-a-port.slot"), []byte("target-slot\n"), 0o600); err != nil {
		t.Fatalf("write invalid relay slot filename: %v", err)
	}
	present, err = persistentDaemonSlotLeasePresent("target-slot")
	if err != nil {
		t.Fatalf("inspect nonmatching relay slots: %v", err)
	}
	if present {
		t.Fatalf("nonmatching relay slots reported a match")
	}

	if err := os.WriteFile(filepath.Join(relayDirectory, "64009.slot"), []byte("target-slot\n"), 0o600); err != nil {
		t.Fatalf("write matching relay slot: %v", err)
	}
	present, err = persistentDaemonSlotLeasePresent("target-slot")
	if err != nil {
		t.Fatalf("inspect matching relay slot: %v", err)
	}
	if !present {
		t.Fatalf("matching relay slot was not observed")
	}
}
