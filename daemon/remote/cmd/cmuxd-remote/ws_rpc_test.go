package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
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

func TestWebSocketRPCAcceptsSignedToken(t *testing.T) {
	useTempSignedLeaseUsedDir(t)
	publicKey, privateKey, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatalf("generate key: %v", err)
	}
	audienceFile := writeSignedAudienceFile(t, "vm-test")
	server := httptest.NewServer(newWebSocketPTYHandler(wsPTYServerConfig{
		PTYAuthLeaseFile:       t.TempDir() + "/pty-lease.json",
		RPCAuthLeaseFile:       t.TempDir() + "/rpc-lease.json",
		SignedAuthPublicKey:    base64.StdEncoding.EncodeToString(publicKey),
		SignedAuthAudienceFile: audienceFile,
		Shell:                  "/bin/sh",
	}, nil))
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	token := signedTestToken(t, privateKey, "rpc", "vm-test", "sess-rpc-signed", false, time.Now().Add(time.Minute), "jti-rpc-signed")
	conn := dialRPC(t, ctx, server.URL)
	defer conn.Close(websocket.StatusNormalClosure, "done")
	sendRPCAuth(t, ctx, conn, token, "sess-rpc-signed")
	ready := readWSRPCFrame(t, ctx, conn)
	if ready["type"] != "ready" {
		t.Fatalf("expected ready frame, got %v", ready)
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
	var pendingEvents []map[string]any
	write := rpcCallCollectingEvents(t, ctx, conn, rpcRequest{
		ID:     4,
		Method: "proxy.write",
		Params: map[string]any{
			"stream_id":   streamID,
			"data_base64": base64.StdEncoding.EncodeToString([]byte(request)),
		},
	}, &pendingEvents)
	if write["ok"] != true {
		t.Fatalf("proxy.write failed: %v", write)
	}

	var output strings.Builder
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		var frame map[string]any
		if len(pendingEvents) > 0 {
			frame = pendingEvents[0]
			pendingEvents = pendingEvents[1:]
		} else {
			frame = readWSRPCFrame(t, ctx, conn)
		}
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

func TestWebSocketRPCPTYWriteNotificationDoesNotEmitResponse(t *testing.T) {
	leasePath := t.TempDir() + "/rpc-lease.json"
	server := httptest.NewServer(newWebSocketPTYHandler(wsPTYServerConfig{
		PTYAuthLeaseFile: t.TempDir() + "/pty-lease.json",
		RPCAuthLeaseFile: leasePath,
		Shell:            "/bin/sh",
	}, nil))
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	writeTestLease(t, leasePath, "rpc-token", "sess-rpc-notify", false, time.Now().Add(time.Minute))
	conn := dialRPC(t, ctx, server.URL)
	defer conn.Close(websocket.StatusNormalClosure, "done")
	sendRPCAuth(t, ctx, conn, "rpc-token", "sess-rpc-notify")
	ready := readWSRPCFrame(t, ctx, conn)
	if ready["type"] != "ready" {
		t.Fatalf("expected ready frame, got %v", ready)
	}

	payload, err := json.Marshal(map[string]any{
		"method": "pty.write",
		"params": map[string]any{
			"session_id":              "missing",
			"attachment_id":           "missing",
			"client_attachment_token": "token",
			"data_base64":             base64.StdEncoding.EncodeToString([]byte("a")),
		},
	})
	if err != nil {
		t.Fatalf("marshal notification: %v", err)
	}
	if err := conn.Write(ctx, websocket.MessageText, payload); err != nil {
		t.Fatalf("write notification: %v", err)
	}
	event := readWSRPCFrame(t, ctx, conn)
	if _, hasID := event["id"]; hasID {
		t.Fatalf("pty.write notification should not emit an RPC response id: %v", event)
	}
	if got := event["event"]; got != "pty.error" {
		t.Fatalf("first frame = %v, want pty.error event; payload=%v", got, event)
	}

	ping := rpcCall(t, ctx, conn, rpcRequest{
		ID:     2,
		Method: "ping",
		Params: map[string]any{},
	})
	if ping["ok"] != true {
		t.Fatalf("ping failed after pty.write notification: %v", ping)
	}
}

func TestWebSocketRPCPTYResizeNotificationDoesNotEmitResponse(t *testing.T) {
	leasePath := t.TempDir() + "/rpc-lease.json"
	server := httptest.NewServer(newWebSocketPTYHandler(wsPTYServerConfig{
		PTYAuthLeaseFile: t.TempDir() + "/pty-lease.json",
		RPCAuthLeaseFile: leasePath,
		Shell:            "/bin/sh",
	}, nil))
	defer server.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	writeTestLease(t, leasePath, "rpc-token", "sess-rpc-notify", false, time.Now().Add(time.Minute))
	conn := dialRPC(t, ctx, server.URL)
	defer conn.Close(websocket.StatusNormalClosure, "done")
	sendRPCAuth(t, ctx, conn, "rpc-token", "sess-rpc-notify")
	ready := readWSRPCFrame(t, ctx, conn)
	if ready["type"] != "ready" {
		t.Fatalf("expected ready frame, got %v", ready)
	}

	payload, err := json.Marshal(map[string]any{
		"method": "pty.resize",
		"params": map[string]any{
			"session_id":              "missing",
			"attachment_id":           "missing",
			"client_attachment_token": "token",
			"cols":                    100,
			"rows":                    30,
		},
	})
	if err != nil {
		t.Fatalf("marshal notification: %v", err)
	}
	if err := conn.Write(ctx, websocket.MessageText, payload); err != nil {
		t.Fatalf("write notification: %v", err)
	}
	event := readWSRPCFrame(t, ctx, conn)
	if _, hasID := event["id"]; hasID {
		t.Fatalf("pty.resize notification should not emit an RPC response id: %v", event)
	}
	if got := event["event"]; got != "pty.error" {
		t.Fatalf("first frame = %v, want pty.error event; payload=%v", got, event)
	}

	ping := rpcCall(t, ctx, conn, rpcRequest{
		ID:     2,
		Method: "ping",
		Params: map[string]any{},
	})
	if ping["ok"] != true {
		t.Fatalf("ping failed after pty.resize notification: %v", ping)
	}
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
	return rpcCallCollectingEvents(t, ctx, conn, req, nil)
}

func rpcCallCollectingEvents(
	t *testing.T,
	ctx context.Context,
	conn *websocket.Conn,
	req rpcRequest,
	events *[]map[string]any,
) map[string]any {
	t.Helper()
	payload, err := json.Marshal(req)
	if err != nil {
		t.Fatalf("marshal request: %v", err)
	}
	if err := conn.Write(ctx, websocket.MessageText, payload); err != nil {
		t.Fatalf("write request: %v", err)
	}
	expectedID, _ := req.ID.(int)
	for {
		frame := readWSRPCFrame(t, ctx, conn)
		if eventName, _ := frame["event"].(string); eventName != "" {
			if events != nil {
				*events = append(*events, frame)
				continue
			}
			t.Fatalf("unexpected event while waiting for response id %v: %v", expectedID, frame)
		}
		id, _ := frame["id"].(float64)
		if int(id) != expectedID {
			t.Fatalf("response id = %v, want %v frame=%v", frame["id"], expectedID, frame)
		}
		return frame
	}
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
