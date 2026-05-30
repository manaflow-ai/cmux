package main

import (
	"bytes"
	"encoding/json"
	"net"
	"os"
	"strings"
	"testing"
	"time"
)

func TestHeadlessListReportsRegisteredUnixInstance(t *testing.T) {
	registryDir := t.TempDir()
	socketPath := makeShortUnixSocketPath(t)
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}
	defer listener.Close()

	record := headlessInstanceRecord{
		Version:       1,
		ID:            "dev",
		Name:          "Development",
		Transport:     "unix",
		SocketPath:    socketPath,
		PID:           os.Getpid(),
		StartedAt:     time.Now().UTC().Format(time.RFC3339Nano),
		GoOS:          "darwin",
		GoArch:        "arm64",
		DaemonVersion: version,
		Capabilities:  daemonCapabilities(),
	}
	if err := registerHeadlessInstance(registryDir, record); err != nil {
		t.Fatalf("register instance: %v", err)
	}

	var stdout, stderr bytes.Buffer
	code := run(
		[]string{"headless", "list", "--json", "--registry-dir", registryDir},
		strings.NewReader(""),
		&stdout,
		&stderr,
	)
	if code != 0 {
		t.Fatalf("headless list exit code = %d, stderr=%s", code, stderr.String())
	}

	var payload struct {
		Instances []headlessInstanceStatus `json:"instances"`
	}
	if err := json.Unmarshal(stdout.Bytes(), &payload); err != nil {
		t.Fatalf("decode list output: %v\n%s", err, stdout.String())
	}
	if len(payload.Instances) != 1 {
		t.Fatalf("instances len = %d, want 1: %#v", len(payload.Instances), payload.Instances)
	}
	instance := payload.Instances[0]
	if instance.ID != "dev" || instance.Name != "Development" || !instance.Online {
		t.Fatalf("unexpected instance: %#v", instance)
	}
	if instance.SocketPath != socketPath {
		t.Fatalf("socket path = %q, want %q", instance.SocketPath, socketPath)
	}
}

func TestHeadlessConnectBridgesRPCFrames(t *testing.T) {
	socketPath := makeShortUnixSocketPath(t)
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("listen unix: %v", err)
	}
	defer listener.Close()

	done := make(chan string, 1)
	go func() {
		conn, err := listener.Accept()
		if err != nil {
			done <- "accept failed: " + err.Error()
			return
		}
		defer conn.Close()
		buffer := make([]byte, 4096)
		n, err := conn.Read(buffer)
		if err != nil {
			done <- "read failed: " + err.Error()
			return
		}
		done <- string(buffer[:n])
		_, _ = conn.Write([]byte(`{"id":1,"ok":true,"result":{"pong":true}}` + "\n"))
	}()

	var stdout, stderr bytes.Buffer
	code := run(
		[]string{"headless", "connect", "--socket", socketPath},
		strings.NewReader(`{"id":1,"method":"ping","params":{}}`+"\n"),
		&stdout,
		&stderr,
	)
	if code != 0 {
		t.Fatalf("headless connect exit code = %d, stderr=%s", code, stderr.String())
	}

	select {
	case received := <-done:
		if !strings.Contains(received, `"method":"ping"`) {
			t.Fatalf("bridge sent %q, want ping request", received)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("server did not receive bridged request")
	}
	if got := strings.TrimSpace(stdout.String()); got != `{"id":1,"ok":true,"result":{"pong":true}}` {
		t.Fatalf("stdout = %q", got)
	}
}
