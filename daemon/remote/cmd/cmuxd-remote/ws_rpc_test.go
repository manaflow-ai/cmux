package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

func TestWebSocketRPCRejectsMissingAndWrongLease(t *testing.T) {
	leasePath := t.TempDir() + "/rpc-lease.json"
	server := httptest.NewServer(newWebSocketPTYHandler(wsPTYServerConfig{
		PTYAuthLeaseFile: t.TempDir() + "/pty-lease.json",
		RPCAuthLeaseFile: leasePath,
		Shell:            "/bin/sh",
	}, nil))
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	conn := dialRPC(t, ctx, server.URL)
	sendRPCAuth(t, ctx, conn, "missing", "sess-missing")
	_, _, err := conn.Read(ctx)
	if websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("missing lease should close with policy violation, got err=%v status=%v", err, websocket.CloseStatus(err))
	}

	writeTestLease(t, leasePath, "correct-token", "sess-good", false, time.Now().Add(time.Minute))
	conn = dialRPC(t, ctx, server.URL)
	sendRPCAuth(t, ctx, conn, "wrong-token", "sess-good")
	_, _, err = conn.Read(ctx)
	if websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("wrong token should close with policy violation, got err=%v status=%v", err, websocket.CloseStatus(err))
	}
}

func TestWebSocketRPCHelloAndProxyRoundTrip(t *testing.T) {
	leasePath := t.TempDir() + "/rpc-lease.json"
	server := httptest.NewServer(newWebSocketPTYHandler(wsPTYServerConfig{
		PTYAuthLeaseFile: t.TempDir() + "/pty-lease.json",
		RPCAuthLeaseFile: leasePath,
		Shell:            "/bin/sh",
	}, nil))
	defer server.Close()

	upstream := newTestTCPServer(t, "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK")
	defer upstream.close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	writeTestLease(t, leasePath, "rpc-token", "sess-rpc", false, time.Now().Add(time.Minute))
	conn := dialRPC(t, ctx, server.URL)
	defer conn.Close(websocket.StatusNormalClosure, "done")
	sendRPCAuth(t, ctx, conn, "rpc-token", "sess-rpc")
	ready := readWSRPCFrame(t, ctx, conn)
	if ready["type"] != "ready" {
		t.Fatalf("expected ready frame, got %v", ready)
	}

	hello := rpcCall(t, ctx, conn, rpcRequest{
		ID:     1,
		Method: "hello",
		Params: map[string]any{},
	})
	if hello["ok"] != true {
		t.Fatalf("hello failed: %v", hello)
	}

	open := rpcCall(t, ctx, conn, rpcRequest{
		ID:     2,
		Method: "proxy.open",
		Params: map[string]any{"host": "127.0.0.1", "port": upstream.port},
	})
	result, _ := open["result"].(map[string]any)
	streamID, _ := result["stream_id"].(string)
	if strings.TrimSpace(streamID) == "" {
		t.Fatalf("proxy.open missing stream_id: %v", open)
	}

	subscribe := rpcCall(t, ctx, conn, rpcRequest{
		ID:     3,
		Method: "proxy.stream.subscribe",
		Params: map[string]any{"stream_id": streamID},
	})
	if subscribe["ok"] != true {
		t.Fatalf("proxy.stream.subscribe failed: %v", subscribe)
	}

	request := "GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
	write := rpcCall(t, ctx, conn, rpcRequest{
		ID:     4,
		Method: "proxy.write",
		Params: map[string]any{
			"stream_id":   streamID,
			"data_base64": base64.StdEncoding.EncodeToString([]byte(request)),
		},
	})
	if write["ok"] != true {
		t.Fatalf("proxy.write failed: %v", write)
	}

	var output strings.Builder
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		frame := readWSRPCFrame(t, ctx, conn)
		eventName, _ := frame["event"].(string)
		switch eventName {
		case "proxy.stream.data", "proxy.stream.eof":
			dataBase64, _ := frame["data_base64"].(string)
			chunk, err := base64.StdEncoding.DecodeString(dataBase64)
			if err != nil {
				t.Fatalf("decode data_base64: %v frame=%v", err, frame)
			}
			output.Write(chunk)
			if eventName == "proxy.stream.eof" {
				if !strings.Contains(output.String(), "200 OK") || !strings.Contains(output.String(), "\r\n\r\nOK") {
					t.Fatalf("unexpected proxy output: %q", output.String())
				}
				return
			}
		case "":
			t.Fatalf("unexpected response while waiting for stream events: %v", frame)
		}
	}
	t.Fatalf("timed out waiting for proxy stream events, output=%q", output.String())
}

func dialRPC(t *testing.T, ctx context.Context, serverURL string) *websocket.Conn {
	t.Helper()
	wsURL := "ws" + strings.TrimPrefix(serverURL, "http") + "/rpc"
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("dial %s: %v", wsURL, err)
	}
	return conn
}

func sendRPCAuth(t *testing.T, ctx context.Context, conn *websocket.Conn, token, sessionID string) {
	t.Helper()
	payload, err := json.Marshal(wsAuthFrame{
		Type:      "auth",
		Token:     token,
		SessionID: sessionID,
	})
	if err != nil {
		t.Fatalf("marshal auth: %v", err)
	}
	if err := conn.Write(ctx, websocket.MessageText, payload); err != nil {
		t.Fatalf("write auth: %v", err)
	}
}

func rpcCall(t *testing.T, ctx context.Context, conn *websocket.Conn, req rpcRequest) map[string]any {
	t.Helper()
	payload, err := json.Marshal(req)
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	if err := conn.Write(ctx, websocket.MessageText, payload); err != nil {
		t.Fatalf("write request: %v", err)
	}
	frame := readWSRPCFrame(t, ctx, conn)
	id, _ := frame["id"].(float64)
	expectedID, _ := req.ID.(int)
	if int(id) != expectedID {
		t.Fatalf("response id = %v, want %v frame=%v", frame["id"], expectedID, frame)
	}
	return frame
}

func readWSRPCFrame(t *testing.T, ctx context.Context, conn *websocket.Conn) map[string]any {
	t.Helper()
	msgType, payload, err := conn.Read(ctx)
	if err != nil {
		t.Fatalf("read rpc frame: %v", err)
	}
	if msgType != websocket.MessageText {
		t.Fatalf("expected text frame, got %v payload=%q", msgType, string(payload))
	}
	var frame map[string]any
	if err := json.Unmarshal(payload, &frame); err != nil {
		t.Fatalf("decode rpc frame: %v payload=%q", err, string(payload))
	}
	return frame
}

type testTCPServer struct {
	listener net.Listener
	port     int
	done     chan struct{}
}

func newTestTCPServer(t *testing.T, response string) *testTCPServer {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	addr := listener.Addr().String()
	_, portRaw, err := net.SplitHostPort(addr)
	if err != nil {
		t.Fatalf("split host/port: %v", err)
	}
	port, err := strconv.Atoi(portRaw)
	if err != nil {
		t.Fatalf("parse port: %v", err)
	}
	server := &testTCPServer{
		listener: listener,
		port:     port,
		done:     make(chan struct{}),
	}
	go func() {
		defer close(server.done)
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		buffer := make([]byte, 4096)
		_, _ = conn.Read(buffer)
		_, _ = conn.Write([]byte(response))
	}()
	return server
}

func (s *testTCPServer) close() {
	_ = s.listener.Close()
	<-s.done
}
