package main

import (
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"sync/atomic"
	"testing"
	"time"
)

func TestCloudCLIBridgeAuthenticatesPeerBeforeForwarding(t *testing.T) {
	for _, test := range []struct {
		name    string
		lookup  func(net.Conn) (uint32, error)
		allowed bool
	}{
		{name: "native same user", allowed: true},
		{name: "another user", lookup: func(net.Conn) (uint32, error) { return uint32(os.Geteuid()) + 1, nil }},
		{name: "credential lookup failure", lookup: func(net.Conn) (uint32, error) { return uint32(os.Geteuid()), errors.New("lookup failed") }},
	} {
		t.Run(test.name, func(t *testing.T) {
			bridge := newCloudCLIBridge()
			if test.lookup != nil {
				bridge.peerUserID = test.lookup
			}
			var forwarded atomic.Int32
			server := &rpcServer{cliBridge: bridge}
			server.frameWriter = testCLIBridgeFrameWriter{onEvent: func(event rpcEvent) error {
				forwarded.Add(1)
				response := server.handleCLIResponse(rpcRequest{
					ID: "response", Method: "cli.response",
					Params: map[string]any{
						"request_id":  event.RequestID,
						"ok":          true,
						"data_base64": base64.StdEncoding.EncodeToString([]byte("pong\n")),
					},
				})
				if !response.OK {
					return fmt.Errorf("bridge response failed: %+v", response)
				}
				return nil
			}}
			t.Cleanup(bridge.register(server))
			ctx, cancel := context.WithCancel(context.Background())
			t.Cleanup(cancel)
			path := makeShortUnixSocketPath(t)
			if err := bridge.start(ctx, path, io.Discard); err != nil {
				t.Fatal(err)
			}
			conn, err := net.Dial("unix", path)
			if err != nil {
				t.Fatal(err)
			}
			defer conn.Close()
			if err := conn.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
				t.Fatal(err)
			}
			_, writeErr := io.WriteString(conn, "ping\n")
			data, readErr := io.ReadAll(conn)
			if test.allowed {
				if writeErr != nil || readErr != nil || string(data) != "pong\n" || forwarded.Load() != 1 {
					t.Fatalf("same-user request failed: write=%v read=%v data=%q forwards=%d", writeErr, readErr, data, forwarded.Load())
				}
			} else {
				if timeout, ok := readErr.(net.Error); ok && timeout.Timeout() {
					t.Fatal("unauthorized connection was not closed")
				}
				if len(data) != 0 || forwarded.Load() != 0 {
					t.Fatalf("unauthorized request forwarded: %q (%d forwards)", data, forwarded.Load())
				}
			}
		})
	}
}
