package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestPersistentDaemonLogsConnectionAndPTYLifecycle(t *testing.T) {
	logOutput := newNotifyingBuffer()
	socketPath, stop := startPersistentDaemonWithVerifierAndLogForTest(
		t,
		persistentDaemonFixedTokenVerifier("lifecycle-log-token"),
		logOutput,
	)
	defer stop()

	conn, reader, writer := openPersistentTestClient(t, socketPath, "lifecycle-log-token")
	defer conn.Close()

	attach := persistentTestRPCCall(t, conn, reader, writer, rpcRequest{
		ID:     1,
		Method: "pty.attach",
		Params: map[string]any{
			"session_id":              "logged-session",
			"attachment_id":           "logged-attachment",
			"client_attachment_token": "secret-token-must-not-be-logged",
			"cols":                    80,
			"rows":                    24,
			"command":                 "sleep 60",
		},
	})
	if ok, _ := attach["ok"].(bool); !ok {
		t.Fatalf("pty.attach failed: %v", attach)
	}
	readPersistentTestEvent(t, conn, reader, func(frame map[string]any) bool {
		return frame["event"] == "pty.ready" && frame["attachment_id"] == "logged-attachment"
	})

	detach := persistentTestRPCCall(t, conn, reader, writer, rpcRequest{
		ID:     2,
		Method: "pty.detach",
		Params: map[string]any{
			"session_id":              "logged-session",
			"attachment_id":           "logged-attachment",
			"client_attachment_token": "secret-token-must-not-be-logged",
		},
	})
	if ok, _ := detach["ok"].(bool); !ok {
		t.Fatalf("pty.detach failed: %v", detach)
	}
	closeResponse := persistentTestRPCCall(t, conn, reader, writer, rpcRequest{
		ID:     3,
		Method: "pty.close",
		Params: map[string]any{
			"session_id": "logged-session",
		},
	})
	if ok, _ := closeResponse["ok"].(bool); !ok {
		t.Fatalf("pty.close failed: %v", closeResponse)
	}
	exitingAttach := persistentTestRPCCall(t, conn, reader, writer, rpcRequest{
		ID:     4,
		Method: "pty.attach",
		Params: map[string]any{
			"session_id":              "logged-exit-session",
			"attachment_id":           "logged-exit-attachment",
			"client_attachment_token": "second-secret-token-must-not-be-logged",
			"cols":                    80,
			"rows":                    24,
			"command":                 "exit 0",
		},
	})
	if ok, _ := exitingAttach["ok"].(bool); !ok {
		t.Fatalf("short-lived pty.attach failed: %v", exitingAttach)
	}
	readPersistentTestEvent(t, conn, reader, func(frame map[string]any) bool {
		return frame["event"] == "pty.exit" && frame["session_id"] == "logged-exit-session"
	})

	logged := logOutput.String()
	for _, event := range []string{
		"event=connection_accepted",
		"event=connection_authenticated",
		"event=pty_attach",
		"event=pty_detach",
		"event=pty_close",
		"event=pty_exit",
	} {
		if !strings.Contains(logged, event) {
			t.Fatalf("persistent daemon log = %q, want %q", logged, event)
		}
	}
	if strings.Contains(logged, "secret-token-must-not-be-logged") {
		t.Fatalf("persistent daemon log exposed an attachment token: %q", logged)
	}
}

func TestPersistentDaemonLogRotationIsSizeBounded(t *testing.T) {
	const maxBytes = int64(220)
	const backups = 2
	logPath := filepath.Join(t.TempDir(), "daemon.log")
	logOutput, err := openPersistentDaemonLogWithLimit(logPath, maxBytes, backups)
	if err != nil {
		t.Fatalf("open persistent daemon log: %v", err)
	}
	for index := 0; index < 12; index++ {
		logPersistentDaemonEvent(
			logOutput,
			"rotation_probe",
			"marker", fmt.Sprintf("event-%02d-%s", index, strings.Repeat("x", 32)),
		)
	}
	if err := logOutput.Close(); err != nil {
		t.Fatalf("close persistent daemon log: %v", err)
	}

	for index, path := range []string{
		logPath,
		persistentDaemonLogBackupPath(logPath, 1),
		persistentDaemonLogBackupPath(logPath, 2),
	} {
		info, err := os.Stat(path)
		if err != nil {
			t.Fatalf("stat log generation %d: %v", index, err)
		}
		if info.Size() > maxBytes {
			t.Fatalf("log generation %d size = %d, want <= %d", index, info.Size(), maxBytes)
		}
		if info.Mode().Perm() != 0o600 {
			t.Fatalf("log generation %d mode = %o, want 600", index, info.Mode().Perm())
		}
	}
	newest, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read newest persistent daemon log: %v", err)
	}
	if !strings.Contains(string(newest), "event-11-") {
		t.Fatalf("newest persistent daemon log lost the latest event: %q", string(newest))
	}
}
