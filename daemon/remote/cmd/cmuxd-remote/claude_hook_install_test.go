package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// readClaudeSettingsForTest parses a settings file.
func readClaudeSettingsForTest(t *testing.T, path string) map[string]any {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	var settings map[string]any
	if err := json.Unmarshal(data, &settings); err != nil {
		t.Fatalf("parse %s: %v\n%s", path, err, data)
	}
	return settings
}

// installedHookCommands lists every hook command under an event.
func installedHookCommands(settings map[string]any, event string) []string {
	var commands []string
	hooks, _ := settings["hooks"].(map[string]any)
	groups, _ := hooks[event].([]any)
	for _, rawGroup := range groups {
		group, _ := rawGroup.(map[string]any)
		entries, _ := group["hooks"].([]any)
		for _, rawEntry := range entries {
			entry, _ := rawEntry.(map[string]any)
			command, _ := entry["command"].(string)
			commands = append(commands, command)
		}
	}
	return commands
}

// TestClaudeHookInstallKeepsUserSettingsAndIsIdempotent installs next to a user's own hooks, twice, then removes only cmux's.
func TestClaudeHookInstallKeepsUserSettingsAndIsIdempotent(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("CLAUDE_CONFIG_DIR", "")
	t.Setenv("CMUX_BUNDLED_CLI_PATH", "")
	cli := filepath.Join(home, ".cmux", "bin", "cmux")
	if err := os.MkdirAll(filepath.Dir(cli), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cli, []byte("#!/bin/sh\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	settingsPath := filepath.Join(home, ".claude", "settings.json")
	if err := os.MkdirAll(filepath.Dir(settingsPath), 0o755); err != nil {
		t.Fatal(err)
	}
	original := `{"model":"opus","permissions":{"allow":["Bash(ls)"]},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash ~/.claude/hooks/guard.sh","timeout":5}]}]}}`
	if err := os.WriteFile(settingsPath, []byte(original), 0o644); err != nil {
		t.Fatal(err)
	}

	for pass := 0; pass < 2; pass++ {
		var stdout, stderr bytes.Buffer
		if code := runClaudeHookInstall([]string{"install"}, &stdout, &stderr); code != 0 {
			t.Fatalf("install exit %d: %s", code, stderr.String())
		}
	}
	settings := readClaudeSettingsForTest(t, settingsPath)
	if settings["model"] != "opus" || settings["permissions"] == nil {
		t.Fatalf("install dropped user settings: %v", settings)
	}
	preToolUse := installedHookCommands(settings, "PreToolUse")
	if len(preToolUse) != 2 || preToolUse[0] != "bash ~/.claude/hooks/guard.sh" {
		t.Fatalf("PreToolUse = %v, want the user's hook plus one cmux hook", preToolUse)
	}
	for _, definition := range claudeRelayHookEvents {
		commands := installedHookCommands(settings, definition.event)
		var installed []string
		for _, command := range commands {
			if strings.Contains(command, claudeHookInstallMarker) {
				installed = append(installed, command)
			}
		}
		want := "test -x '" + cli + "' && '" + cli + "' claude-hook --user-settings " + definition.subcommand + " || :"
		if len(installed) != 1 || installed[0] != want {
			t.Fatalf("%s hooks = %v, want exactly %q", definition.event, installed, want)
		}
	}
	if info, err := os.Stat(settingsPath); err != nil || info.Mode().Perm() != 0o644 {
		t.Fatalf("install changed the file mode: %v %v", info.Mode(), err)
	}

	var stdout, stderr bytes.Buffer
	if code := runClaudeHookInstall([]string{"uninstall"}, &stdout, &stderr); code != 0 {
		t.Fatalf("uninstall exit %d: %s", code, stderr.String())
	}
	settings = readClaudeSettingsForTest(t, settingsPath)
	hooks, _ := settings["hooks"].(map[string]any)
	if len(hooks) != 1 || len(installedHookCommands(settings, "PreToolUse")) != 1 {
		t.Fatalf("uninstall must leave only the user's hook: %v", hooks)
	}
}

// TestClaudeHookInstallTargetsConfigDirAndCreatesPrivateFile follows CLAUDE_CONFIG_DIR and writes a new file 0600.
func TestClaudeHookInstallTargetsConfigDirAndCreatesPrivateFile(t *testing.T) {
	configDir := filepath.Join(t.TempDir(), "claude-config")
	t.Setenv("CLAUDE_CONFIG_DIR", configDir)
	var stdout, stderr bytes.Buffer
	if code := runClaudeHookInstall([]string{"install"}, &stdout, &stderr); code != 0 {
		t.Fatalf("install exit %d: %s", code, stderr.String())
	}
	path := filepath.Join(configDir, "settings.json")
	info, err := os.Stat(path)
	if err != nil || info.Mode().Perm() != 0o600 {
		t.Fatalf("new settings file mode = %v err=%v, want 0600", info, err)
	}
	if len(installedHookCommands(readClaudeSettingsForTest(t, path), "Stop")) != 1 {
		t.Fatal("expected one Stop hook")
	}
}

// TestClaudeHookInstallFollowsSymlinkAndRefusesInvalidJSON keeps dotfile symlinks and never clobbers a broken file.
func TestClaudeHookInstallFollowsSymlinkAndRefusesInvalidJSON(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "dotfiles-settings.json")
	if err := os.WriteFile(target, []byte(`{"model":"opus"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(dir, "settings.json")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	var stdout, stderr bytes.Buffer
	if code := runClaudeHookInstall([]string{"install", "--settings-file", link}, &stdout, &stderr); code != 0 {
		t.Fatalf("install exit %d: %s", code, stderr.String())
	}
	if info, err := os.Lstat(link); err != nil || info.Mode()&os.ModeSymlink == 0 {
		t.Fatal("install replaced the symlink")
	}
	if len(installedHookCommands(readClaudeSettingsForTest(t, target), "SessionStart")) != 1 {
		t.Fatal("install did not write through the symlink")
	}

	broken := filepath.Join(dir, "broken.json")
	if err := os.WriteFile(broken, []byte(`{"model":`), 0o600); err != nil {
		t.Fatal(err)
	}
	stderr.Reset()
	if code := runClaudeHookInstall([]string{"install", "--settings-file=" + broken}, &stdout, &stderr); code == 0 {
		t.Fatal("install must refuse a settings file that is not JSON")
	}
	if data, _ := os.ReadFile(broken); string(data) != `{"model":` {
		t.Fatalf("install changed an unparseable file: %q", data)
	}
	if code := runClaudeHookInstall([]string{"install", "--bogus"}, &stdout, &stderr); code != 2 {
		t.Fatalf("unknown flag exit = %d, want 2", code)
	}
}
