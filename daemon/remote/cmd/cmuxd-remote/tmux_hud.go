package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// tmuxHudProvider describes one managed launcher's tmux HUD. The fields mirror
// the Swift CLI's `TmuxCompatHudProvider` so a remote split produces the same
// result a local one does.
type tmuxHudProvider struct {
	name         string
	commandWords []string
	shimEnvKey   string
	// extraHomeConfigPaths are provider-specific config locations outside the
	// provider's own dot-directory.
	extraHomeConfigPaths []string
}

var tmuxHudProviders = []tmuxHudProvider{
	{
		name:                 "omx",
		commandWords:         []string{"omx", "oh-my-codex"},
		shimEnvKey:           "CMUX_OMX_CMUX_BIN",
		extraHomeConfigPaths: []string{".codex/.omx-config.json"},
	},
	{
		name:         "omp",
		commandWords: []string{"omp", "oh-my-pi"},
		shimEnvKey:   "CMUX_OMP_CMUX_BIN",
	},
}

// tmuxHudProviderForCommand reports which provider's HUD these arguments launch,
// or "" when they are not a HUD launch.
//
// A command that names the provider is the positive signature. A shim-owned pane
// is trusted only for the `hud --watch` form the providers actually run, so
// `echo hud` inside a provider shell is not mistaken for a HUD launch.
func tmuxHudProviderForCommand(args []string) string {
	text := strings.ToLower(strings.Join(args, " "))
	if !tmuxHudTextContainsWord(text, "hud") {
		return ""
	}

	for _, provider := range tmuxHudProviders {
		for _, word := range provider.commandWords {
			if tmuxHudTextContainsWord(text, word) {
				return provider.name
			}
		}
	}

	if !strings.Contains(text, "--watch") {
		return ""
	}

	// CMUX_AGENT_LAUNCH_KIND is the more specific signal: a launcher records it for
	// the process it started, while a shim binary path can be inherited from an
	// outer provider's shell.
	if kind := strings.ToLower(strings.TrimSpace(os.Getenv("CMUX_AGENT_LAUNCH_KIND"))); kind != "" {
		for _, provider := range tmuxHudProviders {
			if provider.name == kind {
				return provider.name
			}
		}
	}
	for _, provider := range tmuxHudProviders {
		if strings.TrimSpace(os.Getenv(provider.shimEnvKey)) != "" {
			return provider.name
		}
	}
	return ""
}

// tmuxHudTextContainsWord matches a word on ASCII identifier boundaries, so
// `prompt` is not read as `omp`.
func tmuxHudTextContainsWord(text, word string) bool {
	if word == "" {
		return false
	}
	index := 0
	for {
		found := strings.Index(text[index:], word)
		if found < 0 {
			return false
		}
		start := index + found
		end := start + len(word)
		if tmuxHudIsWordBoundary(text, start-1) && tmuxHudIsWordBoundary(text, end) {
			return true
		}
		index = end
	}
}

func tmuxHudIsWordBoundary(text string, index int) bool {
	if index < 0 || index >= len(text) {
		return true
	}
	c := text[index]
	switch {
	case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c >= '0' && c <= '9':
		return false
	case c == '_' || c == '-':
		return false
	default:
		return true
	}
}

// tmuxHudConfigDisablesHud mirrors the Swift CLI: provider environment switches
// plus the provider's HUD config files in the working directory and home.
func tmuxHudConfigDisablesHud(provider, cwd string) bool {
	upper := strings.ToUpper(provider)
	for _, key := range []string{upper + "_HUD_ENABLED", "CMUX_" + upper + "_HUD_ENABLED"} {
		if value, ok := tmuxHudBoolValue(os.Getenv(key)); ok && !value {
			return true
		}
	}
	for _, key := range []string{upper + "_HUD_DISABLED", "CMUX_" + upper + "_HUD_DISABLED"} {
		if value, ok := tmuxHudBoolValue(os.Getenv(key)); ok && value {
			return true
		}
	}

	var candidates []string
	appendCandidates := func(dir string, extra []string) {
		if dir == "" {
			return
		}
		candidates = append(candidates,
			filepath.Join(dir, "."+provider, "hud-config.json"),
			filepath.Join(dir, "."+provider, "config.json"),
			filepath.Join(dir, "."+provider+"-config.json"),
		)
		for _, relative := range extra {
			candidates = append(candidates, filepath.Join(dir, relative))
		}
	}
	appendCandidates(strings.TrimSpace(cwd), nil)
	if home, err := os.UserHomeDir(); err == nil {
		appendCandidates(home, tmuxHudProviderExtraHomeConfigPaths(provider))
	}

	for _, candidate := range candidates {
		if tmuxHudConfigFileDisablesHud(candidate) {
			return true
		}
	}
	return false
}

func tmuxHudProviderExtraHomeConfigPaths(provider string) []string {
	for _, candidate := range tmuxHudProviders {
		if candidate.name == provider {
			return candidate.extraHomeConfigPaths
		}
	}
	return nil
}

// tmuxHudConfigFileDisablesHud reads a JSON config and reports whether it turns
// the HUD off, accepting both the provider's own top-level `enabled` spelling and
// HUD-scoped keys.
func tmuxHudConfigFileDisablesHud(path string) bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	var dictionary map[string]any
	if err := json.Unmarshal(data, &dictionary); err != nil {
		return false
	}
	for _, key := range []string{"enabled", "hudEnabled", "omxHudEnabled", "ompHudEnabled"} {
		if value, ok := tmuxHudBoolValue(dictionary[key]); ok && !value {
			return true
		}
	}
	for _, key := range []string{"disabled", "hudDisabled", "omxHudDisabled", "ompHudDisabled"} {
		if value, ok := tmuxHudBoolValue(dictionary[key]); ok && value {
			return true
		}
	}
	for _, key := range []string{"hud", "omxHud", "ompHud", "hudPane"} {
		nested, ok := dictionary[key].(map[string]any)
		if !ok {
			continue
		}
		if value, ok := tmuxHudBoolValue(nested["enabled"]); ok && !value {
			return true
		}
		if value, ok := tmuxHudBoolValue(nested["disabled"]); ok && value {
			return true
		}
	}
	return false
}

func tmuxHudBoolValue(raw any) (bool, bool) {
	switch value := raw.(type) {
	case nil:
		return false, false
	case bool:
		return value, true
	case float64:
		return value != 0, true
	case string:
		switch strings.ToLower(strings.TrimSpace(value)) {
		case "1", "true", "yes", "on", "enabled":
			return true, true
		case "0", "false", "no", "off", "disabled":
			return false, true
		default:
			return false, false
		}
	default:
		return false, false
	}
}

// tmuxHudConfiguredCwd resolves the working directory a HUD config check should
// read, matching the local path's resolution of `-c`.
func tmuxHudConfiguredCwd(raw string) string {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return ""
	}
	if resolved := tmuxNormalizePath(trimmed); resolved != "" {
		return resolved
	}
	return trimmed
}

// tmuxHudStartupScript writes the pane's startup script on the host that runs the
// pane, so the HUD command launches as a pane command rather than being typed
// into a shell. It mirrors the local CLI's generated script.
func tmuxHudStartupScript(commandText string, cwd string) string {
	trimmed := strings.TrimSpace(commandText)
	if trimmed == "" {
		return ""
	}
	file, err := os.CreateTemp("", "cmux-tmux-command-*.sh")
	if err != nil {
		return ""
	}
	path := file.Name()
	lines := []string{
		"#!/bin/sh",
		`rm -f -- "$0" 2>/dev/null || true`,
	}
	if resolved := strings.TrimSpace(cwd); resolved != "" {
		lines = append(lines, "cd -- "+tmuxShellSingleQuote(resolved)+" || exit $?")
	}
	lines = append(lines, `exec "${SHELL:-/bin/sh}" -lc `+tmuxShellSingleQuote(trimmed))
	contents := strings.Join(lines, "\n") + "\n"
	_, writeErr := file.WriteString(contents)
	closeErr := file.Close()
	if writeErr != nil || closeErr != nil {
		_ = os.Remove(path)
		return ""
	}
	if err := os.Chmod(path, 0o700); err != nil {
		_ = os.Remove(path)
		return ""
	}
	return path
}

func tmuxShellSingleQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", `'\''`) + "'"
}

// tmuxSplitSizeCells parses a `-l` size in cells. Percentages are handled by the
// divider-position path instead.
func tmuxSplitSizeCells(raw string) (int, bool) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" || strings.Contains(trimmed, "%") {
		return 0, false
	}
	cells, err := strconv.Atoi(trimmed)
	if err != nil {
		return 0, false
	}
	return cells, true
}

// tmuxInitialDividerPosition computes the divider position that gives the new
// pane the requested number of cells, clamped the way the local path clamps it.
func tmuxInitialDividerPosition(pane map[string]any, newPaneDirection string, targetCells int) (float64, bool) {
	if targetCells <= 0 || pane == nil {
		return 0, false
	}

	key := "rows"
	switch newPaneDirection {
	case "left", "right":
		key = "columns"
	}
	currentCells := intFromAnyGo(pane[key])
	if currentCells <= 0 {
		return 0, false
	}

	requested := targetCells
	if maximum := currentCells - 1; requested > maximum {
		requested = maximum
	}
	if requested < 1 {
		requested = 1
	}

	var rawPosition float64
	switch newPaneDirection {
	case "left", "up":
		rawPosition = float64(requested) / float64(currentCells)
	default:
		rawPosition = float64(currentCells-requested) / float64(currentCells)
	}
	if rawPosition < 0.1 {
		rawPosition = 0.1
	}
	if rawPosition > 0.9 {
		rawPosition = 0.9
	}
	return rawPosition, true
}

// tmuxDividerPositionForTarget resolves the target pane's geometry and returns
// the divider position for the requested cell count. The pane is located by id or
// ref, and by its surface when the caller only knows the surface.
func tmuxDividerPositionForTarget(rc *rpcContext, workspaceId, paneId, surfaceId, direction string, targetCells int) (float64, bool) {
	payload, err := rc.call("pane.list", map[string]any{"workspace_id": workspaceId})
	if err != nil {
		return 0, false
	}
	panes, _ := payload["panes"].([]any)

	findPane := func(match func(map[string]any) bool) map[string]any {
		for _, entry := range panes {
			pane, _ := entry.(map[string]any)
			if pane != nil && match(pane) {
				return pane
			}
		}
		return nil
	}

	pane := findPane(func(candidate map[string]any) bool {
		return stringFromAnyGo(candidate["id"]) == paneId || stringFromAnyGo(candidate["ref"]) == paneId
	})
	if pane == nil && surfaceId != "" {
		if surfacePayload, err := rc.call("surface.list", map[string]any{"workspace_id": workspaceId}); err == nil {
			surfaces, _ := surfacePayload["surfaces"].([]any)
			for _, entry := range surfaces {
				surface, _ := entry.(map[string]any)
				if surface == nil || stringFromAnyGo(surface["id"]) != surfaceId {
					continue
				}
				surfacePaneId := stringFromAnyGo(surface["pane_id"])
				pane = findPane(func(candidate map[string]any) bool {
					return stringFromAnyGo(candidate["id"]) == surfacePaneId || stringFromAnyGo(candidate["ref"]) == surfacePaneId
				})
				break
			}
		}
	}
	if pane == nil {
		return 0, false
	}
	return tmuxInitialDividerPosition(pane, direction, targetCells)
}

// tmuxHudSplitMetadata assembles the split parameters the local CLI sends for a
// HUD pane: the generated startup script, the raw start command for restore, and
// the compact divider position.
func tmuxHudSplitMetadata(rc *rpcContext, workspaceId, paneId, surfaceId string, direction string, args []string, cwd string, sizeRaw string) map[string]any {
	params := map[string]any{}
	commandText := strings.TrimSpace(strings.Join(args, " "))
	if commandText == "" {
		return params
	}
	params["tmux_start_command"] = commandText
	if script := tmuxHudStartupScript(commandText, cwd); script != "" {
		params["initial_command"] = script
	}
	if cells, ok := tmuxSplitSizeCells(sizeRaw); ok {
		if position, ok := tmuxDividerPositionForTarget(rc, workspaceId, paneId, surfaceId, direction, cells); ok {
			params["initial_divider_position"] = position
		}
	}
	return params
}
