package home

import (
	"fmt"
	"strings"
)

func Summary(state HomeState) string {
	state.Normalize()

	var b strings.Builder
	b.WriteString("cmux home\n")
	b.WriteString("adapters:")
	for _, count := range AdapterCounts(state.Sessions) {
		fmt.Fprintf(&b, " %s=%d", count.Adapter, count.Count)
	}
	b.WriteString("\n")

	for _, group := range GroupSessions(state.Sessions) {
		fmt.Fprintf(&b, "%s: %d\n", group.Status, len(group.Sessions))
		for _, session := range group.Sessions {
			fmt.Fprintf(
				&b,
				"  %s %s %s",
				session.Adapter,
				session.ResumeSessionID(),
				session.Title,
			)
			if cwd := session.WorkingDir(); cwd != "" {
				fmt.Fprintf(&b, " [%s]", cwd)
			}
			b.WriteString("\n")
		}
	}

	if selected, ok := FirstSession(state); ok {
		fmt.Fprintf(&b, "selected: %s\n", selected.ResumeSessionID())
		if adapter, ok := AdapterFor(selected.Adapter); ok {
			fmt.Fprintf(&b, "resume: %s\n", adapter.ResumeCommand(selected))
		}
	}
	fmt.Fprintf(&b, "task prompt: %d queued\n", len(state.Tasks))
	return b.String()
}

func FirstSession(state HomeState) (Session, bool) {
	groups := GroupSessions(state.Sessions)
	for _, group := range groups {
		if len(group.Sessions) > 0 {
			return group.Sessions[0], true
		}
	}
	return Session{}, false
}
