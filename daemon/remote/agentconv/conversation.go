package agentconv

// conversation is the shared item store both parsers mutate. Parsers consume
// transcript lines and report changes; the subscription layer turns changes
// into protocol events (snapshot replay and live tail share this one path).

type changeKind int

const (
	changeStarted changeKind = iota
	changeUpdated
	changeCompleted
)

type change struct {
	itemIndex int
	kind      changeKind
}

type conversation struct {
	items       []Item
	byID        map[string]int
	byToolUseID map[string]int
	session     SessionRef
	// sessionDirty flags session metadata discovered after the snapshot.
	sessionDirty bool
}

func newConversation(provider ProviderID, transcriptPath string) *conversation {
	return &conversation{
		byID:        map[string]int{},
		byToolUseID: map[string]int{},
		session: SessionRef{
			Provider:       provider,
			TranscriptPath: transcriptPath,
		},
	}
}

// appendItem adds a new item and reports it as started (in progress) or
// completed (items that arrive whole in the transcript).
func (c *conversation) appendItem(item Item) change {
	index := len(c.items)
	c.items = append(c.items, item)
	if item.ID != "" {
		c.byID[item.ID] = index
	}
	if item.ToolUseID != "" {
		c.byToolUseID[item.ToolUseID] = index
	}
	kind := changeCompleted
	if item.Status == StatusInProgress {
		kind = changeStarted
	}
	return change{itemIndex: index, kind: kind}
}

// resolveTool folds a tool result into its pending tool item. Returns false
// for orphan results (no matching call seen).
func (c *conversation) resolveTool(toolUseID string, output *ToolOutput, failed bool) (change, bool) {
	index, ok := c.byToolUseID[toolUseID]
	if !ok {
		return change{}, false
	}
	item := &c.items[index]
	item.Output = output
	if failed {
		item.Status = StatusFailed
	} else {
		item.Status = StatusCompleted
	}
	return change{itemIndex: index, kind: changeCompleted}, true
}

func (c *conversation) noteSessionID(id string) {
	if id != "" && c.session.SessionID != id {
		c.session.SessionID = id
		c.sessionDirty = true
	}
}

func (c *conversation) noteCwd(cwd string) {
	if cwd != "" && c.session.Cwd != cwd {
		c.session.Cwd = cwd
		c.sessionDirty = true
	}
}

func (c *conversation) noteTitle(title string) {
	if title != "" && c.session.Title == "" {
		c.session.Title = title
		c.sessionDirty = true
	}
}

const maxTitleLength = 120

func truncateTitle(text string) string {
	runes := []rune(text)
	for i, r := range runes {
		if r == '\n' {
			runes = runes[:i]
			break
		}
	}
	if len(runes) > maxTitleLength {
		runes = runes[:maxTitleLength]
	}
	return string(runes)
}

// transcriptParser is one provider's incremental line consumer. consumeLine
// mutates the conversation and reports the resulting item changes; malformed
// or irrelevant lines return nil and are never fatal.
type transcriptParser interface {
	consumeLine(line []byte) []change
	conv() *conversation
}

func newTranscriptParser(provider ProviderID, transcriptPath string) transcriptParser {
	switch provider {
	case ProviderCodex:
		return newCodexParser(transcriptPath)
	default:
		return newClaudeParser(provider, transcriptPath)
	}
}
