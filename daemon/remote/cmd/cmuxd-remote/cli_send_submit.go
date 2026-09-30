package main

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
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
	agent := sendStateAgent(state)
	knownAgent := agent && (stateString(state, "agent_kind") == "claude" || stateString(state, "agent_kind") == "codex")
	ownSlashCommand := strings.HasPrefix(strings.TrimSpace(text), "/")
	if knownAgent {
		visible := false
		for probe := 0; probe < sendSubmitAttempts; probe++ {
			time.Sleep(time.Duration(100*(probe+1)) * time.Millisecond)
			state, screen = readSendState(socketPath, target, refreshAddr)
			if sendStateDialog(state) && !sendScreenShowsSlashPopup(screen) {
				fmt.Fprintln(os.Stderr, "cmux send: text was pasted but the target opened a dialog; nothing was confirmed as submitted")
				return 1
			}
			if stateString(state, "state") == "draft" || boolValue(state, "slash_popup") || sendScreenShowsSlashPopup(screen) {
				visible = true
				break
			}
		}
		if !visible {
			fmt.Fprintln(os.Stderr, "cmux send: text was pasted but never became visible in the composer; nothing was confirmed as submitted")
			return 1
		}
	} else {
		time.Sleep(50 * time.Millisecond)
	}
	var lastState map[string]any
	for attempt := 0; attempt < sendSubmitAttempts; attempt++ {
		if attempt > 0 {
			state, screen = readSendState(socketPath, target, refreshAddr)
			if sendStateConfirmed(state, screen) {
				return printSendSubmitResult(sendConfirmedStatus(state), jsonOutput)
			}
			if sendStateDialog(state) && !boolValue(state, "slash_popup") && !sendScreenShowsSlashPopup(screen) {
				return sendSubmitUnconfirmed("target opened a dialog; retry was refused", jsonOutput)
			}
			if !sendComposerMatches(screen, text) {
				return sendSubmitUnconfirmed("composer changed or could not be identified; retry was refused to preserve human input", jsonOutput)
			}
		}
		key := sendSubmitKey(state, screen, text)
		keyParams := cloneParams(target)
		keyParams["key"] = key
		if _, err := socketRoundTripV2(socketPath, "surface.send_key", keyParams, refreshAddr); err != nil {
			fmt.Fprintf(os.Stderr, "cmux: submit key failed: %v\n", err)
			return 1
		}
		time.Sleep(time.Duration(100*(attempt+1)) * time.Millisecond)
		if !knownAgent {
			if agent {
				return printSendSubmitResult("sent", jsonOutput)
			}
			return printSendSubmitResult("submitted", jsonOutput)
		}
		lastState, screen = readSendState(socketPath, target, refreshAddr)
		if sendStateDialog(lastState) {
			if screen == "" {
				screen, _ = readSendScreen(socketPath, target, refreshAddr)
			}
			if !sendScreenShowsSlashPopup(screen) {
				if ownSlashCommand {
					return printSendSubmitResult("submitted", jsonOutput)
				}
				return sendSubmitUnconfirmed("target opened a dialog while submitting", jsonOutput)
			}
		}
		if sendStateConfirmed(lastState, screen) {
			status := "submitted"
			if sendStateQueued(lastState) {
				status = "queued"
			}
			return printSendSubmitResult(status, jsonOutput)
		}
		state = lastState
	}

	// One final bounded read lets slow renderers show a clear or queued prompt
	// without sending another key.
	time.Sleep(200 * time.Millisecond)
	lastState, screen = readSendState(socketPath, target, refreshAddr)
	if sendStateConfirmed(lastState, screen) {
		return printSendSubmitResult(sendConfirmedStatus(lastState), jsonOutput)
	}
	return sendSubmitUnconfirmed("submit key was sent but submission was not confirmed after bounded retries", jsonOutput)

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
		screen, _ := readSendScreen(socketPath, target, refreshAddr)
		// A relay may answer input_state without hook metadata. Prefer the
		// visible prompt classifier when it can identify an agent composer, so a
		// hookless human draft still cannot be overwritten.
		if screen != "" {
			fallback := sendStateFromScreen(screen)
			if !sendStateAgent(state) && sendStateAgent(fallback) {
				state = fallback
			} else if sendStateAgent(state) {
				for _, key := range []string{"agent_kind", "busy", "lifecycle", "slash_popup"} {
					if _, present := state[key]; !present {
						state[key] = fallback[key]
					}
				}
				if sendStateQueued(fallback) {
					state["queued"], state["state"] = true, "queued"
				}
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
	state, screen, _ := inspectSendTarget(socketPath, target, refreshAddr)
	return state, screen
}

func sendSubmitKey(state map[string]any, screen, text string) string {
	if sendStateLooksLikeBusyCodex(state, screen) {
		return "tab"
	}
	return "return"
}

func sendConfirmedStatus(state map[string]any) string {
	if sendStateQueued(state) {
		return "queued"
	}
	return "submitted"
}

func sendSubmitUnconfirmed(reason string, jsonOutput bool) int {
	_ = printSendSubmitResult("unconfirmed", jsonOutput)
	fmt.Fprintf(os.Stderr, "cmux send: %s; text may already be submitted, do not paste it again without checking the target\n", reason)
	return 1
}

func sendComposerMatches(screen, text string) bool {
	lines := strings.Split(sendANSISequence.ReplaceAllString(screen, ""), "\n")
	body := ""
	found := false
	for _, line := range lines {
		trimmed := trimSendBox(line)
		if strings.HasPrefix(trimmed, "❯") || strings.HasPrefix(trimmed, "›") {
			body, found = promptBody(trimmed), true
		} else if found && strings.HasPrefix(strings.TrimSpace(line), "│") {
			body += " " + trimmed
		}
	}
	return found && strings.Join(strings.Fields(body), " ") == strings.Join(strings.Fields(text), " ")
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
	if boolValue(state, "slash_popup") || sendScreenShowsSlashPopup(screen) {
		return false
	}
	return sendStateAgent(state) && (stateString(state, "state") == "empty" || sendStateQueued(state))
}

func sendStateLooksLikeBusyCodex(state map[string]any, screen string) bool {
	kind := stateString(state, "agent_kind")
	if kind != "" && kind != "codex" {
		return false
	}
	if kind == "" {
		kind = stateString(sendStateFromScreen(screen), "agent_kind")
	}
	return kind == "codex" && (stateString(state, "lifecycle") == "running" || boolValue(state, "busy"))
}

var sendANSISequence = regexp.MustCompile(`\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07]*(?:\x07|\x1b\\)`)

func sendStateFromScreen(screen string) map[string]any {
	clean := sendANSISequence.ReplaceAllString(screen, "")
	lower := strings.ToLower(clean)
	lines := strings.Split(clean, "\n")
	state := map[string]any{"state": "unknown", "agent": false, "blocks_typing": false}
	kind := ""
	if sendScreenBrand(clean) == "codex" {
		kind = "codex"
	} else if sendScreenBrand(clean) == "claude" {
		kind = "claude"
	}
	promptIndex := -1
	body := ""
	for i := len(lines) - 1; i >= 0; i-- {
		rawLine := strings.Trim(lines[i], " \t│")
		line := trimSendBox(lines[i])
		if strings.HasPrefix(rawLine, "❯\u00a0") || strings.HasPrefix(rawLine, "›") || (kind == "claude" && strings.HasPrefix(line, "❯")) || (kind == "codex" && strings.HasPrefix(line, "> ")) {
			promptIndex = i
			body = promptBody(line)
			if kind == "" {
				if strings.HasPrefix(rawLine, "❯\u00a0") {
					kind = "claude"
				} else {
					kind = "codex"
				}
			}
			break
		}
	}
	if kind == "" {
		return state
	}
	state["agent"], state["agent_kind"] = true, kind
	busy := strings.Contains(lower, "esc to interrupt") || strings.Contains(lower, "tab to queue") || strings.Contains(lower, "tab to enqueue")
	state["busy"] = busy
	if busy {
		state["lifecycle"] = "running"
	}
	for _, hint := range []string{"esc to cancel", "esc to go back", "enter to confirm", "enter to select", "press enter to continue", "do you want to proceed", "allow this tool"} {
		if strings.Contains(lower, hint) && !sendScreenShowsSlashPopup(clean) {
			state["state"], state["blocks_typing"] = "dialog", true
			return state
		}
	}
	if promptIndex < 0 {
		return state
	}
	normalized := strings.ToLower(body)
	placeholder := kind == "codex" && (normalized == "ask codex to do anything" || normalized == "ask codex anything" || normalized == "ask codex to do something")
	// Keep normal user text such as "Try fixing the tests" as a draft. Only
	// an explicitly faint hint row may use Claude's changing placeholder.
	rawLines := strings.Split(screen, "\n")
	if promptIndex < len(rawLines) && strings.Contains(rawLines[promptIndex], "\x1b[2m") && (strings.HasPrefix(normalized, "try ") || strings.HasPrefix(normalized, "ask ")) {
		placeholder = true
	}
	if placeholder {
		body = ""
	}
	for _, line := range lines[promptIndex+1:] {
		trimmed := strings.TrimSpace(line)
		if !strings.HasPrefix(trimmed, "│") {
			break
		}
		continuation := trimSendBox(line)
		if continuation != "" {
			body += "\n" + continuation
		}
	}
	state["state"], state["blocks_typing"] = "empty", false
	if strings.TrimSpace(body) != "" {
		state["state"], state["blocks_typing"] = "draft", true
	}
	state["slash_popup"] = sendScreenShowsSlashPopup(clean)
	if strings.Contains(lower, "queued messages:") || strings.Contains(lower, "message queued") || strings.Contains(lower, "queued message") {
		state["queued"], state["state"] = true, "queued"
	}
	return state
}

func sendScreenBrand(screen string) string {
	for _, line := range strings.Split(screen, "\n") {
		trimmed := strings.ToLower(trimSendBox(line))
		if strings.HasPrefix(trimmed, "openai codex") || trimmed == "codex" || strings.HasPrefix(trimmed, "codex v") {
			return "codex"
		}
		if strings.HasPrefix(trimmed, "claude code") {
			return "claude"
		}
	}
	return ""
}

func trimSendBox(line string) string {
	return strings.TrimSpace(strings.Trim(strings.TrimSpace(line), "│"))
}

func sendScreenShowsSlashPopup(screen string) bool {
	lines := strings.Split(sendANSISequence.ReplaceAllString(screen, ""), "\n")
	prompt := ""
	for i := len(lines) - 1; i >= 0; i-- {
		trimmed := trimSendBox(lines[i])
		if strings.HasPrefix(trimmed, "❯") || strings.HasPrefix(trimmed, "›") {
			prompt = promptBody(trimmed)
			break
		}
	}
	if !strings.HasPrefix(prompt, "/") {
		return false
	}
	for _, line := range lines {
		trimmed := trimSendBox(line)
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
