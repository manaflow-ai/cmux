package main

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"testing"
)

func startMockTmuxCompatSocket(t *testing.T) string {
	t.Helper()
	sockPath := makeShortUnixSocketPath(t)

	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatalf("failed to listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

	go func() {
		splitCreated := false
		for {
			conn, err := ln.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				reader := bufio.NewReader(conn)
				line, err := reader.ReadBytes('\n')
				if err != nil {
					return
				}

				var req map[string]any
				if err := json.Unmarshal(line, &req); err != nil {
					_, _ = conn.Write([]byte(`{"ok":false,"error":{"code":"parse","message":"bad json"}}` + "\n"))
					return
				}

				method, _ := req["method"].(string)
				params, _ := req["params"].(map[string]any)
				resp := map[string]any{
					"id": req["id"],
					"ok": true,
				}

				switch method {
				case "workspace.list":
					resp["result"] = map[string]any{
						"workspaces": []map[string]any{{
							"id":    "11111111-1111-4111-8111-111111111111",
							"ref":   "workspace:1",
							"index": 1,
							"title": "demo",
						}},
					}
				case "surface.list":
					surfaces := []map[string]any{{
						"id":      "44444444-4444-4444-8444-444444444444",
						"ref":     "surface:1",
						"focused": true,
						"pane_id": "33333333-3333-4333-8333-333333333333",
						"title":   "leader",
					}}
					if splitCreated {
						surfaces = append(surfaces, map[string]any{
							"id":      "77777777-7777-4777-8777-777777777777",
							"ref":     "surface:2",
							"focused": false,
							"pane_id": "66666666-6666-4666-8666-666666666666",
							"title":   "teammate",
						})
					}
					resp["result"] = map[string]any{"surfaces": surfaces}
				case "surface.current":
					resp["result"] = map[string]any{
						"workspace_id":  "11111111-1111-4111-8111-111111111111",
						"workspace_ref": "workspace:1",
						"pane_id":       "33333333-3333-4333-8333-333333333333",
						"pane_ref":      "pane:1",
						"surface_id":    "44444444-4444-4444-8444-444444444444",
						"surface_ref":   "surface:1",
					}
				case "pane.list":
					panes := []map[string]any{{
						"id":    "33333333-3333-4333-8333-333333333333",
						"ref":   "pane:1",
						"index": 1,
					}}
					if splitCreated {
						panes = append(panes, map[string]any{
							"id":    "66666666-6666-4666-8666-666666666666",
							"ref":   "pane:2",
							"index": 2,
						})
					}
					resp["result"] = map[string]any{"panes": panes}
				case "surface.split":
					if got, _ := params["surface_id"].(string); got != "44444444-4444-4444-8444-444444444444" {
						resp["ok"] = false
						resp["error"] = map[string]any{
							"code":    "not_found",
							"message": "Surface not found",
						}
						break
					}
					splitCreated = true
					resp["result"] = map[string]any{
						"surface_id": "77777777-7777-4777-8777-777777777777",
						"pane_id":    "66666666-6666-4666-8666-666666666666",
					}
				case "workspace.equalize_splits":
					resp["result"] = map[string]any{"ok": true}
				default:
					resp["ok"] = false
					resp["error"] = map[string]any{
						"code":    "unsupported",
						"message": method,
					}
				}

				payload, _ := json.Marshal(resp)
				_, _ = conn.Write(append(payload, '\n'))
			}(conn)
		}
	}()

	return sockPath
}

func TestTmuxSplitWindowCanonicalizesCallerSurfaceRefs(t *testing.T) {
	origHome := os.Getenv("HOME")
	origWorkspace := os.Getenv("CMUX_WORKSPACE_ID")
	origSurface := os.Getenv("CMUX_SURFACE_ID")
	origPane := os.Getenv("TMUX_PANE")
	os.Setenv("HOME", t.TempDir())
	os.Setenv("CMUX_WORKSPACE_ID", "workspace:1")
	os.Setenv("CMUX_SURFACE_ID", "surface:1")
	os.Setenv("TMUX_PANE", "%pane:1")
	defer func() {
		os.Setenv("HOME", origHome)
		if origWorkspace != "" {
			os.Setenv("CMUX_WORKSPACE_ID", origWorkspace)
		} else {
			os.Unsetenv("CMUX_WORKSPACE_ID")
		}
		if origSurface != "" {
			os.Setenv("CMUX_SURFACE_ID", origSurface)
		} else {
			os.Unsetenv("CMUX_SURFACE_ID")
		}
		if origPane != "" {
			os.Setenv("TMUX_PANE", origPane)
		} else {
			os.Unsetenv("TMUX_PANE")
		}
	}()

	sockPath := startMockTmuxCompatSocket(t)
	rc := &rpcContext{socketPath: sockPath}

	output := captureStdout(t, func() {
		if err := dispatchTmuxCommand(rc, "split-window", []string{"-h", "-P", "-F", "#{pane_id}"}); err != nil {
			t.Fatalf("split-window: %v", err)
		}
	})

	if got := output; got != "%66666666-6666-4666-8666-666666666666\n" {
		t.Fatalf("stdout = %q", got)
	}
}

func TestTmuxSplitWindowIgnoresStaleUUIDColumnSurface(t *testing.T) {
	origHome := os.Getenv("HOME")
	origWorkspace := os.Getenv("CMUX_WORKSPACE_ID")
	origSurface := os.Getenv("CMUX_SURFACE_ID")
	origPane := os.Getenv("TMUX_PANE")
	home := t.TempDir()
	os.Setenv("HOME", home)
	os.Setenv("CMUX_WORKSPACE_ID", "workspace:1")
	os.Setenv("CMUX_SURFACE_ID", "surface:1")
	os.Setenv("TMUX_PANE", "%pane:1")
	defer func() {
		os.Setenv("HOME", origHome)
		if origWorkspace != "" {
			os.Setenv("CMUX_WORKSPACE_ID", origWorkspace)
		} else {
			os.Unsetenv("CMUX_WORKSPACE_ID")
		}
		if origSurface != "" {
			os.Setenv("CMUX_SURFACE_ID", origSurface)
		} else {
			os.Unsetenv("CMUX_SURFACE_ID")
		}
		if origPane != "" {
			os.Setenv("TMUX_PANE", origPane)
		} else {
			os.Unsetenv("TMUX_PANE")
		}
	}()

	storePath := filepath.Join(home, ".cmuxterm", "tmux-compat-store.json")
	if err := os.MkdirAll(filepath.Dir(storePath), 0o755); err != nil {
		t.Fatalf("mkdir store dir: %v", err)
	}
	storeBytes, err := json.Marshal(tmuxCompatStore{
		Buffers: make(map[string]string),
		Hooks:   make(map[string]string),
		MainVerticalLayouts: map[string]mainVerticalState{
			"11111111-1111-4111-8111-111111111111": {
				MainSurfaceId:       "44444444-4444-4444-8444-444444444444",
				LastColumnSurfaceId: "77777777-7777-4777-8777-777777777777",
			},
		},
		LastSplitSurface: map[string]string{
			"11111111-1111-4111-8111-111111111111": "77777777-7777-4777-8777-777777777777",
		},
	})
	if err != nil {
		t.Fatalf("marshal store: %v", err)
	}
	if err := os.WriteFile(storePath, storeBytes, 0o644); err != nil {
		t.Fatalf("write store: %v", err)
	}

	sockPath := startMockTmuxCompatSocket(t)
	rc := &rpcContext{socketPath: sockPath}

	output := captureStdout(t, func() {
		if err := dispatchTmuxCommand(rc, "split-window", []string{"-h", "-P", "-F", "#{pane_id}"}); err != nil {
			t.Fatalf("split-window: %v", err)
		}
	})

	if got := output; got != "%66666666-6666-4666-8666-666666666666\n" {
		t.Fatalf("stdout = %q", got)
	}
}
