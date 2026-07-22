package main

import (
	"bufio"
	"encoding/json"
	"net"
	"strings"
	"sync"
	"testing"
)

// Regression coverage for https://github.com/manaflow-ai/cmux/issues/7014:
// the remote tmux-compat dispatcher must support respawn-pane/respawnp the
// same way the local Swift CLI does (resolve the target surface, forward to
// the surface.respawn RPC). Claude Code >= 2.1.183 launches agent-team
// teammate panes with `split-window … cat` followed by `respawn-pane -k …`,
// so a dispatcher without respawn-pane breaks teammate panes over SSH.
// Expected semantics mirror CLI/cmux.swift ("respawn-pane", "respawnp") and
// are pinned app-side by tests/test_cli_omo_tmux_respawn_pane.py.

const (
	tmuxRespawnWorkspaceId       = "11111111-1111-4111-8111-111111111111"
	tmuxRespawnLeaderPaneId      = "33333333-3333-4333-8333-333333333333"
	tmuxRespawnLeaderSurfaceId   = "44444444-4444-4444-8444-444444444444"
	tmuxRespawnTeammatePaneId    = "66666666-6666-4666-8666-666666666666"
	tmuxRespawnTeammateSurfaceId = "77777777-7777-4777-8777-777777777777"
)

type tmuxRespawnCallLog struct {
	mu    sync.Mutex
	calls []map[string]any
}

func (l *tmuxRespawnCallLog) append(params map[string]any) {
	l.mu.Lock()
	defer l.mu.Unlock()
	copied := make(map[string]any, len(params))
	for key, value := range params {
		copied[key] = value
	}
	l.calls = append(l.calls, copied)
}

func (l *tmuxRespawnCallLog) snapshot() []map[string]any {
	l.mu.Lock()
	defer l.mu.Unlock()
	return append([]map[string]any(nil), l.calls...)
}

// startTmuxRespawnRecordingSocket serves the minimal RPC surface needed to
// resolve a pane target (workspace.list, pane.list, pane.surfaces,
// surface.list) and records every surface.respawn call it receives.
// teammateStartCommand, when non-empty, is exposed as the teammate surface's
// tmux_start_command so the stored-start-command fallback can be exercised.
func startTmuxRespawnRecordingSocket(t *testing.T, teammateStartCommand string) (string, *tmuxRespawnCallLog) {
	t.Helper()
	sockPath := makeShortUnixSocketPath(t)
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatalf("failed to listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })

	log := &tmuxRespawnCallLog{}

	go func() {
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
							"id":     tmuxRespawnWorkspaceId,
							"ref":    "workspace:1",
							"index":  1,
							"title":  "demo",
							"active": true,
						}},
					}
				case "pane.list":
					resp["result"] = map[string]any{
						"panes": []map[string]any{
							{"id": tmuxRespawnLeaderPaneId, "ref": "pane:1", "index": 1, "focused": "1"},
							{"id": tmuxRespawnTeammatePaneId, "ref": "pane:2", "index": 2, "focused": "0"},
						},
					}
				case "pane.surfaces":
					paneId, _ := params["pane_id"].(string)
					surface := map[string]any{
						"id":       tmuxRespawnLeaderSurfaceId,
						"ref":      "surface:1",
						"selected": "1",
					}
					if paneId == tmuxRespawnTeammatePaneId {
						surface = map[string]any{
							"id":       tmuxRespawnTeammateSurfaceId,
							"ref":      "surface:2",
							"selected": "1",
						}
					}
					resp["result"] = map[string]any{"surfaces": []map[string]any{surface}}
				case "surface.list":
					teammate := map[string]any{
						"id":      tmuxRespawnTeammateSurfaceId,
						"ref":     "surface:2",
						"pane_id": tmuxRespawnTeammatePaneId,
					}
					if teammateStartCommand != "" {
						teammate["tmux_start_command"] = teammateStartCommand
					}
					resp["result"] = map[string]any{
						"surfaces": []map[string]any{
							{
								"id":      tmuxRespawnLeaderSurfaceId,
								"ref":     "surface:1",
								"pane_id": tmuxRespawnLeaderPaneId,
							},
							teammate,
						},
					}
				case "surface.respawn":
					log.append(params)
					resp["result"] = map[string]any{}
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

	return sockPath, log
}

func setTmuxRespawnCallerEnv(t *testing.T) {
	t.Helper()
	t.Setenv("HOME", t.TempDir())
	t.Setenv("CMUX_WORKSPACE_ID", "workspace:1")
	t.Setenv("CMUX_SURFACE_ID", "surface:1")
	t.Setenv("TMUX_PANE", "%"+tmuxStableNumericId(tmuxRespawnLeaderPaneId))
	// Never inherit an ambient claude-teams sandbox opt-in from the host
	// running the tests; the opt-in case sets this explicitly.
	t.Setenv("CMUX_CLAUDE_TEAMS_SANDBOXED", "")
}

func tmuxRespawnTeammateTarget() string {
	return "%" + tmuxStableNumericId(tmuxRespawnTeammatePaneId)
}

func singleRespawnCall(t *testing.T, log *tmuxRespawnCallLog) map[string]any {
	t.Helper()
	calls := log.snapshot()
	if len(calls) != 1 {
		t.Fatalf("surface.respawn calls = %d, want 1 (calls: %v)", len(calls), calls)
	}
	return calls[0]
}

func TestTmuxRespawnPaneForwardsToSurfaceRespawn(t *testing.T) {
	for _, command := range []string{"respawn-pane", "respawnp"} {
		t.Run(command, func(t *testing.T) {
			setTmuxRespawnCallerEnv(t)
			sockPath, log := startTmuxRespawnRecordingSocket(t, "")
			rc := &rpcContext{socketPath: sockPath}

			err := dispatchTmuxCommand(rc, command, []string{
				"-k", "-t", tmuxRespawnTeammateTarget(), "--", "echo", "hi",
			})
			if err != nil {
				t.Fatalf("%s: %v", command, err)
			}

			params := singleRespawnCall(t, log)
			if got, _ := params["workspace_id"].(string); got != tmuxRespawnWorkspaceId {
				t.Errorf("workspace_id = %q, want %q", got, tmuxRespawnWorkspaceId)
			}
			if got, _ := params["surface_id"].(string); got != tmuxRespawnTeammateSurfaceId {
				t.Errorf("surface_id = %q, want %q", got, tmuxRespawnTeammateSurfaceId)
			}
			// The pane process command is shell-invoked (issue #6447) while the
			// tmux_start_command metadata stays raw for display/persistence.
			if got, _ := params["command"].(string); got != "/bin/sh -c 'echo hi'" {
				t.Errorf("command = %q, want %q", got, "/bin/sh -c 'echo hi'")
			}
			if got, _ := params["tmux_start_command"].(string); got != "echo hi" {
				t.Errorf("tmux_start_command = %q, want %q", got, "echo hi")
			}
			if cwd, ok := params["working_directory"]; ok {
				t.Errorf("working_directory should be absent without -c, got %v", cwd)
			}
		})
	}
}

func TestTmuxRespawnPaneRequiresKillFlag(t *testing.T) {
	setTmuxRespawnCallerEnv(t)
	sockPath, log := startTmuxRespawnRecordingSocket(t, "")
	rc := &rpcContext{socketPath: sockPath}

	err := dispatchTmuxCommand(rc, "respawn-pane", []string{
		"-t", tmuxRespawnTeammateTarget(), "--", "echo", "hi",
	})
	if err == nil {
		t.Fatal("respawn-pane without -k should fail")
	}
	if !strings.Contains(err.Error(), "requires -k") {
		t.Fatalf("error = %q, want it to mention the required -k flag", err.Error())
	}
	if calls := log.snapshot(); len(calls) != 0 {
		t.Fatalf("surface.respawn must not be called without -k, got %v", calls)
	}
}

func TestTmuxRespawnPaneWithoutCommandReusesStoredStartCommand(t *testing.T) {
	const stored = `/bin/sh -c "opencode attach http://127.0.0.1:4096 --session subagent-session"`
	setTmuxRespawnCallerEnv(t)
	sockPath, log := startTmuxRespawnRecordingSocket(t, stored)
	rc := &rpcContext{socketPath: sockPath}

	err := dispatchTmuxCommand(rc, "respawn-pane", []string{
		"-k", "-t", tmuxRespawnTeammateTarget(),
	})
	if err != nil {
		t.Fatalf("respawn-pane: %v", err)
	}

	params := singleRespawnCall(t, log)
	if got, _ := params["surface_id"].(string); got != tmuxRespawnTeammateSurfaceId {
		t.Errorf("surface_id = %q, want %q", got, tmuxRespawnTeammateSurfaceId)
	}
	if got, _ := params["command"].(string); got != "/bin/sh -c '"+stored+"'" {
		t.Errorf("command = %q, want stored start command shell-invoked", got)
	}
	if got, _ := params["tmux_start_command"].(string); got != stored {
		t.Errorf("tmux_start_command = %q, want stored start command %q", got, stored)
	}
}

func TestTmuxRespawnPaneWithoutCommandFallsBackToLoginShell(t *testing.T) {
	setTmuxRespawnCallerEnv(t)
	sockPath, log := startTmuxRespawnRecordingSocket(t, "")
	rc := &rpcContext{socketPath: sockPath}

	err := dispatchTmuxCommand(rc, "respawn-pane", []string{
		"-k", "-t", tmuxRespawnTeammateTarget(),
	})
	if err != nil {
		t.Fatalf("respawn-pane: %v", err)
	}

	params := singleRespawnCall(t, log)
	if got, _ := params["command"].(string); got != `/bin/sh -c 'exec ${SHELL:-/bin/sh} -l'` {
		t.Errorf("command = %q, want login shell fallback", got)
	}
	if got, _ := params["tmux_start_command"].(string); got != `exec ${SHELL:-/bin/sh} -l` {
		t.Errorf("tmux_start_command = %q, want login shell fallback", got)
	}
}

func TestTmuxRespawnPaneHonorsCwdAndClaudeTeamsSandboxOptIn(t *testing.T) {
	setTmuxRespawnCallerEnv(t)
	t.Setenv("CMUX_CLAUDE_TEAMS_SANDBOXED", "1")
	cwd := t.TempDir()
	sockPath, log := startTmuxRespawnRecordingSocket(t, "")
	rc := &rpcContext{socketPath: sockPath}

	err := dispatchTmuxCommand(rc, "respawn-pane", []string{
		"-k", "-c", cwd, "-t", tmuxRespawnTeammateTarget(), "--", "echo", "hi",
	})
	if err != nil {
		t.Fatalf("respawn-pane: %v", err)
	}

	params := singleRespawnCall(t, log)
	if got, _ := params["working_directory"].(string); got != cwd {
		t.Errorf("working_directory = %q, want %q", got, cwd)
	}
	// The sandbox opt-in recorded by the claude-teams launcher is re-exported
	// inside the wrapping shell (see tmuxClaudeTeamsRespawnEnvironment in
	// CLI/CMUXCLI+TmuxCompatSupport.swift) but never baked into the raw
	// tmux_start_command metadata.
	want := `/bin/sh -c 'export CLAUDE_CODE_SANDBOXED='"'"'1'"'"'; echo hi'`
	if got, _ := params["command"].(string); got != want {
		t.Errorf("command = %q, want %q", got, want)
	}
	if got, _ := params["tmux_start_command"].(string); got != "echo hi" {
		t.Errorf("tmux_start_command = %q, want raw command without sandbox export", got)
	}
}
