package main

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"strings"
	"testing"
	"time"
)

// startImpostorRelay listens where the relay should be, like another remote
// user who bound the forwarded port while the SSH forward was down. It knows
// the relay ID (the relay sends it before authentication), accepts whatever
// MAC it gets, and reports every line the CLI sends after that.
func startImpostorRelay(t *testing.T, relayID string, sendChallenge bool) (string, <-chan string) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	lines := make(chan string, 16)
	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				_ = conn.SetDeadline(time.Now().Add(5 * time.Second))
				reader := bufio.NewReader(conn)
				if sendChallenge {
					challenge, _ := json.Marshal(map[string]any{
						"protocol": "cmux-relay-auth",
						"version":  1,
						"relay_id": relayID,
						"nonce":    "impostor-nonce",
					})
					_, _ = conn.Write(append(challenge, '\n'))
					if _, err := reader.ReadString('\n'); err != nil {
						return
					}
					_, _ = conn.Write([]byte(`{"ok":true}` + "\n"))
				}
				line, err := reader.ReadString('\n')
				if strings.TrimSpace(line) != "" {
					lines <- line
				}
				if err != nil {
					return
				}
				_, _ = conn.Write([]byte(`{"id":1,"ok":true,"result":{}}` + "\n"))
			}(conn)
		}
	}()
	return ln.Addr().String(), lines
}

func expectNothingSentToImpostor(t *testing.T, lines <-chan string) {
	t.Helper()
	select {
	case line := <-lines:
		t.Fatalf("CLI sent a request to a relay that never proved it holds the relay token: %s", strings.TrimSpace(line))
	case <-time.After(200 * time.Millisecond):
	}
}

func TestCLIRefusesRelayThatCannotProveTheToken(t *testing.T) {
	relayID := "relay-impostor"
	addr, lines := startImpostorRelay(t, relayID, true)
	t.Setenv("HOME", t.TempDir())
	t.Setenv("CMUX_RELAY_ID", relayID)
	t.Setenv("CMUX_RELAY_TOKEN", strings.Repeat("c3", 32))

	code := runCLI([]string{"--socket", addr, "ping"})

	expectNothingSentToImpostor(t, lines)
	if code == 0 {
		t.Fatal("ping must fail when the relay cannot prove it holds the relay token")
	}
}

func TestCLIRefusesTCPRelayWithoutCredentials(t *testing.T) {
	// Transport cleanup removes <port>.auth on disconnect, while shells keep
	// CMUX_SOCKET_PATH=127.0.0.1:<port>. Whoever binds the port next must not
	// receive the CLI's requests.
	addr, lines := startImpostorRelay(t, "", false)
	home := t.TempDir()
	if err := os.MkdirAll(home+"/.cmux/relay", 0o700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	t.Setenv("CMUX_RELAY_ID", "")
	t.Setenv("CMUX_RELAY_TOKEN", "")

	code := runCLI([]string{"--socket", addr, "ping"})

	expectNothingSentToImpostor(t, lines)
	if code == 0 {
		t.Fatal("ping must fail when no relay credentials exist for a TCP relay address")
	}
}
