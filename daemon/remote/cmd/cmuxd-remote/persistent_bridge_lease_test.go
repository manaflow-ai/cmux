package main

import (
	"bufio"
	"errors"
	"io"
	"net"
	"testing"
	"time"
)

// A bridge whose SSH channel went half-open can remain authenticated on the
// remote Unix socket forever. The next authenticated bridge must be able to
// claim the slot and evict that stale connection before it starts forwarding.
func TestPersistentDaemonAuthenticatedBridgeLeaseTakeoverEvictsStaleHolder(t *testing.T) {
	socketPath, stop := startPersistentDaemonForTest(t, "bridge-lease-token")
	defer stop()

	stale, staleReader, _ := openPersistentTestClientWithBridgeLease(
		t,
		socketPath,
		"bridge-lease-token",
		"stale-bridge",
	)
	defer stale.Close()

	current, currentReader, currentWriter := openPersistentTestClientWithBridgeLease(
		t,
		socketPath,
		"bridge-lease-token",
		"replacement-bridge",
	)
	defer current.Close()

	if response := persistentTestRPCCall(t, current, currentReader, currentWriter, rpcRequest{
		ID:     "hello",
		Method: "hello",
		Params: map[string]any{},
	}); response["ok"] != true {
		t.Fatalf("replacement bridge hello failed: %v", response)
	}

	if err := stale.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatalf("set stale bridge read deadline: %v", err)
	}
	_, err := staleReader.ReadByte()
	if err == nil {
		t.Fatal("stale bridge remained connected after authenticated lease takeover")
	}
	if errors.Is(err, net.ErrClosed) || errors.Is(err, io.EOF) {
		return
	}
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		t.Fatalf("stale bridge was not evicted before read deadline: %v", err)
	}
	// A Unix socket may report ECONNRESET instead of EOF when the server closes
	// the connection; any non-timeout read failure is still an eviction.
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
	reader := bufio.NewReader(conn)
	writer := bufio.NewWriter(conn)
	writePersistentTestFrame(t, writer, rpcRequest{
		ID:     "auth-" + leaseID,
		Method: persistentDaemonAuthMethod,
		Params: map[string]any{
			"token":           token,
			"bridge_lease_id": leaseID,
		},
	})
	frame := readPersistentTestFrame(t, conn, reader)
	if ok, _ := frame["ok"].(bool); !ok {
		_ = conn.Close()
		t.Fatalf("persistent daemon bridge lease auth failed: %v", frame)
	}
	return conn, reader, writer
}
