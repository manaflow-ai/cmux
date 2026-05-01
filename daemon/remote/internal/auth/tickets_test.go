package auth

import (
	"testing"
	"time"
)

func TestTicketsRejectExpiredClaims(t *testing.T) {
	t.Parallel()

	claims := TicketClaims{
		ServerID:     "cmux-macmini",
		SessionID:    "sess-1",
		AttachmentID: "att-1",
		Capabilities: []string{"session.attach"},
		ExpiresAt:    time.Now().Add(-time.Minute).Unix(),
	}

	token, err := SignTicket(claims, []byte("secret"))
	if err != nil {
		t.Fatalf("sign ticket: %v", err)
	}

	if _, err := VerifyTicket(token, []byte("secret"), "cmux-macmini"); err == nil {
		t.Fatal("expected expired ticket verification to fail")
	}
}

func TestTicketsRejectWrongServerClaims(t *testing.T) {
	t.Parallel()

	claims := TicketClaims{
		ServerID:     "cmux-macmini",
		SessionID:    "sess-1",
		AttachmentID: "att-1",
		Capabilities: []string{"session.attach"},
		ExpiresAt:    time.Now().Add(time.Minute).Unix(),
	}

	token, err := SignTicket(claims, []byte("secret"))
	if err != nil {
		t.Fatalf("sign ticket: %v", err)
	}

	if _, err := VerifyTicket(token, []byte("secret"), "cmux-sequoia"); err == nil {
		t.Fatal("expected wrong-server ticket verification to fail")
	}
}
