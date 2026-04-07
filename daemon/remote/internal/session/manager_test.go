package session

import "testing"

func TestSessionManagerReattachKeepsExistingSessionState(t *testing.T) {
	t.Parallel()

	mgr := NewManager()
	sessionID, attachmentID, err := mgr.Open("", 120, 40)
	if err != nil {
		t.Fatalf("open session: %v", err)
	}

	if err := mgr.Resize(sessionID, attachmentID, 100, 30); err != nil {
		t.Fatalf("resize existing attachment: %v", err)
	}

	const newAttachmentID = "att-2"
	if err := mgr.Attach(sessionID, newAttachmentID, 80, 24); err != nil {
		t.Fatalf("attach second client: %v", err)
	}

	status, err := mgr.Status(sessionID)
	if err != nil {
		t.Fatalf("status: %v", err)
	}

	if status.EffectiveCols != 80 {
		t.Fatalf("effective cols = %d, want 80", status.EffectiveCols)
	}
	if status.EffectiveRows != 24 {
		t.Fatalf("effective rows = %d, want 24", status.EffectiveRows)
	}
}

func TestSessionManagerOpenRejectsDuplicateExplicitSessionID(t *testing.T) {
	t.Parallel()

	mgr := NewManager()
	if _, _, err := mgr.Open("demo", 120, 40); err != nil {
		t.Fatalf("open first session: %v", err)
	}
	if _, _, err := mgr.Open("demo", 80, 24); err != ErrSessionExists {
		t.Fatalf("duplicate open error = %v, want %v", err, ErrSessionExists)
	}

	status, err := mgr.Status("demo")
	if err != nil {
		t.Fatalf("status after duplicate open: %v", err)
	}
	if len(status.Attachments) != 1 {
		t.Fatalf("attachments = %d, want 1", len(status.Attachments))
	}
}

func TestSessionManagerGeneratedIDsSkipExistingCustomIDs(t *testing.T) {
	t.Parallel()

	mgr := NewManager()
	firstSessionID, _, err := mgr.Open("sess-1", 120, 40)
	if err != nil {
		t.Fatalf("open custom session: %v", err)
	}
	secondSessionID, _, err := mgr.Open("", 80, 24)
	if err != nil {
		t.Fatalf("open generated session: %v", err)
	}

	if firstSessionID != "sess-1" {
		t.Fatalf("first session id = %q, want %q", firstSessionID, "sess-1")
	}
	if secondSessionID != "sess-2" {
		t.Fatalf("generated session id = %q, want %q", secondSessionID, "sess-2")
	}
}
