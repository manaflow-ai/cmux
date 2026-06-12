package agentconv

// Live hook ingest: agent hook processes (Claude Code settings hooks first)
// push newline-JSON frames into the daemon, which routes them to the open
// subscription for the same (provider, session_id). Hooks and the transcript
// tail are two producers into ONE canonical stream; this file is the merge
// point. The rules:
//
//   - hook wins on latency: PreToolUse appends the tool item (sparse content)
//     before its transcript line exists; PostToolUse completes it early.
//   - transcript wins on content: when the transcript line for the same
//     tool_use_id lands, the existing item is updated in place with the full
//     content (item.updated, never a duplicate item.started); a transcript
//     tool_result landing after a hook PostToolUse is likewise downgraded
//     from item.completed to item.updated.
//   - a tool hook frame arriving after its transcript line is suppressed.
//   - turn.* and request.* events exist only on the hook path; transcripts
//     cannot observe them.

import (
	"strings"
)

// Hook kind vocabulary accepted on the ingest socket. Unknown kinds are
// ignored without error.
const (
	HookUserPromptSubmit  = "UserPromptSubmit"
	HookPreToolUse        = "PreToolUse"
	HookPostToolUse       = "PostToolUse"
	HookStop              = "Stop"
	HookNotification      = "Notification"
	HookPermissionRequest = "PermissionRequest"
)

// HookFrame is one newline-JSON frame on the ingest socket. The emit verb
// (`cmuxd-remote agent-hook-emit`) translates provider-native hook payloads
// into this shape.
type HookFrame struct {
	Provider  ProviderID `json:"provider"`
	SessionID string     `json:"session_id"`
	Hook      string     `json:"hook"`
	// TurnID carries the provider's own turn identifier when the native
	// payload has one (Codex notify). For providers without one (Claude),
	// turn ids are synthesized per subscription.
	TurnID    string     `json:"turn_id,omitempty"`
	ToolName  string     `json:"tool_name,omitempty"`
	ToolUseID string     `json:"tool_use_id,omitempty"`
	Prompt    string     `json:"prompt,omitempty"`
	Detail    string     `json:"detail,omitempty"`
	Decision  string     `json:"decision,omitempty"`
	TS        string     `json:"ts,omitempty"`
}

// pendingRequest is an opened-not-yet-resolved request.
type pendingRequest struct {
	id          string
	requestType RequestType
}

// hookMerger holds the per-subscription merge state between the hook source
// and the transcript source. It is owned by the subscription run loop (single
// goroutine); events it returns carry no Seq — the run loop assigns them.
type hookMerger struct {
	conversation *conversation
	// completedByHook: item ids completed by a PostToolUse frame before their
	// transcript tool_result landed; the transcript completion downgrades to
	// item.updated.
	completedByHook map[string]bool
	// pendingRequests preserves open order for implicit resolution.
	pendingRequests []pendingRequest
	activeTurnID    string
	// seenExternalTurnIDs deduplicates provider-reported turn completions
	// (frames carrying their own turn_id, with no observed turn.started),
	// bounded FIFO so non-consecutive redeliveries are dropped too.
	seenExternalTurnIDs   map[string]bool
	seenExternalTurnOrder []string
	turnCounter           int
	requestCounter        int
}

const maxSeenExternalTurns = 64

func (m *hookMerger) externalTurnSeen(turnID string) bool {
	return m.seenExternalTurnIDs[turnID]
}

func (m *hookMerger) markExternalTurnSeen(turnID string) {
	if m.seenExternalTurnIDs == nil {
		m.seenExternalTurnIDs = map[string]bool{}
	}
	m.seenExternalTurnIDs[turnID] = true
	m.seenExternalTurnOrder = append(m.seenExternalTurnOrder, turnID)
	if len(m.seenExternalTurnOrder) > maxSeenExternalTurns {
		delete(m.seenExternalTurnIDs, m.seenExternalTurnOrder[0])
		m.seenExternalTurnOrder = m.seenExternalTurnOrder[1:]
	}
}

func newHookMerger(conversation *conversation) *hookMerger {
	return &hookMerger{
		conversation:    conversation,
		completedByHook: map[string]bool{},
	}
}

// transcriptChange converts a parser-reported change into its event,
// downgrading a transcript completion to item.updated when a hook frame
// already completed the item (the transcript copy carries the full content).
func (m *hookMerger) transcriptChange(lineChange change) Event {
	item := m.conversation.items[lineChange.itemIndex]
	eventType := EventItemUpdated
	switch lineChange.kind {
	case changeStarted:
		eventType = EventItemStarted
	case changeCompleted:
		eventType = EventItemCompleted
		if m.completedByHook[item.ID] {
			delete(m.completedByHook, item.ID)
			eventType = EventItemUpdated
		}
	}
	return Event{Type: eventType, Item: &item}
}

// consumeHookFrame maps one hook frame to canonical events against the
// current conversation state. Frames that duplicate transcript-known state
// return no events.
func (m *hookMerger) consumeHookFrame(frame HookFrame) []Event {
	switch frame.Hook {
	case HookUserPromptSubmit:
		events := m.resolveAllPending()
		m.turnCounter++
		m.activeTurnID = "turn-" + itoa(m.turnCounter)
		return append(events, Event{
			Type:   EventTurnStarted,
			TurnID: m.activeTurnID,
			Prompt: frame.Prompt,
		})
	case HookStop:
		if frame.TurnID != "" && m.externalTurnSeen(frame.TurnID) {
			// A redelivered notification for an already-completed turn is not
			// new progress evidence: it must not resolve requests opened
			// since, not re-emit the completion, and not close an unrelated
			// turn that started after it.
			return nil
		}
		if m.activeTurnID == "" {
			events := m.resolveAllPending()
			// No observed turn.started. A frame carrying the provider's own
			// turn id (Codex notify, which only fires at turn end) still
			// proves a turn completed.
			if frame.TurnID == "" {
				return events
			}
			m.markExternalTurnSeen(frame.TurnID)
			return append(events, Event{Type: EventTurnCompleted, TurnID: frame.TurnID})
		}
		events := m.resolveAllPending()
		if frame.TurnID != "" {
			// Providers that bracket turns with their own ids (turn.started
			// observed, native id on the stop) get redeliveries deduplicated
			// too, not only the notify-at-end shape.
			m.markExternalTurnSeen(frame.TurnID)
		}
		turnID := m.activeTurnID
		m.activeTurnID = ""
		return append(events, Event{Type: EventTurnCompleted, TurnID: turnID})
	case HookPreToolUse:
		return append(m.resolveAllPending(), m.hookToolStarted(frame)...)
	case HookPostToolUse:
		return append(m.resolveAllPending(), m.hookToolCompleted(frame)...)
	case HookNotification, HookPermissionRequest:
		return m.hookRequest(frame)
	default:
		return nil
	}
}

func (m *hookMerger) hookToolStarted(frame HookFrame) []Event {
	// Without a tool_use_id the item could never be deduplicated against its
	// transcript line, so it would render twice; drop it.
	if frame.ToolUseID == "" {
		return nil
	}
	if _, exists := m.conversation.byToolUseID[frame.ToolUseID]; exists {
		// The transcript line (or an earlier duplicate frame) won.
		return nil
	}
	itemChange := m.conversation.appendItem(Item{
		ID:        frame.ToolUseID,
		Type:      classifyHookTool(frame.Provider, frame.ToolName),
		Status:    StatusInProgress,
		ToolName:  frame.ToolName,
		ToolUseID: frame.ToolUseID,
		Title:     hookToolTitle(frame),
		CreatedAt: frame.TS,
	})
	return []Event{m.eventForHookChange(itemChange)}
}

func (m *hookMerger) hookToolCompleted(frame HookFrame) []Event {
	if frame.ToolUseID == "" {
		return nil
	}
	index, exists := m.conversation.byToolUseID[frame.ToolUseID]
	if !exists {
		// Hook-only completion with no preceding start: record the whole item.
		// Content stays sparse until (unless) the transcript line lands.
		itemChange := m.conversation.appendItem(Item{
			ID:        frame.ToolUseID,
			Type:      classifyHookTool(frame.Provider, frame.ToolName),
			Status:    StatusCompleted,
			ToolName:  frame.ToolName,
			ToolUseID: frame.ToolUseID,
			Title:     hookToolTitle(frame),
			CreatedAt: frame.TS,
		})
		m.completedByHook[frame.ToolUseID] = true
		return []Event{m.eventForHookChange(itemChange)}
	}
	item := &m.conversation.items[index]
	if item.Status != StatusInProgress {
		// Already completed (transcript tool_result landed first); the hook
		// frame is late and carries nothing new.
		return nil
	}
	item.Status = StatusCompleted
	m.completedByHook[item.ID] = true
	completed := *item
	return []Event{{Type: EventItemCompleted, Item: &completed}}
}

func (m *hookMerger) hookRequest(frame HookFrame) []Event {
	requestID := frame.ToolUseID
	if requestID == "" {
		m.requestCounter++
		requestID = "req-" + itoa(m.requestCounter)
	}
	requestType := classifyHookRequest(frame)
	if frame.Decision != "" {
		// A frame carrying a decision resolves the request; if it was never
		// opened on this subscription, open and resolve in one balanced pair.
		if m.removePending(requestID) {
			return []Event{{Type: EventRequestResolved, RequestID: requestID, Decision: frame.Decision}}
		}
		return []Event{
			{Type: EventRequestOpened, RequestID: requestID, RequestType: requestType, Detail: frame.Detail},
			{Type: EventRequestResolved, RequestID: requestID, Decision: frame.Decision},
		}
	}
	for _, pending := range m.pendingRequests {
		if pending.id == requestID {
			return nil
		}
	}
	m.pendingRequests = append(m.pendingRequests, pendingRequest{id: requestID, requestType: requestType})
	return []Event{{
		Type:        EventRequestOpened,
		RequestID:   requestID,
		RequestType: requestType,
		Detail:      frame.Detail,
	}}
}

// resolveAllPending closes every open request without a decision. Any
// progress frame (prompt submitted, tool ran, turn ended) proves the agent is
// no longer blocked on the request, so the banner must not stick.
func (m *hookMerger) resolveAllPending() []Event {
	if len(m.pendingRequests) == 0 {
		return nil
	}
	events := make([]Event, 0, len(m.pendingRequests))
	for _, pending := range m.pendingRequests {
		events = append(events, Event{Type: EventRequestResolved, RequestID: pending.id})
	}
	m.pendingRequests = nil
	return events
}

func (m *hookMerger) removePending(requestID string) bool {
	for index, pending := range m.pendingRequests {
		if pending.id == requestID {
			m.pendingRequests = append(m.pendingRequests[:index], m.pendingRequests[index+1:]...)
			return true
		}
	}
	return false
}

func (m *hookMerger) eventForHookChange(itemChange change) Event {
	item := m.conversation.items[itemChange.itemIndex]
	eventType := EventItemUpdated
	switch itemChange.kind {
	case changeStarted:
		eventType = EventItemStarted
	case changeCompleted:
		eventType = EventItemCompleted
	}
	return Event{Type: eventType, Item: &item}
}

func classifyHookRequest(frame HookFrame) RequestType {
	if frame.Hook == HookPermissionRequest {
		return RequestToolApproval
	}
	detail := strings.ToLower(frame.Detail)
	switch {
	case strings.Contains(detail, "permission"):
		return RequestToolApproval
	case strings.Contains(detail, "waiting for your input"), strings.Contains(detail, "waiting for input"):
		return RequestUserInput
	default:
		return RequestUnknown
	}
}

func hookToolTitle(frame HookFrame) string {
	if frame.Detail != "" {
		return truncateTitle(frame.Detail)
	}
	return frame.ToolName
}

// classifyHookTool picks the provider's own tool classifier for hook frames.
// The ingest path takes frames from any provider (opencode plugin frames
// arrive ready-made with their own provider id), so unknown providers get a
// case-insensitive generic classification instead of Claude's.
func classifyHookTool(provider ProviderID, name string) ItemType {
	switch provider {
	case ProviderCodex:
		return classifyCodexTool(name)
	case ProviderClaude:
		return classifyClaudeTool(name)
	default:
		return classifyGenericTool(name)
	}
}

// classifyGenericTool maps widely used tool names (opencode's bash, edit,
// write, patch, webfetch, ...) without provider-specific knowledge. Anything
// unrecognized stays a dynamic tool call.
func classifyGenericTool(name string) ItemType {
	lower := strings.ToLower(name)
	switch {
	case strings.HasPrefix(lower, "mcp__"):
		return ItemMCPToolCall
	case lower == "bash" || strings.Contains(lower, "shell") || strings.Contains(lower, "exec"):
		return ItemCommandExecution
	case lower == "edit" || lower == "multiedit" || lower == "write" || lower == "patch" || strings.Contains(lower, "apply_patch"):
		return ItemFileChange
	case strings.Contains(lower, "websearch") || strings.Contains(lower, "web_search") || strings.Contains(lower, "webfetch") || strings.Contains(lower, "web_fetch"):
		return ItemWebSearch
	default:
		return ItemDynamicToolCall
	}
}
