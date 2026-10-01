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
// The provider must identify the command being executed — its program, or the
// script an interpreter runs, after any leading `env`/`NAME=value` prefix — so
// an ordinary command that merely mentions the words (`echo 'omp hud'`) is not
// a HUD launch. A shim-owned pane is trusted only for the `hud --watch` form
// the providers actually run.
func tmuxHudProviderForCommand(args []string) string {
	text := strings.ToLower(strings.Join(args, " "))
	if !tmuxHudTextContainsWord(text, "hud") {
		return ""
	}

	if provider := tmuxHudProviderExecutingCommand(args); provider != "" {
		return provider
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

// tmuxHudInterpreterNames are the runtimes the providers' HUD scripts launch
// under when the script is not executable directly.
var tmuxHudInterpreterNames = map[string]bool{"node": true, "bun": true, "deno": true}

// tmuxHudProviderExecutingCommand names the provider a command actually runs,
// or "" when the provider words appear only in its argument text. A leading
// `env` and `NAME=value` prefix is skipped first, and an interpreter's script
// argument identifies its provider the way a directly executed provider binary
// does: `omp hud`, `node omp.js hud`, and
// `env OMP_SESSION_ID=x node '/opt/oh-my-pi/dist/cli/omp.js' hud` all run the
// omp HUD, while `echo 'omp hud'` runs echo.
func tmuxHudProviderExecutingCommand(args []string) string {
	index := 0
	for index < len(args) {
		if args[index] == "env" || tmuxHudIsEnvironmentAssignment(args[index]) {
			index++
			continue
		}
		break
	}
	if index >= len(args) {
		return ""
	}
	if provider := tmuxHudProviderForExecutableName(args[index]); provider != "" {
		return provider
	}
	if !tmuxHudInterpreterNames[tmuxHudExecutableName(args[index])] || index+1 >= len(args) {
		return ""
	}
	for _, component := range strings.Split(args[index+1], "/") {
		if provider := tmuxHudProviderForExecutableName(component); provider != "" {
			return provider
		}
	}
	return ""
}

// tmuxHudIsEnvironmentAssignment reports whether a token is a leading
// `NAME=value` environment assignment (`env FOO=1 cmd`).
func tmuxHudIsEnvironmentAssignment(token string) bool {
	equals := strings.IndexByte(token, '=')
	if equals <= 0 {
		return false
	}
	for index, c := range token[:equals] {
		alphaNumeric := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
			(c >= '0' && c <= '9') || c == '_'
		if !alphaNumeric {
			return false
		}
		if index == 0 && c >= '0' && c <= '9' {
			return false
		}
	}
	return true
}

func tmuxHudProviderForExecutableName(token string) string {
	name := tmuxHudExecutableName(token)
	for _, provider := range tmuxHudProviders {
		for _, word := range provider.commandWords {
			if name == word {
				return provider.name
			}
		}
	}
	return ""
}

// tmuxHudExecutableName reduces a path token to its extensionless basename, so
// `omp.js` identifies the omp provider.
func tmuxHudExecutableName(token string) string {
	base := strings.ToLower(filepath.Base(token))
	if dot := strings.LastIndexByte(base, '.'); dot > 0 {
		return base[:dot]
	}
	return base
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

	// The dedicated HUD file may disable the HUD through the top-level
	// `enabled`/`disabled` spelling; a shared config keeps those keys for the
	// agent itself, matching the local CLI's per-file policy.
	type hudConfigCandidate struct {
		path             string
		allowTopLevelHUD bool
	}
	var candidates []hudConfigCandidate
	appendCandidates := func(dir string, extra []string) {
		if dir == "" {
			return
		}
		candidates = append(candidates,
			hudConfigCandidate{filepath.Join(dir, "."+provider, "hud-config.json"), true},
			hudConfigCandidate{filepath.Join(dir, "."+provider, "config.json"), false},
			hudConfigCandidate{filepath.Join(dir, "."+provider+"-config.json"), false},
		)
		for _, relative := range extra {
			candidates = append(candidates, hudConfigCandidate{filepath.Join(dir, relative), false})
		}
	}
	appendCandidates(strings.TrimSpace(cwd), nil)
	if home, err := os.UserHomeDir(); err == nil {
		appendCandidates(home, tmuxHudProviderExtraHomeConfigPaths(provider))
	}

	for _, candidate := range candidates {
		if tmuxHudConfigFileDisablesHud(candidate.path, candidate.allowTopLevelHUD) {
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
// the HUD off. Only the provider's dedicated HUD file may do so through the
// top-level `enabled`/`disabled` spelling; a shared config file keeps those keys
// for the agent itself, mirroring the local CLI.
func tmuxHudConfigFileDisablesHud(path string, allowTopLevelHUDKeys bool) bool {
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	var dictionary map[string]any
	if err := json.Unmarshal(data, &dictionary); err != nil {
		return false
	}
	if allowTopLevelHUDKeys {
		if value, ok := tmuxHudBoolValue(dictionary["enabled"]); ok && !value {
			return true
		}
		if value, ok := tmuxHudBoolValue(dictionary["disabled"]); ok && value {
			return true
		}
	}
	for _, key := range []string{"hudEnabled", "omxHudEnabled", "ompHudEnabled"} {
		if value, ok := tmuxHudBoolValue(dictionary[key]); ok && !value {
			return true
		}
	}
	for _, key := range []string{"hudDisabled", "omxHudDisabled", "ompHudDisabled"} {
		if value, ok := tmuxHudBoolValue(dictionary[key]); ok && value {
			return true
		}
	}
	nestedCandidates := []any{
		dictionary["hud"], dictionary["omxHud"], dictionary["ompHud"], dictionary["hudPane"],
	}
	if omx, ok := dictionary["omx"].(map[string]any); ok {
		nestedCandidates = append(nestedCandidates, omx["hud"])
	}
	if omp, ok := dictionary["omp"].(map[string]any); ok {
		nestedCandidates = append(nestedCandidates, omp["hud"])
	}
	for _, candidate := range nestedCandidates {
		nested, ok := candidate.(map[string]any)
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

// tmuxHudDividerPositionParams assembles the HUD split's compact-size request.
// Command-bearing parameters (the startup script, the raw start command) are
// denied by the relay on every method, so the HUD command is typed into the new
// pane instead and only the layout request travels with the split.
func tmuxHudDividerPositionParams(rc *rpcContext, workspaceId, paneId, surfaceId, direction, sizeRaw string) map[string]any {
	params := map[string]any{}
	if cells, ok := tmuxSplitSizeCells(sizeRaw); ok {
		if position, ok := tmuxDividerPositionForTarget(rc, workspaceId, paneId, surfaceId, direction, cells); ok {
			params["initial_divider_position"] = position
		}
	}
	return params
}
