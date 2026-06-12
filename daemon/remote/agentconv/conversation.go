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
// completed (items that arrive whole in the transcript). When an item with
// the same tool_use_id (or id) already exists — a hook frame raced the
// transcript line, or vice versa — the incoming content merges into the
// existing item instead of duplicating it, reported as updated.
func (c *conversation) appendItem(item Item) change {
	if item.ToolUseID != "" {
		if index, ok := c.byToolUseID[item.ToolUseID]; ok {
			return c.mergeItem(index, item)
		}
	}
	if item.ID != "" {
		if index, ok := c.byID[item.ID]; ok {
			return c.mergeItem(index, item)
		}
	}
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

// trimToNewest drops the oldest items beyond keep and rebuilds the id maps
// with the shifted indexes. Live tailing calls this so a subscription held
// open on a busy session cannot grow without bound; consumers observe the
// trim as a fresh snapshot.
func (c *conversation) trimToNewest(keep int) {
	if keep < 0 || len(c.items) <= keep {
		return
	}
	drop := len(c.items) - keep
	c.items = append([]Item(nil), c.items[drop:]...)
	c.byID = make(map[string]int, len(c.items))
	c.byToolUseID = make(map[string]int, len(c.items))
	for index := range c.items {
		if id := c.items[index].ID; id != "" {
			c.byID[id] = index
		}
		if toolUseID := c.items[index].ToolUseID; toolUseID != "" {
			c.byToolUseID[toolUseID] = index
		}
	}
}

// mergeItem folds incoming content into an existing item (same logical item
// seen by two sources). Incoming fields win where set, except status never
// regresses from a terminal state back to in_progress.
func (c *conversation) mergeItem(index int, incoming Item) change {
	existing := &c.items[index]
	if incoming.Type != "" && incoming.Type != ItemUnknown {
		existing.Type = incoming.Type
	}
	if incoming.Text != "" {
		existing.Text = incoming.Text
	}
	if incoming.ToolName != "" {
		existing.ToolName = incoming.ToolName
	}
	if incoming.Input != nil {
		existing.Input = incoming.Input
	}
	if incoming.Output != nil {
		existing.Output = incoming.Output
	}
	if incoming.Title != "" {
		existing.Title = incoming.Title
	}
	if incoming.CreatedAt != "" && existing.CreatedAt == "" {
		existing.CreatedAt = incoming.CreatedAt
	}
	wasTerminal := existing.Status != StatusInProgress
	if incoming.Status != "" && incoming.Status != StatusInProgress {
		existing.Status = incoming.Status
	}
	kind := changeUpdated
	if !wasTerminal && existing.Status != StatusInProgress {
		kind = changeCompleted
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
