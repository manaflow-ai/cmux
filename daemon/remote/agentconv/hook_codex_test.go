package agentconv

import "testing"

// Codex's only hook source is the notify program, which fires once per
// completed turn and carries the provider's own turn id. There is no
// prompt-submit hook, so turn.completed must be emitted without an observed
// turn.started, deduplicated on the provider turn id.
func TestHookMergeCodexNotifyTurnCompleted(t *testing.T) {
	parser := newCodexParser("/tmp/sess-codex.jsonl")
	merger := newHookMerger(parser.conv())

	frame := HookFrame{Provider: ProviderCodex, SessionID: "sess-codex", Hook: HookStop, TurnID: "turn-abc"}
	events := merger.consumeHookFrame(frame)
	if len(events) != 1 || events[0].Type != EventTurnCompleted || events[0].TurnID != "turn-abc" {
		t.Fatalf("codex notify stop = %+v, want turn.completed turn-abc", events)
	}

	// A redelivered notification for the same turn is dropped.
	if events := merger.consumeHookFrame(frame); len(events) != 0 {
		t.Fatalf("duplicate codex notify emitted %+v", events)
	}

	// The next turn's notification is a fresh completion.
	next := HookFrame{Provider: ProviderCodex, SessionID: "sess-codex", Hook: HookStop, TurnID: "turn-def"}
	events = merger.consumeHookFrame(next)
	if len(events) != 1 || events[0].Type != EventTurnCompleted || events[0].TurnID != "turn-def" {
		t.Fatalf("next codex notify stop = %+v, want turn.completed turn-def", events)
	}

	// Non-consecutive redelivery of an old turn id is dropped too.
	if events := merger.consumeHookFrame(frame); len(events) != 0 {
		t.Fatalf("non-consecutive duplicate codex notify emitted %+v", events)
	}

	// A Stop with neither an active turn nor a provider turn id stays a no-op.
	if events := merger.consumeHookFrame(HookFrame{Provider: ProviderCodex, SessionID: "sess-codex", Hook: HookStop}); len(events) != 0 {
		t.Fatalf("bare stop emitted %+v", events)
	}
}

// A redelivered notification for an already-completed turn is not progress
// evidence: a request opened after the original completion must stay pending.
func TestHookMergeCodexDuplicateNotifyKeepsRequestsPending(t *testing.T) {
	parser := newCodexParser("/tmp/sess-codex.jsonl")
	merger := newHookMerger(parser.conv())

	stop := HookFrame{Provider: ProviderCodex, SessionID: "sess-codex", Hook: HookStop, TurnID: "turn-1"}
	if events := merger.consumeHookFrame(stop); len(events) != 1 {
		t.Fatalf("first stop = %+v", events)
	}
	opened := merger.consumeHookFrame(HookFrame{Provider: ProviderCodex, SessionID: "sess-codex", Hook: HookNotification, Detail: "Codex is waiting for input"})
	if len(opened) != 1 || opened[0].Type != EventRequestOpened {
		t.Fatalf("request open = %+v", opened)
	}
	// Duplicate of turn-1 arrives late: full no-op, request stays pending.
	if events := merger.consumeHookFrame(stop); len(events) != 0 {
		t.Fatalf("duplicate stop after request opened emitted %+v", events)
	}
	// A genuinely new completion is progress and resolves it.
	events := merger.consumeHookFrame(HookFrame{Provider: ProviderCodex, SessionID: "sess-codex", Hook: HookStop, TurnID: "turn-2"})
	if len(events) != 2 || events[0].Type != EventRequestResolved || events[1].Type != EventTurnCompleted {
		t.Fatalf("next stop = %+v", events)
	}
}

// An observed turn (UserPromptSubmit) still wins over the frame's own turn
// id, and pending requests resolve on the provider-reported stop like on any
// other progress frame.
func TestHookMergeCodexNotifyResolvesPending(t *testing.T) {
	parser := newCodexParser("/tmp/sess-codex.jsonl")
	merger := newHookMerger(parser.conv())

	opened := merger.consumeHookFrame(HookFrame{Provider: ProviderCodex, SessionID: "sess-codex", Hook: HookNotification, Detail: "Codex is waiting for input"})
	if len(opened) != 1 || opened[0].Type != EventRequestOpened {
		t.Fatalf("request open = %+v", opened)
	}
	events := merger.consumeHookFrame(HookFrame{Provider: ProviderCodex, SessionID: "sess-codex", Hook: HookStop, TurnID: "turn-1"})
	if len(events) != 2 || events[0].Type != EventRequestResolved || events[1].Type != EventTurnCompleted || events[1].TurnID != "turn-1" {
		t.Fatalf("stop with pending request = %+v", events)
	}
}
