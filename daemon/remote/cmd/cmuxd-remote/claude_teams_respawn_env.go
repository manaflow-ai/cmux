package main

import (
	"encoding/base64"
	"encoding/json"
	"strings"
)

// claudeTeamsRespawnEnvironmentKey carries the encoded launcher environment from
// the claude-teams relay to the `__tmux-compat` process that respawns a teammate
// pane. Same key and wire format as the Swift
// ClaudeTeamsRespawnEnvironmentTransport, so either end can produce the value.
const claudeTeamsRespawnEnvironmentKey = "CMUX_CLAUDE_TEAMS_RESPAWN_ENV_B64"

// claudeTeamsRespawnEnvironmentAllowlist is deliberately narrower than the Swift
// AgentLaunchEnvironmentPolicy: PATH is the only value a remote teammate needs
// replayed, and a second hand-copied allowlist would drift from the Swift one.
var claudeTeamsRespawnEnvironmentAllowlist = []string{"PATH"}

// encodeClaudeTeamsRespawnEnvironment encodes the replay-safe subset of a
// launcher environment as base64 JSON, or "" when there is nothing to replay.
func encodeClaudeTeamsRespawnEnvironment(environ []string) string {
	environment, _ := envMapWithOrder(environ)
	selected := selectClaudeTeamsRespawnEnvironment(environment)
	if len(selected) == 0 {
		return ""
	}
	// json.Marshal sorts map keys, matching the Swift encoder's .sortedKeys.
	encoded, err := json.Marshal(selected)
	if err != nil {
		return ""
	}
	return base64.StdEncoding.EncodeToString(encoded)
}

// decodeClaudeTeamsRespawnEnvironment decodes a transport value and reapplies the
// allowlist, so a forged value cannot promote arbitrary variables into a teammate
// pane. Invalid data yields no values rather than a partial environment.
func decodeClaudeTeamsRespawnEnvironment(encoded string) map[string]string {
	data, err := base64.StdEncoding.DecodeString(strings.TrimSpace(encoded))
	if err != nil {
		return nil
	}
	var transported map[string]string
	if err := json.Unmarshal(data, &transported); err != nil {
		return nil
	}
	return selectClaudeTeamsRespawnEnvironment(transported)
}

func selectClaudeTeamsRespawnEnvironment(environment map[string]string) map[string]string {
	selected := make(map[string]string, len(claudeTeamsRespawnEnvironmentAllowlist))
	for _, key := range claudeTeamsRespawnEnvironmentAllowlist {
		// An empty value would emit `export PATH=''` and leave the pane worse off.
		if value := environment[key]; value != "" {
			selected[key] = value
		}
	}
	return selected
}
