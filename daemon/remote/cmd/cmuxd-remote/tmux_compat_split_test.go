package main

import (
	"bufio"
	"encoding/json"
	"net"
	"sync"
	"testing"
)

type splitRecorder struct {
	socketPath string
	// Set before the listener starts and never written afterwards, so the
	// server goroutine reads them without synchronization.
	acceptSplits bool
	failSendText bool
	mu           sync.Mutex
	requests     []tmuxCorpusRPCRequest
}

// acceptSplits answers surface.split the way a workspace routed to a remote
// tmux mirror does: an asynchronous acceptance without a local surface id.
// failSendText makes surface.send_text fail, covering the rollback path.
func startSplitRecorder(t *testing.T) *splitRecorder {
	t.Helper()
	return startSplitRecorderWith(t, false, false)
}

func startSplitRecorderWith(t *testing.T, acceptSplits bool, failSendText bool) *splitRecorder {
	t.Helper()

	recorder := &splitRecorder{
		socketPath:   makeShortUnixSocketPath(t),
		acceptSplits: acceptSplits,
		failSendText: failSendText,
	}
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
						if recorder.acceptSplits {
							result = map[string]any{"accepted": true, "routed": "remote-tmux", "surface_id": nil}
						} else {
							result = map[string]any{
								"surface_id": "77777777-7777-4777-8777-777777777777",
								"pane_id":    "66666666-6666-4666-8666-666666666666",
							}
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
					if recorder.failSendText && method == "surface.send_text" {
						payload, _ := json.Marshal(map[string]any{
							"id": request["id"], "ok": false,
							"error": map[string]any{"code": "unavailable", "message": "recorder refused the text"},
						})
						_, _ = conn.Write(append(payload, '\n'))
						continue
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

func (r *splitRecorder) record(method string, params map[string]any) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.requests = append(r.requests, tmuxCorpusRPCRequest{Method: method, Params: params})
}

func (r *splitRecorder) request(method string) (map[string]any, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	for _, request := range r.requests {
		if request.Method == method {
			return request.Params, true
		}
	}
	return nil, false
}

func (r *splitRecorder) count(method string) int {
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

func tmuxSplitEnv(t *testing.T) string {
	t.Helper()
	t.Setenv("CMUX_WORKSPACE_ID", "workspace:1")
	t.Setenv("CMUX_SURFACE_ID", "surface:1")
	t.Setenv("TMUX_PANE", "%"+tmuxStableNumericId("33333333-3333-4333-8333-333333333333"))
	return t.TempDir()
}

func TestTmuxSplitWindowMirrorRoutedPlainSplitSkipsLocalWork(t *testing.T) {
	tmuxSplitEnv(t)
	recorder := startSplitRecorderWith(t, true, false)
	rc := &rpcContext{socketPath: recorder.socketPath}

	_ = captureStdout(t, func() {
		if err := dispatchTmuxCommand(rc, "split-window", []string{"-v", "-d"}); err != nil {
			t.Fatalf("split-window: %v", err)
		}
	})

	params, ok := recorder.request("surface.split")
	if !ok {
		t.Fatal("expected a surface.split call")
	}
	if params["remote_tmux_unsupported_options"] != nil {
		t.Fatalf("a plain split must not name unsupported options: %v", params)
	}
	if recorder.count("surface.send_text") != 0 {
		t.Fatal("a mirror-routed split has no local surface to type into")
	}
	if recorder.count("workspace.equalize_splits") != 0 {
		t.Fatal("a mirror-routed split must not equalize the local layout")
	}
}

func TestTmuxSplitWindowClosesPaneWhenCommandDeliveryFails(t *testing.T) {
	tmuxSplitEnv(t)
	recorder := startSplitRecorderWith(t, false, true)
	rc := &rpcContext{socketPath: recorder.socketPath}

	var splitErr error
	_ = captureStdout(t, func() {
		splitErr = dispatchTmuxCommand(rc, "split-window", []string{"-v", "-d", "echo", "hello"})
	})
	if splitErr == nil {
		t.Fatal("a split whose command never reached the shell must fail")
	}
	closeParams, ok := recorder.request("surface.close")
	if !ok {
		t.Fatal("the failed split must close the pane it created")
	}
	if closeParams["surface_id"] != "77777777-7777-4777-8777-777777777777" {
		t.Fatalf("rollback must close the created surface: %v", closeParams)
	}
}

func TestTmuxSplitWindowForwardsCommandForOrdinarySplit(t *testing.T) {
	tmuxSplitEnv(t)
	recorder := startSplitRecorder(t)
	rc := &rpcContext{socketPath: recorder.socketPath}

	_ = captureStdout(t, func() {
		if err := dispatchTmuxCommand(rc, "split-window", []string{"-v", "-d", "echo", "omp hud"}); err != nil {
			t.Fatalf("split-window: %v", err)
		}
	})

	params, ok := recorder.request("surface.split")
	if !ok {
		t.Fatal("expected a surface.split call")
	}
	if params["initial_command"] != nil || params["tmux_start_command"] != nil {
		t.Fatalf("a split must not carry command-bearing parameters: %v", params)
	}
	options, _ := params["remote_tmux_unsupported_options"].([]any)
	if len(options) != 1 || options[0] != "initial_command" {
		t.Fatalf("a command-carrying split must name the command as an unsupported option: %v", params)
	}
	if recorder.count("surface.send_text") != 1 {
		t.Fatal("a local split must type its command")
	}
	if recorder.count("workspace.equalize_splits") != 1 {
		t.Fatal("an ordinary split is equalized")
	}
}

func TestTmuxSplitWindowForwardsPrintRequestAsUnsupportedRemoteOption(t *testing.T) {
	tmuxSplitEnv(t)
	recorder := startSplitRecorder(t)
	rc := &rpcContext{socketPath: recorder.socketPath}

	_ = captureStdout(t, func() {
		if err := dispatchTmuxCommand(rc, "split-window", []string{"-v", "-d", "-P", "-F", "#{pane_id}"}); err != nil {
			t.Fatalf("split-window: %v", err)
		}
	})

	params, ok := recorder.request("surface.split")
	if !ok {
		t.Fatal("expected a surface.split call")
	}
	options, _ := params["remote_tmux_unsupported_options"].([]any)
	if len(options) != 1 || options[0] != "-P" {
		t.Fatalf("a print request must carry remote_tmux_unsupported_options=[\"-P\"]: %v", params)
	}
}
