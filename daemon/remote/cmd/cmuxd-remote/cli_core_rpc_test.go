package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestCoreRPCNamesAreNotImplicitAliases(t *testing.T) {
	for _, tc := range []struct {
		args   []string
		method string
	}{
		{[]string{"--json", "rpc", "ping", "{}"}, "ping"},
		{[]string{"--json", "rpc", "capabilities", "{}"}, "capabilities"},
		{[]string{"--json", "list-workspaces"}, "workspace.list"},
		{[]string{"--json", "rpc", "system.ping", "{}"}, "system.ping"},
		{[]string{"--json", "rpc", "system.capabilities", "{}"}, "system.capabilities"},
		{[]string{"--json", "ping"}, "system.ping"},
		{[]string{"--json", "capabilities"}, "system.capabilities"},
	} {
		t.Run(strings.Join(tc.args, " "), func(t *testing.T) {
			path, requests := startMockV2SocketWithRequestCapture(t)
			t.Setenv("CMUX_SOCKET_PATH", path)
			if code := runCLI(tc.args); code != 0 {
				t.Fatalf("exit = %d", code)
			}
			request := receiveRequest(t, requests)
			if request["method"] != tc.method || len(params(request)) != 0 {
				t.Fatalf("unexpected wire request: %v", request)
			}
		})
	}
}

func TestCoreRPCAuthenticatedRelayFailuresExitNonzero(t *testing.T) {
	for _, code := range []string{"remote_relay_denied", "remote_relay_workspace_denied", "method_not_found"} {
		for _, args := range [][]string{
			{"--json", "rpc", "ping", "{}"},
			{"--json", "rpc", "capabilities", "{}"},
			{"--json", "list-workspaces"},
		} {
			t.Run(code+"/"+strings.Join(args, " "), func(t *testing.T) {
				relayID, token := "core-rpc-test", strings.Repeat("a1", 32)
				response, err := json.Marshal(map[string]any{
					"ok": false, "error": map[string]any{"code": code, "message": "denied"},
				})
				if err != nil {
					t.Fatal(err)
				}
				t.Setenv("CMUX_RELAY_ID", relayID)
				t.Setenv("CMUX_RELAY_TOKEN", token)
				t.Setenv("CMUX_SOCKET_PATH", startMockAuthenticatedTCPSocket(t, relayID, token, string(response)))
				output := captureStdout(t, func() {
					if status := runCLI(args); status != 1 {
						t.Errorf("exit = %d, want 1", status)
					}
				})
				if output != "" {
					t.Fatalf("failed RPC printed success output: %q", output)
				}
			})
		}
	}
}
