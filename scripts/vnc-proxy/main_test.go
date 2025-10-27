package main

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

func newTestConfig(t *testing.T, backendAddr string, webRoot string) proxyConfig {
	t.Helper()
	tcpAddr, err := net.ResolveTCPAddr("tcp", backendAddr)
	if err != nil {
		t.Fatalf("resolve backend addr: %v", err)
	}
	return proxyConfig{
		listenHost:    "127.0.0.1",
		listenPort:    0,
		targetHost:    tcpAddr.IP.String(),
		targetPort:    tcpAddr.Port,
		websocketPath: "/websockify",
		webRoot:       webRoot,
		dialTimeout:   time.Second,
		idleTimeout:   0,
	}
}

func TestProxyDataFlow(t *testing.T) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("listen backend: %v", err)
	}
	t.Cleanup(func() { _ = listener.Close() })

	events := make(chan error, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			events <- err
			return
		}
		defer conn.Close()

		buf := make([]byte, 5)
		if _, err := io.ReadFull(conn, buf); err != nil {
			events <- err
			return
		}
		if string(buf) != "hello" {
			events <- fmt.Errorf("unexpected payload: %q", string(buf))
			return
		}
		if _, err := conn.Write([]byte("world")); err != nil {
			events <- err
			return
		}
		events <- nil
	}()

	tempDir := t.TempDir()
	cfg := newTestConfig(t, listener.Addr().String(), tempDir)
	handler := newServeMux(cfg)

	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	wsURL := "ws" + strings.TrimPrefix(server.URL, "http") + cfg.websocketPath
	conn, _, err := websocket.Dial(ctx, wsURL, nil)
	if err != nil {
		t.Fatalf("dial websocket: %v", err)
	}
	defer conn.Close(websocket.StatusInternalError, "test shutdown")

	netConn := websocket.NetConn(ctx, conn, websocket.MessageBinary)
	defer netConn.Close()

	deadline := time.Now().Add(2 * time.Second)
	_ = netConn.SetDeadline(deadline)

	if _, err := netConn.Write([]byte("hello")); err != nil {
		t.Fatalf("write to websocket: %v", err)
	}

	respBuf := make([]byte, 5)
	if _, err := io.ReadFull(netConn, respBuf); err != nil {
		t.Fatalf("read from websocket: %v", err)
	}
	if string(respBuf) != "world" {
		t.Fatalf("unexpected response %q", string(respBuf))
	}

	if err := conn.Close(websocket.StatusNormalClosure, "done"); err != nil {
		t.Fatalf("closing websocket: %v", err)
	}

	select {
	case err := <-events:
		if err != nil {
			t.Fatalf("backend error: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatalf("backend handler timed out")
	}
}

func TestStaticFileServing(t *testing.T) {
	tempDir := t.TempDir()
	content := []byte("<html>ok</html>")
	if err := os.WriteFile(filepath.Join(tempDir, "vnc.html"), content, 0o644); err != nil {
		t.Fatalf("write static file: %v", err)
	}

	cfg := newTestConfig(t, "127.0.0.1:5901", tempDir)
	handler := newServeMux(cfg)

	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)

	resp, err := http.Get(server.URL + "/vnc.html")
	if err != nil {
		t.Fatalf("http get: %v", err)
	}
	t.Cleanup(func() { _ = resp.Body.Close() })

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("unexpected status %d", resp.StatusCode)
	}

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		t.Fatalf("read body: %v", err)
	}
	if string(body) != string(content) {
		t.Fatalf("unexpected body %q", string(body))
	}

	expectedHeaders := map[string]string{
		"X-Content-Type-Options":       "nosniff",
		"X-Frame-Options":              "SAMEORIGIN",
		"Referrer-Policy":              "no-referrer",
		"Cross-Origin-Resource-Policy": "same-origin",
	}
	for key, want := range expectedHeaders {
		if got := resp.Header.Get(key); got != want {
			t.Fatalf("header %s = %q, want %q", key, got, want)
		}
	}
}

func TestWebsocketPathRequiresUpgrade(t *testing.T) {
	tempDir := t.TempDir()
	cfg := newTestConfig(t, "127.0.0.1:5901", tempDir)
	handler := newServeMux(cfg)

	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)

	resp, err := http.Get(server.URL + cfg.websocketPath)
	if err != nil {
		t.Fatalf("http get: %v", err)
	}
	t.Cleanup(func() { _ = resp.Body.Close() })

	if resp.StatusCode != http.StatusUpgradeRequired {
		t.Fatalf("unexpected status %d", resp.StatusCode)
	}
}
