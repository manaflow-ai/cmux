package agentconv

import (
	"encoding/json"
	"strings"
)

// Claude Code transcripts: ~/.claude/projects/<encoded-cwd>/<uuid>.jsonl, one
// JSON object per line. Only `user` and `assistant` lines carry conversation
// content; tool results arrive inside `user` lines and fold into their tool
// item by tool_use_id. Everything else (summary, queue-operation, attachment,
// system, progress, file-history-snapshot, ...) is skipped, as are sidechain
// (subagent) and meta lines.

type claudeParser struct {
	conversation *conversation
}

func newClaudeParser(provider ProviderID, transcriptPath string) *claudeParser {
	return &claudeParser{conversation: newConversation(provider, transcriptPath)}
}

func (p *claudeParser) conv() *conversation { return p.conversation }

type claudeLine struct {
	Type        string         `json:"type"`
	UUID        string         `json:"uuid"`
	Timestamp   string         `json:"timestamp"`
	SessionID   string         `json:"sessionId"`
	Cwd         string         `json:"cwd"`
	IsSidechain bool           `json:"isSidechain"`
	IsMeta      bool           `json:"isMeta"`
	Message     *claudeMessage `json:"message"`
}

type claudeMessage struct {
	Role    string          `json:"role"`
	Content json.RawMessage `json:"content"`
}

type claudeBlock struct {
	Type      string          `json:"type"`
	Text      string          `json:"text"`
	Thinking  string          `json:"thinking"`
	ID        string          `json:"id"`
	Name      string          `json:"name"`
	Input     json.RawMessage `json:"input"`
	ToolUseID string          `json:"tool_use_id"`
	IsError   *bool           `json:"is_error"`
	Content   json.RawMessage `json:"content"`
}

func (p *claudeParser) consumeLine(data []byte) []change {
	var line claudeLine
	if err := json.Unmarshal(data, &line); err != nil {
		return nil
	}
	p.conversation.noteSessionID(line.SessionID)
	p.conversation.noteCwd(line.Cwd)
	if line.IsSidechain || line.IsMeta || line.Message == nil {
		return nil
	}
	switch line.Type {
	case "user":
		return p.consumeUser(line)
	case "assistant":
		return p.consumeAssistant(line)
	default:
		return nil
	}
}

func (p *claudeParser) consumeUser(line claudeLine) []change {
	blocks, text := decodeClaudeContent(line.Message.Content)
	var changes []change
	for _, block := range blocks {
		if block.Type != "tool_result" {
			continue
		}
		output := &ToolOutput{Text: flattenClaudeToolResult(block.Content)}
		failed := block.IsError != nil && *block.IsError
		output.IsError = failed
		if resolved, ok := p.conversation.resolveTool(block.ToolUseID, output, failed); ok {
			changes = append(changes, resolved)
		}
	}
	if text = strings.TrimSpace(text); text != "" && !isClaudeLocalCommandNoise(text) {
		p.conversation.noteTitle(truncateTitle(text))
		changes = append(changes, p.conversation.appendItem(Item{
			ID:        line.UUID,
			Type:      ItemUserMessage,
			Status:    StatusCompleted,
			Text:      text,
			CreatedAt: line.Timestamp,
		}))
	}
	return changes
}

func (p *claudeParser) consumeAssistant(line claudeLine) []change {
	blocks, text := decodeClaudeContent(line.Message.Content)
	var changes []change
	if text != "" && len(blocks) == 0 {
		blocks = []claudeBlock{{Type: "text", Text: text}}
	}
	for index, block := range blocks {
		switch block.Type {
		case "text":
			if strings.TrimSpace(block.Text) == "" {
				continue
			}
			changes = append(changes, p.conversation.appendItem(Item{
				ID:        claudeBlockID(line.UUID, index),
				Type:      ItemAssistantMessage,
				Status:    StatusCompleted,
				Text:      block.Text,
				CreatedAt: line.Timestamp,
			}))
		case "thinking":
			if strings.TrimSpace(block.Thinking) == "" {
				continue
			}
			changes = append(changes, p.conversation.appendItem(Item{
				ID:        claudeBlockID(line.UUID, index),
				Type:      ItemReasoning,
				Status:    StatusCompleted,
				Text:      block.Thinking,
				CreatedAt: line.Timestamp,
			}))
		case "tool_use":
			if block.ID == "" {
				continue
			}
			var input any
			if len(block.Input) > 0 {
				_ = json.Unmarshal(block.Input, &input)
			}
			changes = append(changes, p.conversation.appendItem(Item{
				ID:        block.ID,
				Type:      classifyClaudeTool(block.Name),
				Status:    StatusInProgress,
				ToolName:  block.Name,
				ToolUseID: block.ID,
				Input:     input,
				Title:     claudeToolTitle(block.Name, block.Input),
				CreatedAt: line.Timestamp,
			}))
		}
	}
	return changes
}

// decodeClaudeContent handles `message.content` as either a plain string or a
// block array. Returns the blocks (empty for string form) and the string form.
func decodeClaudeContent(raw json.RawMessage) ([]claudeBlock, string) {
	if len(raw) == 0 {
		return nil, ""
	}
	var text string
	if err := json.Unmarshal(raw, &text); err == nil {
		return nil, text
	}
	var blocks []claudeBlock
	if err := json.Unmarshal(raw, &blocks); err != nil {
		return nil, ""
	}
	var parts []string
	for _, block := range blocks {
		if block.Type == "text" && strings.TrimSpace(block.Text) != "" {
			parts = append(parts, block.Text)
		}
	}
	return blocks, strings.Join(parts, "\n\n")
}

// flattenClaudeToolResult renders a tool_result `content` (string, or array of
// text/image blocks) to display text. Image payloads are dropped (referenced
// by id in a later phase), only their presence is preserved by the caller.
func flattenClaudeToolResult(raw json.RawMessage) string {
	if len(raw) == 0 {
		return ""
	}
	var text string
	if err := json.Unmarshal(raw, &text); err == nil {
		return text
	}
	var blocks []claudeBlock
	if err := json.Unmarshal(raw, &blocks); err != nil {
		return ""
	}
	var parts []string
	for _, block := range blocks {
		if block.Type == "text" && block.Text != "" {
			parts = append(parts, block.Text)
		}
	}
	return strings.Join(parts, "\n")
}

// isClaudeLocalCommandNoise filters the local-command echo lines (`/clear`,
// `! foo` shell escapes, ...) that appear as user messages in the transcript
// but are not conversation input.
func isClaudeLocalCommandNoise(text string) bool {
	return strings.HasPrefix(text, "<command-name>") ||
		strings.HasPrefix(text, "<command-message>") ||
		strings.HasPrefix(text, "<local-command-stdout>") ||
		strings.HasPrefix(text, "<bash-input>") ||
		strings.HasPrefix(text, "<bash-stdout>") ||
		strings.HasPrefix(text, "<bash-stderr>") ||
		strings.HasPrefix(text, "Caveat: The messages below were generated by the user while running local commands")
}

func claudeBlockID(uuid string, blockIndex int) string {
	if blockIndex == 0 {
		return uuid
	}
	return uuid + ":" + itoa(blockIndex)
}

func itoa(value int) string {
	if value == 0 {
		return "0"
	}
	var digits [20]byte
	index := len(digits)
	for value > 0 {
		index--
		digits[index] = byte('0' + value%10)
		value /= 10
	}
	return string(digits[index:])
}

func classifyClaudeTool(name string) ItemType {
	switch name {
	case "Bash", "BashOutput", "KillShell":
		return ItemCommandExecution
	case "Edit", "Write", "MultiEdit", "NotebookEdit":
		return ItemFileChange
	case "WebSearch", "WebFetch":
		return ItemWebSearch
	}
	if strings.HasPrefix(name, "mcp__") {
		return ItemMCPToolCall
	}
	return ItemDynamicToolCall
}

// claudeToolTitle extracts a one-line label from the tool input without
// caring about the full input schema.
func claudeToolTitle(name string, rawInput json.RawMessage) string {
	if len(rawInput) == 0 {
		return name
	}
	var input map[string]any
	if err := json.Unmarshal(rawInput, &input); err != nil {
		return name
	}
	for _, key := range []string{"command", "file_path", "notebook_path", "path", "query", "url", "pattern", "description", "prompt", "skill"} {
		if value, ok := input[key].(string); ok && strings.TrimSpace(value) != "" {
			return truncateTitle(value)
		}
	}
	return name
}
