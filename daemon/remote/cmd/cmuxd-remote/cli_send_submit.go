package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"time"
)

const sendSubmitAttempts = 3
const sendMaximumEncodedTextBytes = 15 * 1024 * 1024

// runSendRelay keeps the paste and its submit key as separate RPC requests.
// This matters for bracketed-paste mode: a return embedded in the paste is
// data, while surface.send_key is a real terminal key event.
func runSendRelay(socketPath string, args []string, jsonOutput bool, refreshAddr func() string) int {
	submit, force, remaining := splitLeadingSendFlags(args)
	parsed, err := parseFlags(remaining, []string{"surface", "workspace", "window"})
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux send: %v\n", err)
		return 2
	}
	if len(parsed.positional) == 0 {
		fmt.Fprintln(os.Stderr, "cmux send: requires text")
		return 2
	}
	text := strings.Join(parsed.positional, " ")
	if encoded, marshalErr := json.Marshal([]string{text}); marshalErr != nil || len(encoded) > sendMaximumEncodedTextBytes {
		fmt.Fprintf(os.Stderr, "cmux send: text is too large; the limit is %d MiB after JSON escaping\n", sendMaximumEncodedTextBytes/(1024*1024))
		return 2
	}
	target := make(map[string]any, 3)
	for _, key := range []string{"surface", "workspace", "window"} {
		if value, ok := parsed.flags[key]; ok {
			target[flagToParamKey(key)] = value
		}
	}
	applyWorkspaceEnvFallback(target)
	applySurfaceEnvFallback(target)

	var state map[string]any
	var screen string
	if !force {
		state, screen, err = inspectSendTarget(socketPath, target, refreshAddr)
		if err != nil {
			fmt.Fprintf(os.Stderr, "cmux send: refusing to send: %v\n", err)
			return 1
		}
		if sendStateBlocksText(state) {
			fmt.Fprintln(os.Stderr, "cmux send: refusing to send: target has a human draft or open dialog (use --force to override)")
			return 1
		}
	}

	if !submit {
		params := cloneParams(target)
		params["text"] = text
		resp, err := socketRoundTripV2(socketPath, "surface.send_text", params, refreshAddr)
		if err != nil {
			fmt.Fprintf(os.Stderr, "cmux: %v\n", err)
			return 1
		}
		if jsonOutput {
			fmt.Println(resp)
		} else {
			fmt.Println(defaultRelayOutput(resp))
		}
		return 0
	}

	// --force still needs a snapshot to choose the agent's submit key. If the
	// snapshot is unavailable, the screen-only classifier safely treats this as
	// a shell and uses Return.
	if state == nil {
		state, screen, _ = inspectSendTarget(socketPath, target, refreshAddr)
	}
	params := cloneParams(target)
	params["text"] = text
	params["submit_key"] = "none"
	if _, err := socketRoundTripV2(socketPath, "terminal.paste", params, refreshAddr); err != nil {
		fmt.Fprintf(os.Stderr, "cmux: %v\n", err)
		return 1
	}
	time.Sleep(50 * time.Millisecond)
	if agentState := sendStateAgent(state); agentState {
		// Hooks can update lifecycle metadata while the paste is being applied;
		// refresh it before selecting Return versus Tab/Ctrl-Enter.
		if refreshed, refreshedScreen := readSendState(socketPath, target, refreshAddr); refreshed != nil {
			state = refreshed
			if refreshedScreen != "" {
				screen = refreshedScreen
			}
		}
	}

	agent := sendStateAgent(state)
	if !agent && screen != "" {
		fallback := sendStateFromScreen(screen)
		agent = sendStateAgent(fallback)
		if state == nil {
			state = fallback
		}
	}
	key := "return"
	if agent && sendStateLooksLikeBusyCodex(state, screen) {
		key = "tab"
	} else if agent && strings.ContainsAny(text, "\r\n") && strings.Contains(strings.ToLower(stateString(state, "agent_kind")), "claude") {
		key = "ctrl+enter"
	}
	minimumAttempts := 1
	if key != "tab" && sendScreenShowsSlashPopup(screen) {
		minimumAttempts = 2
	}

	var lastState map[string]any
	for attempt := 0; attempt < sendSubmitAttempts; attempt++ {
		keyParams := cloneParams(target)
		keyParams["key"] = key
		if _, err := socketRoundTripV2(socketPath, "surface.send_key", keyParams, refreshAddr); err != nil {
			fmt.Fprintf(os.Stderr, "cmux: submit key failed: %v\n", err)
			return 1
		}
		time.Sleep(time.Duration(50*(attempt+1)) * time.Millisecond)
		if !agent {
			return printSendSubmitResult("submitted", jsonOutput)
		}
		lastState, screen = readSendState(socketPath, target, refreshAddr)
		if sendStateDialog(lastState) {
			if screen == "" {
				screen, _ = readSendScreen(socketPath, target, refreshAddr)
			}
			if !sendScreenShowsSlashPopup(screen) {
				fmt.Fprintln(os.Stderr, "cmux send: target opened a dialog while submitting; nothing was confirmed as submitted")
				return 1
			}
		}
		if sendStateConfirmed(lastState, screen) && attempt+1 >= minimumAttempts {
			status := "submitted"
			if key == "tab" || sendStateQueued(lastState) {
				status = "queued"
			}
			return printSendSubmitResult(status, jsonOutput)
		}
	}

	if sendStateDialog(lastState) {
		fmt.Fprintln(os.Stderr, "cmux send: target opened a dialog while submitting; nothing was confirmed as submitted")
	} else {
		fmt.Fprintf(os.Stderr, "cmux send: composer still contains the message after %d submit attempts; nothing was confirmed as submitted\n", sendSubmitAttempts)
	}
	return 1
}

func splitLeadingSendFlags(args []string) (submit, force bool, remaining []string) {
	remaining = args
	var prefix []string
	for i := 0; i < len(remaining); {
		token := remaining[i]
		if token == "--" {
			prefix = append(prefix, remaining[i:]...)
			break
		}
		if token == "--surface" || token == "--workspace" || token == "--window" {
			prefix = append(prefix, token)
			if i+1 < len(remaining) {
				prefix = append(prefix, remaining[i+1])
				i += 2
				continue
			}
			break
		}
		switch token {
		case "--submit":
			submit = true
		case "--force":
			force = true
		default:
			prefix = append(prefix, remaining[i:]...)
			return submit, force, prefix
		}
		i++
	}
	return submit, force, prefix
}

func inspectSendTarget(socketPath string, target map[string]any, refreshAddr func() string) (map[string]any, string, error) {
	state, err := readSendInputState(socketPath, target, refreshAddr)
	if err == nil {
		if agentValue, hasAgent := state["agent"]; hasAgent {
			if agent, isBool := agentValue.(bool); isBool && !agent {
				// Plain shells have no composer; the separate Return key is the
				// complete submit contract, so avoid an unnecessary screen probe.
				return state, "", nil
			}
		}
		screen, _ := readSendScreen(socketPath, target, refreshAddr)
		// A relay may answer input_state without hook metadata. Prefer the
		// visible prompt classifier when it can identify an agent composer, so a
		// hookless human draft still cannot be overwritten.
		if !sendStateAgent(state) && screen != "" {
			if fallback := sendStateFromScreen(screen); sendStateAgent(fallback) {
				state = fallback
			}
		}
		return state, screen, nil
	}
	// Older relays may not expose input_state. Screen text is a conservative
	// fallback for hookless SSH panes, and still refuses visible drafts/dialogs.
	screen, screenErr := readSendScreen(socketPath, target, refreshAddr)
	if screenErr != nil {
		return nil, "", fmt.Errorf("cannot inspect target input state: %v", err)
	}
	return sendStateFromScreen(screen), screen, nil
}

func readSendInputState(socketPath string, target map[string]any, refreshAddr func() string) (map[string]any, error) {
	resp, err := socketRoundTripV2(socketPath, "surface.input_state", target, refreshAddr)
	if err != nil {
		return nil, err
	}
	var state map[string]any
	if err := json.Unmarshal([]byte(resp), &state); err != nil {
		return nil, err
	}
	return state, nil
}

func readSendScreen(socketPath string, target map[string]any, refreshAddr func() string) (string, error) {
	resp, err := socketRoundTripV2(socketPath, "surface.read_text", target, refreshAddr)
	if err != nil {
		return "", err
	}
	var payload struct {
		Text string `json:"text"`
	}
	if err := json.Unmarshal([]byte(resp), &payload); err != nil {
		return "", err
	}
	return payload.Text, nil
}

func readSendState(socketPath string, target map[string]any, refreshAddr func() string) (map[string]any, string) {
	state, err := readSendInputState(socketPath, target, refreshAddr)
	if err == nil {
		return state, ""
	}
	screen, _ := readSendScreen(socketPath, target, refreshAddr)
	return sendStateFromScreen(screen), screen
}

func sendStateBlocksText(state map[string]any) bool {
	if !sendStateAgent(state) {
		return false
	}
	return sendStateDialog(state) || stateString(state, "state") == "draft" || boolValue(state, "blocks_typing")
}

func sendStateAgent(state map[string]any) bool { return boolValue(state, "agent") }
func sendStateDialog(state map[string]any) bool {
	return sendStateAgent(state) && stateString(state, "state") == "dialog"
}
func sendStateQueued(state map[string]any) bool {
	return stateString(state, "state") == "queued" || boolValue(state, "queued")
}
func sendStateConfirmed(state map[string]any, screen string) bool {
	if stateString(state, "state") == "empty" || sendStateQueued(state) {
		return true
	}
	if screen != "" {
		fallback := sendStateFromScreen(screen)
		return stateString(fallback, "state") == "empty" || sendStateQueued(fallback)
	}
	return false
}

func sendStateLooksLikeBusyCodex(state map[string]any, screen string) bool {
	if strings.Contains(strings.ToLower(stateString(state, "agent_kind")), "codex") && stateString(state, "lifecycle") == "running" {
		return true
	}
	return sendScreenLooksLikeCodex(screen) && stateString(state, "lifecycle") == "running"
}

func sendStateFromScreen(screen string) map[string]any {
	lower := strings.ToLower(screen)
	for _, hint := range []string{"esc to cancel", "esc to go back", "press enter to", "enter to confirm", "enter to select"} {
		if strings.Contains(lower, hint) {
			return map[string]any{"state": "dialog", "agent": true, "blocks_typing": true}
		}
	}
	lines := strings.Split(screen, "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		trimmed := strings.TrimSpace(lines[i])
		if strings.HasPrefix(trimmed, "│") {
			trimmed = strings.TrimSpace(strings.TrimPrefix(trimmed, "│"))
		}
		if strings.HasPrefix(trimmed, "❯") || strings.HasPrefix(trimmed, "›") || strings.HasPrefix(trimmed, "> ") {
			body := promptBody(trimmed)
			return map[string]any{"state": map[bool]string{true: "draft", false: "empty"}[body != ""], "agent": true, "blocks_typing": body != ""}
		}
	}
	return map[string]any{"state": "unknown", "agent": false, "blocks_typing": false}
}

func sendScreenLooksLikeCodex(screen string) bool {
	for _, line := range strings.Split(screen, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "›") || strings.HasPrefix(trimmed, "> ") {
			return true
		}
	}
	return false
}

func sendScreenShowsSlashPopup(screen string) bool {
	lines := strings.Split(screen, "\n")
	prompt := ""
	for i := len(lines) - 1; i >= 0; i-- {
		trimmed := strings.TrimSpace(lines[i])
		if strings.HasPrefix(trimmed, "❯") || strings.HasPrefix(trimmed, "›") {
			prompt = promptBody(trimmed)
			break
		}
	}
	if !strings.HasPrefix(prompt, "/") {
		return false
	}
	for _, line := range lines {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "/") && trimmed != prompt {
			return true
		}
	}
	return false
}

func promptBody(line string) string {
	for _, glyph := range []string{"❯", "›", ">"} {
		if strings.HasPrefix(line, glyph) {
			return strings.TrimSpace(strings.TrimPrefix(line, glyph))
		}
	}
	return strings.TrimSpace(line)
}

func stateString(state map[string]any, key string) string {
	value, _ := state[key].(string)
	return strings.ToLower(value)
}

func boolValue(state map[string]any, key string) bool {
	value, _ := state[key].(bool)
	return value
}

func cloneParams(params map[string]any) map[string]any {
	copy := make(map[string]any, len(params))
	for key, value := range params {
		copy[key] = value
	}
	return copy
}

func printSendSubmitResult(status string, jsonOutput bool) int {
	if jsonOutput {
		payload, _ := json.Marshal(map[string]any{"status": status, "submitted": status == "submitted", "queued": status == "queued"})
		fmt.Println(string(payload))
	} else {
		fmt.Println(status)
	}
	return 0
}
