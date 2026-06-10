// Package agentconv normalizes coding-agent session transcripts read from the
// filesystem into a canonical conversation event stream.
//
// The wire shapes mirror webviews/src/agent-chat/protocol.ts (the source of
// truth); keep both in sync with the golden fixtures under testdata/.
package agentconv

// ProviderID identifies a coding agent. Open vocabulary: parse unknown
// providers without failing.
type ProviderID string

const (
	ProviderClaude ProviderID = "claude"
	ProviderCodex  ProviderID = "codex"
)

// SessionRef identifies one agent session backed by a transcript file.
type SessionRef struct {
	Provider       ProviderID `json:"provider"`
	SessionID      string     `json:"session_id"`
	TranscriptPath string     `json:"transcript_path"`
	Cwd            string     `json:"cwd,omitempty"`
	Title          string     `json:"title,omitempty"`
	UpdatedAt      string     `json:"updated_at,omitempty"`
}

// ItemType classifies a conversation item.
type ItemType string

const (
	ItemUserMessage       ItemType = "user_message"
	ItemAssistantMessage  ItemType = "assistant_message"
	ItemReasoning         ItemType = "reasoning"
	ItemPlan              ItemType = "plan"
	ItemCommandExecution  ItemType = "command_execution"
	ItemFileChange        ItemType = "file_change"
	ItemMCPToolCall       ItemType = "mcp_tool_call"
	ItemDynamicToolCall   ItemType = "dynamic_tool_call"
	ItemWebSearch         ItemType = "web_search"
	ItemContextCompaction ItemType = "context_compaction"
	ItemInterrupted       ItemType = "interrupted"
	ItemError             ItemType = "error"
	ItemUnknown           ItemType = "unknown"
)

// ItemStatus is the lifecycle state of an item.
type ItemStatus string

const (
	StatusInProgress ItemStatus = "in_progress"
	StatusCompleted  ItemStatus = "completed"
	StatusFailed     ItemStatus = "failed"
	StatusDeclined   ItemStatus = "declined"
)

// ToolOutput is the folded result of a tool-shaped item. Image payloads are
// referenced by id, never inlined.
type ToolOutput struct {
	Text     string   `json:"text,omitempty"`
	IsError  bool     `json:"is_error,omitempty"`
	ImageIDs []string `json:"image_ids,omitempty"`
}

// Item is one unit of conversation timeline content. Messages, reasoning, and
// tool calls are all items; tool results fold into their tool item.
type Item struct {
	ID        string      `json:"id"`
	Type      ItemType    `json:"type"`
	Status    ItemStatus  `json:"status"`
	Text      string      `json:"text,omitempty"`
	ToolName  string      `json:"tool_name,omitempty"`
	ToolUseID string      `json:"tool_use_id,omitempty"`
	Input     any         `json:"input,omitempty"`
	Output    *ToolOutput `json:"output,omitempty"`
	Title     string      `json:"title,omitempty"`
	CreatedAt string      `json:"created_at,omitempty"`
}

// EventType discriminates Event. The name content.delta remains reserved for
// the token-streaming phase. turn.* and request.* events are produced only by
// the live hook ingest source (hook.go); transcripts cannot observe them.
type EventType string

const (
	EventSnapshot        EventType = "snapshot"
	EventItemStarted     EventType = "item.started"
	EventItemUpdated     EventType = "item.updated"
	EventItemCompleted   EventType = "item.completed"
	EventSessionMeta     EventType = "session.meta"
	EventError           EventType = "error"
	EventTurnStarted     EventType = "turn.started"
	EventTurnCompleted   EventType = "turn.completed"
	EventRequestOpened   EventType = "request.opened"
	EventRequestResolved EventType = "request.resolved"
)

// RequestType classifies a pending request surfaced by request.opened.
type RequestType string

const (
	RequestToolApproval RequestType = "tool_approval"
	RequestUserInput    RequestType = "user_input"
	RequestUnknown      RequestType = "unknown"
)

// Event is one canonical conversation event. Exactly the fields relevant to
// its Type are set; Seq is monotonically increasing per subscription.
//
// Content optionality: items first emitted from a hook frame carry only what
// the hook saw (tool name, a short title, maybe a detail string). The full
// content (input, output, text) arrives later as item.updated when the
// transcript line for the same tool_use_id lands.
type Event struct {
	Type    EventType   `json:"type"`
	Seq     uint64      `json:"seq"`
	Session *SessionRef `json:"session,omitempty"`
	Items   []Item      `json:"items,omitempty"`
	Item    *Item       `json:"item,omitempty"`
	Message string      `json:"message,omitempty"`
	// Recoverable is meaningful only for EventError.
	Recoverable bool `json:"recoverable,omitempty"`
	// TurnID and Prompt are set for turn.started; TurnID alone for
	// turn.completed.
	TurnID string `json:"turn_id,omitempty"`
	Prompt string `json:"prompt,omitempty"`
	// RequestID/RequestType/Detail are set for request.opened; RequestID and
	// (when known) Decision for request.resolved.
	RequestID   string      `json:"request_id,omitempty"`
	RequestType RequestType `json:"request_type,omitempty"`
	Detail      string      `json:"detail,omitempty"`
	Decision    string      `json:"decision,omitempty"`
}
