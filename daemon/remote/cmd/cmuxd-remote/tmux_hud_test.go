package main

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

func TestTmuxHudProviderForCommand(t *testing.T) {
	t.Setenv("CMUX_AGENT_LAUNCH_KIND", "")
	t.Setenv("CMUX_OMX_CMUX_BIN", "")
	t.Setenv("CMUX_OMP_CMUX_BIN", "")

	tests := []struct {
		name string
		args []string
		env  map[string]string
		want string
	}{
		{name: "no args", args: nil, want: ""},
		{name: "omp watch by name", args: []string{"node", "/opt/oh-my-pi/dist/omp.js", "hud", "--watch"}, want: "omp"},
		{name: "omx watch by name", args: []string{"node", "omx.js", "hud", "--watch"}, want: "omx"},
		{name: "prompt is not omp", args: []string{"prompt", "hud", "--watch"}, want: ""},
		{name: "hud alone is not a launch", args: []string{"echo", "hud"}, want: ""},
		{name: "provider without watch still matches by word", args: []string{"omp", "hud"}, want: "omp"},
		{name: "omp watch through shim env", args: []string{"hud", "--watch"}, env: map[string]string{"CMUX_OMP_CMUX_BIN": "/tmp/cmux"}, want: "omp"},
		{name: "omx shim env is ignored without watch", args: []string{"echo", "hud"}, env: map[string]string{"CMUX_OMX_CMUX_BIN": "/tmp/cmux"}, want: ""},
		{name: "launch kind wins over inherited shim", args: []string{"hud", "--watch"}, env: map[string]string{"CMUX_OMX_CMUX_BIN": "/tmp/cmux", "CMUX_AGENT_LAUNCH_KIND": "omp"}, want: "omp"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv("CMUX_AGENT_LAUNCH_KIND", "")
			t.Setenv("CMUX_OMX_CMUX_BIN", "")
			t.Setenv("CMUX_OMP_CMUX_BIN", "")
			for key, value := range tt.env {
				t.Setenv(key, value)
			}
			if got := tmuxHudProviderForCommand(tt.args); got != tt.want {
				t.Fatalf("provider = %q, want %q", got, tt.want)
			}
		})
	}
}

func TestTmuxHudConfigDisablesHud(t *testing.T) {
	t.Setenv("OMX_HUD_ENABLED", "")
	t.Setenv("OMP_HUD_ENABLED", "")
	t.Setenv("OMP_HUD_DISABLED", "")
	t.Setenv("CMUX_OMP_HUD_ENABLED", "")

	home := t.TempDir()
	t.Setenv("HOME", home)

	t.Run("no config", func(t *testing.T) {
		if tmuxHudConfigDisablesHud("omp", t.TempDir()) {
			t.Fatal("empty cwd and home must not disable the HUD")
		}
	})

	t.Run("provider hud config", func(t *testing.T) {
		cwd := t.TempDir()
		directory := filepath.Join(cwd, ".omp")
		if err := os.MkdirAll(directory, 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		if err := os.WriteFile(filepath.Join(directory, "hud-config.json"), []byte(`{"enabled": false}`), 0o600); err != nil {
			t.Fatalf("write: %v", err)
		}
		if !tmuxHudConfigDisablesHud("omp", cwd) {
			t.Fatal("disabled .omp/hud-config.json must disable the HUD")
		}
		if tmuxHudConfigDisablesHud("omx", cwd) {
			t.Fatal("the omp config must not disable the omx HUD")
		}
	})

	t.Run("environment switch", func(t *testing.T) {
		t.Setenv("OMP_HUD_ENABLED", "0")
		if !tmuxHudConfigDisablesHud("omp", t.TempDir()) {
			t.Fatal("OMP_HUD_ENABLED=0 must disable the HUD")
		}
	})

	t.Run("shared config needs hud scoped keys", func(t *testing.T) {
		cwd := t.TempDir()
		directory := filepath.Join(cwd, ".omp")
		if err := os.MkdirAll(directory, 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
		if err := os.WriteFile(filepath.Join(directory, "config.json"), []byte(`{"unrelated": false}`), 0o600); err != nil {
			t.Fatalf("write: %v", err)
		}
		if tmuxHudConfigDisablesHud("omp", cwd) {
			t.Fatal("an unrelated key in .omp/config.json must not disable the HUD")
		}
	})
}

func TestTmuxInitialDividerPosition(t *testing.T) {
	pane := map[string]any{"columns": 120, "rows": 40}

	down, ok := tmuxInitialDividerPosition(pane, "down", 4)
	if !ok || down < 0.89 || down > 0.91 {
		t.Fatalf("down divider = %v ok=%v, want 0.9", down, ok)
	}

	up, ok := tmuxInitialDividerPosition(pane, "up", 4)
	if !ok || up < 0.09 || up > 0.11 {
		t.Fatalf("up divider = %v ok=%v, want 0.1", up, ok)
	}

	right, ok := tmuxInitialDividerPosition(pane, "right", 20)
	if !ok || right < 0.82 || right > 0.84 {
		t.Fatalf("right divider = %v ok=%v, want 100/120", right, ok)
	}

	if _, ok := tmuxInitialDividerPosition(pane, "down", 0); ok {
		t.Fatal("a non-positive cell count must not produce a divider")
	}
	if _, ok := tmuxInitialDividerPosition(nil, "down", 4); ok {
		t.Fatal("a missing pane must not produce a divider")
	}
}

type hudSplitRecorder struct {
	socketPath string
	mu         sync.Mutex
	requests   []tmuxCorpusRPCRequest
}

func startHudSplitRecorder(t *testing.T) *hudSplitRecorder {
	t.Helper()

	recorder := &hudSplitRecorder{socketPath: makeShortUnixSocketPath(t)}
	listener, err := net.Listen("unix", recorder.socketPath)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { listener.Close() })

	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func(conn net.Conn) {
				defer conn.Close()
				reader := bufio.NewReader(conn)
				for {
					line, err := reader.ReadBytes('\n')
					if err != nil {
						return
					}
					var request map[string]any
					if err := json.Unmarshal(line, &request); err != nil {
						return
					}
					method, _ := request["method"].(string)
					params, _ := request["params"].(map[string]any)
					recorder.record(method, params)

					result := map[string]any{}
					switch method {
					case "surface.split":
						result = map[string]any{
							"surface_id": "77777777-7777-4777-8777-777777777777",
							"pane_id":    "66666666-6666-4666-8666-666666666666",
						}
					case "pane.list":
						result = map[string]any{"panes": []any{map[string]any{
							"id":      "33333333-3333-4333-8333-333333333333",
							"ref":     "pane:1",
							"rows":    40,
							"columns": 120,
						}}}
					case "surface.list":
						result = map[string]any{"surfaces": []any{map[string]any{
							"id":       "44444444-4444-4444-8444-444444444444",
							"ref":      "surface:1",
							"pane_id":  "33333333-3333-4333-8333-333333333333",
							"pane_ref": "pane:1",
						}}}
					case "workspace.list":
						result = map[string]any{"workspaces": []any{map[string]any{
							"id":    "11111111-1111-4111-8111-111111111111",
							"ref":   "workspace:1",
							"index": 1,
						}}}
					case "surface.current":
						result = map[string]any{
							"workspace_id": "11111111-1111-4111-8111-111111111111",
							"pane_id":      "33333333-3333-4333-8333-333333333333",
							"surface_id":   "44444444-4444-4444-8444-444444444444",
						}
					}
					response := map[string]any{"id": request["id"], "ok": true, "result": result}
					payload, _ := json.Marshal(response)
					_, _ = conn.Write(append(payload, '\n'))
				}
			}(conn)
		}
	}()
	return recorder
}

func (r *hudSplitRecorder) record(method string, params map[string]any) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.requests = append(r.requests, tmuxCorpusRPCRequest{Method: method, Params: params})
}

func (r *hudSplitRecorder) request(method string) (map[string]any, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, request := range r.requests {
		if request.Method == method {
			return request.Params, true
		}
	}
	return nil, false
}

func (r *hudSplitRecorder) count(method string) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	total := 0
	for _, request := range r.requests {
		if request.Method == method {
			total++
		}
	}
	return total
}

func hudSplitEnv(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CMUX_WORKSPACE_ID", "workspace:1")
	t.Setenv("CMUX_SURFACE_ID", "surface:1")
	t.Setenv("TMUX_PANE", "%"+tmuxStableNumericId("33333333-3333-4333-8333-333333333333"))
	t.Setenv("CMUX_AGENT_LAUNCH_KIND", "")
	t.Setenv("CMUX_OMX_CMUX_BIN", "")
	t.Setenv("CMUX_OMP_CMUX_BIN", "cmux")
	return home
}

func TestTmuxSplitWindowHudPanesGetStartupMetadata(t *testing.T) {
	hudSplitEnv(t)
	recorder := startHudSplitRecorder(t)
	rc := &rpcContext{socketPath: recorder.socketPath}
	cwd := t.TempDir()

	_ = captureStdout(t, func() {
		if err := dispatchTmuxCommand(rc, "split-window", []string{
			"-v", "-d", "-l", "4", "-c", cwd,
			"node", "/opt/oh-my-pi/dist/omp.js", "hud", "--watch",
		}); err != nil {
			t.Fatalf("split-window: %v", err)
		}
	})

	params, ok := recorder.request("surface.split")
	if !ok {
		t.Fatal("expected a surface.split call")
	}
	if got := stringFromAnyGo(params["tmux_start_command"]); got == "" {
		t.Fatalf("HUD split must keep its raw start command: %v", params)
	}
	script := stringFromAnyGo(params["initial_command"])
	if script == "" {
		t.Fatalf("HUD split must launch through a startup script: %v", params)
	}
	if _, err := os.Stat(script); err != nil {
		t.Fatalf("startup script %q must exist: %v", script, err)
	}
	if _, ok := params["initial_divider_position"]; !ok {
		t.Fatalf("HUD split must request a compact divider position: %v", params)
	}
	if recorder.count("workspace.equalize_splits") != 0 {
		t.Fatal("a HUD split must not be equalized")
	}
	if recorder.count("surface.send_text") != 0 {
		t.Fatal("a HUD command must not be typed into a shell")
	}
}

func TestTmuxSplitWindowKeepsNonHudSplitsUnchanged(t *testing.T) {
	hudSplitEnv(t)
	recorder := startHudSplitRecorder(t)
	rc := &rpcContext{socketPath: recorder.socketPath}

	_ = captureStdout(t, func() {
		if err := dispatchTmuxCommand(rc, "split-window", []string{"-v", "-d", "echo", "hud"}); err != nil {
			t.Fatalf("split-window: %v", err)
		}
	})

	params, ok := recorder.request("surface.split")
	if !ok {
		t.Fatal("expected a surface.split call")
	}
	if params["initial_command"] != nil || params["tmux_start_command"] != nil {
		t.Fatalf("a lookalike command must not get HUD metadata: %v", params)
	}
	if recorder.count("surface.send_text") != 1 {
		t.Fatal("a non-HUD split still types its command")
	}
}

func TestTmuxSplitWindowSuppressesDisabledHud(t *testing.T) {
	hudSplitEnv(t)
	recorder := startHudSplitRecorder(t)
	rc := &rpcContext{socketPath: recorder.socketPath}
	cwd := t.TempDir()
	directory := filepath.Join(cwd, ".omp")
	if err := os.MkdirAll(directory, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(directory, "hud-config.json"), []byte(`{"enabled": false}`), 0o600); err != nil {
		t.Fatalf("write: %v", err)
	}

	if err := dispatchTmuxCommand(rc, "split-window", []string{
		"-v", "-d", "-c", cwd, "node", "/opt/oh-my-pi/dist/omp.js", "hud", "--watch",
	}); err != nil {
		t.Fatalf("split-window: %v", err)
	}

	if got := recorder.count("surface.split"); got != 0 {
		t.Fatalf("disabled HUD must not split, got %d surface.split calls", got)
	}
}
