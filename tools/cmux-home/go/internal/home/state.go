package home

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"sort"
	"strings"
)

type HomeState struct {
	GeneratedAt string    `json:"generatedAt,omitempty"`
	Sessions    []Session `json:"sessions"`
	Tasks       []Task    `json:"tasks,omitempty"`
}

type Session struct {
	ID               string `json:"id"`
	SessionID        string `json:"sessionId,omitempty"`
	Adapter          string `json:"adapter"`
	Status           string `json:"status"`
	Title            string `json:"title"`
	CWD              string `json:"cwd,omitempty"`
	WorkingDirectory string `json:"workingDirectory,omitempty"`
	Branch           string `json:"branch,omitempty"`
	UpdatedAt        string `json:"updatedAt,omitempty"`
	Preview          string `json:"preview,omitempty"`
	Summary          string `json:"summary,omitempty"`
	ResumeCommand    string `json:"resumeCommand,omitempty"`
}

type Task struct {
	ID      string `json:"id,omitempty"`
	Title   string `json:"title"`
	Status  string `json:"status,omitempty"`
	Adapter string `json:"adapter,omitempty"`
}

func LoadState(path string) (HomeState, string, error) {
	if strings.TrimSpace(path) != "" {
		state, err := loadStateFile(path)
		return state, path, err
	}

	for _, candidate := range DefaultDataPaths() {
		state, err := loadStateFile(candidate)
		if err == nil {
			return state, candidate, nil
		}
		if !errors.Is(err, os.ErrNotExist) {
			return HomeState{}, candidate, err
		}
	}

	return FallbackState(), "fallback", nil
}

func DefaultDataPaths() []string {
	return []string{
		"state.json",
		"example-state.json",
		"tools/cmux-home/example-state.json",
		"tools/cmux-home/state/example.json",
		"tools/cmux-home/state/state.json",
		"tools/cmux-home/shared/state.json",
		"../state/example.json",
		"../state/state.json",
		"../examples/state.json",
		"../shared/state.json",
	}
}

func ParseState(data []byte) (HomeState, error) {
	data = bytes.TrimSpace(data)
	if len(data) == 0 {
		return HomeState{}, fmt.Errorf("empty state JSON")
	}

	decoder := json.NewDecoder(bytes.NewReader(data))
	decoder.UseNumber()
	var raw any
	if err := decoder.Decode(&raw); err != nil {
		return HomeState{}, err
	}

	var state HomeState
	switch value := raw.(type) {
	case []any:
		state.Sessions = sessionsFromAny(value)
	case map[string]any:
		if err := validateSchemaContract(value); err != nil {
			return HomeState{}, err
		}
		state.GeneratedAt = firstString(value, "generatedAt", "generated_at", "updatedAt", "updated_at")
		state.Sessions = sessionsFromAny(firstAny(value, "sessions", "items", "agentSessions", "agent_sessions"))
		state.Tasks = tasksFromAny(firstAny(value, "tasks", "queue"))
		if len(state.Sessions) == 0 && looksLikeSession(value) {
			state.Sessions = []Session{sessionFromMap(value)}
		}
	default:
		return HomeState{}, fmt.Errorf("state root must be an object or array")
	}

	state.Normalize()
	return state, nil
}

func (s *HomeState) Normalize() {
	for index := range s.Sessions {
		session := &s.Sessions[index]
		session.Adapter = NormalizeAdapter(session.Adapter)
		session.Status = NormalizeStatus(session.Status)
		session.ID = strings.TrimSpace(session.ID)
		session.SessionID = strings.TrimSpace(session.SessionID)
		session.Title = strings.TrimSpace(session.Title)
		session.CWD = strings.TrimSpace(session.CWD)
		session.WorkingDirectory = strings.TrimSpace(session.WorkingDirectory)
		session.Branch = strings.TrimSpace(session.Branch)
		session.UpdatedAt = strings.TrimSpace(session.UpdatedAt)
		session.Preview = strings.TrimSpace(session.Preview)
		session.Summary = strings.TrimSpace(session.Summary)
		session.ResumeCommand = strings.TrimSpace(session.ResumeCommand)
		if session.ID == "" {
			session.ID = session.ResumeSessionID()
		}
		if session.Title == "" {
			session.Title = session.ID
		}
	}
	for index := range s.Tasks {
		task := &s.Tasks[index]
		task.ID = strings.TrimSpace(task.ID)
		task.Title = strings.TrimSpace(task.Title)
		task.Status = NormalizeStatus(task.Status)
		task.Adapter = NormalizeAdapter(task.Adapter)
	}
}

func (s Session) ResumeSessionID() string {
	if trimmed := strings.TrimSpace(s.SessionID); trimmed != "" {
		return trimmed
	}
	return strings.TrimSpace(s.ID)
}

func (s Session) WorkingDir() string {
	if trimmed := strings.TrimSpace(s.CWD); trimmed != "" {
		return trimmed
	}
	return strings.TrimSpace(s.WorkingDirectory)
}

func (s Session) PreviewText() string {
	if trimmed := strings.TrimSpace(s.Preview); trimmed != "" {
		return trimmed
	}
	return strings.TrimSpace(s.Summary)
}

func loadStateFile(path string) (HomeState, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return HomeState{}, err
	}
	return ParseState(data)
}

func sessionsFromAny(value any) []Session {
	values, ok := value.([]any)
	if !ok {
		return nil
	}
	sessions := make([]Session, 0, len(values))
	for _, item := range values {
		object, ok := item.(map[string]any)
		if !ok {
			continue
		}
		sessions = append(sessions, sessionFromMap(object))
	}
	return sessions
}

func tasksFromAny(value any) []Task {
	values, ok := value.([]any)
	if !ok {
		return nil
	}
	tasks := make([]Task, 0, len(values))
	for _, item := range values {
		object, ok := item.(map[string]any)
		if !ok {
			continue
		}
		tasks = append(tasks, Task{
			ID:      firstString(object, "id", "taskId", "task_id"),
			Title:   firstString(object, "title", "name", "prompt", "text"),
			Status:  firstString(object, "status", "state"),
			Adapter: adapterFromObject(object),
		})
	}
	return tasks
}

func sessionFromMap(object map[string]any) Session {
	workspace, _ := object["workspace"].(map[string]any)
	workspaceGit, _ := workspace["git"].(map[string]any)
	resume, _ := object["resume"].(map[string]any)
	activity, _ := object["activity"].(map[string]any)
	attention, _ := object["attention"].(map[string]any)
	session := Session{
		ID:        firstString(object, "id", "uuid"),
		SessionID: firstString(object, "agentSessionId", "agent_session_id", "sessionId", "session_id", "nativeSessionId", "native_session_id"),
		Adapter:   adapterFromObject(object),
		Status:    firstString(object, "status", "state"),
		Title:     firstString(object, "title", "name", "prompt", "task"),
		CWD:       firstNonEmpty(firstString(object, "cwd", "workspacePath", "projectPath", "directory"), firstString(workspace, "cwd")),
		WorkingDirectory: firstString(
			object,
			"workingDirectory",
			"working_directory",
		),
		Branch:    firstNonEmpty(firstString(object, "branch", "gitBranch", "git_branch"), firstString(workspaceGit, "branch", "gitBranch", "git_branch")),
		UpdatedAt: firstString(object, "updatedAt", "updated_at", "modified", "mtime"),
		Preview: firstNonEmpty(
			firstString(object, "preview", "details", "message", "lastMessage", "last_message"),
			firstString(activity, "lastMessage", "last_message"),
			firstString(attention, "promptSummary", "prompt_summary"),
		),
		Summary: firstString(object, "summary"),
		ResumeCommand: commandArrayString(
			firstAny(resume, "command"),
		),
	}

	if session.ID == "" {
		session.ID = session.SessionID
	}
	if session.SessionID == "" {
		session.SessionID = firstString(object, "sessionPath", "session_path")
	}
	if session.Branch == "" {
		if git, ok := object["git"].(map[string]any); ok {
			session.Branch = firstString(git, "branch", "gitBranch", "git_branch")
		}
	}
	if session.Title == "" {
		session.Title = titleFromMessages(firstAny(object, "messages", "transcript"))
	}
	return session
}

func adapterFromObject(object map[string]any) string {
	if adapter := firstString(object, "adapter", "kind", "agentKind", "agent_kind", "type"); adapter != "" {
		return adapter
	}
	switch agent := object["agent"].(type) {
	case string:
		return agent
	case map[string]any:
		return firstString(agent, "id", "kind", "name", "type")
	}
	return ""
}

func titleFromMessages(value any) string {
	values, ok := value.([]any)
	if !ok {
		return ""
	}
	for _, item := range values {
		object, ok := item.(map[string]any)
		if !ok {
			continue
		}
		role := strings.ToLower(firstString(object, "role", "author"))
		if role != "" && role != "user" {
			continue
		}
		if text := firstString(object, "content", "text", "message"); text != "" {
			return text
		}
	}
	return ""
}

func looksLikeSession(object map[string]any) bool {
	for _, key := range []string{"sessionId", "session_id", "adapter", "kind", "agent", "status", "state"} {
		if _, ok := object[key]; ok {
			return true
		}
	}
	return false
}

func firstAny(object map[string]any, keys ...string) any {
	if object == nil {
		return nil
	}
	for _, key := range keys {
		if value, ok := object[key]; ok {
			return value
		}
	}
	return nil
}

func firstString(object map[string]any, keys ...string) string {
	if object == nil {
		return ""
	}
	for _, key := range keys {
		value, ok := object[key]
		if !ok {
			continue
		}
		switch typed := value.(type) {
		case string:
			if trimmed := strings.TrimSpace(typed); trimmed != "" {
				return trimmed
			}
		case json.Number:
			return typed.String()
		}
	}
	return ""
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if trimmed := strings.TrimSpace(value); trimmed != "" {
			return trimmed
		}
	}
	return ""
}

func commandArrayString(value any) string {
	values, ok := value.([]any)
	if !ok {
		return ""
	}
	parts := make([]string, 0, len(values))
	for _, value := range values {
		part, ok := value.(string)
		if !ok {
			return ""
		}
		part = strings.TrimSpace(part)
		if part == "" {
			return ""
		}
		parts = append(parts, ShellQuoteBareSafe(part))
	}
	return strings.Join(parts, " ")
}

func validateSchemaContract(object map[string]any) error {
	version, ok := object["schemaVersion"]
	if !ok {
		version, ok = object["schema_version"]
	}
	if !ok {
		return nil
	}
	if number, ok := version.(json.Number); !ok || number.String() != "1" {
		return fmt.Errorf("unsupported cmux home schemaVersion, expected 1")
	}
	sessions, ok := object["sessions"].([]any)
	if !ok {
		return nil
	}
	for index, item := range sessions {
		session, ok := item.(map[string]any)
		if !ok {
			continue
		}
		status := firstString(session, "status")
		if status != "awaiting" && status != "working" && status != "completed" {
			return fmt.Errorf("sessions[%d].status must be awaiting, working, or completed", index)
		}
	}
	return nil
}

func FallbackState() HomeState {
	state := HomeState{
		GeneratedAt: "prototype",
		Sessions: []Session{
			{
				ID:        "claude-session-001",
				SessionID: "claude-session-001",
				Adapter:   "claude",
				Status:    "working",
				Title:     "Wire shared session snapshots into cmux home",
				CWD:       "repo/",
				Branch:    "feat-cmux-home",
				Preview:   "Prototype row backed by the Claude Code adapter.",
			},
			{
				ID:        "codex-session-001",
				SessionID: "codex-session-001",
				Adapter:   "codex",
				Status:    "awaiting",
				Title:     "Review terminal resume metadata",
				CWD:       "worktrees/feat-cmux-home",
				Branch:    "feat-cmux-home",
				Preview:   "Queued state showing Codex resume semantics.",
			},
			{
				ID:        "opencode-session-001",
				SessionID: "opencode-session-001",
				Adapter:   "opencode",
				Status:    "completed",
				Title:     "Sketch grouped Agent View layout",
				CWD:       "tools/cmux-home",
				Branch:    "feat-cmux-home",
				Preview:   "Completed state for OpenCode sessions.",
			},
			{
				ID:        "pi-session-001",
				SessionID: "pi-session-001",
				Adapter:   "pi",
				Status:    "awaiting",
				Title:     "Validate Pi project-scoped session files",
				CWD:       "repo/",
				Branch:    "feat-cmux-home",
				Preview:   "Blocked state captures a known prototype gap.",
			},
		},
		Tasks: []Task{
			{ID: "task-001", Title: "Start a read-only cmux home shell", Status: "queued", Adapter: "claude"},
		},
	}
	state.Normalize()
	return state
}

type StatusGroup struct {
	Status   string
	Sessions []Session
}

var StatusOrder = []string{"awaiting", "working", "completed"}

func GroupSessions(sessions []Session) []StatusGroup {
	buckets := make(map[string][]Session)
	for _, session := range sessions {
		session.Adapter = NormalizeAdapter(session.Adapter)
		status := NormalizeStatus(session.Status)
		session.Status = status
		buckets[status] = append(buckets[status], session)
	}

	for status := range buckets {
		sort.SliceStable(buckets[status], func(i, j int) bool {
			left := buckets[status][i]
			right := buckets[status][j]
			return sessionSortKey(left) < sessionSortKey(right)
		})
	}

	result := make([]StatusGroup, 0, len(buckets))
	seen := make(map[string]bool)
	for _, status := range StatusOrder {
		if sessions := buckets[status]; len(sessions) > 0 {
			result = append(result, StatusGroup{Status: status, Sessions: sessions})
			seen[status] = true
		}
	}

	extra := make([]string, 0)
	for status := range buckets {
		if !seen[status] {
			extra = append(extra, status)
		}
	}
	sort.Strings(extra)
	for _, status := range extra {
		result = append(result, StatusGroup{Status: status, Sessions: buckets[status]})
	}

	return result
}

func NormalizeStatus(value string) string {
	normalized := strings.ToLower(strings.TrimSpace(value))
	normalized = strings.ReplaceAll(normalized, "_", "-")
	switch normalized {
	case "", "unknown":
		return "completed"
	case "active", "in-progress", "in progress", "working", "running":
		return "working"
	case "awaiting", "awaiting-user", "awaitinguser", "needs-input", "needs input", "blocked", "waiting", "queued", "pending", "created":
		return "awaiting"
	case "paused", "idle", "stopped":
		return "completed"
	case "done", "complete", "completed", "success", "succeeded":
		return "completed"
	case "failed", "failure", "error", "errored":
		return "awaiting"
	default:
		return "completed"
	}
}

func sessionSortKey(session Session) string {
	return session.Adapter + "\x00" + session.Title + "\x00" + session.ResumeSessionID()
}
