package home

import "testing"

func TestGroupSessionsUsesStableStatusAndSessionOrdering(t *testing.T) {
	groups := GroupSessions([]Session{
		{ID: "z", Adapter: "pi", Status: "completed", Title: "Z"},
		{ID: "b", Adapter: "codex", Status: "active", Title: "B"},
		{ID: "a", Adapter: "claude", Status: "active", Title: "A"},
		{ID: "q", Adapter: "opencode", Status: "pending", Title: "Q"},
	})

	if len(groups) != 3 {
		t.Fatalf("groups = %d, want 3", len(groups))
	}
	wantStatuses := []string{"awaiting", "working", "completed"}
	for index, want := range wantStatuses {
		if groups[index].Status != want {
			t.Fatalf("group[%d] status = %q, want %q", index, groups[index].Status, want)
		}
	}
	if groups[1].Sessions[0].ID != "a" || groups[1].Sessions[1].ID != "b" {
		t.Fatalf("working group order = %#v", groups[1].Sessions)
	}
}
