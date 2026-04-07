package compat

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

type tmuxCommandResult struct {
	OK        bool
	Stdout    string
	Stderr    string
	ErrorCode string
}

type tmuxBackend interface {
	Name() string
	Exec(args ...string) tmuxCommandResult
}

type realTmuxBackend struct {
	socketName string
	tmpDir     string
}

func newRealTmuxBackend(t *testing.T) *realTmuxBackend {
	t.Helper()

	if _, err := exec.LookPath("tmux"); err != nil {
		t.Skip("tmux not available")
	}

	backend := &realTmuxBackend{
		socketName: fmt.Sprintf("p%d", time.Now().UnixNano()),
		tmpDir:     shortTempDir(t, "tmux-parity-"),
	}
	t.Cleanup(func() {
		_ = exec.Command("tmux", "-f", "/dev/null", "-L", backend.socketName, "kill-server").Run()
	})
	return backend
}

func (b *realTmuxBackend) Name() string { return "tmux" }

func (b *realTmuxBackend) Exec(args ...string) tmuxCommandResult {
	cmd := exec.Command("tmux", append([]string{"-f", "/dev/null", "-L", b.socketName}, args...)...)
	cmd.Env = append(os.Environ(), "TMUX_TMPDIR="+b.tmpDir, "TERM=xterm-256color")
	output, err := cmd.CombinedOutput()
	result := tmuxCommandResult{
		OK:     err == nil,
		Stdout: normalizeText(string(output)),
	}
	if err == nil {
		return result
	}
	result.Stderr = normalizeText(string(output))
	return result
}

type cmuxTmuxBackend struct {
	bin        string
	socketPath string
	client     *unixJSONRPCClient
}

func newCmuxTmuxBackend(t *testing.T) *cmuxTmuxBackend {
	t.Helper()

	bin := daemonBinary(t)
	socketPath := startUnixDaemon(t, bin)
	return &cmuxTmuxBackend{
		bin:        bin,
		socketPath: socketPath,
		client:     newUnixJSONRPCClient(t, socketPath),
	}
}

func (b *cmuxTmuxBackend) Name() string { return "cmuxd-remote" }

func (b *cmuxTmuxBackend) Exec(args ...string) tmuxCommandResult {
	argv := make([]any, 0, len(args))
	for _, arg := range args {
		argv = append(argv, arg)
	}
	response, err := callUnixJSONRPCUnchecked(b.client, map[string]any{
		"id":     "tmux",
		"method": "tmux.exec",
		"params": map[string]any{"argv": argv},
	})
	if err != nil {
		return tmuxCommandResult{
			OK:     false,
			Stderr: normalizeText(err.Error()),
		}
	}
	if ok, _ := response["ok"].(bool); !ok {
		errPayload, _ := response["error"].(map[string]any)
		return tmuxCommandResult{
			OK:        false,
			ErrorCode: stringValue(errPayload["code"]),
			Stderr:    normalizeText(stringValue(errPayload["message"])),
		}
	}
	resultPayload, _ := response["result"].(map[string]any)
	return tmuxCommandResult{
		OK:     true,
		Stdout: normalizeText(stringValue(resultPayload["stdout"])),
		Stderr: normalizeText(stringValue(resultPayload["stderr"])),
	}
}

type tmuxWindowState struct {
	Index  string          `json:"index"`
	Name   string          `json:"name"`
	Active string          `json:"active"`
	Panes  []tmuxPaneState `json:"panes"`
}

type tmuxPaneState struct {
	Index   string `json:"index"`
	Active  string `json:"active"`
	Capture string `json:"capture"`
}

type tmuxSessionState struct {
	Windows []tmuxWindowState `json:"windows"`
}

func TestTmuxParityCommonCommands(t *testing.T) {
	t.Parallel()

	real := newRealTmuxBackend(t)
	cmux := newCmuxTmuxBackend(t)
	readyScript := fixturePath(t, "ready_cat.sh")

	mustBothSucceed(t, "new-session", real, cmux, "new-session", "-d", "-s", "parity", "-n", "alpha", "/bin/sh", readyScript)
	waitForCaptureContains(t, real, "parity:0.0", "READY", 3*time.Second)
	waitForCaptureContains(t, cmux, "parity:0.0", "READY", 3*time.Second)
	assertSessionStateEqual(t, "after-new-session", real, cmux, "parity")

	assertBothOK(t, "has-session", real.Exec("has-session", "-t", "parity"), cmux.Exec("has-session", "-t", "parity"))

	mustBothSucceed(t, "send-keys-text", real, cmux, "send-keys", "-t", "parity:0.0", "-l", "parity-hello")
	mustBothSucceed(t, "send-keys-enter", real, cmux, "send-keys", "-t", "parity:0.0", "Enter")
	waitForCaptureContains(t, real, "parity:0.0", "parity-hello", 3*time.Second)
	waitForCaptureContains(t, cmux, "parity:0.0", "parity-hello", 3*time.Second)
	assertNormalizedStdoutEqual(t, "capture-pane", real.Exec("capture-pane", "-p", "-t", "parity:0.0", "-S", "-5"), cmux.Exec("capture-pane", "-p", "-t", "parity:0.0", "-S", "-5"))

	displayFormat := "#{session_name}|#{window_name}|#{window_index}|#{window_active}|#{pane_index}|#{pane_active}"
	assertNormalizedStdoutEqual(t, "display-message", real.Exec("display-message", "-p", "-t", "parity:0.0", displayFormat), cmux.Exec("display-message", "-p", "-t", "parity:0.0", displayFormat))

	mustBothSucceed(t, "new-window", real, cmux, "new-window", "-d", "-t", "parity", "-n", "beta", "/bin/sh", readyScript)
	waitForCaptureContains(t, real, "parity:1.0", "READY", 3*time.Second)
	waitForCaptureContains(t, cmux, "parity:1.0", "READY", 3*time.Second)
	mustBothSucceed(t, "rename-window", real, cmux, "rename-window", "-t", "parity:1", "gamma")
	assertNormalizedStdoutEqual(t, "list-windows", real.Exec("list-windows", "-t", "parity", "-F", "#{window_index}|#{window_name}|#{window_active}"), cmux.Exec("list-windows", "-t", "parity", "-F", "#{window_index}|#{window_name}|#{window_active}"))

	mustBothSucceed(t, "select-window", real, cmux, "select-window", "-t", "parity:1")
	assertSessionStateEqual(t, "after-select-window", real, cmux, "parity")
	mustBothSucceed(t, "last-window", real, cmux, "last-window", "-t", "parity")
	assertSessionStateEqual(t, "after-last-window", real, cmux, "parity")
	mustBothSucceed(t, "next-window", real, cmux, "next-window", "-t", "parity")
	assertSessionStateEqual(t, "after-next-window", real, cmux, "parity")
	mustBothSucceed(t, "previous-window", real, cmux, "previous-window", "-t", "parity")
	assertSessionStateEqual(t, "after-previous-window", real, cmux, "parity")

	mustBothSucceed(t, "split-window", real, cmux, "split-window", "-d", "-t", "parity:0", "/bin/sh", readyScript)
	waitForCaptureContains(t, real, "parity:0.1", "READY", 3*time.Second)
	waitForCaptureContains(t, cmux, "parity:0.1", "READY", 3*time.Second)
	assertNormalizedStdoutEqual(t, "list-panes", real.Exec("list-panes", "-t", "parity:0", "-F", "#{pane_index}|#{pane_active}"), cmux.Exec("list-panes", "-t", "parity:0", "-F", "#{pane_index}|#{pane_active}"))

	mustBothSucceed(t, "select-pane", real, cmux, "select-pane", "-t", "parity:0.1")
	assertSessionStateEqual(t, "after-select-pane", real, cmux, "parity")
	mustBothSucceed(t, "last-pane", real, cmux, "last-pane", "-t", "parity:0")
	assertSessionStateEqual(t, "after-last-pane", real, cmux, "parity")

	mustBothSucceed(t, "set-buffer", real, cmux, "set-buffer", "-b", "clip", "clip-text")
	assertNormalizedStdoutEqual(t, "show-buffer", real.Exec("show-buffer", "-b", "clip"), cmux.Exec("show-buffer", "-b", "clip"))
	realSavePath := filepath.Join(t.TempDir(), "tmux-buffer.txt")
	cmuxSavePath := filepath.Join(t.TempDir(), "cmux-buffer.txt")
	assertResultOK(t, "save-buffer tmux", real.Exec("save-buffer", "-b", "clip", realSavePath))
	assertResultOK(t, "save-buffer cmux", cmux.Exec("save-buffer", "-b", "clip", cmuxSavePath))
	realSaved, err := os.ReadFile(realSavePath)
	if err != nil {
		t.Fatalf("read tmux save-buffer file: %v", err)
	}
	cmuxSaved, err := os.ReadFile(cmuxSavePath)
	if err != nil {
		t.Fatalf("read cmux save-buffer file: %v", err)
	}
	if string(realSaved) != string(cmuxSaved) {
		recordDiffArtifacts(t, "save-buffer-file", string(realSaved), string(cmuxSaved))
		t.Fatalf("save-buffer file mismatch: tmux=%q cmux=%q", string(realSaved), string(cmuxSaved))
	}
	assertListContains(t, "list-buffers tmux", real.Exec("list-buffers"), "clip")
	assertListContains(t, "list-buffers cmux", cmux.Exec("list-buffers"), "clip")

	mustBothSucceed(t, "paste-buffer", real, cmux, "paste-buffer", "-b", "clip", "-t", "parity:0.0")
	waitForCaptureContains(t, real, "parity:0.0", "clip-text", 3*time.Second)
	waitForCaptureContains(t, cmux, "parity:0.0", "clip-text", 3*time.Second)
	assertNormalizedStdoutEqual(t, "capture-after-paste", real.Exec("capture-pane", "-p", "-t", "parity:0.0", "-S", "-8"), cmux.Exec("capture-pane", "-p", "-t", "parity:0.0", "-S", "-8"))

	mustBothSucceed(t, "wait-for-signal", real, cmux, "wait-for", "-S", "parity-signal")
	assertBothOK(t, "wait-for", real.Exec("wait-for", "parity-signal"), cmux.Exec("wait-for", "parity-signal"))

	assertBothOK(t, "find-window", real.Exec("find-window", "clip-text"), cmux.Exec("find-window", "clip-text"))
	assertSessionStateEqual(t, "after-find-window", real, cmux, "parity")

	shellScript := fixturePath(t, "ready_shell.sh")
	pipeWindowTmux := mustStdout(t, "new-window-pipe tmux", real.Exec("new-window", "-d", "-P", "-F", "#{window_index}", "-t", "parity", "-n", "pipe", "/bin/sh", shellScript))
	pipeWindowCmux := mustStdout(t, "new-window-pipe cmux", cmux.Exec("new-window", "-d", "-P", "-F", "#{window_index}", "-t", "parity", "-n", "pipe", "/bin/sh", shellScript))
	if pipeWindowTmux != pipeWindowCmux {
		t.Fatalf("pipe window index mismatch: tmux=%q cmux=%q", pipeWindowTmux, pipeWindowCmux)
	}
	pipeTarget := "parity:" + pipeWindowTmux + ".0"
	waitForCaptureContains(t, real, pipeTarget, "READY", 3*time.Second)
	waitForCaptureContains(t, cmux, pipeTarget, "READY", 3*time.Second)

	pipePathTmux := filepath.Join(t.TempDir(), "pipe-tmux.txt")
	pipePathCmux := filepath.Join(t.TempDir(), "pipe-cmux.txt")
	assertResultOK(t, "pipe-pane tmux", real.Exec("pipe-pane", "-t", pipeTarget, "cat > "+pipePathTmux))
	assertResultOK(t, "pipe-pane cmux", cmux.Exec("pipe-pane", "-t", pipeTarget, "cat > "+pipePathCmux))
	mustBothSucceed(t, "send-keys-pipe-command", real, cmux, "send-keys", "-t", pipeTarget, "-l", "echo piped-line")
	mustBothSucceed(t, "send-keys-pipe-enter", real, cmux, "send-keys", "-t", pipeTarget, "Enter")
	waitForFileContains(t, pipePathTmux, "piped-line", 3*time.Second)
	waitForFileContains(t, pipePathCmux, "piped-line", 3*time.Second)
	pipeTmux, _ := os.ReadFile(pipePathTmux)
	pipeCmux, _ := os.ReadFile(pipePathCmux)
	if normalizeText(string(pipeTmux)) != normalizeText(string(pipeCmux)) {
		recordDiffArtifacts(t, "pipe-pane-file", string(pipeTmux), string(pipeCmux))
		t.Fatalf("pipe-pane file mismatch: tmux=%q cmux=%q", string(pipeTmux), string(pipeCmux))
	}

	respawnScript := fixturePath(t, "respawned_cat.sh")
	mustBothSucceed(t, "respawn-pane", real, cmux, "respawn-pane", "-k", "-t", "parity:0.0", "/bin/sh "+respawnScript)
	waitForCaptureContains(t, real, "parity:0.0", "respawned", 3*time.Second)
	waitForCaptureContains(t, cmux, "parity:0.0", "respawned", 3*time.Second)
	assertNormalizedStdoutEqual(t, "capture-after-respawn", real.Exec("capture-pane", "-p", "-t", "parity:0.0", "-S", "-8"), cmux.Exec("capture-pane", "-p", "-t", "parity:0.0", "-S", "-8"))

	mustBothSucceed(t, "kill-pane", real, cmux, "kill-pane", "-t", "parity:0.1")
	assertNormalizedStdoutEqual(t, "list-panes-after-kill", real.Exec("list-panes", "-t", "parity:0", "-F", "#{pane_index}|#{pane_active}"), cmux.Exec("list-panes", "-t", "parity:0", "-F", "#{pane_index}|#{pane_active}"))

	mustBothSucceed(t, "kill-window", real, cmux, "kill-window", "-t", "parity:"+pipeWindowTmux)
	assertNormalizedStdoutEqual(t, "list-windows-after-kill", real.Exec("list-windows", "-t", "parity", "-F", "#{window_index}|#{window_name}|#{window_active}"), cmux.Exec("list-windows", "-t", "parity", "-F", "#{window_index}|#{window_name}|#{window_active}"))
	assertSessionStateEqual(t, "after-kill-window", real, cmux, "parity")
}

func fixturePath(t *testing.T, name string) string {
	t.Helper()
	return filepath.Join(compatPackageDir(), "testdata", name)
}

func assertSessionStateEqual(t *testing.T, step string, real, cmux tmuxBackend, session string) {
	t.Helper()
	realState := snapshotSession(t, real, session)
	cmuxState := snapshotSession(t, cmux, session)
	if !reflect.DeepEqual(realState, cmuxState) {
		recordJSONArtifacts(t, step+"-tmux-state.json", realState)
		recordJSONArtifacts(t, step+"-cmux-state.json", cmuxState)
		t.Fatalf("%s state mismatch", step)
	}
}

func snapshotSession(t *testing.T, backend tmuxBackend, session string) tmuxSessionState {
	t.Helper()

	windowsResult := backend.Exec("list-windows", "-t", session, "-F", "#{window_index}|#{window_name}|#{window_active}")
	assertResultOK(t, backend.Name()+" list-windows", windowsResult)
	windowLines := nonEmptyLines(windowsResult.Stdout)
	state := tmuxSessionState{
		Windows: make([]tmuxWindowState, 0, len(windowLines)),
	}
	for _, line := range windowLines {
		parts := strings.SplitN(line, "|", 3)
		if len(parts) != 3 {
			t.Fatalf("%s list-windows line malformed: %q", backend.Name(), line)
		}
		window := tmuxWindowState{
			Index:  parts[0],
			Name:   parts[1],
			Active: parts[2],
		}
		panesResult := backend.Exec("list-panes", "-t", session+":"+window.Index, "-F", "#{pane_index}|#{pane_active}")
		assertResultOK(t, backend.Name()+" list-panes", panesResult)
		for _, paneLine := range nonEmptyLines(panesResult.Stdout) {
			paneParts := strings.SplitN(paneLine, "|", 2)
			if len(paneParts) != 2 {
				t.Fatalf("%s list-panes line malformed: %q", backend.Name(), paneLine)
			}
			capture := backend.Exec("capture-pane", "-p", "-t", session+":"+window.Index+"."+paneParts[0], "-S", "-12")
			assertResultOK(t, backend.Name()+" capture-pane", capture)
			window.Panes = append(window.Panes, tmuxPaneState{
				Index:   paneParts[0],
				Active:  paneParts[1],
				Capture: normalizeCapture(capture.Stdout),
			})
		}
		state.Windows = append(state.Windows, window)
	}
	return state
}

func waitForCaptureContains(t *testing.T, backend tmuxBackend, target, needle string, timeout time.Duration) string {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		result := backend.Exec("capture-pane", "-p", "-t", target, "-S", "-20")
		if result.OK && strings.Contains(result.Stdout, needle) {
			return result.Stdout
		}
		time.Sleep(50 * time.Millisecond)
	}
	result := backend.Exec("capture-pane", "-p", "-t", target, "-S", "-20")
	recordDiffArtifacts(t, "capture-timeout-"+strings.NewReplacer(":", "_", ".", "_").Replace(target), needle, result.Stdout)
	t.Fatalf("%s capture for %s never contained %q; got %q", backend.Name(), target, needle, result.Stdout)
	return ""
}

func waitForFileContains(t *testing.T, path, needle string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		data, err := os.ReadFile(path)
		if err == nil && strings.Contains(string(data), needle) {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}
	data, _ := os.ReadFile(path)
	recordDiffArtifacts(t, filepath.Base(path), needle, string(data))
	t.Fatalf("file %s never contained %q; got %q", path, needle, string(data))
}

func mustBothSucceed(t *testing.T, step string, real, cmux tmuxBackend, args ...string) {
	t.Helper()
	assertBothOK(t, step, real.Exec(args...), cmux.Exec(args...))
}

func assertBothOK(t *testing.T, step string, realResult, cmuxResult tmuxCommandResult) {
	t.Helper()
	if !realResult.OK || !cmuxResult.OK {
		recordJSONArtifacts(t, step+"-tmux-result.json", realResult)
		recordJSONArtifacts(t, step+"-cmux-result.json", cmuxResult)
		t.Fatalf("%s failed: tmux=%+v cmux=%+v", step, realResult, cmuxResult)
	}
}

func assertNormalizedStdoutEqual(t *testing.T, step string, realResult, cmuxResult tmuxCommandResult) {
	t.Helper()
	assertBothOK(t, step, realResult, cmuxResult)
	if normalizeCapture(realResult.Stdout) != normalizeCapture(cmuxResult.Stdout) {
		recordDiffArtifacts(t, step, realResult.Stdout, cmuxResult.Stdout)
		t.Fatalf("%s stdout mismatch: tmux=%q cmux=%q", step, realResult.Stdout, cmuxResult.Stdout)
	}
}

func assertResultOK(t *testing.T, label string, result tmuxCommandResult) {
	t.Helper()
	if !result.OK {
		t.Fatalf("%s failed: %+v", label, result)
	}
}

func assertListContains(t *testing.T, step string, result tmuxCommandResult, needle string) {
	t.Helper()
	assertResultOK(t, step, result)
	if !strings.Contains(result.Stdout, needle) {
		recordDiffArtifacts(t, step, needle, result.Stdout)
		t.Fatalf("%s missing %q in %q", step, needle, result.Stdout)
	}
}

func mustStdout(t *testing.T, step string, result tmuxCommandResult) string {
	t.Helper()
	assertResultOK(t, step, result)
	return strings.TrimSpace(result.Stdout)
}

func normalizeText(value string) string {
	value = strings.ReplaceAll(value, "\r\n", "\n")
	return strings.TrimSpace(value)
}

func normalizeCapture(value string) string {
	lines := strings.Split(strings.ReplaceAll(value, "\r\n", "\n"), "\n")
	for len(lines) > 0 && strings.TrimSpace(lines[len(lines)-1]) == "" {
		lines = lines[:len(lines)-1]
	}
	return strings.Join(lines, "\n")
}

func nonEmptyLines(value string) []string {
	var out []string
	for _, line := range strings.Split(normalizeText(value), "\n") {
		if strings.TrimSpace(line) != "" {
			out = append(out, line)
		}
	}
	return out
}

func stringValue(value any) string {
	if text, ok := value.(string); ok {
		return text
	}
	return ""
}

func callUnixJSONRPCUnchecked(client *unixJSONRPCClient, payload map[string]any) (map[string]any, error) {
	if client == nil || client.conn == nil || client.reader == nil {
		return nil, fmt.Errorf("unix client is closed")
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	if err := client.conn.SetDeadline(time.Now().Add(3 * time.Second)); err != nil {
		return nil, err
	}
	if _, err := client.conn.Write(append(encoded, '\n')); err != nil {
		return nil, err
	}
	line, err := client.reader.ReadString('\n')
	if err != nil {
		return nil, err
	}
	var response map[string]any
	if err := json.Unmarshal([]byte(line), &response); err != nil {
		return nil, err
	}
	return response, nil
}

func recordJSONArtifacts(t *testing.T, name string, value any) {
	t.Helper()
	root := strings.TrimSpace(os.Getenv("CMUX_REMOTE_TEST_ARTIFACT_DIR"))
	if root == "" {
		return
	}
	dir := filepath.Join(root, sanitizeTestName(t.Name()))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return
	}
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return
	}
	_ = os.WriteFile(filepath.Join(dir, name), data, 0o644)
}

func recordDiffArtifacts(t *testing.T, name, expected, actual string) {
	t.Helper()
	recordJSONArtifacts(t, name+"-diff.json", map[string]string{
		"expected": expected,
		"actual":   actual,
	})
}

func sanitizeTestName(name string) string {
	replacer := strings.NewReplacer("/", "_", " ", "_", ":", "_")
	return replacer.Replace(name)
}

func shortTempDir(t *testing.T, prefix string) string {
	t.Helper()

	dir, err := os.MkdirTemp("", prefix)
	if err != nil {
		t.Fatalf("mkdir temp dir: %v", err)
	}
	shortDir := filepath.Join("/tmp", filepath.Base(dir))
	if renameErr := os.Rename(dir, shortDir); renameErr == nil {
		dir = shortDir
	}
	t.Cleanup(func() {
		_ = os.RemoveAll(dir)
	})
	return dir
}
