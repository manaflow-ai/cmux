package main

// `cmuxd-remote agent-hook-emit --socket <path> [--provider <id>] [frame-json]`
//
// Tiny, dependency-free hook relay: agent hook commands (Claude Code settings
// hooks first) pipe their stdin payload to this verb, which translates it to
// an agentconv.HookFrame and writes one newline-JSON line to the daemon's
// ingest socket. The frame JSON can also be passed as the single positional
// argument. Hooks must never break the agent: this verb ALWAYS exits 0, even
// on bad input or connect failure; diagnostics go to stderr only.

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"strings"
	"time"

	"github.com/manaflow-ai/cmux/daemon/remote/agentconv"
)

const hookEmitDialTimeout = 1 * time.Second
const hookEmitWriteTimeout = 2 * time.Second
const maxHookEmitInputBytes = maxHookFrameBytes

// claudeHookPayload is the native stdin shape Claude Code passes to settings
// hooks (https://code.claude.com/docs/en/hooks). Only the fields the frame
// needs are decoded.
type claudeHookPayload struct {
	SessionID     string          `json:"session_id"`
	HookEventName string          `json:"hook_event_name"`
	ToolName      string          `json:"tool_name"`
	ToolUseID     string          `json:"tool_use_id"`
	ToolInput     json.RawMessage `json:"tool_input"`
	Prompt        string          `json:"prompt"`
	Message       string          `json:"message"`
}

func runAgentHookEmit(args []string, stdin io.Reader) int {
	socketPath := ""
	provider := string(agentconv.ProviderClaude)
	var positional []string
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--socket":
			if i+1 < len(args) {
				socketPath = args[i+1]
				i++
			}
		case "--provider":
			if i+1 < len(args) {
				provider = args[i+1]
				i++
			}
		default:
			positional = append(positional, args[i])
		}
	}
	if socketPath == "" {
		socketPath = defaultAgentHookSocketPath()
	}

	var input []byte
	if len(positional) > 0 {
		input = []byte(positional[0])
	} else {
		data, err := io.ReadAll(io.LimitReader(stdin, maxHookEmitInputBytes))
		if err != nil {
			fmt.Fprintf(os.Stderr, "cmux agent-hook-emit: read stdin: %v\n", err)
			return 0
		}
		input = data
	}
	frame, ok := decodeHookEmitInput(input, agentconv.ProviderID(provider))
	if !ok {
		fmt.Fprintln(os.Stderr, "cmux agent-hook-emit: input is not a hook frame or a known native hook payload")
		return 0
	}
	line, err := json.Marshal(frame)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux agent-hook-emit: encode frame: %v\n", err)
		return 0
	}

	conn, err := net.DialTimeout("unix", socketPath, hookEmitDialTimeout)
	if err != nil {
		// No daemon listening (no chat pane open) is the common case; stay
		// silent and successful so the hook never slows or breaks the agent.
		return 0
	}
	defer conn.Close()
	_ = conn.SetWriteDeadline(time.Now().Add(hookEmitWriteTimeout))
	if _, err := conn.Write(append(line, '\n')); err != nil {
		fmt.Fprintf(os.Stderr, "cmux agent-hook-emit: write: %v\n", err)
	}
	return 0
}

// codexNotifyPayload is the JSON Codex appends as the final argv argument to
// the program configured as `notify` in ~/.codex/config.toml. Field names are
// kebab-case (codex-rs/hooks/src/legacy_notify.rs); agent-turn-complete is
// the only type Codex emits. thread-id is the rollout session id; very old
// Codex versions omitted it, and such payloads cannot be routed.
type codexNotifyPayload struct {
	Type                 string   `json:"type"`
	ThreadID             string   `json:"thread-id"`
	TurnID               string   `json:"turn-id"`
	Cwd                  string   `json:"cwd"`
	InputMessages        []string `json:"input-messages"`
	LastAssistantMessage string   `json:"last-assistant-message"`
}

// decodeHookEmitInput accepts a ready agentconv.HookFrame (has "hook") or a
// provider-native payload: Claude Code's hook stdin shape (has
// "hook_event_name") or Codex's notify argv shape (type
// "agent-turn-complete"), normalized to a frame.
func decodeHookEmitInput(input []byte, provider agentconv.ProviderID) (agentconv.HookFrame, bool) {
	trimmed := strings.TrimSpace(string(input))
	if trimmed == "" {
		return agentconv.HookFrame{}, false
	}
	var frame agentconv.HookFrame
	if err := json.Unmarshal([]byte(trimmed), &frame); err != nil {
		return agentconv.HookFrame{}, false
	}
	if frame.Hook != "" {
		if frame.Provider == "" {
			frame.Provider = provider
		}
		stampHookFrameTS(&frame)
		return frame, frame.SessionID != ""
	}
	if claudeFrame, ok := decodeClaudeNativePayload(trimmed, provider); ok {
		return claudeFrame, true
	}
	return decodeCodexNotifyPayload(trimmed)
}

func decodeClaudeNativePayload(trimmed string, provider agentconv.ProviderID) (agentconv.HookFrame, bool) {
	var native claudeHookPayload
	if err := json.Unmarshal([]byte(trimmed), &native); err != nil {
		return agentconv.HookFrame{}, false
	}
	if native.HookEventName == "" || native.SessionID == "" {
		return agentconv.HookFrame{}, false
	}
	frame := agentconv.HookFrame{
		Provider:  provider,
		SessionID: native.SessionID,
		Hook:      native.HookEventName,
		ToolName:  native.ToolName,
		ToolUseID: native.ToolUseID,
		Prompt:    native.Prompt,
		Detail:    native.Message,
	}
	if frame.Detail == "" && native.ToolName != "" {
		frame.Detail = agentconv.ToolCallTitle(native.ToolName, native.ToolInput)
	}
	stampHookFrameTS(&frame)
	return frame, true
}

// decodeCodexNotifyPayload maps Codex's agent-turn-complete notification to a
// turn-completion frame. Only what the payload supports is mapped: thread-id
// is the session id, turn-id the provider turn id, last-assistant-message a
// human-readable detail. input-messages and cwd have no canonical frame
// destination and are dropped. The payload shape is Codex's own, so the
// provider is always codex regardless of --provider.
func decodeCodexNotifyPayload(trimmed string) (agentconv.HookFrame, bool) {
	var notify codexNotifyPayload
	if err := json.Unmarshal([]byte(trimmed), &notify); err != nil {
		return agentconv.HookFrame{}, false
	}
	if notify.Type != "agent-turn-complete" || notify.ThreadID == "" {
		return agentconv.HookFrame{}, false
	}
	frame := agentconv.HookFrame{
		Provider:  agentconv.ProviderCodex,
		SessionID: notify.ThreadID,
		Hook:      agentconv.HookStop,
		TurnID:    notify.TurnID,
		Detail:    notify.LastAssistantMessage,
	}
	stampHookFrameTS(&frame)
	return frame, true
}

func stampHookFrameTS(frame *agentconv.HookFrame) {
	if frame.TS == "" {
		frame.TS = time.Now().UTC().Format(time.RFC3339)
	}
}
