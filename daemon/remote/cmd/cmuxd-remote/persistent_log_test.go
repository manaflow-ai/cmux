package main

import (
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

	logged := logOutput.String()
	for _, event := range []string{
		"event=connection_accepted",
		"event=connection_authenticated",
		"event=pty_attach",
		"event=pty_detach",
		"event=pty_close",
	} {
		if !strings.Contains(logged, event) {
			t.Fatalf("persistent daemon log = %q, want %q", logged, event)
		}
	}
	if strings.Contains(logged, "secret-token-must-not-be-logged") {
		t.Fatalf("persistent daemon log exposed an attachment token: %q", logged)
	}
}
