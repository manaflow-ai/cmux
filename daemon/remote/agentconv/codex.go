package agentconv

import (
	"encoding/json"
	"strings"
)

// Codex rollouts: ~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl. Each
// line is {timestamp, type, payload}. Conversation content lives in
// `response_item` payloads; `event_msg` duplicates that text and is dropped
// along with `turn_context` and token-count noise. `session_meta` carries the
// session id and cwd; `compacted` marks a context compaction.

type codexParser struct {
	conversation *conversation
	// lineIndex synthesizes stable ids for payloads with no id of their own.
	lineIndex int
}

func newCodexParser(transcriptPath string) *codexParser {
	return &codexParser{conversation: newConversation(ProviderCodex, transcriptPath)}
}

func (p *codexParser) conv() *conversation { return p.conversation }

type codexEnvelope struct {
	Timestamp string          `json:"timestamp"`
	Type      string          `json:"type"`
	Payload   json.RawMessage `json:"payload"`
}

type codexPayload struct {
	Type      string          `json:"type"`
	ID        string          `json:"id"`
	Cwd       string          `json:"cwd"`
	Role      string          `json:"role"`
	Content   json.RawMessage `json:"content"`
	Summary   []codexSummary  `json:"summary"`
	Name      string          `json:"name"`
	Arguments string          `json:"arguments"`
	CallID    string          `json:"call_id"`
	Input     string          `json:"input"`
	Output    json.RawMessage `json:"output"`
	Action    *codexAction    `json:"action"`
	Message   string          `json:"message"`
}

type codexSummary struct {
	Type string `json:"type"`
	Text string `json:"text"`
}

type codexAction struct {
	Type  string `json:"type"`
	Query string `json:"query"`
}

func (p *codexParser) consumeLine(data []byte) []change {
	p.lineIndex++
	var envelope codexEnvelope
	if err := json.Unmarshal(data, &envelope); err != nil {
		return nil
	}
	var payload codexPayload
	if len(envelope.Payload) > 0 {
		if err := json.Unmarshal(envelope.Payload, &payload); err != nil {
			return nil
		}
	}
	switch envelope.Type {
	case "session_meta":
		p.conversation.noteSessionID(payload.ID)
		p.conversation.noteCwd(payload.Cwd)
		return nil
	case "compacted":
		return []change{p.conversation.appendItem(Item{
			ID:        p.syntheticID(),
			Type:      ItemContextCompaction,
			Status:    StatusCompleted,
			Text:      payload.Message,
			CreatedAt: envelope.Timestamp,
		})}
	case "response_item":
		return p.consumeResponseItem(envelope.Timestamp, payload)
	default:
		// event_msg, turn_context, and anything newer are non-content noise.
		return nil
	}
}

func (p *codexParser) consumeResponseItem(timestamp string, payload codexPayload) []change {
	switch payload.Type {
	case "message":
		if payload.Role != "user" && payload.Role != "assistant" {
			return nil
		}
		text := stripCodexEnvelopes(decodeCodexContent(payload.Content))
		if text == "" {
			return nil
		}
		itemType := ItemUserMessage
		if payload.Role == "assistant" {
			itemType = ItemAssistantMessage
		} else {
			p.conversation.noteTitle(truncateTitle(text))
		}
		return []change{p.conversation.appendItem(Item{
			ID:        p.payloadID(payload),
			Type:      itemType,
			Status:    StatusCompleted,
			Text:      text,
			CreatedAt: timestamp,
		})}
	case "reasoning":
		var parts []string
		for _, summary := range payload.Summary {
			if strings.TrimSpace(summary.Text) != "" {
				parts = append(parts, summary.Text)
			}
		}
		// Encrypted reasoning with no summary has nothing renderable.
		if len(parts) == 0 {
			return nil
		}
		return []change{p.conversation.appendItem(Item{
			ID:        p.payloadID(payload),
			Type:      ItemReasoning,
			Status:    StatusCompleted,
			Text:      strings.Join(parts, "\n\n"),
			CreatedAt: timestamp,
		})}
	case "function_call", "custom_tool_call":
		if payload.CallID == "" {
			return nil
		}
		input := codexToolInput(payload)
		return []change{p.conversation.appendItem(Item{
			ID:        payload.CallID,
			Type:      classifyCodexTool(payload.Name),
			Status:    StatusInProgress,
			ToolName:  payload.Name,
			ToolUseID: payload.CallID,
			Input:     input,
			Title:     codexToolTitle(payload),
			CreatedAt: timestamp,
		})}
	case "function_call_output", "custom_tool_call_output":
		output, failed := decodeCodexToolOutput(payload.Output)
		if resolved, ok := p.conversation.resolveTool(payload.CallID, output, failed); ok {
			return []change{resolved}
		}
		return nil
	case "web_search_call":
		title := ""
		if payload.Action != nil {
			title = truncateTitle(payload.Action.Query)
		}
		return []change{p.conversation.appendItem(Item{
			ID:        p.payloadID(payload),
			Type:      ItemWebSearch,
			Status:    StatusCompleted,
			ToolName:  "web_search",
			Title:     title,
			CreatedAt: timestamp,
		})}
	default:
		return nil
	}
}

func (p *codexParser) payloadID(payload codexPayload) string {
	if payload.ID != "" {
		return payload.ID
	}
	return p.syntheticID()
}

func (p *codexParser) syntheticID() string {
	return "codex-line-" + itoa(p.lineIndex)
}

// decodeCodexContent handles `content` as a plain string or an array of
// {type, text} parts (input_text / output_text).
func decodeCodexContent(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var text string
	if err := json.Unmarshal(raw, &text); err == nil {
		return text
	}
	var parts []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if err := json.Unmarshal(raw, &parts); err != nil {
		return ""
	}
	var collected []string
	for _, part := range parts {
		if strings.TrimSpace(part.Text) != "" {
			collected = append(collected, part.Text)
		}
	}
	return strings.Join(collected, "\n\n")
}

var codexEnvelopeTags = []string{"permissions", "environment_context", "user_instructions", "turn_aborted"}

// stripCodexEnvelopes removes the instruction wrappers codex injects into
// message text. A message that is nothing but an AGENTS.md dump is dropped
// entirely (returns "").
func stripCodexEnvelopes(text string) string {
	for _, tag := range codexEnvelopeTags {
		text = stripTagBlocks(text, tag)
	}
	text = strings.TrimSpace(text)
	if strings.HasPrefix(text, "# AGENTS.md") {
		return ""
	}
	return text
}

func stripTagBlocks(text, tag string) string {
	open := "<" + tag + ">"
	close := "</" + tag + ">"
	for {
		start := strings.Index(text, open)
		if start < 0 {
			return text
		}
		end := strings.Index(text[start:], close)
		if end < 0 {
			return text[:start]
		}
		text = text[:start] + text[start+end+len(close):]
	}
}

func classifyCodexTool(name string) ItemType {
	switch name {
	case "exec_command", "shell", "local_shell", "container.exec", "write_stdin":
		return ItemCommandExecution
	case "apply_patch":
		return ItemFileChange
	}
	if strings.HasPrefix(name, "mcp__") || strings.Contains(name, "/") {
		return ItemMCPToolCall
	}
	return ItemDynamicToolCall
}

// codexToolInput returns the decoded arguments (function calls carry a JSON
// string) or the raw input text (custom tool calls like apply_patch).
func codexToolInput(payload codexPayload) any {
	if payload.Arguments != "" {
		var decoded any
		if err := json.Unmarshal([]byte(payload.Arguments), &decoded); err == nil {
			return decoded
		}
		return payload.Arguments
	}
	if payload.Input != "" {
		return payload.Input
	}
	return nil
}

func codexToolTitle(payload codexPayload) string {
	if payload.Name == "apply_patch" {
		if title := applyPatchTitle(payload.Input); title != "" {
			return title
		}
	}
	if payload.Arguments != "" {
		var args map[string]any
		if err := json.Unmarshal([]byte(payload.Arguments), &args); err == nil {
			for _, key := range []string{"cmd", "command", "chars", "query", "path"} {
				switch value := args[key].(type) {
				case string:
					if strings.TrimSpace(value) != "" {
						return truncateTitle(value)
					}
				case []any:
					var parts []string
					for _, entry := range value {
						if s, ok := entry.(string); ok {
							parts = append(parts, s)
						}
					}
					if len(parts) > 0 {
						return truncateTitle(strings.Join(parts, " "))
					}
				}
			}
		}
	}
	return payload.Name
}

// applyPatchTitle pulls the first "*** <Action> File: <path>" line out of an
// apply_patch payload.
func applyPatchTitle(patch string) string {
	for _, line := range strings.Split(patch, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "*** ") && strings.Contains(trimmed, "File:") {
			if _, path, found := strings.Cut(trimmed, "File:"); found {
				return truncateTitle(strings.TrimSpace(path))
			}
		}
	}
	return ""
}

// decodeCodexToolOutput unwraps the function_call_output `output` value: a
// JSON string that often itself encodes {"output": ..., "metadata":
// {"exit_code": N}}.
func decodeCodexToolOutput(raw json.RawMessage) (*ToolOutput, bool) {
	if len(raw) == 0 {
		return &ToolOutput{}, false
	}
	var text string
	if err := json.Unmarshal(raw, &text); err != nil {
		// Object form: same {output, metadata.exit_code} shape, just not
		// string-encoded. Keep "content" as a text fallback.
		var object struct {
			Output   string `json:"output"`
			Content  string `json:"content"`
			Metadata *struct {
				ExitCode *float64 `json:"exit_code"`
			} `json:"metadata"`
		}
		if err := json.Unmarshal(raw, &object); err == nil {
			failed := object.Metadata != nil && object.Metadata.ExitCode != nil && *object.Metadata.ExitCode != 0
			if object.Output != "" {
				return &ToolOutput{Text: object.Output, IsError: failed}, failed
			}
			if object.Content != "" {
				return &ToolOutput{Text: object.Content, IsError: failed}, failed
			}
		}
		return &ToolOutput{}, false
	}
	var wrapper struct {
		Output   string `json:"output"`
		Metadata *struct {
			ExitCode *float64 `json:"exit_code"`
		} `json:"metadata"`
	}
	if err := json.Unmarshal([]byte(text), &wrapper); err == nil && wrapper.Output != "" {
		failed := wrapper.Metadata != nil && wrapper.Metadata.ExitCode != nil && *wrapper.Metadata.ExitCode != 0
		return &ToolOutput{Text: wrapper.Output, IsError: failed}, failed
	}
	return &ToolOutput{Text: text}, false
}
