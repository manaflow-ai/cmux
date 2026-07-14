package main

import (
	"io"
	"net"
	"os"
	"path/filepath"
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
