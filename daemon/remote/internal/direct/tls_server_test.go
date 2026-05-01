package direct

import (
	"context"
	"testing"
	"time"

	"github.com/manaflow-ai/cmux/daemon/remote/internal/auth"
	"github.com/manaflow-ai/cmux/daemon/remote/internal/rpc"
)

func TestDirectTLSServerRejectsMissingOrExpiredTicket(t *testing.T) {
	t.Parallel()

	server := NewTLSServer(Config{
		ServerID:     "cmux-macmini",
		TicketSecret: []byte("secret"),
	})

	if err := server.HandleHandshake(context.Background(), Handshake{Ticket: "not-a-valid-ticket"}); err == nil {
		t.Fatal("expected invalid ticket handshake to fail")
	}

	expired, err := auth.SignTicket(auth.TicketClaims{
		ServerID:     "cmux-macmini",
		SessionID:    "sess-1",
		AttachmentID: "att-1",
		Capabilities: []string{"session.attach"},
		ExpiresAt:    time.Now().Add(-time.Minute).Unix(),
		Nonce:        "n-1",
	}, []byte("secret"))
	if err != nil {
		t.Fatalf("sign expired ticket: %v", err)
	}

	if err := server.HandleHandshake(context.Background(), Handshake{Ticket: expired}); err == nil {
		t.Fatal("expected expired ticket handshake to fail")
	}
}

func TestDirectTLSServerAcceptsValidSessionAttachTicket(t *testing.T) {
	t.Parallel()

	token, err := auth.SignTicket(auth.TicketClaims{
		ServerID:     "cmux-macmini",
		SessionID:    "sess-1",
		AttachmentID: "att-1",
		Capabilities: []string{"session.attach"},
		ExpiresAt:    time.Now().Add(time.Minute).Unix(),
		Nonce:        "n-1",
	}, []byte("secret"))
	if err != nil {
		t.Fatalf("sign ticket: %v", err)
	}

	server := NewTLSServer(Config{
		ServerID:     "cmux-macmini",
		TicketSecret: []byte("secret"),
	})
	if err := server.HandleHandshake(context.Background(), Handshake{Ticket: token}); err != nil {
		t.Fatalf("valid handshake: %v", err)
	}
}

func TestDirectTLSServerRejectsReplayedTicketNonce(t *testing.T) {
	t.Parallel()

	token, err := auth.SignTicket(auth.TicketClaims{
		ServerID:     "cmux-macmini",
		SessionID:    "sess-1",
		AttachmentID: "att-1",
		Capabilities: []string{"session.attach"},
		ExpiresAt:    time.Now().Add(time.Minute).Unix(),
		Nonce:        "n-replay",
	}, []byte("secret"))
	if err != nil {
		t.Fatalf("sign ticket: %v", err)
	}

	server := NewTLSServer(Config{
		ServerID:     "cmux-macmini",
		TicketSecret: []byte("secret"),
	})
	if err := server.HandleHandshake(context.Background(), Handshake{Ticket: token}); err != nil {
		t.Fatalf("first handshake: %v", err)
	}
	if err := server.HandleHandshake(context.Background(), Handshake{Ticket: token}); err == nil {
		t.Fatal("expected replayed ticket to fail")
	}
}

func TestDirectTLSServerRejectsTicketWithoutNonce(t *testing.T) {
	t.Parallel()

	token, err := auth.SignTicket(auth.TicketClaims{
		ServerID:     "cmux-macmini",
		SessionID:    "sess-1",
		AttachmentID: "att-1",
		Capabilities: []string{"session.attach"},
		ExpiresAt:    time.Now().Add(time.Minute).Unix(),
	}, []byte("secret"))
	if err != nil {
		t.Fatalf("sign ticket: %v", err)
	}

	server := NewTLSServer(Config{
		ServerID:     "cmux-macmini",
		TicketSecret: []byte("secret"),
	})
	if err := server.HandleHandshake(context.Background(), Handshake{Ticket: token}); err == nil {
		t.Fatal("expected missing nonce handshake to fail")
	}
}

func TestDirectTLSServerRejectsScopedSessionEscape(t *testing.T) {
	t.Parallel()

	authorizer := newRequestAuthorizer(auth.TicketClaims{
		SessionID:    "sess-1",
		AttachmentID: "att-1",
		Capabilities: []string{"session.attach"},
	})

	handler := authorizer.wrap(func(req rpc.Request) rpc.Response {
		return rpc.Response{
			ID:     req.ID,
			OK:     true,
			Result: map[string]any{"ok": true},
		}
	})

	resp := handler(rpc.Request{
		ID:     1,
		Method: "session.resize",
		Params: map[string]any{
			"session_id":    "sess-2",
			"attachment_id": "att-1",
			"cols":          120,
			"rows":          40,
		},
	})
	if resp.OK {
		t.Fatalf("expected session escape to be rejected: %+v", resp)
	}
	if resp.Error == nil || resp.Error.Code != "unauthorized" {
		t.Fatalf("expected unauthorized error, got %+v", resp)
	}
}

func TestDirectTLSServerBindsFreshSessionAndRejectsSecondTerminalOpen(t *testing.T) {
	t.Parallel()

	authorizer := newRequestAuthorizer(auth.TicketClaims{
		Capabilities: []string{"session.open"},
	})

	openCount := 0
	handler := authorizer.wrap(func(req rpc.Request) rpc.Response {
		switch req.Method {
		case "terminal.open":
			openCount++
			return rpc.Response{
				ID: req.ID,
				OK: true,
				Result: map[string]any{
					"session_id":    "sess-1",
					"attachment_id": "att-1",
				},
			}
		case "terminal.write":
			return rpc.Response{
				ID:     req.ID,
				OK:     true,
				Result: map[string]any{"written": 5},
			}
		default:
			return rpc.Response{ID: req.ID, OK: true}
		}
	})

	firstOpen := handler(rpc.Request{
		ID:     1,
		Method: "terminal.open",
		Params: map[string]any{"command": "sh", "cols": 120, "rows": 40},
	})
	if !firstOpen.OK {
		t.Fatalf("expected first terminal.open to succeed: %+v", firstOpen)
	}

	write := handler(rpc.Request{
		ID:     2,
		Method: "terminal.write",
		Params: map[string]any{
			"session_id": "sess-1",
			"data":       "aGVsbG8K",
		},
	})
	if !write.OK {
		t.Fatalf("expected terminal.write on bound session to succeed: %+v", write)
	}

	secondOpen := handler(rpc.Request{
		ID:     3,
		Method: "terminal.open",
		Params: map[string]any{"command": "sh", "cols": 120, "rows": 40},
	})
	if secondOpen.OK {
		t.Fatalf("expected second terminal.open to be rejected: %+v", secondOpen)
	}
	if secondOpen.Error == nil || secondOpen.Error.Code != "unauthorized" {
		t.Fatalf("expected unauthorized error, got %+v", secondOpen)
	}
	if openCount != 1 {
		t.Fatalf("terminal.open handler called %d times, want 1", openCount)
	}
}
