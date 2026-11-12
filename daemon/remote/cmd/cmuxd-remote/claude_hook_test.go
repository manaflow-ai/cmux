package main

import (
	"bytes"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// claudeHookTestEnv returns a getenv backed by a fixed map.
func claudeHookTestEnv(values map[string]string) func(string) string {
	return func(key string) string { return values[key] }
}

// TestClaudeHookRelayEnqueuesSurfaceScopedEvent checks the enqueue shape and that host paths are stripped.
func TestClaudeHookRelayEnqueuesSurfaceScopedEvent(t *testing.T) {
	sockPath, requests := startMockV2SocketWithRequestCapture(t)
	t.Setenv("CMUX_WORKSPACE_ID", "11111111-1111-4111-8111-111111111111")
	t.Setenv("CMUX_SURFACE_ID", "22222222-2222-4222-8222-222222222222")
	t.Setenv("CMUX_CLAUDE_HOOKS_DISABLED", "")

	input := strings.NewReader(`{"session_id":"sess-1","hook_event_name":"SessionStart","cwd":"/home/dev/repo","transcript_path":"/home/dev/.claude/projects/x.jsonl","source":"startup"}`)
	var stdout bytes.Buffer
	if code := runClaudeHookRelay(sockPath, []string{"session-start"}, nil, input, &stdout); code != 0 {
		t.Fatalf("claude-hook exit %d", code)
	}
	if got := strings.TrimSpace(stdout.String()); got != "{}" {
		t.Fatalf("claude-hook stdout = %q, want {}", got)
	}

	req := receiveRequest(t, requests)
	if req["method"] != "agent.hook.enqueue" {
		t.Fatalf("method = %v, want agent.hook.enqueue", req["method"])
	}
	p := params(req)
	for key, want := range map[string]any{
		"agent":        "claude",
		"subcommand":   "session-start",
		"relay_backed": true,
		"workspace_id": "11111111-1111-4111-8111-111111111111",
		"surface_id":   "22222222-2222-4222-8222-222222222222",
	} {
		if p[key] != want {
			t.Fatalf("params[%s] = %v, want %v", key, p[key], want)
		}
	}
	if _, ok := p["environment"]; ok {
		t.Fatalf("relay hook must not send an environment map: %v", p)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(p["payload"].(string)), &payload); err != nil {
		t.Fatalf("payload is not JSON: %v", err)
	}
	if payload["session_id"] != "sess-1" || payload["source"] != "startup" {
		t.Fatalf("payload lost lifecycle fields: %v", payload)
	}
	if _, ok := payload["cwd"]; ok {
		t.Fatalf("payload kept remote cwd: %v", payload)
	}
	if _, ok := payload["transcript_path"]; ok {
		t.Fatalf("payload kept remote transcript path: %v", payload)
	}
}

// TestClaudeHookRelayFailsOpenWithoutRelay checks the hook answers {} when no relay is configured.
func TestClaudeHookRelayFailsOpenWithoutRelay(t *testing.T) {
	var stdout bytes.Buffer
	code := runClaudeHookRelay("", []string{"stop"}, nil, strings.NewReader(`{"session_id":"s"}`), &stdout)
	if code != 0 || strings.TrimSpace(stdout.String()) != "{}" {
		t.Fatalf("claude-hook without relay: exit %d stdout %q", code, stdout.String())
	}
}

// TestClaudeHookEnqueueParamsRejectsDecisionAndUnroutedEvents keeps decision hooks and surfaceless hooks local.
func TestClaudeHookEnqueueParamsRejectsDecisionAndUnroutedEvents(t *testing.T) {
	routed := claudeHookTestEnv(map[string]string{
		"CMUX_WORKSPACE_ID": "11111111-1111-4111-8111-111111111111",
		"CMUX_SURFACE_ID":   "22222222-2222-4222-8222-222222222222",
	})
	noTTY := func(string) string { return "" }
	for _, subcommand := range []string{"feed", "cron-create-guard", "auto-name", ""} {
		if _, ok := claudeHookEnqueueParams(subcommand, []byte(`{}`), routed, noTTY); ok {
			t.Fatalf("subcommand %q must not be relayed", subcommand)
		}
	}
	unrouted := claudeHookTestEnv(map[string]string{"CMUX_WORKSPACE_ID": "11111111-1111-4111-8111-111111111111"})
	if _, ok := claudeHookEnqueueParams("stop", []byte(`{}`), unrouted, noTTY); ok {
		t.Fatal("a hook without CMUX_SURFACE_ID must not be relayed")
	}
	withTTY := func(string) string { return "/dev/pts/7" }
	p, ok := claudeHookEnqueueParams("Stop", []byte(`{}`), routed, withTTY)
	if !ok || p["subcommand"] != "stop" || p["caller_tty"] != "/dev/pts/7" {
		t.Fatalf("params = %v ok=%v", p, ok)
	}
}

// TestCompactClaudeHookPayloadBoundsLargeEvents checks oversized payloads fall back to bounded lifecycle fields.
func TestCompactClaudeHookPayloadBoundsLargeEvents(t *testing.T) {
	large := map[string]any{
		"session_id":             "sess-2",
		"hook_event_name":        "Stop",
		"last_assistant_message": strings.Repeat("x", 10_000),
		"prompt":                 strings.Repeat("z", 5_000),
		"transcript_path":        "/home/dev/t.jsonl",
		"tool_response":          map[string]any{"stdout": strings.Repeat("y", 10_000)},
	}
	data, _ := json.Marshal(large)
	compacted := compactClaudeHookPayload(data)
	if len(compacted) > claudeHookMaximumPayloadBytes {
		t.Fatalf("payload is %d bytes, limit %d", len(compacted), claudeHookMaximumPayloadBytes)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(compacted), &payload); err != nil {
		t.Fatalf("compacted payload is not JSON: %v", err)
	}
	if payload["session_id"] != "sess-2" || payload["hook_event_name"] != "Stop" {
		t.Fatalf("compaction dropped identity: %v", payload)
	}
	if message, _ := payload["last_assistant_message"].(string); len([]rune(message)) != 240 {
		t.Fatalf("message not truncated to 240 runes: %d", len([]rune(message)))
	}
	if _, ok := payload["transcript_path"]; ok {
		t.Fatalf("compaction kept a remote path: %v", payload)
	}
	if got := compactClaudeHookPayload([]byte("not json")); got != "{}" {
		t.Fatalf("invalid input compacted to %q", got)
	}
}

// TestClaudeArgsWithRelayHooksMergesLauncherSettings checks a launcher --settings file and inline JSON merge with the relay hooks.
func TestClaudeArgsWithRelayHooksMergesLauncherSettings(t *testing.T) {
	dir := t.TempDir()
	// A launcher prepends its own --settings file.
	launcherSettings := filepath.Join(dir, "launcher-settings.json")
	if err := os.WriteFile(launcherSettings, []byte(`{"apiKeyHelper":"launcher-helper","hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"user-stop"}]}]}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	args := []string{"--settings", launcherSettings, "--model", "opus", "--settings={\"theme\":\"dark\"}", "--", "--settings", "literal"}
	out, err := claudeArgsWithRelayHooks(args, "/home/dev/.cmux/bin/cmux", filepath.Join(dir, "cache"))
	if err != nil {
		t.Fatal(err)
	}
	if len(out) < 2 || out[0] != "--settings" {
		t.Fatalf("args = %v", out)
	}
	if got, want := strings.Join(out[2:], " "), "--model opus -- --settings literal"; got != want {
		t.Fatalf("remaining args = %q, want %q", got, want)
	}
	info, err := os.Stat(out[1])
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("settings file mode = %v", info.Mode().Perm())
	}
	data, _ := os.ReadFile(out[1])
	var settings map[string]any
	if err := json.Unmarshal(data, &settings); err != nil {
		t.Fatal(err)
	}
	if settings["apiKeyHelper"] != "launcher-helper" || settings["theme"] != "dark" {
		t.Fatalf("launcher settings lost: %v", settings)
	}
	hooks := settings["hooks"].(map[string]any)
	stopGroups := hooks["Stop"].([]any)
	if len(stopGroups) != 2 || !strings.Contains(string(data), "user-stop") {
		t.Fatalf("Stop hooks = %v", stopGroups)
	}
	if !strings.Contains(string(data), `'/home/dev/.cmux/bin/cmux' claude-hook session-start`) {
		t.Fatalf("cmux session-start hook missing: %s", data)
	}
	for _, event := range []string{"SessionStart", "UserPromptSubmit", "StopFailure", "Notification", "SessionEnd", "PreToolUse"} {
		if _, ok := hooks[event]; !ok {
			t.Fatalf("hook event %s missing", event)
		}
	}
	if _, ok := hooks["PermissionRequest"]; ok {
		t.Fatal("decision hooks must not be injected on relay hosts")
	}

	again, err := claudeArgsWithRelayHooks(args, "/home/dev/.cmux/bin/cmux", filepath.Join(dir, "cache"))
	if err != nil || again[1] != out[1] {
		t.Fatalf("identical launches should reuse one settings file: %v %v", again, err)
	}
}

// TestClaudeArgsWithRelayHooksRejectsUnreadableSettings checks an unreadable --settings file skips injection.
func TestClaudeArgsWithRelayHooksRejectsUnreadableSettings(t *testing.T) {
	if _, err := claudeArgsWithRelayHooks([]string{"--settings", "/nonexistent/settings.json"}, "cmux", t.TempDir()); err == nil {
		t.Fatal("expected an error for an unreadable --settings file")
	}
}

// TestFindRealClaudeSkipsCmuxShims checks resolution skips shim and cmux bin directories.
func TestFindRealClaudeSkipsCmuxShims(t *testing.T) {
	root := t.TempDir()
	shimDir := filepath.Join(root, "cmux-cli-shims", "surface")
	cmuxBinDir := filepath.Join(root, ".cmux", "bin")
	realDir := filepath.Join(root, "real")
	for _, dir := range []string{shimDir, cmuxBinDir, realDir} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "claude"), []byte("#!/bin/sh\n"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	pathEnv := strings.Join([]string{shimDir, cmuxBinDir, realDir}, string(os.PathListSeparator))
	got := findRealClaude(pathEnv, filepath.Join(cmuxBinDir, "cmux"))
	if want := filepath.Join(realDir, "claude"); got != want {
		t.Fatalf("findRealClaude = %q, want %q", got, want)
	}
}

// TestClaudeWrapperSkipsInjectionForNonLaunchInvocations checks informational and management invocations pass through.
func TestClaudeWrapperSkipsInjectionForNonLaunchInvocations(t *testing.T) {
	sockPath := startMockV2Socket(t)
	t.Setenv("CMUX_WORKSPACE_ID", "11111111-1111-4111-8111-111111111111")
	t.Setenv("CMUX_SURFACE_ID", "22222222-2222-4222-8222-222222222222")
	t.Setenv("CMUX_CLAUDE_HOOKS_DISABLED", "")
	if !claudeWrapperShouldInject([]string{"--model", "opus"}, sockPath, nil) {
		t.Fatal("an interactive launch with a live relay should get hooks")
	}
	for _, args := range [][]string{{"--version"}, {"mcp", "list"}} {
		if claudeWrapperShouldInject(args, sockPath, nil) {
			t.Fatalf("%v must pass through without hooks", args)
		}
	}
	if claudeWrapperShouldInject(nil, "", nil) {
		t.Fatal("no relay means no hooks")
	}
	t.Setenv("CMUX_CLAUDE_HOOKS_DISABLED", "1")
	if claudeWrapperShouldInject(nil, sockPath, nil) {
		t.Fatal("CMUX_CLAUDE_HOOKS_DISABLED=1 must disable injection")
	}
}

// TestClaudeWrapperProbeAnswersWithoutRelay checks the version probe the relay
// bootstrap wrapper runs succeeds offline and never launches the agent.
func TestClaudeWrapperProbeAnswersWithoutRelay(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	if code := runClaudeWrapper("", []string{claudeWrapperProbeFlag}, nil); code != 0 {
		t.Fatalf("probe exit = %d, want 0", code)
	}
	if code := runCLI([]string{"claude-wrapper", claudeWrapperProbeFlag}); code != 0 {
		t.Fatalf("cli probe exit = %d, want 0", code)
	}
	// With extra arguments it is a launch; no agent on PATH means 127.
	if code := runClaudeWrapper("", []string{claudeWrapperProbeFlag, "--model", "opus"}, nil); code != 127 {
		t.Fatalf("launch exit = %d, want 127", code)
	}
}

// TestWriteClaudeSettingsFilePrunesIdleCopies checks idle copies are pruned and reused copies refreshed.
func TestWriteClaudeSettingsFilePrunesIdleCopies(t *testing.T) {
	dir := t.TempDir()
	stale := filepath.Join(dir, "stale.json")
	recent := filepath.Join(dir, "recent.json")
	for _, path := range []string{stale, recent} {
		if err := os.WriteFile(path, []byte(`{}`), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	old := time.Now().Add(-claudeSettingsRetention - time.Hour)
	if err := os.Chtimes(stale, old, old); err != nil {
		t.Fatal(err)
	}
	path, err := writeClaudeSettingsFile(dir, []byte(`{"hooks":{}}`))
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(stale); !os.IsNotExist(err) {
		t.Fatalf("idle settings copy was not pruned: %v", err)
	}
	if _, err := os.Stat(recent); err != nil {
		t.Fatalf("recent settings copy was pruned: %v", err)
	}
	if err := os.Chtimes(path, old, old); err != nil {
		t.Fatal(err)
	}
	if _, err := writeClaudeSettingsFile(dir, []byte(`{"hooks":{}}`)); err != nil {
		t.Fatal(err)
	}
	if info, err := os.Stat(path); err != nil || time.Since(info.ModTime()) > time.Minute {
		t.Fatalf("reused settings copy was not refreshed: %v", err)
	}
}

// TestClaudeArgsWithRelayHooksRejectsBareSettingsFlag checks a trailing --settings without a value skips injection.
func TestClaudeArgsWithRelayHooksRejectsBareSettingsFlag(t *testing.T) {
	if _, err := claudeArgsWithRelayHooks([]string{"--model", "opus", "--settings"}, "cmux", t.TempDir()); err == nil {
		t.Fatal("a trailing --settings without a value must skip injection")
	}
}

// TestPathWithoutCmuxShims checks shim directories are removed from PATH.
func TestPathWithoutCmuxShims(t *testing.T) {
	t.Setenv("CMUX_CLAUDE_WRAPPER_SHIM_ROOT", "/custom/shim")
	got := pathWithoutCmuxShims("/custom/shim:/tmp/cmux-cli-shims/s:/usr/bin::/bin")
	if got != "/usr/bin:/bin" {
		t.Fatalf("pathWithoutCmuxShims = %q", got)
	}
}

// TestWriteClaudeSettingsFileRestoresPrivateModes checks reuse resets file and directory modes to private.
func TestWriteClaudeSettingsFileRestoresPrivateModes(t *testing.T) {
	dir := filepath.Join(t.TempDir(), "settings")
	data := []byte(`{"env":{"TOKEN":"x"}}`)
	path, err := writeClaudeSettingsFile(dir, data)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := writeClaudeSettingsFile(dir, data); err != nil {
		t.Fatal(err)
	}
	for target, want := range map[string]os.FileMode{path: 0o600, dir: 0o700} {
		info, err := os.Stat(target)
		if err != nil || info.Mode().Perm() != want {
			t.Fatalf("%s mode = %v, want %v (%v)", target, info.Mode().Perm(), want, err)
		}
	}
}

// TestWriteClaudeSettingsFileRefusesSymlinkedDirectory checks a symlink at the cache path is not followed.
func TestWriteClaudeSettingsFileRefusesSymlinkedDirectory(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "target")
	if err := os.Mkdir(target, 0o755); err != nil {
		t.Fatal(err)
	}
	stale := filepath.Join(target, "stale.json")
	if err := os.WriteFile(stale, []byte(`{}`), 0o600); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-claudeSettingsRetention - time.Hour)
	if err := os.Chtimes(stale, old, old); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "settings")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if _, err := writeClaudeSettingsFile(link, []byte(`{"hooks":{}}`)); err == nil {
		t.Fatal("settings were written through a symlinked cache directory")
	}
	if _, err := os.Stat(stale); err != nil {
		t.Fatalf("a file behind the symlink was pruned: %v", err)
	}
	if info, err := os.Stat(target); err != nil || info.Mode().Perm() != 0o755 {
		t.Fatalf("the symlink target's mode changed: %v", err)
	}
}

// TestClaudeHookRelayGivesUpAtItsDeadline checks a silent relay cannot hold the hook past its deadline.
func TestClaudeHookRelayGivesUpAtItsDeadline(t *testing.T) {
	// A listener that accepts and never answers the relay handshake.
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			t.Cleanup(func() { conn.Close() })
		}
	}()
	t.Setenv("CMUX_RELAY_ID", "relay-test")
	t.Setenv("CMUX_RELAY_TOKEN", "00112233445566778899aabbccddeeff")
	start := time.Now()
	_, err = socketRoundTripV2Until(listener.Addr().String(), "system.ping", nil, nil, time.Now().Add(200*time.Millisecond))
	if err == nil {
		t.Fatal("expected a deadline error")
	}
	if elapsed := time.Since(start); elapsed > 2*time.Second {
		t.Fatalf("round trip ignored its deadline: %v", elapsed)
	}
}
