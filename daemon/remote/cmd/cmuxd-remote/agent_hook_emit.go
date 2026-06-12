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

// decodeHookEmitInput accepts either a ready agentconv.HookFrame (has "hook")
// or a provider-native hook payload (Claude Code's, has "hook_event_name")
// and normalizes to a frame.
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
	var native claudeHookPayload
	if err := json.Unmarshal([]byte(trimmed), &native); err != nil {
		return agentconv.HookFrame{}, false
	}
	if native.HookEventName == "" || native.SessionID == "" {
		return agentconv.HookFrame{}, false
	}
	frame = agentconv.HookFrame{
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

func stampHookFrameTS(frame *agentconv.HookFrame) {
	if frame.TS == "" {
		frame.TS = time.Now().UTC().Format(time.RFC3339)
	}
}
