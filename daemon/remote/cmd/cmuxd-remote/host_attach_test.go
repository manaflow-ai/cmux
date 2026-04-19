package main

import (
	"encoding/json"
	"path/filepath"
	"testing"
)

func TestExtractScreenText(t *testing.T) {
	tests := []struct {
		name     string
		result   map[string]any
		expected string
	}{
		{
			name:     "nil result",
			result:   nil,
			expected: "",
		},
		{
			name:     "text field",
			result:   map[string]any{"text": "hello world\n$ "},
			expected: "hello world\n$ ",
		},
		{
			name:     "content field",
			result:   map[string]any{"content": "screen content here"},
			expected: "screen content here",
		},
		{
			name:     "screen field",
			result:   map[string]any{"screen": "screen content here"},
			expected: "screen content here",
		},
		{
			name:     "empty result",
			result:   map[string]any{},
			expected: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := extractScreenText(tt.result)
			if got != tt.expected {
				t.Errorf("extractScreenText() = %q, want %q", got, tt.expected)
			}
		})
	}
}

func TestDiscoverHostSocketPath(t *testing.T) {
	path := discoverHostSocketPath()
	if path == "" {
		t.Skip("no home directory available")
	}
	// Just verify it returns a non-empty path that looks reasonable
	if len(path) < 10 {
		t.Errorf("discoverHostSocketPath() = %q, seems too short", path)
	}
}

func TestHostAttachRPCRouting(t *testing.T) {
	// Verify the new RPC methods are routed correctly (without actual socket)
	server := &rpcServer{
		nextStreamID:  1,
		nextSessionID: 1,
		streams:       map[string]*streamState{},
		sessions:      map[string]*sessionState{},
	}

	// Force isolation: point to a non-existent socket so tests don't depend on host cmux
	t.Setenv("CMUX_HOST_SOCKET_PATH", filepath.Join(t.TempDir(), "nope.sock"))

	// host.surface.list should fail gracefully (no socket) but not panic
	resp := server.handleRequest(rpcRequest{
		ID:     "test-1",
		Method: "host.surface.list",
		Params: map[string]any{},
	})
	if resp.OK {
		t.Error("host.surface.list should fail without host cmux socket")
	}

	// host.surface.send_text should validate params
	resp = server.handleRequest(rpcRequest{
		ID:     "test-2",
		Method: "host.surface.send_text",
		Params: map[string]any{},
	})
	if resp.OK {
		t.Error("host.surface.send_text should fail without surface_id")
	}
	if resp.Error == nil || resp.Error.Code != "invalid_params" {
		t.Errorf("expected invalid_params error, got %v", resp.Error)
	}

	// host.attach should validate params
	resp = server.handleRequest(rpcRequest{
		ID:     "test-3",
		Method: "host.attach",
		Params: map[string]any{},
	})
	if resp.OK {
		t.Error("host.attach should fail without surface_id")
	}

	// host.detach should handle missing attach_id
	resp = server.handleRequest(rpcRequest{
		ID:     "test-4",
		Method: "host.detach",
		Params: map[string]any{},
	})
	if resp.OK {
		t.Error("host.detach should fail without attach_id")
	}
}

func TestHostAttachCapability(t *testing.T) {
	server := &rpcServer{
		nextStreamID:  1,
		nextSessionID: 1,
		streams:       map[string]*streamState{},
		sessions:      map[string]*sessionState{},
	}

	resp := server.handleRequest(rpcRequest{
		ID:     "hello-1",
		Method: "hello",
	})
	if !resp.OK {
		t.Fatal("hello should succeed")
	}

	result, ok := resp.Result.(map[string]any)
	if !ok {
		t.Fatal("hello result should be a map")
	}

	caps, ok := result["capabilities"].([]string)
	if !ok {
		t.Fatal("capabilities should be a string slice")
	}

	found := false
	for _, c := range caps {
		if c == "host.attach" {
			found = true
			break
		}
	}
	if !found {
		capsJSON, _ := json.Marshal(caps)
		t.Errorf("host.attach capability not found in %s", capsJSON)
	}
}
