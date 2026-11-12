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
// the user settings file they merge (a routed launcher, for example, merges
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
	var changed bool
	var err error
	switch action {
	case "install":
		cmuxBin, binErr := claudeHookInstalledCmuxBinary()
		if binErr != nil {
			err = binErr
			break
		}
		changed, err = updateClaudeUserSettingsFile(settingsPath, func(settings map[string]any) error {
			if _, present := settings["hooks"]; present {
				if _, ok := settings["hooks"].(map[string]any); !ok {
					return errors.New(`"hooks" is not a JSON object; leaving the settings file unchanged`)
				}
			}
			removeInstalledClaudeHooks(settings)
			mergeClaudeSettings(settings, installedClaudeHookSettings(cmuxBin))
			return nil
		})
		if err == nil {
			if changed {
				fmt.Fprintf(stdout, "cmux: installed status hooks in %s\n", settingsPath)
				fmt.Fprintln(stdout, "cmux: restart running agent sessions to load them")
			} else {
				fmt.Fprintf(stdout, "cmux: status hooks are already installed in %s\n", settingsPath)
			}
		}
	case "uninstall":
		changed, err = updateClaudeUserSettingsFile(settingsPath, func(settings map[string]any) error {
			removeInstalledClaudeHooks(settings)
			return nil
		})
		if err == nil {
			if changed {
				fmt.Fprintf(stdout, "cmux: removed status hooks from %s\n", settingsPath)
			} else {
				fmt.Fprintf(stdout, "cmux: no status hooks installed in %s\n", settingsPath)
			}
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

// claudeHookInstalledCmuxBinary is the CLI path written into user settings:
// the relay's stable entrypoint, which follows daemon and app upgrades. The
// installed command skips itself while that path is missing.
func claudeHookInstalledCmuxBinary() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return "", errors.New("could not locate the home directory for the cmux CLI path")
	}
	return filepath.Join(home, ".cmux", "bin", "cmux"), nil
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
// group, event, or hooks object that removal leaves empty. Other hooks,
// including empty ones the user wrote, are untouched.
func removeInstalledClaudeHooks(settings map[string]any) {
	hooks, ok := settings["hooks"].(map[string]any)
	if !ok {
		return
	}
	removedEvent := false
	for event, rawGroups := range hooks {
		groups, ok := rawGroups.([]any)
		if !ok {
			continue
		}
		keptGroups := make([]any, 0, len(groups))
		for _, rawGroup := range groups {
			group, ok := rawGroup.(map[string]any)
			entries, entriesOK := group["hooks"].([]any)
			if !ok || !entriesOK {
				keptGroups = append(keptGroups, rawGroup)
				continue
			}
			keptEntries := make([]any, 0, len(entries))
			for _, rawEntry := range entries {
				entry, _ := rawEntry.(map[string]any)
				command, _ := entry["command"].(string)
				if strings.Contains(command, claudeHookInstallMarker) {
					continue
				}
				keptEntries = append(keptEntries, rawEntry)
			}
			if len(keptEntries) == len(entries) {
				keptGroups = append(keptGroups, rawGroup)
				continue
			}
			if len(keptEntries) > 0 {
				group["hooks"] = keptEntries
				keptGroups = append(keptGroups, group)
			}
		}
		if len(keptGroups) == len(groups) {
			continue
		}
		if len(keptGroups) == 0 {
			delete(hooks, event)
			removedEvent = true
		} else {
			hooks[event] = keptGroups
		}
	}
	if removedEvent && len(hooks) == 0 {
		delete(settings, "hooks")
	}
}

// updateClaudeUserSettingsFile rewrites a settings file through update and
// reports whether it changed. A file that is not a JSON object is left alone,
// and nothing is written (or created) when update changes nothing. Numbers
// keep their exact text. The write replaces the resolved file atomically and
// keeps its mode; a new file is private.
func updateClaudeUserSettingsFile(path string, update func(map[string]any) error) (bool, error) {
	target := path
	if resolved, err := filepath.EvalSymlinks(path); err == nil {
		target = resolved
	}
	settings := map[string]any{}
	mode := fs.FileMode(0o600)
	exists := false
	data, err := os.ReadFile(target)
	switch {
	case err == nil:
		exists = true
		if trimmed := bytes.TrimSpace(data); len(trimmed) > 0 {
			if err := decodeClaudeSettingsObject(trimmed, &settings); err != nil {
				return false, fmt.Errorf("%s is not a JSON object; leaving it unchanged", path)
			}
		}
		if info, err := os.Stat(target); err == nil {
			mode = info.Mode().Perm()
		}
	case errors.Is(err, fs.ErrNotExist):
	default:
		return false, err
	}
	before, err := encodeClaudeSettings(settings)
	if err != nil {
		return false, err
	}
	if err := update(settings); err != nil {
		return false, fmt.Errorf("%s: %w", path, err)
	}
	after, err := encodeClaudeSettings(settings)
	if err != nil {
		return false, err
	}
	if bytes.Equal(before, after) {
		return false, nil
	}
	if !exists {
		if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
			return false, err
		}
	}
	file, err := os.CreateTemp(filepath.Dir(target), ".settings-*.json")
	if err != nil {
		return false, err
	}
	defer os.Remove(file.Name())
	defer file.Close()
	if _, err := file.Write(after); err != nil {
		return false, err
	}
	if err := file.Chmod(mode); err != nil {
		return false, err
	}
	if err := file.Sync(); err != nil {
		return false, err
	}
	if err := file.Close(); err != nil {
		return false, err
	}
	if err := os.Rename(file.Name(), target); err != nil {
		return false, err
	}
	return true, nil
}

// decodeClaudeSettingsObject parses exactly one JSON object, keeping numbers
// as json.Number so large integers survive a rewrite.
func decodeClaudeSettingsObject(data []byte, settings *map[string]any) error {
	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	if err := decoder.Decode(settings); err != nil {
		return err
	}
	if *settings == nil {
		return errors.New("settings are null")
	}
	if _, err := decoder.Token(); err != io.EOF {
		return errors.New("trailing data after the settings object")
	}
	return nil
}

// encodeClaudeSettings is the file form of settings: indented, keys sorted.
func encodeClaudeSettings(settings map[string]any) ([]byte, error) {
	var encoded bytes.Buffer
	encoder := json.NewEncoder(&encoded)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(settings); err != nil {
		return nil, err
	}
	return encoded.Bytes(), nil
}
