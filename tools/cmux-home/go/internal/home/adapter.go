package home

import (
	"sort"
	"strings"
)

type Adapter struct {
	ID             string
	Name           string
	Executable     string
	ResumeArgs     []string
	ResumeTemplate string
	FeatureGaps    []string
}

var adapterOrder = []string{"claude", "codex", "opencode", "pi"}

var adapters = map[string]Adapter{
	"claude": {
		ID:             "claude",
		Name:           "Claude Code",
		Executable:     "claude",
		ResumeArgs:     []string{"--resume", "{{sessionId}}"},
		ResumeTemplate: "claude --resume {{sessionId}}",
		FeatureGaps: []string{
			"Hook settings and MCP state are display-only.",
			"Session launch flags are not sanitized from live process snapshots yet.",
		},
	},
	"codex": {
		ID:             "codex",
		Name:           "Codex",
		Executable:     "codex",
		ResumeArgs:     []string{"resume", "{{sessionId}}"},
		ResumeTemplate: "codex resume {{sessionId}}",
		FeatureGaps: []string{
			"Cloud task and review metadata is summarized only.",
			"Profile and sandbox flags require serialized launch metadata.",
		},
	},
	"opencode": {
		ID:             "opencode",
		Name:           "OpenCode",
		Executable:     "opencode",
		ResumeArgs:     []string{"--session", "{{sessionId}}"},
		ResumeTemplate: "opencode --session {{sessionId}}",
		FeatureGaps: []string{
			"Server and web modes are not actionable from the prototype.",
			"Internal worker sessions depend on upstream cmux filtering.",
		},
	},
	"pi": {
		ID:             "pi",
		Name:           "Pi",
		Executable:     "pi",
		ResumeArgs:     []string{"--session", "{{sessionId}}"},
		ResumeTemplate: "pi --session {{sessionId}}",
		FeatureGaps: []string{
			"Project-scoped discovery depends on Pi session files.",
			"Registry overrides are represented as static metadata only.",
		},
	},
}

func KnownAdapters() []Adapter {
	result := make([]Adapter, 0, len(adapterOrder))
	for _, id := range adapterOrder {
		result = append(result, adapters[id])
	}
	return result
}

func AdapterFor(id string) (Adapter, bool) {
	adapter, ok := adapters[NormalizeAdapter(id)]
	return adapter, ok
}

func AdapterCounts(sessions []Session) []AdapterCount {
	counts := make(map[string]int)
	for _, session := range sessions {
		counts[NormalizeAdapter(session.Adapter)]++
	}

	result := make([]AdapterCount, 0, len(counts))
	for _, id := range adapterOrder {
		result = append(result, AdapterCount{Adapter: id, Count: counts[id]})
		delete(counts, id)
	}

	extra := make([]string, 0, len(counts))
	for id := range counts {
		if id != "" {
			extra = append(extra, id)
		}
	}
	sort.Strings(extra)
	for _, id := range extra {
		result = append(result, AdapterCount{Adapter: id, Count: counts[id]})
	}

	return result
}

type AdapterCount struct {
	Adapter string
	Count   int
}

func (a Adapter) ResumeCommand(session Session) string {
	if strings.TrimSpace(session.ResumeCommand) != "" {
		return strings.TrimSpace(session.ResumeCommand)
	}

	sessionID := session.ResumeSessionID()
	if sessionID == "" {
		return ""
	}

	argv := []string{a.Executable}
	for _, arg := range a.ResumeArgs {
		argv = append(argv, strings.ReplaceAll(arg, "{{sessionId}}", sessionID))
	}

	parts := make([]string, 0, len(argv))
	for _, arg := range argv {
		parts = append(parts, ShellQuote(arg))
	}
	command := strings.Join(parts, " ")
	if cwd := session.WorkingDir(); cwd != "" {
		command = "cd " + ShellQuote(cwd) + " && " + command
	}
	return command
}

func NormalizeAdapter(value string) string {
	normalized := strings.ToLower(strings.TrimSpace(value))
	normalized = strings.ReplaceAll(normalized, "_", "-")
	normalized = strings.ReplaceAll(normalized, " ", "-")
	switch {
	case normalized == "":
		return "unknown"
	case strings.Contains(normalized, "claude"):
		return "claude"
	case strings.Contains(normalized, "codex"):
		return "codex"
	case normalized == "open-code", normalized == "opencode", strings.Contains(normalized, "opencode"):
		return "opencode"
	case normalized == "pi", strings.Contains(normalized, "pi-coding-agent"):
		return "pi"
	default:
		return normalized
	}
}

func ShellQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

func ShellQuoteBareSafe(value string) string {
	for _, char := range value {
		if (char >= 'a' && char <= 'z') ||
			(char >= 'A' && char <= 'Z') ||
			(char >= '0' && char <= '9') ||
			strings.ContainsRune("_./:=+-", char) {
			continue
		}
		return ShellQuote(value)
	}
	return value
}
