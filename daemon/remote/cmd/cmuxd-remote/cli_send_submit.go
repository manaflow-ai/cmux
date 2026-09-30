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
			if !submit {
				fmt.Fprintf(os.Stderr, "cmux send: refusing to send: %v\n", err)
				return 1
			}
			// An older relay may not expose input_state. Submit with Return
			// and report sent; no screen heuristic can safely claim delivery.
			state, screen = nil, ""
		}
		if err == nil && sendStateBlocksText(state) {
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

	// --force still uses host input_state when available. If it is unavailable,
	// use Return and report sent because the relay cannot identify an agent.
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
	queuedBeforePaste := sendStateQueued(state)
	ownSlashCommand := strings.HasPrefix(strings.TrimSpace(text), "/")
	if knownAgent {
		visible := false
		for probe := 0; probe < sendSubmitAttempts; probe++ {
			time.Sleep(time.Duration(100*(probe+1)) * time.Millisecond)
			state, screen = readSendState(socketPath, target, refreshAddr)
			if sendStateDialog(state) && !sendStateSlashPopup(state) {
				fmt.Fprintln(os.Stderr, "cmux send: text was pasted but the target opened a dialog; nothing was confirmed as submitted")
				return 1
			}
			if stateString(state, "state") == "draft" || sendStateSlashPopup(state) {
				visible = true
				break
			}
			if sendStateQueued(state) && (!queuedBeforePaste || sendComposerMatches(screen, text)) {
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
			if sendStateConfirmed(state, screen, queuedBeforePaste, text) {
				return printSendSubmitResult(sendConfirmedStatus(state), jsonOutput)
			}
			if sendStateDialog(state) && !sendStateSlashPopup(state) {
				return sendSubmitUnconfirmed("target opened a dialog; retry was refused", jsonOutput)
			}
			if !sendComposerMatches(screen, text) {
				return sendSubmitUnconfirmed("composer changed or could not be identified; retry was refused to preserve human input", jsonOutput)
			}
		}
		key := sendSubmitKey(state)
		keyParams := cloneParams(target)
		keyParams["key"] = key
		if _, err := socketRoundTripV2(socketPath, "surface.send_key", keyParams, refreshAddr); err != nil {
			return sendSubmitUnconfirmed(fmt.Sprintf("submit key failed: %v", err), jsonOutput)
		}
		time.Sleep(time.Duration(100*(attempt+1)) * time.Millisecond)
		if !knownAgent {
			if state == nil || agent {
				return printSendSubmitResult("sent", jsonOutput)
			}
			return printSendSubmitResult("submitted", jsonOutput)
		}
		lastState, screen = readSendState(socketPath, target, refreshAddr)
		if sendStateDialog(lastState) {
			if screen == "" {
				screen, _ = readSendScreen(socketPath, target, refreshAddr)
			}
			if !sendStateSlashPopup(lastState) {
				if ownSlashCommand {
					return printSendSubmitResult("submitted", jsonOutput)
				}
				return sendSubmitUnconfirmed("target opened a dialog while submitting", jsonOutput)
			}
		}
		if sendStateConfirmed(lastState, screen, queuedBeforePaste, text) {
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
	if sendStateConfirmed(lastState, screen, queuedBeforePaste, text) {
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
	if err != nil {
		return nil, "", err
	}
	screen, _ := readSendScreen(socketPath, target, refreshAddr)
	return state, screen, nil
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

func sendSubmitKey(state map[string]any) string {
	if sendStateLooksLikeBusyCodex(state) {
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

func sendStateAgent(state map[string]any) bool {
	return boolValue(state, "agent")
}

func sendStateDialog(state map[string]any) bool {
	return sendStateAgent(state) && stateString(state, "state") == "dialog"
}

func sendStateSlashPopup(state map[string]any) bool {
	return boolValue(state, "slash_popup") || boolValue(state, "slash_command_popup")
}

func sendStateQueued(state map[string]any) bool {
	return stateString(state, "state") == "queued" || boolValue(state, "queued")
}

func sendStateConfirmed(state map[string]any, screen string, queuedBeforePaste bool, text string) bool {
	if sendStateSlashPopup(state) || !sendStateAgent(state) {
		return false
	}
	if stateString(state, "state") == "empty" {
		return true
	}
	if !sendStateQueued(state) {
		return false
	}
	return !queuedBeforePaste || sendComposerMatches(screen, text)
}

func sendStateLooksLikeBusyCodex(state map[string]any) bool {
	return sendStateAgent(state) && stateString(state, "agent_kind") == "codex" &&
		(stateString(state, "lifecycle") == "running" || boolValue(state, "busy"))
}

var sendANSISequence = regexp.MustCompile(`\x1b\[[0-?]*[ -/]*[@-~]|\x1b\][^\x07]*(?:\x07|\x1b\\)`)

func trimSendBox(line string) string {
	return strings.TrimSpace(strings.Trim(strings.TrimSpace(line), "│"))
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
