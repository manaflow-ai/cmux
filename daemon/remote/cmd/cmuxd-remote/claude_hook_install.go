package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

// `cmux claude-hook install` writes the relay hooks into Claude's user
// settings. The launch wrapper covers sessions started from a cmux shell;
// the installed hooks also cover sessions whose shell never saw cmux, such as
// a tmux server or launcher started before cmux attached to it. Launchers
// that pass their own --settings and CLAUDE_CONFIG_DIR still load hooks from
// the user settings file they merge (sr, for example, merges
// ~/.claude/settings.json into its launch settings).

// claudeHookInstallMarker identifies installed hook commands, so install is
// idempotent and uninstall removes only cmux's entries.
const claudeHookInstallMarker = "claude-hook " + claudeHookUserSettingsFlag + " "

// runClaudeHookInstall implements `cmux claude-hook install|uninstall
// [--settings-file <path>]`.
func runClaudeHookInstall(args []string, stdout io.Writer, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: cmux claude-hook install|uninstall [--settings-file <path>]")
		return 2
	}
	action := args[0]
	settingsPath := ""
	for index := 1; index < len(args); index++ {
		switch {
		case args[index] == "--settings-file" && index+1 < len(args):
			settingsPath = args[index+1]
			index++
		case strings.HasPrefix(args[index], "--settings-file="):
			settingsPath = strings.TrimPrefix(args[index], "--settings-file=")
		default:
			fmt.Fprintln(stderr, "usage: cmux claude-hook install|uninstall [--settings-file <path>]")
			return 2
		}
	}
	if settingsPath == "" {
		settingsPath = defaultClaudeUserSettingsPath()
	}
	if settingsPath == "" {
		fmt.Fprintln(stderr, "cmux: could not locate the agent settings file; pass --settings-file")
		return 1
	}
	var err error
	switch action {
	case "install":
		err = updateClaudeUserSettingsFile(settingsPath, func(settings map[string]any) {
			removeInstalledClaudeHooks(settings)
			mergeClaudeSettings(settings, installedClaudeHookSettings(claudeWrapperCmuxBinary()))
		})
		if err == nil {
			fmt.Fprintf(stdout, "cmux: installed status hooks in %s\n", settingsPath)
			fmt.Fprintln(stdout, "cmux: restart running agent sessions to load them")
		}
	case "uninstall":
		err = updateClaudeUserSettingsFile(settingsPath, removeInstalledClaudeHooks)
		if err == nil {
			fmt.Fprintf(stdout, "cmux: removed status hooks from %s\n", settingsPath)
		}
	default:
		fmt.Fprintln(stderr, "usage: cmux claude-hook install|uninstall [--settings-file <path>]")
		return 2
	}
	if err != nil {
		fmt.Fprintf(stderr, "cmux: %v\n", err)
		return 1
	}
	return 0
}

// defaultClaudeUserSettingsPath is Claude's user settings file for this shell.
func defaultClaudeUserSettingsPath() string {
	if dir := strings.TrimSpace(os.Getenv("CLAUDE_CONFIG_DIR")); dir != "" {
		return filepath.Join(dir, "settings.json")
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	return filepath.Join(home, ".claude", "settings.json")
}

// installedClaudeHookSettings is the hook fragment for Claude's user settings.
// Each command is a no-op when the remote CLI is missing, and the CLI itself
// is a no-op outside a cmux surface.
func installedClaudeHookSettings(cmuxBin string) map[string]any {
	quoted := shellQuoteClaudeHookPath(cmuxBin)
	hooks := map[string]any{}
	for _, definition := range claudeRelayHookEvents {
		command := fmt.Sprintf("test -x %s && %s %s%s || :", quoted, quoted, claudeHookInstallMarker, definition.subcommand)
		group := map[string]any{
			"matcher": definition.matcher,
			"hooks": []any{map[string]any{
				"type":    "command",
				"command": command,
				"timeout": claudeHookDeclaredTimeout,
			}},
		}
		existing, _ := hooks[definition.event].([]any)
		hooks[definition.event] = append(existing, group)
	}
	return map[string]any{"hooks": hooks}
}

// removeInstalledClaudeHooks drops cmux-installed hook commands, then any
// group, event, or hooks object they leave empty. Other hooks are untouched.
func removeInstalledClaudeHooks(settings map[string]any) {
	hooks, ok := settings["hooks"].(map[string]any)
	if !ok {
		return
	}
	for event, rawGroups := range hooks {
		groups, ok := rawGroups.([]any)
		if !ok {
			continue
		}
		var keptGroups []any
		for _, rawGroup := range groups {
			group, ok := rawGroup.(map[string]any)
			entries, entriesOK := group["hooks"].([]any)
			if !ok || !entriesOK {
				keptGroups = append(keptGroups, rawGroup)
				continue
			}
			var keptEntries []any
			for _, rawEntry := range entries {
				entry, _ := rawEntry.(map[string]any)
				command, _ := entry["command"].(string)
				if strings.Contains(command, claudeHookInstallMarker) {
					continue
				}
				keptEntries = append(keptEntries, rawEntry)
			}
			if len(keptEntries) == 0 {
				continue
			}
			if len(keptEntries) != len(entries) {
				group["hooks"] = keptEntries
			}
			keptGroups = append(keptGroups, group)
		}
		if len(keptGroups) == 0 {
			delete(hooks, event)
		} else {
			hooks[event] = keptGroups
		}
	}
	if len(hooks) == 0 {
		delete(settings, "hooks")
	}
}

// updateClaudeUserSettingsFile rewrites a settings file through update. A
// file that is not a JSON object is left alone. The write replaces the
// resolved file atomically and keeps its mode; a new file is private.
func updateClaudeUserSettingsFile(path string, update func(map[string]any)) error {
	target := path
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		target = resolved
	}
	settings := map[string]any{}
	mode := fs.FileMode(0o600)
	data, err := os.ReadFile(target)
	switch {
	case err == nil:
		if trimmed := bytes.TrimSpace(data); len(trimmed) > 0 {
			if err := json.Unmarshal(trimmed, &settings); err != nil || settings == nil {
				return fmt.Errorf("%s is not a JSON object; leaving it unchanged", path)
			}
		}
		if info, err := os.Stat(target); err == nil {
			mode = info.Mode().Perm()
		}
	case errors.Is(err, fs.ErrNotExist):
		if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
			return err
		}
	default:
		return err
	}
	update(settings)
	var encoded bytes.Buffer
	encoder := json.NewEncoder(&encoded)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(settings); err != nil {
		return err
	}
	file, err := os.CreateTemp(filepath.Dir(target), ".settings-*.json")
	if err != nil {
		return err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	if _, err := file.Write(encoded.Bytes()); err != nil {
		return err
	}
	if err := file.Chmod(mode); err != nil {
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	return os.Rename(file.Name(), target)
}
