package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"nhooyr.io/websocket"
)

func TestOmoShadowConfigKeepsCredentialsPrivate(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("OPENCODE_CONFIG_DIR", "")
	userDir := omoUserConfigDir()
	if err := os.MkdirAll(filepath.Join(userDir, "node_modules", omoPluginName), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(userDir, "opencode.json"), []byte(`{"provider":{"test":{"options":{"apiKey":"fixture-secret"}}}}`), 0600); err != nil {
		t.Fatal(err)
	}
	shadow := omoShadowConfigDir()
	if err := os.MkdirAll(shadow, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(shadow, 0755); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"opencode.json", "oh-my-opencode.json"} {
		path := filepath.Join(shadow, name)
		if err := os.WriteFile(path, []byte(`{}`), 0644); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(path, 0644); err != nil {
			t.Fatal(err)
		}
	}
	if err := omoEnsurePlugin(""); err != nil {
		t.Fatal(err)
	}
	for name, want := range map[string]os.FileMode{"": 0700, "opencode.json": 0600, "oh-my-opencode.json": 0600} {
		info, err := os.Stat(filepath.Join(shadow, name))
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != want {
			t.Errorf("shadow %q permissions = %o, want %o", name, info.Mode().Perm(), want)
		}
	}
	data, err := os.ReadFile(filepath.Join(shadow, "opencode.json"))
	if err != nil || !bytes.Contains(data, []byte("fixture-secret")) {
		t.Fatalf("private config must retain the user's provider configuration: %v", err)
	}
}

func TestTmuxStaleInheritedSurfaceCannotRetarget(t *testing.T) {
	for _, command := range []string{"send-keys", "kill-pane"} {
		for _, target := range []string{"", "%33333333-3333-4333-8333-333333333333"} {
			t.Run(command+"/"+target, func(t *testing.T) {
				recorder := startTmuxCorpusRPCRecorder(t)
				t.Setenv("CMUX_WORKSPACE_ID", "11111111-1111-4111-8111-111111111111")
				t.Setenv("CMUX_SURFACE_ID", "surface:missing")
				t.Setenv("CMUX_PANE_ID", "pane:1")
				var args []string
				if target != "" {
					args = append(args, "-t", target)
				}
				if command == "send-keys" {
					args = append(args, "do-not-send")
				}
				err := dispatchTmuxCommand(&rpcContext{socketPath: recorder.socketPath}, command, args)
				if err == nil {
					t.Error("stale inherited surface unexpectedly succeeded")
				}
				for _, method := range []string{"surface.send_text", "surface.send_key", "surface.close"} {
					if requests := recorder.requestsFor(method); len(requests) != 0 {
						t.Errorf("stale caller attempted mutation of another terminal: %+v", requests)
					}
				}
			})
		}
	}
}

func TestCLINotifySucceedsWithSSHRelayTargetContract(t *testing.T) {
	path := makeShortUnixSocketPath(t)
	listener, err := net.Listen("unix", path)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	done := make(chan struct{})
	go func() {
		defer close(done)
		conn, err := listener.Accept()
		if err != nil {
			return
		}
		defer conn.Close()
		var request rpcRequest
		if json.NewDecoder(conn).Decode(&request) != nil {
			return
		}
		// This is the existing SSH relay contract: caller-only requests are
		// rejected before rewriting; explicit owned targets are supported.
		allowed := request.Method == "notification.create_for_target" &&
			request.Params["workspace_id"] == "owned-workspace" &&
			request.Params["surface_id"] == "owned-surface" &&
			request.Params["title"] == "Done"
		response := rpcResponse{ID: request.ID, OK: allowed}
		if !allowed {
			response.Error = &rpcError{Code: "remote_relay_denied", Message: "unsupported notification target"}
		}
		_ = json.NewEncoder(conn).Encode(response)
	}()
	t.Setenv("CMUX_WORKSPACE_ID", "owned-workspace")
	t.Setenv("CMUX_SURFACE_ID", "owned-surface")
	if code := runCLI([]string{"--socket", path, "notify", "--title", "Done"}); code != 0 {
		t.Errorf("notification through SSH relay contract exited %d, want success", code)
	}
	<-done
}

type writeStartedConn struct {
	net.Conn
	started chan struct{}
	once    sync.Once
}

func (conn *writeStartedConn) Write(data []byte) (int, error) {
	conn.once.Do(func() { close(conn.started) })
	return conn.Conn.Write(data)
}

func TestRPCEOFInterruptsBlockedOutputBeforeTeardown(t *testing.T) {
	serverConn, clientConn := net.Pipe()
	defer serverConn.Close()
	defer clientConn.Close()
	observed := &writeStartedConn{Conn: serverConn, started: make(chan struct{})}
	writer := &stdioFrameWriter{writer: bufio.NewWriter(observed)}
	writeDone := make(chan error, 1)
	go func() { writeDone <- writer.writeEvent(rpcEvent{Event: "blocked-output"}) }()
	<-observed.started
	hub := newWebSocketPTYHub(wsPTYServerConfig{}, io.Discard)
	defer hub.closeAll()
	serverDone := make(chan error, 1)
	go func() {
		serverDone <- runRPCServerWithReader(bufio.NewReader(strings.NewReader("")), writer, hub, false, nil, func() { _ = serverConn.Close() })
	}()
	select {
	case err := <-serverDone:
		if err != nil {
			t.Error(err)
		}
	case <-time.After(time.Second):
		t.Error("EOF teardown waited for a client that stopped reading RPC output")
		_ = clientConn.Close()
		<-serverDone
	}
	<-writeDone
}

func TestScrollbackSteadyOutputDoesNotAllocateHistoryPerChunk(t *testing.T) {
	hub := newWebSocketPTYHub(wsPTYServerConfig{}, io.Discard)
	session := &wsPTYSession{}
	hub.mu.Lock()
	hub.appendScrollbackLocked(session, bytes.Repeat([]byte("x"), defaultWebSocketScrollbackCap))
	hub.mu.Unlock()
	chunk := bytes.Repeat([]byte("z"), 1024)
	allocs := testing.AllocsPerRun(100, func() {
		hub.mu.Lock()
		hub.appendScrollbackLocked(session, chunk)
		hub.mu.Unlock()
	})
	if allocs != 0 {
		t.Fatalf("steady PTY output allocations per 1 KiB chunk = %g, want 0", allocs)
	}
}

func TestScrollbackDoesNotReserveFullHistoryForQuietSessions(t *testing.T) {
	hub := newWebSocketPTYHub(wsPTYServerConfig{}, io.Discard)
	session := &wsPTYSession{}
	hub.recordAndBroadcast(session, []byte("prompt"))
	if cap(session.scrollback) > 4096 {
		t.Fatalf("a quiet terminal reserved %d bytes of history", cap(session.scrollback))
	}
}

func TestScrollbackReplayRetainsNewestOutputInOrder(t *testing.T) {
	hub, session, _, readFile, writeFile, done := newTestPTYInputSession(t, "replay-ring", "first", false)
	defer close(done)
	defer readFile.Close()
	defer writeFile.Close()
	hub.scrollbackLimit = 64
	var output []byte
	for i := 1; i <= 20; i++ {
		chunk := bytes.Repeat([]byte{byte(i)}, i*7)
		output = append(output, chunk...)
		hub.recordAndBroadcast(session, chunk)
	}
	attachment, _, _, err := hub.prepareAttachment(context.Background(), nil, session.id, "second", 80, 24, true, "", "token", true, false)
	if err != nil {
		t.Fatal(err)
	}
	defer attachment.cancel()
	var replay []byte
	for len(replay) < attachment.replayBytes {
		frame := <-attachment.send
		if frame.messageType == websocket.MessageBinary {
			replay = append(replay, frame.payload...)
		}
	}
	if !bytes.Equal(replay, output[len(output)-64:]) {
		t.Fatalf("replay did not preserve the newest output: %x", replay)
	}
}
