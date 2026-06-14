package main

import (
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
	sockPath, _ := startMockV2SocketWithRequestCapture(t)
	code := runCLI([]string{"--socket", sockPath, "new-workspace", "--focus", "maybe"})
	if code == 0 {
		t.Fatal("new-workspace --focus maybe: expected non-zero exit")
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

// TestNewWorkspaceRemovedFlags verifies that --working-directory and --command
// are no longer accepted. Both were previously accepted but sent wrong param
// names to workspace.create (working_directory and initial_command respectively),
// so the server silently ignored them. They are now removed to surface the error.
func TestNewWorkspaceRemovedFlags(t *testing.T) {
	for _, flag := range []string{"--working-directory", "--command"} {
		t.Run(flag, func(t *testing.T) {
			sockPath := startMockV2Socket(t)
			code := runCLI([]string{"--socket", sockPath, "new-workspace", flag, "somevalue"})
			if code == 0 {
				t.Fatalf("new-workspace %s: expected non-zero exit (flag was silently broken before and has been removed)", flag)
			}
		})
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
