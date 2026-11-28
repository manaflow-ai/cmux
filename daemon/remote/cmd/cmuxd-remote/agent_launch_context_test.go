package main

import (
	"bufio"
	"encoding/json"
	"errors"
	"net"
	"os"
	"sync"
	"testing"
	"time"
)

const (
	agentLaunchTestWorkspaceId = "11111111-1111-4111-8111-111111111111"
	agentLaunchTestPaneId      = "33333333-3333-4333-8333-333333333333"
	agentLaunchTestSurfaceId   = "44444444-4444-4444-8444-444444444444"
)

func TestInheritedAgentLaunchContextUsesCallerSurfaceWithoutGlobalFocus(t *testing.T) {
	socketPath, recordedRequests := startAgentLaunchContextSocket(t, true)
	t.Setenv("CMUX_WORKSPACE_ID", agentLaunchTestWorkspaceId)
	t.Setenv("CMUX_SURFACE_ID", agentLaunchTestSurfaceId)

	context := inheritedAgentLaunchContextWithTimeout(
		&rpcContext{socketPath: socketPath},
		time.Second,
	)
	if context == nil {
		t.Fatal("inheritedAgentLaunchContextWithTimeout returned nil")
	}
	if context.workspaceId != agentLaunchTestWorkspaceId {
		t.Fatalf("workspaceId = %q", context.workspaceId)
	}
	if context.surfaceId != agentLaunchTestSurfaceId {
		t.Fatalf("surfaceId = %q", context.surfaceId)
	}
	if context.paneId != agentLaunchTestPaneId {
		t.Fatalf("paneId = %q", context.paneId)
	}
	for _, request := range recordedRequests() {
		if request["method"] == "system.identify" {
			t.Fatalf("managed launch consulted global focus: %v", recordedRequests())
		}
	}
}

func TestInheritedAgentLaunchContextRelocatesMovedSurfaceByStableId(t *testing.T) {
	socketPath, recordedRequests := startMovedAgentLaunchContextSocket(t)
	t.Setenv("CMUX_WORKSPACE_ID", agentLaunchTestWorkspaceId)
	t.Setenv("CMUX_SURFACE_ID", agentLaunchTestSurfaceId)

	context := inheritedAgentLaunchContextWithTimeout(
		&rpcContext{socketPath: socketPath},
		time.Second,
	)
	if context == nil {
		t.Fatal("inheritedAgentLaunchContextWithTimeout returned nil")
	}
	const movedWorkspaceId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
	if context.workspaceId != movedWorkspaceId {
		t.Fatalf("workspaceId = %q, want moved workspace %q", context.workspaceId, movedWorkspaceId)
	}
	if context.surfaceId != agentLaunchTestSurfaceId {
		t.Fatalf("surfaceId = %q", context.surfaceId)
	}

	requests := recordedRequests()
	foundRelocationLookup := false
	for _, request := range requests {
		if request["method"] == "system.identify" {
			t.Fatalf("moved-surface relocation consulted global focus: %v", requests)
		}
		if request["method"] != "surface.list" {
			continue
		}
		params, _ := request["params"].(map[string]any)
		if stringFromAnyGo(params["surface_id"]) == agentLaunchTestSurfaceId {
			foundRelocationLookup = true
		}
	}
	if !foundRelocationLookup {
		t.Fatalf("moved surface was not relocated through surface.list(surface_id:): %v", requests)
	}
}

func TestAgentLaunchContextFailsClosedForMissingOrStaleIdentity(t *testing.T) {
	t.Run("missing pair does not open socket", func(t *testing.T) {
		socketPath, recordedRequests := startAgentLaunchContextSocket(t, true)
		t.Setenv("CMUX_WORKSPACE_ID", agentLaunchTestWorkspaceId)
		t.Setenv("CMUX_SURFACE_ID", "")
		rc := &rpcContext{socketPath: socketPath}

		if context, err := agentLaunchContextForInvocation(rc, true); context != nil || err != nil {
			t.Fatalf("non-launch context = %#v, err = %v", context, err)
		}
		if _, err := agentLaunchContextForInvocation(rc, false); !errors.Is(err, errAgentLaunchContextRequired) {
			t.Fatalf("launch error = %v, want %v", err, errAgentLaunchContextRequired)
		}
		if requests := recordedRequests(); len(requests) != 0 {
			t.Fatalf("missing inherited pair opened socket: %v", requests)
		}
	})

	t.Run("stale surface never falls back to focus", func(t *testing.T) {
		socketPath, recordedRequests := startAgentLaunchContextSocket(t, false)
		t.Setenv("CMUX_WORKSPACE_ID", agentLaunchTestWorkspaceId)
		t.Setenv("CMUX_SURFACE_ID", agentLaunchTestSurfaceId)
		rc := &rpcContext{socketPath: socketPath}

		if _, err := agentLaunchContextForInvocation(rc, false); !errors.Is(err, errAgentLaunchContextRequired) {
			t.Fatalf("launch error = %v, want %v", err, errAgentLaunchContextRequired)
		}
		for _, request := range recordedRequests() {
			if request["method"] == "system.identify" {
				t.Fatalf("stale inherited identity consulted global focus: %v", recordedRequests())
			}
		}
	})
}

func TestConfigureAgentEnvironmentClearsRejectedRoutingIdentity(t *testing.T) {
	for _, key := range []string{
		"PATH",
		"TMUX",
		"TMUX_PANE",
		"TERM",
		"CMUX_SOCKET_PATH",
		"CMUX_SOCKET",
		"TERM_PROGRAM",
		"COLORTERM",
		"CMUX_AGENT_LAUNCH_TEST_BIN",
		"CMUX_AGENT_LAUNCH_TEST_TERM",
	} {
		t.Setenv(key, os.Getenv(key))
	}
	for _, key := range []string{
		"CMUX_WORKSPACE_ID",
		"CMUX_SURFACE_ID",
		"CMUX_PANEL_ID",
		"CMUX_TAB_ID",
		"CMUX_PANE_ID",
	} {
		t.Setenv(key, "stale-"+key)
	}
	t.Setenv("PATH", "/usr/bin:/bin")

	configureAgentEnvironment(agentConfig{
		shimDir:        t.TempDir(),
		socketPath:     "/tmp/cmux-agent-launch-test.sock",
		launchContext:  nil,
		tmuxPathPrefix: "cmux-agent-launch-test",
		cmuxBinEnvVar:  "CMUX_AGENT_LAUNCH_TEST_BIN",
		termEnvVar:     "CMUX_AGENT_LAUNCH_TEST_TERM",
		extraEnv:       map[string]string{},
	})

	for _, key := range []string{
		"CMUX_WORKSPACE_ID",
		"CMUX_SURFACE_ID",
		"CMUX_PANEL_ID",
		"CMUX_TAB_ID",
		"CMUX_PANE_ID",
	} {
		if value, present := os.LookupEnv(key); present {
			t.Errorf("%s leaked rejected value %q", key, value)
		}
	}
}

func TestAgentLaunchRPCSocketHandlesMultipleRequestsPerConnection(t *testing.T) {
	socketPath, recordedRequests := startAgentLaunchRPCSocket(
		t,
		func(method string, _ map[string]any) (map[string]any, bool) {
			if method == "surface.list" {
				return map[string]any{"surfaces": []map[string]any{}}, true
			}
			return nil, false
		},
	)
	connection, err := net.Dial("unix", socketPath)
	if err != nil {
		t.Fatal(err)
	}
	defer connection.Close()
	encoder := json.NewEncoder(connection)
	decoder := json.NewDecoder(connection)

	for _, request := range []map[string]any{
		{"id": "first", "method": "surface.list", "params": map[string]any{}},
		{"id": "second", "method": "pane.list", "params": map[string]any{}},
	} {
		if err := encoder.Encode(request); err != nil {
			t.Fatal(err)
		}
		var response map[string]any
		if err := decoder.Decode(&response); err != nil {
			t.Fatal(err)
		}
		if response["id"] != request["id"] || response["ok"] != true {
			t.Fatalf("response = %#v for request %#v", response, request)
		}
	}

	requests := recordedRequests()
	if len(requests) != 2 || requests[0]["method"] != "surface.list" || requests[1]["method"] != "pane.list" {
		t.Fatalf("recorded requests = %#v", requests)
	}
}

func startAgentLaunchContextSocket(t *testing.T, surfaceExists bool) (string, func() []map[string]any) {
	t.Helper()
	return startAgentLaunchRPCSocket(t, func(method string, _ map[string]any) (map[string]any, bool) {
		if method != "surface.list" {
			return nil, false
		}
		surfaces := []map[string]any{}
		if surfaceExists {
			surfaces = append(surfaces, map[string]any{
				"id":       agentLaunchTestSurfaceId,
				"ref":      "surface:1",
				"pane_id":  agentLaunchTestPaneId,
				"pane_ref": "pane:1",
			})
		}
		return map[string]any{
			"workspace_id": agentLaunchTestWorkspaceId,
			"window_id":    "22222222-2222-4222-8222-222222222222",
			"surfaces":     surfaces,
		}, true
	})
}

func startMovedAgentLaunchContextSocket(t *testing.T) (string, func() []map[string]any) {
	t.Helper()
	const movedWorkspaceId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
	return startAgentLaunchRPCSocket(t, func(method string, params map[string]any) (map[string]any, bool) {
		if method != "surface.list" {
			return nil, false
		}
		if stringFromAnyGo(params["surface_id"]) == agentLaunchTestSurfaceId {
			return map[string]any{
				"workspace_id": movedWorkspaceId,
				"window_id":    "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
				"surfaces": []map[string]any{{
					"id":       agentLaunchTestSurfaceId,
					"ref":      "surface:1",
					"pane_id":  agentLaunchTestPaneId,
					"pane_ref": "pane:1",
				}},
			}, true
		}
		return map[string]any{
			"workspace_id": agentLaunchTestWorkspaceId,
			"surfaces":     []map[string]any{},
		}, true
	})
}

func startAgentLaunchRPCSocket(
	t *testing.T,
	respond func(method string, params map[string]any) (map[string]any, bool),
) (string, func() []map[string]any) {
	t.Helper()
	socketPath := makeShortUnixSocketPath(t)
	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		t.Fatalf("failed to listen: %v", err)
	}
	t.Cleanup(func() { _ = listener.Close() })

	var mutex sync.Mutex
	requests := []map[string]any{}
	recordedRequests := func() []map[string]any {
		mutex.Lock()
		defer mutex.Unlock()
		return append([]map[string]any(nil), requests...)
	}

	go func() {
		for {
			connection, err := listener.Accept()
			if err != nil {
				return
			}
			go func(connection net.Conn) {
				defer connection.Close()
				reader := bufio.NewReader(connection)
				for {
					line, err := reader.ReadBytes('\n')
					if err != nil {
						return
					}
					var request map[string]any
					if err := json.Unmarshal(line, &request); err != nil {
						return
					}
					mutex.Lock()
					requests = append(requests, request)
					mutex.Unlock()

					method, _ := request["method"].(string)
					params, _ := request["params"].(map[string]any)
					response := map[string]any{"id": request["id"], "ok": true}
					if method == "pane.list" {
						response["result"] = map[string]any{"panes": []map[string]any{{
							"id": agentLaunchTestPaneId, "ref": "pane:1", "index": 1,
						}}}
					} else if result, ok := respond(method, params); ok {
						response["result"] = result
					} else {
						response["ok"] = false
						response["error"] = map[string]any{"code": "unexpected", "message": method}
					}
					payload, _ := json.Marshal(response)
					if _, err := connection.Write(append(payload, '\n')); err != nil {
						return
					}
				}
			}(connection)
		}
	}()

	return socketPath, recordedRequests
}
