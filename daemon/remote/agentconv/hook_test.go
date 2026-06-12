package agentconv

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// The merge engine tests drive exactly what the subscription run loop does:
// transcript lines through parser.consumeLine + merger.transcriptChange, hook
// frames through merger.consumeHookFrame, both against one conversation.

type mergeStep struct {
	// Exactly one of line/frame is set.
	line  string
	frame *HookFrame

	want []Event
}

func claudeToolUseLine(uuid, toolUseID, command string) string {
	return `{"type":"assistant","uuid":"` + uuid + `","timestamp":"2026-06-10T10:00:00.000Z","sessionId":"sess-hook","message":{"role":"assistant","content":[{"type":"tool_use","id":"` + toolUseID + `","name":"Bash","input":{"command":"` + command + `"}}]}}`
}

func claudeToolResultLine(uuid, toolUseID, text string) string {
	return `{"type":"user","uuid":"` + uuid + `","timestamp":"2026-06-10T10:00:01.000Z","sessionId":"sess-hook","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"` + toolUseID + `","content":"` + text + `"}]}}`
}

func runMergeSteps(t *testing.T, steps []mergeStep) {
	t.Helper()
	parser := newClaudeParser(ProviderClaude, "/tmp/sess-hook.jsonl")
	merger := newHookMerger(parser.conv())
	for stepIndex, step := range steps {
		var got []Event
		if step.frame != nil {
			got = merger.consumeHookFrame(*step.frame)
		} else {
			for _, lineChange := range parser.consumeLine([]byte(step.line)) {
				got = append(got, merger.transcriptChange(lineChange))
			}
		}
		if len(got) != len(step.want) {
			t.Fatalf("step %d: got %d events, want %d: %+v", stepIndex, len(got), len(step.want), got)
		}
		for eventIndex, want := range step.want {
			assertMergeEvent(t, stepIndex, eventIndex, got[eventIndex], want)
		}
	}
}

func assertMergeEvent(t *testing.T, stepIndex, eventIndex int, got, want Event) {
	t.Helper()
	if got.Type != want.Type {
		t.Errorf("step %d event %d: type = %s, want %s", stepIndex, eventIndex, got.Type, want.Type)
		return
	}
	if want.Item != nil {
		if got.Item == nil {
			t.Errorf("step %d event %d: missing item", stepIndex, eventIndex)
			return
		}
		if got.Item.ID != want.Item.ID {
			t.Errorf("step %d event %d: item id = %q, want %q", stepIndex, eventIndex, got.Item.ID, want.Item.ID)
		}
		if want.Item.Status != "" && got.Item.Status != want.Item.Status {
			t.Errorf("step %d event %d: item status = %s, want %s", stepIndex, eventIndex, got.Item.Status, want.Item.Status)
		}
		if want.Item.Title != "" && got.Item.Title != want.Item.Title {
			t.Errorf("step %d event %d: item title = %q, want %q", stepIndex, eventIndex, got.Item.Title, want.Item.Title)
		}
		if want.Item.Output != nil {
			if got.Item.Output == nil || got.Item.Output.Text != want.Item.Output.Text {
				t.Errorf("step %d event %d: item output = %+v, want %+v", stepIndex, eventIndex, got.Item.Output, want.Item.Output)
			}
		}
	}
	if want.TurnID != "" && got.TurnID != want.TurnID {
		t.Errorf("step %d event %d: turn id = %q, want %q", stepIndex, eventIndex, got.TurnID, want.TurnID)
	}
	if want.Prompt != "" && got.Prompt != want.Prompt {
		t.Errorf("step %d event %d: prompt = %q, want %q", stepIndex, eventIndex, got.Prompt, want.Prompt)
	}
	if want.RequestID != "" && got.RequestID != want.RequestID {
		t.Errorf("step %d event %d: request id = %q, want %q", stepIndex, eventIndex, got.RequestID, want.RequestID)
	}
	if want.RequestType != "" && got.RequestType != want.RequestType {
		t.Errorf("step %d event %d: request type = %q, want %q", stepIndex, eventIndex, got.RequestType, want.RequestType)
	}
	if want.Decision != "" && got.Decision != want.Decision {
		t.Errorf("step %d event %d: decision = %q, want %q", stepIndex, eventIndex, got.Decision, want.Decision)
	}
}

func TestHookMerge(t *testing.T) {
	cases := map[string][]mergeStep{
		"hook-then-transcript": {
			{
				// Hook wins on latency: sparse tool item appears immediately.
				frame: &HookFrame{Provider: ProviderClaude, SessionID: "sess-hook", Hook: HookPreToolUse, ToolName: "Bash", ToolUseID: "toolu_1", Detail: "ls"},
				want:  []Event{{Type: EventItemStarted, Item: &Item{ID: "toolu_1", Status: StatusInProgress, Title: "ls"}}},
			},
			{
				// Transcript wins on content: same tool_use_id becomes
				// item.updated with the full input, never a second started.
				line: claudeToolUseLine("a1", "toolu_1", "ls"),
				want: []Event{{Type: EventItemUpdated, Item: &Item{ID: "toolu_1", Status: StatusInProgress}}},
			},
			{
				line: claudeToolResultLine("u2", "toolu_1", "README.md"),
				want: []Event{{Type: EventItemCompleted, Item: &Item{ID: "toolu_1", Status: StatusCompleted, Output: &ToolOutput{Text: "README.md"}}}},
			},
		},
		"transcript-then-hook": {
			{
				line: claudeToolUseLine("a1", "toolu_2", "pwd"),
				want: []Event{{Type: EventItemStarted, Item: &Item{ID: "toolu_2", Status: StatusInProgress}}},
			},
			{
				// The transcript-emitted item suppresses the late hook frame.
				frame: &HookFrame{Provider: ProviderClaude, SessionID: "sess-hook", Hook: HookPreToolUse, ToolName: "Bash", ToolUseID: "toolu_2"},
				want:  nil,
			},
			{
				// Hook completion still wins on latency for an in-progress item.
				frame: &HookFrame{Provider: ProviderClaude, SessionID: "sess-hook", Hook: HookPostToolUse, ToolName: "Bash", ToolUseID: "toolu_2"},
				want:  []Event{{Type: EventItemCompleted, Item: &Item{ID: "toolu_2", Status: StatusCompleted}}},
			},
			{
				// The transcript tool_result then lands content as an update,
				// not a duplicate completion.
				line: claudeToolResultLine("u2", "toolu_2", "/tmp"),
				want: []Event{{Type: EventItemUpdated, Item: &Item{ID: "toolu_2", Status: StatusCompleted, Output: &ToolOutput{Text: "/tmp"}}}},
			},
		},
		"hook-only": {
			{
				frame: &HookFrame{Provider: ProviderClaude, SessionID: "sess-hook", Hook: HookPreToolUse, ToolName: "Read", ToolUseID: "toolu_3", Detail: "main.go"},
				want:  []Event{{Type: EventItemStarted, Item: &Item{ID: "toolu_3", Status: StatusInProgress, Title: "main.go"}}},
			},
			{
				// No transcript line ever lands; the hook pair still brackets
				// the item lifecycle.
				frame: &HookFrame{Provider: ProviderClaude, SessionID: "sess-hook", Hook: HookPostToolUse, ToolName: "Read", ToolUseID: "toolu_3"},
				want:  []Event{{Type: EventItemCompleted, Item: &Item{ID: "toolu_3", Status: StatusCompleted}}},
			},
			{
				// Duplicate hook completion is suppressed.
				frame: &HookFrame{Provider: ProviderClaude, SessionID: "sess-hook", Hook: HookPostToolUse, ToolName: "Read", ToolUseID: "toolu_3"},
				want:  nil,
			},
			{
				// Tool frames without a tool_use_id cannot be deduplicated and
				// are dropped.
				frame: &HookFrame{Provider: ProviderClaude, SessionID: "sess-hook", Hook: HookPreToolUse, ToolName: "Bash"},
				want:  nil,
			},
		},
		"request-open-resolve": {
			{
				frame: &HookFrame{Provider: ProviderClaude, SessionID: "sess-hook", Hook: HookNotification, ToolUseID: "toolu_4", Detail: "Claude needs your permission to use Bash"},
				want:  []Event{{Type: EventRequestOpened, RequestID: "toolu_4", RequestType: RequestToolApproval}},
			},
			{
				// Re-notification for the same request is not re-opened.
				frame: &HookFrame{Provider: ProviderClaude, SessionID: "sess-hook", Hook: HookNotification, ToolUseID: "toolu_4", Detail: "Claude needs your permission to use Bash"},
				want:  nil,
			},
			{
				frame: &HookFrame{Provider: ProviderClaude, SessionID: "sess-hook", Hook: HookPermissionRequest, ToolUseID: "toolu_4", Decision: "approved"},
				want:  []Event{{Type: EventRequestResolved, RequestID: "toolu_4", Decision: "approved"}},
			},
			{
				// A decision for a request never opened emits a balanced pair.
				frame: &HookFrame{Provider: ProviderClaude, SessionID: "sess-hook", Hook: HookPermissionRequest, ToolUseID: "toolu_5", Detail: "Bash: rm -rf /tmp/x", Decision: "denied"},
				want: []Event{
					{Type: EventRequestOpened, RequestID: "toolu_5", RequestType: RequestToolApproval},
					{Type: EventRequestResolved, RequestID: "toolu_5", Decision: "denied"},
				},
			},
		},
		"request-implicit-resolution": {
			{
				frame: &HookFrame{Provider: ProviderClaude, SessionID: "sess-hook", Hook: HookNotification, Detail: "Claude is waiting for your input"},
				want:  []Event{{Type: EventRequestOpened, RequestID: "req-1", RequestType: RequestUserInput}},
			},
			{
				// Any progress frame proves the request is no longer blocking:
				// pending requests resolve (decision unknown) first.
				frame: &HookFrame{Provider: ProviderClaude, SessionID: "sess-hook", Hook: HookUserPromptSubmit, Prompt: "continue"},
				want: []Event{
					{Type: EventRequestResolved, RequestID: "req-1"},
					{Type: EventTurnStarted, TurnID: "turn-1", Prompt: "continue"},
				},
			},
		},
		"turn-bracketing": {
			{
				// Stop with no active turn emits nothing.
				frame: &HookFrame{Provider: ProviderClaude, SessionID: "sess-hook", Hook: HookStop},
				want:  nil,
			},
			{
				frame: &HookFrame{Provider: ProviderClaude, SessionID: "sess-hook", Hook: HookUserPromptSubmit, Prompt: "fix the bug"},
				want:  []Event{{Type: EventTurnStarted, TurnID: "turn-1", Prompt: "fix the bug"}},
			},
			{
				frame: &HookFrame{Provider: ProviderClaude, SessionID: "sess-hook", Hook: HookStop},
				want:  []Event{{Type: EventTurnCompleted, TurnID: "turn-1"}},
			},
			{
				frame: &HookFrame{Provider: ProviderClaude, SessionID: "sess-hook", Hook: HookUserPromptSubmit, Prompt: "now the tests"},
				want:  []Event{{Type: EventTurnStarted, TurnID: "turn-2", Prompt: "now the tests"}},
			},
		},
		"unknown-hook-ignored": {
			{
				frame: &HookFrame{Provider: ProviderClaude, SessionID: "sess-hook", Hook: "SubagentStop"},
				want:  nil,
			},
		},
	}

	for name, steps := range cases {
		t.Run(name, func(t *testing.T) {
			runMergeSteps(t, steps)
		})
	}
}

// TestSubscriptionInjectsHookFrames exercises the live path: hook frames
// injected into an open subscription interleave with transcript growth on the
// same seq-ordered event channel, deduplicated by tool_use_id.
func TestSubscriptionInjectsHookFrames(t *testing.T) {
	path := filepath.Join(t.TempDir(), "session.jsonl")
	if err := os.WriteFile(path, []byte(claudeUserLine("u1", "first")), 0o644); err != nil {
		t.Fatal(err)
	}
	subscription, _, err := Open(Config{
		Provider:       ProviderClaude,
		TranscriptPath: path,
		PollInterval:   2 * time.Millisecond,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer subscription.Close()
	snapshot := awaitEvent(t, subscription.Events, EventSnapshot)

	if !subscription.InjectHookFrame(HookFrame{
		Provider: ProviderClaude, SessionID: "sess-tail", Hook: HookUserPromptSubmit, Prompt: "run ls",
	}) {
		t.Fatal("inject UserPromptSubmit failed")
	}
	turnStarted := awaitEvent(t, subscription.Events, EventTurnStarted)
	if turnStarted.Prompt != "run ls" || turnStarted.TurnID == "" {
		t.Fatalf("turn.started = %+v", turnStarted)
	}
	if turnStarted.Seq <= snapshot.Seq {
		t.Errorf("seq did not advance: snapshot=%d turn=%d", snapshot.Seq, turnStarted.Seq)
	}

	subscription.InjectHookFrame(HookFrame{
		Provider: ProviderClaude, SessionID: "sess-tail", Hook: HookPreToolUse,
		ToolName: "Bash", ToolUseID: "toolu_live", Detail: "ls",
	})
	started := awaitEvent(t, subscription.Events, EventItemStarted)
	if started.Item == nil || started.Item.ID != "toolu_live" || started.Item.Status != StatusInProgress {
		t.Fatalf("hook item.started = %+v", started.Item)
	}

	// The transcript line for the same tool call must update, not duplicate.
	file, err := os.OpenFile(path, os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := file.WriteString(claudeToolUseLine("a1", "toolu_live", "ls") + "\n"); err != nil {
		t.Fatal(err)
	}
	file.Close()
	updated := awaitEvent(t, subscription.Events, EventItemUpdated)
	if updated.Item == nil || updated.Item.ID != "toolu_live" || updated.Item.Input == nil {
		t.Fatalf("transcript-confirmed item.updated = %+v", updated.Item)
	}

	subscription.InjectHookFrame(HookFrame{
		Provider: ProviderClaude, SessionID: "sess-tail", Hook: HookStop,
	})
	completedTurn := awaitEvent(t, subscription.Events, EventTurnCompleted)
	if completedTurn.TurnID != turnStarted.TurnID {
		t.Errorf("turn.completed id = %q, want %q", completedTurn.TurnID, turnStarted.TurnID)
	}
}
