package main

import (
	"bufio"
	"encoding/base64"
	"errors"
	"net"
	"strings"
	"testing"
	"time"
)

// A bridge whose SSH channel went half-open can remain authenticated on the
// remote Unix socket forever. The next authenticated bridge must be able to
// claim the slot and evict that stale connection before it starts forwarding.
func TestPersistentDaemonAuthenticatedBridgeLeaseTakeoverEvictsStaleHolder(t *testing.T) {
	socketPath, stop := startPersistentDaemonForTest(t, "bridge-lease-token")
	defer stop()

	stale, staleReader, staleWriter := openPersistentTestClientWithBridgeLease(
		t,
		socketPath,
		"bridge-lease-token",
		"stale-bridge",
	)
	defer stale.Close()
	staleAttach := persistentTestRPCCall(t, stale, staleReader, staleWriter, rpcRequest{
		ID:     "stale-attach",
		Method: "pty.attach",
		Params: map[string]any{
			"session_id":              "lease-preserved-session",
			"attachment_id":           "stale-attachment",
			"client_attachment_token": "stale-attachment-token",
			"cols":                    80,
			"rows":                    24,
			"command":                 "printf 'lease-preserved-data\\n'; sleep 60",
		},
	})
	if staleAttach["ok"] != true {
		t.Fatalf("stale bridge PTY attach failed: %v", staleAttach)
	}
	readPersistentTestEvent(t, stale, staleReader, func(frame map[string]any) bool {
		return frame["event"] == "pty.ready" && frame["attachment_id"] == "stale-attachment"
	})
	readPersistentTestEvent(t, stale, staleReader, func(frame map[string]any) bool {
		if frame["event"] != "pty.data" || frame["attachment_id"] != "stale-attachment" {
			return false
		}
		payload, decodeErr := base64.StdEncoding.DecodeString(frame["data_base64"].(string))
		return decodeErr == nil && strings.Contains(string(payload), "lease-preserved-data")
	})

	current, currentReader, currentWriter := openPersistentTestClientWithBridgeLease(
		t,
		socketPath,
		"bridge-lease-token",
		"replacement-bridge",
	)
	defer current.Close()

	if err := stale.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatalf("set stale bridge read deadline: %v", err)
	}
	_, err := staleReader.ReadByte()
	if err == nil {
		t.Fatal("stale bridge remained connected after authenticated lease takeover")
	}
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		t.Fatalf("stale bridge was not evicted before read deadline: %v", err)
	}
	// A Unix socket may report ECONNRESET instead of EOF when the server closes
	// the connection; any non-timeout read failure is still an eviction.
	reattach := persistentTestRPCCall(t, current, currentReader, currentWriter, rpcRequest{
		ID:     "replacement-attach",
		Method: "pty.attach",
		Params: map[string]any{
			"session_id":              "lease-preserved-session",
			"attachment_id":           "replacement-attachment",
			"client_attachment_token": "replacement-attachment-token",
			"cols":                    100,
			"rows":                    30,
			"require_existing":        true,
		},
	})
	if reattach["ok"] != true {
		t.Fatalf("replacement bridge PTY reattach failed: %v", reattach)
	}
	result, _ := reattach["result"].(map[string]any)
	if replayBytes, _ := result["replay_bytes"].(float64); replayBytes <= 0 {
		t.Fatalf("replacement bridge replay_bytes = %v, want preserved output", result["replay_bytes"])
	}
	readPersistentTestEvent(t, current, currentReader, func(frame map[string]any) bool {
		return frame["event"] == "pty.ready" && frame["attachment_id"] == "replacement-attachment"
	})
	readPersistentTestEvent(t, current, currentReader, func(frame map[string]any) bool {
		if frame["event"] != "pty.data" || frame["attachment_id"] != "replacement-attachment" {
			return false
		}
		payload, decodeErr := base64.StdEncoding.DecodeString(frame["data_base64"].(string))
		return decodeErr == nil && strings.Contains(string(payload), "lease-preserved-data")
	})
}

func TestPersistentDaemonBridgeLeaseTakeoverEvictsLegacyAuthenticatedConnection(t *testing.T) {
	socketPath, stop := startPersistentDaemonForTest(t, "legacy-bridge-token")
	defer stop()

	legacy, legacyReader, _ := openPersistentTestClient(t, socketPath, "legacy-bridge-token")
	defer legacy.Close()
	replacement, _, _ := openPersistentTestClientWithBridgeLease(
		t,
		socketPath,
		"legacy-bridge-token",
		"replacement-bridge",
	)
	defer replacement.Close()

	if err := legacy.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatalf("set legacy bridge read deadline: %v", err)
	}
	_, err := legacyReader.ReadByte()
	if err == nil {
		t.Fatal("legacy bridge remained connected after lease takeover")
	}
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		t.Fatalf("legacy bridge was not evicted before read deadline: %v", err)
	}
}

func openPersistentTestClientWithBridgeLease(
	t *testing.T,
	socketPath string,
	token string,
	leaseID string,
) (net.Conn, *bufio.Reader, *bufio.Writer) {
	t.Helper()
	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		t.Fatalf("dial persistent daemon: %v", err)
	}
	if err := authenticatePersistentDaemonClientWithBridgeLease(conn, token, leaseID); err != nil {
		_ = conn.Close()
		t.Fatalf("persistent daemon bridge lease auth failed: %v", err)
	}
	reader := bufio.NewReader(conn)
	writer := bufio.NewWriter(conn)
	return conn, reader, writer
}
