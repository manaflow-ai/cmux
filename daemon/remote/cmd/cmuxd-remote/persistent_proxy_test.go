package main

import (
	"bytes"
	"io"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestPersistentStdioProxyCopiesDaemonFramesThenReturnsOnClose(t *testing.T) {
	listener, socketPath := listenUnixForPersistentProxyTest(t)
	defer listener.Close()

	serverDone := make(chan struct{}, 1)
	go func() {
		defer func() { serverDone <- struct{}{} }()
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		_, _ = conn.Write([]byte("frame-one\n"))
		_, _ = conn.Write([]byte("frame-two\n"))
	}()

	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		t.Fatalf("dial unix socket: %v", err)
	}
	stdinReader, stdinWriter := io.Pipe()
	defer stdinWriter.Close()
	stdout := &bytes.Buffer{}
	done := make(chan error, 1)
	go func() {
		done <- proxyPersistentDaemonConn(stdinReader, stdout, conn)
	}()

	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("proxyPersistentDaemonConn returned error: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatalf("proxyPersistentDaemonConn did not return after daemon side closed")
	}
	if got := stdout.String(); got != "frame-one\nframe-two\n" {
		t.Fatalf("stdout = %q, want copied daemon frames", got)
	}
	select {
	case <-serverDone:
	case <-time.After(time.Second):
		t.Fatalf("server did not finish")
	}
}

func TestPersistentStdioProxyKeepsPumpingWhileDaemonStaysOpen(t *testing.T) {
	listener, socketPath := listenUnixForPersistentProxyTest(t)
	defer listener.Close()

	serverRead := make(chan string, 1)
	serverCanClose := make(chan struct{})
	serverDone := make(chan struct{}, 1)
	go func() {
		defer func() { serverDone <- struct{}{} }()
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		_, _ = conn.Write([]byte("daemon-ready\n"))
		buffer := make([]byte, 64)
		n, _ := conn.Read(buffer)
		serverRead <- string(buffer[:n])
		<-serverCanClose
	}()

	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		t.Fatalf("dial unix socket: %v", err)
	}
	stdinReader, stdinWriter := io.Pipe()
	stdout := newNotifyingBuffer()
	done := make(chan error, 1)
	go func() {
		done <- proxyPersistentDaemonConn(stdinReader, stdout, conn)
	}()

	if _, err := stdinWriter.Write([]byte("client-input\n")); err != nil {
		t.Fatalf("write stdin pipe: %v", err)
	}
	select {
	case got := <-serverRead:
		if got != "client-input\n" {
			t.Fatalf("server read %q, want client input", got)
		}
	case <-time.After(time.Second):
		t.Fatalf("server did not receive stdin data")
	}
	select {
	case <-stdout.notify:
	case <-time.After(time.Second):
		t.Fatalf("proxy did not copy daemon frame")
	}
	if got := stdout.String(); got != "daemon-ready\n" {
		t.Fatalf("stdout = %q, want daemon frame", got)
	}
	select {
	case err := <-done:
		t.Fatalf("proxyPersistentDaemonConn returned while daemon stayed open: %v", err)
	default:
	}

	if err := stdinWriter.Close(); err != nil {
		t.Fatalf("close stdin pipe: %v", err)
	}
	close(serverCanClose)
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("proxyPersistentDaemonConn returned error: %v", err)
		}
	case <-time.After(time.Second):
		t.Fatalf("proxyPersistentDaemonConn did not return after stdin and daemon closed")
	}
	select {
	case <-serverDone:
	case <-time.After(time.Second):
		t.Fatalf("server did not finish")
	}
}

func listenUnixForPersistentProxyTest(t *testing.T) (net.Listener, string) {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "cmux-proxy-test-*")
	if err != nil {
		t.Fatalf("create unix socket dir: %v", err)
	}
	socketPath := filepath.Join(dir, "proxy.sock")
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		_ = os.RemoveAll(dir)
		t.Fatalf("listen unix socket: %v", err)
	}
	t.Cleanup(func() {
		_ = listener.Close()
		_ = os.RemoveAll(dir)
	})
	return listener, socketPath
}
