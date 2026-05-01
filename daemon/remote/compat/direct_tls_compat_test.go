package compat

import (
	"encoding/base64"
	"testing"
	"time"

	"github.com/manaflow-ai/cmux/daemon/remote/internal/auth"
)

func TestDirectTLSRejectsExpiredTicket(t *testing.T) {
	t.Parallel()

	server := startTLSServer(t, daemonBinary(t))
	token, err := auth.SignTicket(auth.TicketClaims{
		ServerID:     server.ServerID,
		SessionID:    "sess-1",
		AttachmentID: "att-1",
		Capabilities: []string{"session.attach"},
		ExpiresAt:    time.Now().Add(-time.Minute).Unix(),
		Nonce:        "expired-nonce",
	}, server.TicketSecret)
	if err != nil {
		t.Fatalf("sign expired ticket: %v", err)
	}

	handshake := runDirectTLSHandshake(t, server, token)
	if ok, _ := handshake["ok"].(bool); ok {
		t.Fatalf("expected expired ticket handshake to fail: %+v", handshake)
	}
}

func TestDirectTLSRejectsReplayedNonce(t *testing.T) {
	t.Parallel()

	server := startTLSServer(t, daemonBinary(t))
	token, err := auth.SignTicket(auth.TicketClaims{
		ServerID:     server.ServerID,
		SessionID:    "sess-1",
		AttachmentID: "att-1",
		Capabilities: []string{"session.attach"},
		ExpiresAt:    time.Now().Add(time.Minute).Unix(),
		Nonce:        "replayed-nonce",
	}, server.TicketSecret)
	if err != nil {
		t.Fatalf("sign replay ticket: %v", err)
	}

	first := runDirectTLSHandshake(t, server, token)
	if ok, _ := first["ok"].(bool); !ok {
		t.Fatalf("first handshake should succeed: %+v", first)
	}

	second := runDirectTLSHandshake(t, server, token)
	if ok, _ := second["ok"].(bool); ok {
		t.Fatalf("expected replayed nonce handshake to fail: %+v", second)
	}
}

func TestDirectTLSSessionScopeIsEnforced(t *testing.T) {
	t.Parallel()

	server := startTLSServer(t, daemonBinary(t))
	token, err := auth.SignTicket(auth.TicketClaims{
		ServerID:     server.ServerID,
		Capabilities: []string{"session.open"},
		ExpiresAt:    time.Now().Add(time.Minute).Unix(),
		Nonce:        "scope-nonce",
	}, server.TicketSecret)
	if err != nil {
		t.Fatalf("sign scope ticket: %v", err)
	}

	openReq := map[string]any{
		"id":     1,
		"method": "terminal.open",
		"params": map[string]any{
			"command": "printf READY; stty raw -echo -onlcr; exec cat",
			"cols":    120,
			"rows":    40,
		},
	}
	openResp, resizeResp := runDirectTLSHandshakeAndRequest(t, server, token, openReq, func(open map[string]any) map[string]any {
		result := open["result"].(map[string]any)
		return map[string]any{
			"id":     2,
			"method": "session.resize",
			"params": map[string]any{
				"session_id":    "sess-999",
				"attachment_id": result["attachment_id"].(string),
				"cols":          100,
				"rows":          30,
			},
		}
	})

	if ok, _ := openResp["ok"].(bool); !ok {
		t.Fatalf("terminal.open should succeed: %+v", openResp)
	}
	if ok, _ := resizeResp["ok"].(bool); ok {
		t.Fatalf("expected session scope escape to fail: %+v", resizeResp)
	}
}

func TestDirectTLSValidTicketCanOpenWriteReadAndQueryStatus(t *testing.T) {
	t.Parallel()

	server := startTLSServer(t, daemonBinary(t))
	token, err := auth.SignTicket(auth.TicketClaims{
		ServerID:     server.ServerID,
		Capabilities: []string{"session.open"},
		ExpiresAt:    time.Now().Add(time.Minute).Unix(),
		Nonce:        "valid-open-nonce",
	}, server.TicketSecret)
	if err != nil {
		t.Fatalf("sign valid open ticket: %v", err)
	}

	conn := dialTLSServer(t, server)
	defer conn.Close()

	handshake := writeAndReadJSON(t, conn, map[string]any{
		"ticket": token,
	})
	if ok, _ := handshake["ok"].(bool); !ok {
		t.Fatalf("tls handshake should succeed: %+v", handshake)
	}

	openResp := writeAndReadJSON(t, conn, map[string]any{
		"id":     1,
		"method": "terminal.open",
		"params": map[string]any{
			"command": "printf READY; stty raw -echo -onlcr; exec cat",
			"cols":    120,
			"rows":    40,
		},
	})
	if ok, _ := openResp["ok"].(bool); !ok {
		t.Fatalf("terminal.open should succeed: %+v", openResp)
	}
	openResult := openResp["result"].(map[string]any)
	sessionID := openResult["session_id"].(string)

	readyResp := writeAndReadJSON(t, conn, map[string]any{
		"id":     2,
		"method": "terminal.read",
		"params": map[string]any{
			"session_id": sessionID,
			"offset":     0,
			"max_bytes":  1024,
			"timeout_ms": 1000,
		},
	})
	if ok, _ := readyResp["ok"].(bool); !ok {
		t.Fatalf("initial terminal.read should succeed: %+v", readyResp)
	}
	readyResult := readyResp["result"].(map[string]any)
	readyData, err := base64.StdEncoding.DecodeString(readyResult["data"].(string))
	if err != nil {
		t.Fatalf("decode initial terminal.read data: %v", err)
	}
	if string(readyData) != "READY" {
		t.Fatalf("initial terminal.read data = %q, want %q", readyData, "READY")
	}
	offset := int(readyResult["offset"].(float64))

	writeResp := writeAndReadJSON(t, conn, map[string]any{
		"id":     3,
		"method": "terminal.write",
		"params": map[string]any{
			"session_id": sessionID,
			"data":       base64.StdEncoding.EncodeToString([]byte("hello\n")),
		},
	})
	if ok, _ := writeResp["ok"].(bool); !ok {
		t.Fatalf("terminal.write should succeed: %+v", writeResp)
	}

	readResp := writeAndReadJSON(t, conn, map[string]any{
		"id":     4,
		"method": "terminal.read",
		"params": map[string]any{
			"session_id": sessionID,
			"offset":     offset,
			"max_bytes":  1024,
			"timeout_ms": 1000,
		},
	})
	if ok, _ := readResp["ok"].(bool); !ok {
		t.Fatalf("terminal.read should succeed: %+v", readResp)
	}
	readResult := readResp["result"].(map[string]any)
	encoded, ok := readResult["data"].(string)
	if !ok {
		t.Fatalf("terminal.read result missing data: %+v", readResp)
	}
	decoded, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		t.Fatalf("decode terminal.read data: %v", err)
	}
	if string(decoded) != "hello\n" {
		t.Fatalf("terminal.read data = %q, want %q", decoded, "hello\n")
	}

	statusResp := writeAndReadJSON(t, conn, map[string]any{
		"id":     5,
		"method": "session.status",
		"params": map[string]any{
			"session_id": sessionID,
		},
	})
	if ok, _ := statusResp["ok"].(bool); !ok {
		t.Fatalf("session.status should succeed: %+v", statusResp)
	}
	statusResult := statusResp["result"].(map[string]any)
	if got := statusResult["session_id"].(string); got != sessionID {
		t.Fatalf("status session_id = %q, want %q: %+v", got, sessionID, statusResp)
	}
	if got := int(statusResult["effective_cols"].(float64)); got != 120 {
		t.Fatalf("status effective_cols = %d, want 120: %+v", got, statusResp)
	}
	if got := int(statusResult["effective_rows"].(float64)); got != 40 {
		t.Fatalf("status effective_rows = %d, want 40: %+v", got, statusResp)
	}
}

func TestDirectTLSValidAttachTicketCanAttachQueryStatusAndDetach(t *testing.T) {
	t.Parallel()

	server := startTLSServer(t, daemonBinary(t))
	openToken, err := auth.SignTicket(auth.TicketClaims{
		ServerID:     server.ServerID,
		Capabilities: []string{"session.open"},
		ExpiresAt:    time.Now().Add(time.Minute).Unix(),
		Nonce:        "attach-open-nonce",
	}, server.TicketSecret)
	if err != nil {
		t.Fatalf("sign open ticket: %v", err)
	}

	openConn := dialTLSServer(t, server)
	handshake := writeAndReadJSON(t, openConn, map[string]any{
		"ticket": openToken,
	})
	if ok, _ := handshake["ok"].(bool); !ok {
		t.Fatalf("open handshake should succeed: %+v", handshake)
	}
	openResp := writeAndReadJSON(t, openConn, map[string]any{
		"id":     1,
		"method": "terminal.open",
		"params": map[string]any{
			"command": "printf READY; exec cat",
			"cols":    120,
			"rows":    40,
		},
	})
	if ok, _ := openResp["ok"].(bool); !ok {
		t.Fatalf("terminal.open should succeed: %+v", openResp)
	}
	openResult := openResp["result"].(map[string]any)
	sessionID := openResult["session_id"].(string)
	_ = openConn.Close()

	attachToken, err := auth.SignTicket(auth.TicketClaims{
		ServerID:     server.ServerID,
		SessionID:    sessionID,
		AttachmentID: "cli-attach",
		Capabilities: []string{"session.attach"},
		ExpiresAt:    time.Now().Add(time.Minute).Unix(),
		Nonce:        "attach-valid-nonce",
	}, server.TicketSecret)
	if err != nil {
		t.Fatalf("sign attach ticket: %v", err)
	}

	attachConn := dialTLSServer(t, server)
	defer attachConn.Close()

	attachHandshake := writeAndReadJSON(t, attachConn, map[string]any{
		"ticket": attachToken,
	})
	if ok, _ := attachHandshake["ok"].(bool); !ok {
		t.Fatalf("attach handshake should succeed: %+v", attachHandshake)
	}

	attachResp := writeAndReadJSON(t, attachConn, map[string]any{
		"id":     2,
		"method": "session.attach",
		"params": map[string]any{
			"session_id":    sessionID,
			"attachment_id": "cli-attach",
			"cols":          100,
			"rows":          30,
		},
	})
	if ok, _ := attachResp["ok"].(bool); !ok {
		t.Fatalf("session.attach should succeed: %+v", attachResp)
	}

	statusResp := writeAndReadJSON(t, attachConn, map[string]any{
		"id":     3,
		"method": "session.status",
		"params": map[string]any{
			"session_id": sessionID,
		},
	})
	if ok, _ := statusResp["ok"].(bool); !ok {
		t.Fatalf("session.status should succeed after attach: %+v", statusResp)
	}
	statusResult := statusResp["result"].(map[string]any)
	if got := int(statusResult["effective_cols"].(float64)); got != 100 {
		t.Fatalf("status effective_cols = %d, want 100 after attach: %+v", got, statusResp)
	}
	if got := int(statusResult["effective_rows"].(float64)); got != 30 {
		t.Fatalf("status effective_rows = %d, want 30 after attach: %+v", got, statusResp)
	}

	detachResp := writeAndReadJSON(t, attachConn, map[string]any{
		"id":     4,
		"method": "session.detach",
		"params": map[string]any{
			"session_id":    sessionID,
			"attachment_id": "cli-attach",
		},
	})
	if ok, _ := detachResp["ok"].(bool); !ok {
		t.Fatalf("session.detach should succeed: %+v", detachResp)
	}
}

func TestDirectTLSOpenTicketRejectsSecondTerminalOpen(t *testing.T) {
	t.Parallel()

	server := startTLSServer(t, daemonBinary(t))
	token, err := auth.SignTicket(auth.TicketClaims{
		ServerID:     server.ServerID,
		Capabilities: []string{"session.open"},
		ExpiresAt:    time.Now().Add(time.Minute).Unix(),
		Nonce:        "second-open-nonce",
	}, server.TicketSecret)
	if err != nil {
		t.Fatalf("sign open ticket: %v", err)
	}

	conn := dialTLSServer(t, server)
	defer conn.Close()

	handshake := writeAndReadJSON(t, conn, map[string]any{
		"ticket": token,
	})
	if ok, _ := handshake["ok"].(bool); !ok {
		t.Fatalf("open handshake should succeed: %+v", handshake)
	}

	firstOpen := writeAndReadJSON(t, conn, map[string]any{
		"id":     1,
		"method": "terminal.open",
		"params": map[string]any{
			"command": "cat",
			"cols":    120,
			"rows":    40,
		},
	})
	if ok, _ := firstOpen["ok"].(bool); !ok {
		t.Fatalf("first terminal.open should succeed: %+v", firstOpen)
	}

	secondOpen := writeAndReadJSON(t, conn, map[string]any{
		"id":     2,
		"method": "terminal.open",
		"params": map[string]any{
			"command": "cat",
			"cols":    100,
			"rows":    30,
		},
	})
	if ok, _ := secondOpen["ok"].(bool); ok {
		t.Fatalf("second terminal.open should fail: %+v", secondOpen)
	}
	errObj := secondOpen["error"].(map[string]any)
	if got := errObj["message"].(string); got != "ticket is already bound to a terminal session" {
		t.Fatalf("second terminal.open error = %q, want %q", got, "ticket is already bound to a terminal session")
	}
}

func TestDirectTLSDetachRevokesFurtherSessionRequests(t *testing.T) {
	t.Parallel()

	server := startTLSServer(t, daemonBinary(t))
	openToken, err := auth.SignTicket(auth.TicketClaims{
		ServerID:     server.ServerID,
		Capabilities: []string{"session.open"},
		ExpiresAt:    time.Now().Add(time.Minute).Unix(),
		Nonce:        "detach-open-nonce",
	}, server.TicketSecret)
	if err != nil {
		t.Fatalf("sign open ticket: %v", err)
	}

	openConn := dialTLSServer(t, server)
	handshake := writeAndReadJSON(t, openConn, map[string]any{
		"ticket": openToken,
	})
	if ok, _ := handshake["ok"].(bool); !ok {
		t.Fatalf("open handshake should succeed: %+v", handshake)
	}
	openResp := writeAndReadJSON(t, openConn, map[string]any{
		"id":     1,
		"method": "terminal.open",
		"params": map[string]any{
			"command": "cat",
			"cols":    120,
			"rows":    40,
		},
	})
	if ok, _ := openResp["ok"].(bool); !ok {
		t.Fatalf("terminal.open should succeed: %+v", openResp)
	}
	sessionID := openResp["result"].(map[string]any)["session_id"].(string)
	_ = openConn.Close()

	attachToken, err := auth.SignTicket(auth.TicketClaims{
		ServerID:     server.ServerID,
		SessionID:    sessionID,
		AttachmentID: "cli-detach",
		Capabilities: []string{"session.attach"},
		ExpiresAt:    time.Now().Add(time.Minute).Unix(),
		Nonce:        "detach-attach-nonce",
	}, server.TicketSecret)
	if err != nil {
		t.Fatalf("sign attach ticket: %v", err)
	}

	conn := dialTLSServer(t, server)
	defer conn.Close()

	attachHandshake := writeAndReadJSON(t, conn, map[string]any{
		"ticket": attachToken,
	})
	if ok, _ := attachHandshake["ok"].(bool); !ok {
		t.Fatalf("attach handshake should succeed: %+v", attachHandshake)
	}

	attachResp := writeAndReadJSON(t, conn, map[string]any{
		"id":     2,
		"method": "session.attach",
		"params": map[string]any{
			"session_id":    sessionID,
			"attachment_id": "cli-detach",
			"cols":          100,
			"rows":          30,
		},
	})
	if ok, _ := attachResp["ok"].(bool); !ok {
		t.Fatalf("session.attach should succeed: %+v", attachResp)
	}

	detachResp := writeAndReadJSON(t, conn, map[string]any{
		"id":     3,
		"method": "session.detach",
		"params": map[string]any{
			"session_id":    sessionID,
			"attachment_id": "cli-detach",
		},
	})
	if ok, _ := detachResp["ok"].(bool); !ok {
		t.Fatalf("session.detach should succeed: %+v", detachResp)
	}

	statusResp := writeAndReadJSON(t, conn, map[string]any{
		"id":     4,
		"method": "session.status",
		"params": map[string]any{
			"session_id": sessionID,
		},
	})
	if ok, _ := statusResp["ok"].(bool); ok {
		t.Fatalf("session.status after detach should fail: %+v", statusResp)
	}
	errObj := statusResp["error"].(map[string]any)
	if got := errObj["message"].(string); got != "request requires an opened or attached terminal session" {
		t.Fatalf("session.status after detach error = %q, want %q", got, "request requires an opened or attached terminal session")
	}
}
