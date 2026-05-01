package terminal

import (
	"testing"
	"time"
)

func TestManagerRoundTripsOutputAndInput(t *testing.T) {
	t.Parallel()

	mgr := NewManager()
	const sessionID = "sess-1"

	if err := mgr.Open(sessionID, "printf READY; stty raw -echo -onlcr; exec cat", 80, 24); err != nil {
		t.Fatalf("open terminal session: %v", err)
	}
	defer func() {
		_ = mgr.Close(sessionID)
	}()

	initial, err := mgr.Read(sessionID, 0, 1024, time.Second)
	if err != nil {
		t.Fatalf("read initial output: %v", err)
	}
	if string(initial.Data) != "READY" {
		t.Fatalf("initial data = %q, want %q", string(initial.Data), "READY")
	}

	if err := mgr.Write(sessionID, []byte("hello\n")); err != nil {
		t.Fatalf("write input: %v", err)
	}

	echo, err := mgr.Read(sessionID, initial.Offset, 1024, time.Second)
	if err != nil {
		t.Fatalf("read echoed output: %v", err)
	}
	if string(echo.Data) != "hello\r\n" {
		t.Fatalf("echo data = %q, want %q", string(echo.Data), "hello\r\n")
	}
}
