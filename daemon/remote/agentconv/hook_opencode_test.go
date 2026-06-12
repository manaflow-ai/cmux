package agentconv

import "testing"

// The emit verb passes ready-made frames through with their own provider, so
// the merge path must not assume claude or codex. opencode plugin frames use
// opencode's lowercase tool ids.
func TestHookMergeOpencodeProviderFrames(t *testing.T) {
	providerOpencode := ProviderID("opencode")
	parser := newTranscriptParser(providerOpencode, "/tmp/oc.jsonl")
	merger := newHookMerger(parser.conv())

	started := merger.consumeHookFrame(HookFrame{
		Provider: providerOpencode, SessionID: "oc-1", Hook: HookPreToolUse,
		ToolName: "bash", ToolUseID: "call-1", Detail: "ls -la",
	})
	if len(started) != 1 || started[0].Type != EventItemStarted {
		t.Fatalf("opencode PreToolUse = %+v", started)
	}
	if started[0].Item.Type != ItemCommandExecution || started[0].Item.Title != "ls -la" {
		t.Errorf("bash item = %+v, want command_execution", started[0].Item)
	}

	completed := merger.consumeHookFrame(HookFrame{
		Provider: providerOpencode, SessionID: "oc-1", Hook: HookPostToolUse,
		ToolName: "bash", ToolUseID: "call-1",
	})
	if len(completed) != 1 || completed[0].Type != EventItemCompleted {
		t.Fatalf("opencode PostToolUse = %+v", completed)
	}

	edit := merger.consumeHookFrame(HookFrame{
		Provider: providerOpencode, SessionID: "oc-1", Hook: HookPreToolUse,
		ToolName: "edit", ToolUseID: "call-2", Detail: "src/main.ts",
	})
	if edit[0].Item.Type != ItemFileChange {
		t.Errorf("edit item type = %s, want file_change", edit[0].Item.Type)
	}
}

func TestClassifyGenericTool(t *testing.T) {
	cases := map[string]ItemType{
		"bash":            ItemCommandExecution,
		"Shell":           ItemCommandExecution,
		"exec_command":    ItemCommandExecution,
		"edit":            ItemFileChange,
		"write":           ItemFileChange,
		"patch":           ItemFileChange,
		"webfetch":        ItemWebSearch,
		"websearch":       ItemWebSearch,
		"mcp__linear__ls": ItemMCPToolCall,
		"todowrite":       ItemDynamicToolCall,
		"read":            ItemDynamicToolCall,
	}
	for name, want := range cases {
		if got := classifyGenericTool(name); got != want {
			t.Errorf("classifyGenericTool(%q) = %s, want %s", name, got, want)
		}
	}
}
