package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func claudeHookTestEnv(values map[string]string) func(string) string {
	return func(key string) string { return values[key] }
}

func TestClaudeHookRelayEnqueuesSurfaceScopedEvent(t *testing.T) {
	sockPath, requests := startMockV2SocketWithRequestCapture(t)
	t.Setenv("CMUX_WORKSPACE_ID", "11111111-1111-4111-8111-111111111111")
	t.Setenv("CMUX_SURFACE_ID", "22222222-2222-4222-8222-222222222222")
	t.Setenv("CMUX_CLAUDE_HOOKS_DISABLED", "")

	input := strings.NewReader(`{"session_id":"sess-1","hook_event_name":"SessionStart","cwd":"/home/leo/repo","transcript_path":"/home/leo/.claude/projects/x.jsonl","source":"startup"}`)
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

func TestClaudeHookRelayFailsOpenWithoutRelay(t *testing.T) {
	var stdout bytes.Buffer
	code := runClaudeHookRelay("", []string{"stop"}, nil, strings.NewReader(`{"session_id":"s"}`), &stdout)
	if code != 0 || strings.TrimSpace(stdout.String()) != "{}" {
		t.Fatalf("claude-hook without relay: exit %d stdout %q", code, stdout.String())
	}
}

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

func TestCompactClaudeHookPayloadBoundsLargeEvents(t *testing.T) {
	large := map[string]any{
		"session_id":             "sess-2",
		"hook_event_name":        "Stop",
		"last_assistant_message": strings.Repeat("x", 10_000),
		"transcript_path":        "/home/leo/t.jsonl",
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

func TestClaudeArgsWithRelayHooksMergesLauncherSettings(t *testing.T) {
	dir := t.TempDir()
	// `sr claude proxy` prepends its own --settings file.
	launcherSettings := filepath.Join(dir, "sr-settings.json")
	if err := os.WriteFile(launcherSettings, []byte(`{"apiKeyHelper":"sr-helper","hooks":{"Stop":[{"matcher":"","hooks":[{"type":"command","command":"user-stop"}]}]}}`), 0o600); err != nil {
		t.Fatal(err)
	}
	args := []string{"--settings", launcherSettings, "--model", "opus", "--settings={\"theme\":\"dark\"}", "--", "--settings", "literal"}
	out, err := claudeArgsWithRelayHooks(args, "/home/leo/.cmux/bin/cmux", filepath.Join(dir, "cache"))
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
	if settings["apiKeyHelper"] != "sr-helper" || settings["theme"] != "dark" {
		t.Fatalf("launcher settings lost: %v", settings)
	}
	hooks := settings["hooks"].(map[string]any)
	stopGroups := hooks["Stop"].([]any)
	if len(stopGroups) != 2 || !strings.Contains(string(data), "user-stop") {
		t.Fatalf("Stop hooks = %v", stopGroups)
	}
	if !strings.Contains(string(data), `'/home/leo/.cmux/bin/cmux' claude-hook session-start`) {
		t.Fatalf("cmux session-start hook missing: %s", data)
	}
	for _, event := range []string{"SessionStart", "UserPromptSubmit", "Notification", "SessionEnd", "PreToolUse"} {
		if _, ok := hooks[event]; !ok {
			t.Fatalf("hook event %s missing", event)
		}
	}
	if _, ok := hooks["PermissionRequest"]; ok {
		t.Fatal("decision hooks must not be injected on relay hosts")
	}

	again, err := claudeArgsWithRelayHooks(args, "/home/leo/.cmux/bin/cmux", filepath.Join(dir, "cache"))
	if err != nil || again[1] != out[1] {
		t.Fatalf("identical launches should reuse one settings file: %v %v", again, err)
	}
}

func TestClaudeArgsWithRelayHooksRejectsUnreadableSettings(t *testing.T) {
	if _, err := claudeArgsWithRelayHooks([]string{"--settings", "/nonexistent/settings.json"}, "cmux", t.TempDir()); err == nil {
		t.Fatal("expected an error for an unreadable --settings file")
	}
}

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
