package main

import (
	"encoding/json"
	"net"
	"os"
	"testing"
	"time"
)

// receiveRequest reads one captured request from the channel with a timeout.
func receiveRequest(t *testing.T, ch <-chan map[string]any) map[string]any {
	t.Helper()
	select {
	case req := <-ch:
		return req
	case <-time.After(2 * time.Second):
		t.Fatal("timed out waiting for request")
		return nil
	}
}

func params(req map[string]any) map[string]any {
	t := req["params"]
	if t == nil {
		return map[string]any{}
	}
	p, ok := t.(map[string]any)
	if !ok {
		return map[string]any{}
	}
	return p
}

// TestBoolFlagCoercionFocusTrue verifies that --focus true is sent as a JSON
// boolean true, not the string "true".
func TestBoolFlagCoercionFocusTrue(t *testing.T) {
	sockPath, requests := startMockV2SocketWithRequestCapture(t)
	code := runCLI([]string{"--socket", sockPath, "new-workspace", "--focus", "true"})
	if code != 0 {
		t.Fatalf("new-workspace --focus true: exit %d", code)
	}
	req := receiveRequest(t, requests)
	p := params(req)
	focus, ok := p["focus"]
	if !ok {
		t.Fatal("expected 'focus' param to be set")
	}
	if focus != true {
		t.Fatalf("expected focus=true (bool), got %T(%v)", focus, focus)
	}
}

// TestBoolFlagCoercionFocusFalse verifies false is sent as JSON false.
func TestBoolFlagCoercionFocusFalse(t *testing.T) {
	sockPath, requests := startMockV2SocketWithRequestCapture(t)
	code := runCLI([]string{"--socket", sockPath, "new-workspace", "--focus", "false"})
	if code != 0 {
		t.Fatalf("new-workspace --focus false: exit %d", code)
	}
	req := receiveRequest(t, requests)
	p := params(req)
	focus, ok := p["focus"]
	if !ok {
		t.Fatal("expected 'focus' param to be set")
	}
	if focus != false {
		t.Fatalf("expected focus=false (bool), got %T(%v)", focus, focus)
	}
}

// TestBoolFlagCoercionInvalidValue verifies that an invalid --focus value
// returns a non-zero exit code without sending a request.
func TestBoolFlagCoercionInvalidValue(t *testing.T) {
	sockPath, requests := startMockV2SocketWithRequestCapture(t)
	code := runCLI([]string{"--socket", sockPath, "new-workspace", "--focus", "maybe"})
	if code == 0 {
		t.Fatal("new-workspace --focus maybe: expected non-zero exit")
	}
	select {
	case req := <-requests:
		t.Fatalf("expected no request to be sent on invalid flag value, got: %v", req)
	case <-time.After(100 * time.Millisecond):
	}
}

// TestNewWorkspaceParamNames verifies that --name maps to "title" and --cwd maps
// to "cwd" (not "name" and "working_directory").
func TestNewWorkspaceParamNames(t *testing.T) {
	sockPath, requests := startMockV2SocketWithRequestCapture(t)
	code := runCLI([]string{"--socket", sockPath, "new-workspace", "--name", "My WS", "--cwd", "/home/dev/code"})
	if code != 0 {
		t.Fatalf("new-workspace: exit %d", code)
	}
	req := receiveRequest(t, requests)
	if req["method"] != "workspace.create" {
		t.Fatalf("expected method workspace.create, got %v", req["method"])
	}
	p := params(req)
	if p["title"] != "My WS" {
		t.Fatalf("expected title='My WS', got %v (wrong param name?)", p["title"])
	}
	if p["name"] != nil {
		t.Fatalf("unexpected 'name' param (should be 'title'): %v", p["name"])
	}
	if p["cwd"] != "/home/dev/code" {
		t.Fatalf("expected cwd='/home/dev/code', got %v", p["cwd"])
	}
	if p["working_directory"] != nil {
		t.Fatalf("unexpected 'working_directory' param (should be 'cwd'): %v", p["working_directory"])
	}
}

// TestRenameWorkspace verifies method and params.
func TestRenameWorkspace(t *testing.T) {
	sockPath, requests := startMockV2SocketWithRequestCapture(t)
	code := runCLI([]string{"--socket", sockPath, "rename-workspace", "--title", "devbox"})
	if code != 0 {
		t.Fatalf("rename-workspace: exit %d", code)
	}
	req := receiveRequest(t, requests)
	if req["method"] != "workspace.rename" {
		t.Fatalf("expected workspace.rename, got %v", req["method"])
	}
	if params(req)["title"] != "devbox" {
		t.Fatalf("expected title='devbox', got %v", params(req)["title"])
	}
}

// TestJoinPaneTargetPaneParam verifies that --target-pane maps to target_pane_id.
func TestJoinPaneTargetPaneParam(t *testing.T) {
	sockPath, requests := startMockV2SocketWithRequestCapture(t)
	code := runCLI([]string{"--socket", sockPath, "join-pane", "--pane", "pane-1", "--target-pane", "pane-2"})
	if code != 0 {
		t.Fatalf("join-pane: exit %d", code)
	}
	req := receiveRequest(t, requests)
	if req["method"] != "pane.join" {
		t.Fatalf("expected pane.join, got %v", req["method"])
	}
	p := params(req)
	if p["target_pane_id"] != "pane-2" {
		t.Fatalf("expected target_pane_id='pane-2', got %v", p["target_pane_id"])
	}
	if p["target-pane"] != nil {
		t.Fatalf("unexpected 'target-pane' param (should be 'target_pane_id'): %v", p["target-pane"])
	}
}

// TestNewWorkspaceRemovedFlags verifies that --working-directory is no longer
// accepted. It was previously accepted but sent the wrong param name
// (working_directory instead of cwd) so the server silently ignored it.
func TestNewWorkspaceRemovedFlags(t *testing.T) {
	sockPath := startMockV2Socket(t)
	code := runCLI([]string{"--socket", sockPath, "new-workspace", "--working-directory", "/home/dev"})
	if code == 0 {
		t.Fatal("new-workspace --working-directory: expected non-zero exit (flag was removed)")
	}
}

// TestNewWorkspaceLayout verifies that --layout parses the JSON value and sends
// it as a nested object, not a string.
func TestNewWorkspaceLayout(t *testing.T) {
	sockPath, requests := startMockV2SocketWithRequestCapture(t)
	layout := `{"splits":[{"direction":"vertical","ratio":0.5}]}`
	code := runCLI([]string{"--socket", sockPath, "new-workspace", "--layout", layout})
	if code != 0 {
		t.Fatalf("new-workspace --layout: exit %d", code)
	}
	req := receiveRequest(t, requests)
	if req["method"] != "workspace.create" {
		t.Fatalf("expected workspace.create, got %v", req["method"])
	}
	p := params(req)
	if p["layout"] == nil {
		t.Fatal("expected 'layout' param to be set")
	}
	// layout must be a map, not a raw string
	if _, ok := p["layout"].(map[string]any); !ok {
		t.Fatalf("expected layout to be a JSON object, got %T", p["layout"])
	}
}

// TestNewWorkspaceLayoutInvalid verifies that non-JSON --layout returns exit 2.
func TestNewWorkspaceLayoutInvalid(t *testing.T) {
	sockPath := startMockV2Socket(t)
	code := runCLI([]string{"--socket", sockPath, "new-workspace", "--layout", "not-json"})
	if code == 0 {
		t.Fatal("new-workspace --layout not-json: expected non-zero exit")
	}
}

// TestNewWorkspaceEnv verifies that --env KEY=VALUE pairs are collected into a
// dict under the "env" param.
func TestNewWorkspaceEnv(t *testing.T) {
	sockPath, requests := startMockV2SocketWithRequestCapture(t)
	code := runCLI([]string{"--socket", sockPath, "new-workspace",
		"--env", "FOO=bar",
		"--env", "BAZ=qux",
	})
	if code != 0 {
		t.Fatalf("new-workspace --env: exit %d", code)
	}
	req := receiveRequest(t, requests)
	p := params(req)
	env, ok := p["env"].(map[string]any)
	if !ok {
		t.Fatalf("expected env to be a map, got %T: %v", p["env"], p["env"])
	}
	if env["FOO"] != "bar" {
		t.Fatalf("expected env.FOO='bar', got %v", env["FOO"])
	}
	if env["BAZ"] != "qux" {
		t.Fatalf("expected env.BAZ='qux', got %v", env["BAZ"])
	}
}

// TestNewWorkspaceEnvBadFormat verifies that --env values without '=' return exit 2.
func TestNewWorkspaceEnvBadFormat(t *testing.T) {
	sockPath := startMockV2Socket(t)
	code := runCLI([]string{"--socket", sockPath, "new-workspace", "--env", "NOEQUALS"})
	if code == 0 {
		t.Fatal("new-workspace --env NOEQUALS: expected non-zero exit")
	}
}

// TestNewWorkspaceEnvFile verifies that --env-file reads a file of KEY=VALUE
// lines (ignoring blank lines and comments) and merges them into the env param.
func TestNewWorkspaceEnvFile(t *testing.T) {
	f, err := os.CreateTemp("", "cmux-env-*.env")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.Remove(f.Name()) })
	f.WriteString("# comment\nHOST=localhost\nPORT=5432\n\n")
	f.Close()

	sockPath, requests := startMockV2SocketWithRequestCapture(t)
	code := runCLI([]string{"--socket", sockPath, "new-workspace", "--env-file", f.Name()})
	if code != 0 {
		t.Fatalf("new-workspace --env-file: exit %d", code)
	}
	req := receiveRequest(t, requests)
	env, ok := params(req)["env"].(map[string]any)
	if !ok {
		t.Fatalf("expected env map, got %T", params(req)["env"])
	}
	if env["HOST"] != "localhost" || env["PORT"] != "5432" {
		t.Fatalf("unexpected env contents: %v", env)
	}
}

// TestNewWorkspaceWindowGroupFlags verifies that --window, --group,
// --group-placement, and --group-reference map to the correct param names.
func TestNewWorkspaceWindowGroupFlags(t *testing.T) {
	sockPath, requests := startMockV2SocketWithRequestCapture(t)
	code := runCLI([]string{
		"--socket", sockPath, "new-workspace",
		"--window", "win-1",
		"--group", "grp-1",
		"--group-placement", "before",
		"--group-reference", "ws-ref-1",
	})
	if code != 0 {
		t.Fatalf("new-workspace with group flags: exit %d", code)
	}
	req := receiveRequest(t, requests)
	p := params(req)
	if p["window_id"] != "win-1" {
		t.Fatalf("expected window_id='win-1', got %v", p["window_id"])
	}
	if p["group_id"] != "grp-1" {
		t.Fatalf("expected group_id='grp-1', got %v", p["group_id"])
	}
	if p["placement"] != "before" {
		t.Fatalf("expected placement='before', got %v", p["placement"])
	}
	if p["group_reference_workspace_id"] != "ws-ref-1" {
		t.Fatalf("expected group_reference_workspace_id='ws-ref-1', got %v", p["group_reference_workspace_id"])
	}
}

// TestNewWorkspaceCommand verifies that --command triggers two follow-up calls
// (surface.send_text and surface.send_key return) using the surface_id returned
// by workspace.create.
func TestNewWorkspaceCommand(t *testing.T) {
	// Custom mock: workspace.create returns surface_id; other methods echo normally.
	sockPath := makeShortUnixSocketPath(t)
	requests := make(chan map[string]any, 8)
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

	go func() {
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				var req map[string]any
				if err := json.NewDecoder(conn).Decode(&req); err != nil {
					conn.Write([]byte(`{"ok":false,"error":{"code":"parse","message":"bad json"}}` + "\n"))
					return
				}
				requests <- req
				var result any
				if req["method"] == "workspace.create" {
					result = map[string]any{"workspace_id": "ws-1", "surface_id": "surf-1"}
				} else {
					result = map[string]any{"ok": true}
				}
				resp := map[string]any{"id": req["id"], "ok": true, "result": result}
				payload, _ := json.Marshal(resp)
				conn.Write(append(payload, '\n'))
			}(conn)
		}
	}()

	code := runCLI([]string{"--socket", sockPath, "new-workspace", "--command", "claude ."})
	if code != 0 {
		t.Fatalf("new-workspace --command: exit %d", code)
	}

	create := receiveRequest(t, requests)
	if create["method"] != "workspace.create" {
		t.Fatalf("expected workspace.create, got %v", create["method"])
	}

	sendText := receiveRequest(t, requests)
	if sendText["method"] != "surface.send_text" {
		t.Fatalf("expected surface.send_text, got %v", sendText["method"])
	}
	sp := params(sendText)
	if sp["surface_id"] != "surf-1" {
		t.Fatalf("expected surface_id='surf-1', got %v", sp["surface_id"])
	}
	if sp["text"] != "claude ." {
		t.Fatalf("expected text='claude .', got %v", sp["text"])
	}

	sendKey := receiveRequest(t, requests)
	if sendKey["method"] != "surface.send_key" {
		t.Fatalf("expected surface.send_key, got %v", sendKey["method"])
	}
	kp := params(sendKey)
	if kp["surface_id"] != "surf-1" {
		t.Fatalf("expected surface_id='surf-1', got %v", kp["surface_id"])
	}
	if kp["key"] != "return" {
		t.Fatalf("expected key='return', got %v", kp["key"])
	}
}

// TestSendPositional verifies that send and send-key take text/key as positional args,
// matching the Mac CLI convention (not --text/--key flags).
func TestSendPositional(t *testing.T) {
	t.Run("send", func(t *testing.T) {
		sockPath, requests := startMockV2SocketWithRequestCapture(t)
		code := runCLI([]string{"--socket", sockPath, "send", "hello world"})
		if code != 0 {
			t.Fatalf("send: exit %d", code)
		}
		req := receiveRequest(t, requests)
		if params(req)["text"] != "hello world" {
			t.Fatalf("expected text='hello world', got %v", params(req)["text"])
		}
	})
	t.Run("send-key", func(t *testing.T) {
		sockPath, requests := startMockV2SocketWithRequestCapture(t)
		code := runCLI([]string{"--socket", sockPath, "send-key", "ctrl+c"})
		if code != 0 {
			t.Fatalf("send-key: exit %d", code)
		}
		req := receiveRequest(t, requests)
		if params(req)["key"] != "ctrl+c" {
			t.Fatalf("expected key='ctrl+c', got %v", params(req)["key"])
		}
	})
	t.Run("send rejects --text flag", func(t *testing.T) {
		sockPath := startMockV2Socket(t)
		code := runCLI([]string{"--socket", sockPath, "send", "--text", "hello"})
		if code == 0 {
			t.Fatal("send --text: expected non-zero exit (--text is not a flag; use positional)")
		}
	})
}

// TestPositionalRejectedOnFlagOnlyCommands verifies that commands without positionalKey
// reject unexpected positional arguments instead of silently ignoring them.
func TestPositionalRejectedOnFlagOnlyCommands(t *testing.T) {
	sockPath := startMockV2Socket(t)
	code := runCLI([]string{"--socket", sockPath, "new-workspace", "unexpected-positional"})
	if code == 0 {
		t.Fatal("new-workspace with positional arg: expected non-zero exit")
	}
}

// TestNewCommandsMethod is a table-driven smoke test verifying that each new
// command sends the correct v2 method.
func TestNewCommandsMethod(t *testing.T) {
	tests := []struct {
		args   []string
		method string
	}{
		{[]string{"next-workspace"}, "workspace.next"},
		{[]string{"previous-workspace"}, "workspace.previous"},
		{[]string{"last-workspace"}, "workspace.last"},
		{[]string{"equalize-splits"}, "workspace.equalize_splits"},
		{[]string{"last-pane"}, "pane.last"},
		{[]string{"swap-pane", "--pane", "p1"}, "pane.swap"},
		{[]string{"break-pane", "--pane", "p1"}, "pane.break"},
		{[]string{"read-screen"}, "surface.read_text"},
		{[]string{"clear-history"}, "surface.clear_history"},
		{[]string{"jump-to-unread"}, "notification.jump_to_unread"},
		{[]string{"dismiss-notification", "--id", "n1"}, "notification.dismiss"},
		{[]string{"mark-notification-read", "--id", "n1"}, "notification.mark_read"},
		{[]string{"open-notification", "--id", "n1"}, "notification.open"},
	}

	for _, tt := range tests {
		t.Run(tt.args[0], func(t *testing.T) {
			sockPath, requests := startMockV2SocketWithRequestCapture(t)
			args := append([]string{"--socket", sockPath}, tt.args...)
			code := runCLI(args)
			if code != 0 {
				t.Fatalf("%s: exit %d", tt.args[0], code)
			}
			req := receiveRequest(t, requests)
			if req["method"] != tt.method {
				t.Fatalf("%s: expected method %q, got %v", tt.args[0], tt.method, req["method"])
			}
		})
	}
}
