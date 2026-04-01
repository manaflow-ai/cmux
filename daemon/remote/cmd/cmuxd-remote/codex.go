package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

type codexHookParsedInput struct {
	rawInput   string
	object     map[string]any
	sessionID  string
	cwd        string
	transcript string
}

type codexHookSessionRecord struct {
	SessionID   string  `json:"sessionId"`
	WorkspaceID string  `json:"workspaceId"`
	SurfaceID   string  `json:"surfaceId"`
	CWD         string  `json:"cwd,omitempty"`
	StartedAt   float64 `json:"startedAt"`
	UpdatedAt   float64 `json:"updatedAt"`
}

type codexHookSessionStoreFile struct {
	Version  int                               `json:"version"`
	Sessions map[string]codexHookSessionRecord `json:"sessions"`
}

type codexHookSessionStore struct {
	statePath string
}

const (
	defaultCodexHookStatePath = "~/.cmuxterm/codex-hook-sessions.json"
	codexHookMaxStateAge      = 7 * 24 * time.Hour
)

var codexHookEvents = []string{"session-start", "prompt-submit", "stop"}

func runCodexCommand(args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "cmux codex: requires a subcommand (install-hooks, uninstall-hooks)")
		return 2
	}

	switch strings.ToLower(strings.TrimSpace(args[0])) {
	case "install-hooks":
		if err := installCodexHooks(args[1:]); err != nil {
			fmt.Fprintf(os.Stderr, "cmux codex: %v\n", err)
			return 1
		}
		return 0
	case "uninstall-hooks":
		if err := uninstallCodexHooks(); err != nil {
			fmt.Fprintf(os.Stderr, "cmux codex: %v\n", err)
			return 1
		}
		return 0
	case "help", "--help", "-h":
		fmt.Fprintln(os.Stderr, "Usage: cmux codex <install-hooks|uninstall-hooks>")
		return 0
	default:
		fmt.Fprintf(os.Stderr, "cmux codex: unknown subcommand %q\n", args[0])
		return 2
	}
}

func runCodexHookCommand(socketPath string, args []string, refreshAddr func() string) int {
	if strings.TrimSpace(os.Getenv("CMUX_SURFACE_ID")) == "" {
		fmt.Println("{}")
		return 0
	}

	subcommand := "help"
	if len(args) > 0 {
		subcommand = strings.ToLower(strings.TrimSpace(args[0]))
	}

	switch subcommand {
	case "session-start", "prompt-submit", "stop":
	case "help", "--help", "-h":
		fmt.Fprintln(os.Stderr, "Usage: cmux codex-hook <session-start|prompt-submit|stop>")
		return 0
	default:
		fmt.Fprintf(os.Stderr, "cmux codex-hook: unknown subcommand %q\n", subcommand)
		return 2
	}

	rawInputBytes, err := io.ReadAll(os.Stdin)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux codex-hook: failed to read stdin: %v\n", err)
		return 1
	}
	parsed := parseCodexHookInput(string(rawInputBytes))
	store := newCodexHookSessionStore()

	switch subcommand {
	case "session-start":
		workspaceID, surfaceID := codexHookContext(parsed.sessionID, store)
		if parsed.sessionID != "" && workspaceID != "" {
			if err := store.upsert(parsed.sessionID, workspaceID, surfaceID, parsed.cwd); err != nil {
				fmt.Fprintf(os.Stderr, "cmux codex-hook: %v\n", err)
				return 1
			}
		}
		fmt.Println("{}")
		return 0

	case "prompt-submit":
		workspaceID, _ := codexHookContext(parsed.sessionID, store)
		if workspaceID != "" {
			if err := sendV1CommandRemote(socketPath, fmt.Sprintf("clear_notifications --tab=%s", workspaceID), refreshAddr); err != nil && !shouldIgnoreCodexHookError(err) {
				fmt.Fprintf(os.Stderr, "cmux codex-hook: %v\n", err)
				return 1
			}
			if err := setCodexStatusRemote(socketPath, workspaceID, "Running", "bolt.fill", "#4C8DFF", refreshAddr); err != nil && !shouldIgnoreCodexHookError(err) {
				fmt.Fprintf(os.Stderr, "cmux codex-hook: %v\n", err)
				return 1
			}
		}
		fmt.Println("{}")
		return 0

	case "stop":
		record, _ := store.lookup(parsed.sessionID)
		workspaceID, surfaceID := codexHookContext(parsed.sessionID, store)
		if record != nil {
			if workspaceID == "" {
				workspaceID = record.WorkspaceID
			}
			if surfaceID == "" {
				surfaceID = record.SurfaceID
			}
		}

		lastMessage := codexLastAssistantMessage(parsed.object)
		if lastMessage != "" {
			lastMessage = truncateCodexHook(normalizedSingleLineCodex(lastMessage), 200)
		}
		cwd := normalizeCodexHookString(parsed.cwd)
		if cwd == "" && record != nil {
			cwd = record.CWD
		}

		subtitle := "Completed"
		if projectName := codexProjectName(cwd); projectName != "" {
			subtitle = "Completed in " + projectName
		}
		body := lastMessage
		if body == "" {
			body = "Codex session completed"
		}

		if parsed.sessionID != "" && workspaceID != "" {
			if err := store.upsert(parsed.sessionID, workspaceID, surfaceID, cwd); err != nil {
				fmt.Fprintf(os.Stderr, "cmux codex-hook: %v\n", err)
				return 1
			}
		}

		if workspaceID != "" {
			var notifyErr error
			if surfaceID != "" {
				_, notifyErr = socketRoundTripV2(socketPath, "notification.create_for_target", map[string]any{
					"workspace_id": workspaceID,
					"surface_id":   surfaceID,
					"title":        "Codex",
					"subtitle":     subtitle,
					"body":         body,
				}, refreshAddr)
			} else {
				_, notifyErr = socketRoundTripV2(socketPath, "notification.create", map[string]any{
					"workspace_id": workspaceID,
					"title":        "Codex",
					"subtitle":     subtitle,
					"body":         body,
				}, refreshAddr)
			}
			if notifyErr != nil && !shouldIgnoreCodexHookError(notifyErr) {
				fmt.Fprintf(os.Stderr, "cmux codex-hook: %v\n", notifyErr)
				return 1
			}

			if err := setCodexStatusRemote(socketPath, workspaceID, "Idle", "pause.circle.fill", "#8E8E93", refreshAddr); err != nil && !shouldIgnoreCodexHookError(err) {
				fmt.Fprintf(os.Stderr, "cmux codex-hook: %v\n", err)
				return 1
			}
		}
		fmt.Println("{}")
		return 0
	}

	return 0
}

func installCodexHooks(args []string) error {
	for _, arg := range args {
		trimmed := strings.TrimSpace(arg)
		switch trimmed {
		case "", "--yes":
			continue
		default:
			return fmt.Errorf("unknown flag %q", arg)
		}
	}

	codexHome := os.Getenv("CODEX_HOME")
	if strings.TrimSpace(codexHome) == "" {
		codexHome = "~/.codex"
	}
	codexHome = expandTildeCodex(codexHome)
	hooksPath := filepath.Join(codexHome, "hooks.json")
	configPath := filepath.Join(codexHome, "config.toml")

	if err := os.MkdirAll(codexHome, 0o700); err != nil {
		return err
	}

	existingHooksContent := readFileIfExists(hooksPath)
	newHooksContent, err := buildCodexHooksContent(existingHooksContent)
	if err != nil {
		return err
	}

	existingConfigContent := readFileIfExists(configPath)
	newConfigContent := buildConfigWithCodexHooksRemote(existingConfigContent)

	hooksChanged := existingHooksContent != newHooksContent
	configChanged := existingConfigContent != newConfigContent
	if !hooksChanged && !configChanged {
		fmt.Println("cmux hooks are already installed. Nothing to change.")
		return nil
	}

	if hooksChanged {
		if err := writeFileAtomic(hooksPath, []byte(newHooksContent), 0o600); err != nil {
			return err
		}
	}
	if configChanged {
		if err := writeFileAtomic(configPath, []byte(newConfigContent), 0o600); err != nil {
			return err
		}
	}

	fmt.Println("Installed. Hooks activate inside cmux and silently no-op elsewhere.")
	return nil
}

func uninstallCodexHooks() error {
	codexHome := os.Getenv("CODEX_HOME")
	if strings.TrimSpace(codexHome) == "" {
		codexHome = "~/.codex"
	}
	codexHome = expandTildeCodex(codexHome)
	hooksPath := filepath.Join(codexHome, "hooks.json")
	configPath := filepath.Join(codexHome, "config.toml")

	existingHooksContent := readFileIfExists(hooksPath)
	if existingHooksContent == "" && readFileIfExists(configPath) == "" {
		fmt.Printf("No hooks.json found at %s\n", hooksPath)
		return nil
	}

	newHooksContent, removedCount, err := buildCodexHooksContentWithoutCmux(existingHooksContent)
	if err != nil {
		return err
	}
	existingConfigContent := readFileIfExists(configPath)
	newConfigContent := buildConfigWithoutCodexHooksRemote(existingConfigContent)
	configChanged := existingConfigContent != newConfigContent
	if removedCount == 0 && !configChanged {
		fmt.Println("No cmux hooks found.")
		return nil
	}

	if removedCount > 0 {
		if err := writeFileAtomic(hooksPath, []byte(newHooksContent), 0o600); err != nil {
			return err
		}
	}
	if configChanged {
		if err := writeFileAtomic(configPath, []byte(newConfigContent), 0o600); err != nil {
			return err
		}
	}
	fmt.Println("Removed cmux Codex hooks.")
	return nil
}

func buildCodexHooksContent(existingContent string) (string, error) {
	existing := map[string]any{}
	if strings.TrimSpace(existingContent) != "" {
		if err := json.Unmarshal([]byte(existingContent), &existing); err != nil {
			return "", fmt.Errorf("invalid hooks.json: %w", err)
		}
	}

	hooks, _ := existing["hooks"].(map[string]any)
	if hooks == nil {
		hooks = map[string]any{}
	}
	for eventName, cmuxGroups := range codexHooksDefinition() {
		var eventGroups []map[string]any
		if rawGroups, ok := hooks[eventName]; ok {
			eventGroups = anySliceToMapSlice(rawGroups)
		}
		filtered := make([]map[string]any, 0, len(eventGroups)+len(cmuxGroups))
		for _, group := range eventGroups {
			if !codexGroupOwnedByCmux(group) {
				filtered = append(filtered, group)
			}
		}
		filtered = append(filtered, cmuxGroups...)
		hooks[eventName] = filtered
	}
	existing["hooks"] = hooks

	data, err := json.MarshalIndent(existing, "", "  ")
	if err != nil {
		return "", err
	}
	return string(data) + "\n", nil
}

func buildCodexHooksContentWithoutCmux(existingContent string) (string, int, error) {
	if strings.TrimSpace(existingContent) == "" {
		return "", 0, nil
	}

	existing := map[string]any{}
	if err := json.Unmarshal([]byte(existingContent), &existing); err != nil {
		return "", 0, err
	}
	hooks, _ := existing["hooks"].(map[string]any)
	if hooks == nil {
		return existingContent, 0, nil
	}

	removedCount := 0
	for eventName, rawGroups := range hooks {
		groups := anySliceToMapSlice(rawGroups)
		filtered := make([]map[string]any, 0, len(groups))
		for _, group := range groups {
			if codexGroupOwnedByCmux(group) {
				removedCount++
				continue
			}
			filtered = append(filtered, group)
		}
		if len(filtered) == 0 {
			delete(hooks, eventName)
			continue
		}
		hooks[eventName] = filtered
	}
	existing["hooks"] = hooks

	data, err := json.MarshalIndent(existing, "", "  ")
	if err != nil {
		return "", 0, err
	}
	return string(data) + "\n", removedCount, nil
}

func codexHooksDefinition() map[string][]map[string]any {
	return map[string][]map[string]any{
		"SessionStart": {
			{
				"hooks": []map[string]any{{
					"type":    "command",
					"command": codexOwnedHookCommandRemote("session-start"),
					"timeout": 10,
				}},
			},
		},
		"UserPromptSubmit": {
			{
				"hooks": []map[string]any{{
					"type":    "command",
					"command": codexOwnedHookCommandRemote("prompt-submit"),
					"timeout": 10,
				}},
			},
		},
		"Stop": {
			{
				"hooks": []map[string]any{{
					"type":    "command",
					"command": codexOwnedHookCommandRemote("stop"),
					"timeout": 10,
				}},
			},
		},
	}
}

func codexHookCommandRemote(event string) string {
	return fmt.Sprintf(`[ -n "$CMUX_SURFACE_ID" ] && command -v cmux >/dev/null 2>&1 && cmux codex-hook %s || echo '{}'`, event)
}

func codexOwnedHookCommandRemote(event string) string {
	return codexHookCommandRemote(event) + " # cmux-managed"
}

func codexGroupOwnedByCmux(group map[string]any) bool {
	rawHooks, ok := group["hooks"]
	if !ok {
		return false
	}
	hooks := anySliceToMapSlice(rawHooks)
	if len(hooks) == 0 {
		return false
	}
	for _, hook := range hooks {
		command, _ := hook["command"].(string)
		if !codexCommandOwnedByCmux(command) {
			return false
		}
	}
	return true
}

func codexCommandOwnedByCmux(command string) bool {
	trimmed := strings.TrimSpace(command)
	if trimmed == "" {
		return false
	}
	if strings.HasSuffix(trimmed, "# cmux-managed") {
		return true
	}
	for _, event := range codexHookEvents {
		if trimmed == codexHookCommandRemote(event) {
			return true
		}
	}
	return false
}

func anySliceToMapSlice(value any) []map[string]any {
	rawSlice, ok := value.([]any)
	if !ok {
		if typed, ok := value.([]map[string]any); ok {
			return typed
		}
		return nil
	}
	result := make([]map[string]any, 0, len(rawSlice))
	for _, item := range rawSlice {
		if typed, ok := item.(map[string]any); ok {
			result = append(result, typed)
		}
	}
	return result
}

func buildConfigWithCodexHooksRemote(content string) string {
	lines := strings.Split(content, "\n")
	sectionRanges := tomlSectionRanges(lines)
	if featuresRange, ok := sectionRanges["features"]; ok {
		for i := featuresRange.start; i < featuresRange.end; i++ {
			if isTOMLKeyRemote(lines[i], "codex_hooks") {
				lines[i] = "codex_hooks = true"
				return strings.Join(lines, "\n")
			}
		}
		insertAt := featuresRange.end
		updated := append([]string{}, lines[:insertAt]...)
		updated = append(updated, "codex_hooks = true")
		updated = append(updated, lines[insertAt:]...)
		return strings.Join(updated, "\n")
	}
	result := content
	if result != "" && !strings.HasSuffix(result, "\n") {
		result += "\n"
	}
	result += "\n[features]\ncodex_hooks = true\n"
	return result
}

func buildConfigWithoutCodexHooksRemote(content string) string {
	lines := strings.Split(content, "\n")
	sectionRanges := tomlSectionRanges(lines)
	featuresRange, ok := sectionRanges["features"]
	if !ok {
		return content
	}

	featuresHasContent := false
	for i, line := range lines {
		if i >= featuresRange.start && i < featuresRange.end {
			trimmed := strings.TrimSpace(line)
			if isTOMLKeyRemote(line, "codex_hooks") {
				continue
			}
			if trimmed != "" && !strings.HasPrefix(trimmed, "#") {
				featuresHasContent = true
			}
		}
	}

	filtered := make([]string, 0, len(lines))
	removingFeaturesHeader := !featuresHasContent
	for i, line := range lines {
		if removingFeaturesHeader && i == featuresRange.headerIndex {
			continue
		}
		if i >= featuresRange.start && i < featuresRange.end && isTOMLKeyRemote(line, "codex_hooks") {
			continue
		}
		filtered = append(filtered, line)
	}

	if featuresHasContent {
		return strings.Join(filtered, "\n")
	}
	return strings.Join(filtered, "\n")
}

func isTOMLKeyRemote(line, key string) bool {
	trimmed := strings.TrimSpace(line)
	if strings.HasPrefix(trimmed, "#") || !strings.HasPrefix(trimmed, key) {
		return false
	}
	rest := strings.TrimSpace(strings.TrimPrefix(trimmed, key))
	return strings.HasPrefix(rest, "=")
}

type tomlSectionRange struct {
	headerIndex int
	start       int
	end         int
}

func tomlSectionRanges(lines []string) map[string]tomlSectionRange {
	ranges := map[string]tomlSectionRange{}
	currentName := ""
	currentHeader := -1
	currentStart := -1
	for i, line := range lines {
		sectionName, ok := parseTOMLSectionName(line)
		if !ok {
			continue
		}
		if currentName != "" {
			ranges[currentName] = tomlSectionRange{
				headerIndex: currentHeader,
				start:       currentStart,
				end:         i,
			}
		}
		currentName = sectionName
		currentHeader = i
		currentStart = i + 1
	}
	if currentName != "" {
		ranges[currentName] = tomlSectionRange{
			headerIndex: currentHeader,
			start:       currentStart,
			end:         len(lines),
		}
	}
	return ranges
}

func parseTOMLSectionName(line string) (string, bool) {
	trimmed := strings.TrimSpace(line)
	if strings.HasPrefix(trimmed, "[[") || !strings.HasPrefix(trimmed, "[") || !strings.HasSuffix(trimmed, "]") {
		return "", false
	}
	name := strings.TrimSpace(trimmed[1 : len(trimmed)-1])
	if name == "" || strings.Contains(name, ".") {
		return "", false
	}
	return name, true
}

func parseCodexHookInput(rawInput string) codexHookParsedInput {
	trimmed := strings.TrimSpace(rawInput)
	if trimmed == "" {
		return codexHookParsedInput{rawInput: rawInput}
	}
	var object map[string]any
	if err := json.Unmarshal([]byte(trimmed), &object); err != nil {
		return codexHookParsedInput{rawInput: rawInput}
	}
	return codexHookParsedInput{
		rawInput:   rawInput,
		object:     object,
		sessionID:  extractCodexSessionID(object),
		cwd:        extractCodexCWD(object),
		transcript: firstCodexString(object, "transcript_path", "transcriptPath"),
	}
}

func extractCodexSessionID(object map[string]any) string {
	if object == nil {
		return ""
	}
	if id := firstCodexString(object, "session_id", "sessionId"); id != "" {
		return id
	}
	if nested, ok := object["notification"].(map[string]any); ok {
		if id := firstCodexString(nested, "session_id", "sessionId"); id != "" {
			return id
		}
	}
	if nested, ok := object["data"].(map[string]any); ok {
		if id := firstCodexString(nested, "session_id", "sessionId"); id != "" {
			return id
		}
	}
	if session, ok := object["session"].(map[string]any); ok {
		if id := firstCodexString(session, "id", "session_id", "sessionId"); id != "" {
			return id
		}
	}
	if context, ok := object["context"].(map[string]any); ok {
		if id := firstCodexString(context, "session_id", "sessionId"); id != "" {
			return id
		}
	}
	return ""
}

func extractCodexCWD(object map[string]any) string {
	cwdKeys := []string{"cwd", "working_directory", "workingDirectory", "project_dir", "projectDir"}
	if object == nil {
		return ""
	}
	if cwd := firstCodexString(object, cwdKeys...); cwd != "" {
		return cwd
	}
	if nested, ok := object["notification"].(map[string]any); ok {
		if cwd := firstCodexString(nested, cwdKeys...); cwd != "" {
			return cwd
		}
	}
	if nested, ok := object["data"].(map[string]any); ok {
		if cwd := firstCodexString(nested, cwdKeys...); cwd != "" {
			return cwd
		}
	}
	if context, ok := object["context"].(map[string]any); ok {
		if cwd := firstCodexString(context, cwdKeys...); cwd != "" {
			return cwd
		}
	}
	return ""
}

func codexLastAssistantMessage(object map[string]any) string {
	if object == nil {
		return ""
	}
	if message := firstCodexString(object, "last_assistant_message", "lastAssistantMessage"); message != "" {
		return message
	}
	if nested, ok := object["data"].(map[string]any); ok {
		if message := firstCodexString(nested, "last_assistant_message", "lastAssistantMessage"); message != "" {
			return message
		}
	}
	return ""
}

func firstCodexString(object map[string]any, keys ...string) string {
	for _, key := range keys {
		value, ok := object[key]
		if !ok {
			continue
		}
		if typed, ok := value.(string); ok {
			if trimmed := strings.TrimSpace(typed); trimmed != "" {
				return trimmed
			}
		}
	}
	return ""
}

func newCodexHookSessionStore() *codexHookSessionStore {
	override := strings.TrimSpace(os.Getenv("CMUX_CLAUDE_HOOK_STATE_PATH"))
	if override != "" {
		return &codexHookSessionStore{statePath: expandTildeCodex(override)}
	}
	return &codexHookSessionStore{statePath: expandTildeCodex(defaultCodexHookStatePath)}
}

func (s *codexHookSessionStore) lookup(sessionID string) (*codexHookSessionRecord, error) {
	normalized := normalizeCodexHookString(sessionID)
	if normalized == "" {
		return nil, nil
	}
	var record *codexHookSessionRecord
	err := s.withLockedState(true, func(state *codexHookSessionStoreFile) error {
		stored, ok := state.Sessions[normalized]
		if !ok {
			return nil
		}
		copyRecord := stored
		record = &copyRecord
		return nil
	})
	return record, err
}

func (s *codexHookSessionStore) upsert(sessionID, workspaceID, surfaceID, cwd string) error {
	normalized := normalizeCodexHookString(sessionID)
	if normalized == "" {
		return nil
	}
	return s.withLockedState(false, func(state *codexHookSessionStoreFile) error {
		now := float64(time.Now().Unix())
		record, ok := state.Sessions[normalized]
		if !ok {
			record = codexHookSessionRecord{
				SessionID:   normalized,
				WorkspaceID: normalizeCodexHookString(workspaceID),
				SurfaceID:   normalizeCodexHookString(surfaceID),
				StartedAt:   now,
				UpdatedAt:   now,
			}
		}
		record.WorkspaceID = normalizeCodexHookString(workspaceID)
		if normalizedSurfaceID := normalizeCodexHookString(surfaceID); normalizedSurfaceID != "" {
			record.SurfaceID = normalizedSurfaceID
		}
		if normalizedCWD := normalizeCodexHookString(cwd); normalizedCWD != "" {
			record.CWD = normalizedCWD
		}
		record.UpdatedAt = now
		state.Sessions[normalized] = record
		return nil
	})
}

func (s *codexHookSessionStore) load() (*codexHookSessionStoreFile, error) {
	state := &codexHookSessionStoreFile{
		Version:  1,
		Sessions: map[string]codexHookSessionRecord{},
	}
	data, err := os.ReadFile(s.statePath)
	if err != nil {
		if os.IsNotExist(err) {
			return state, nil
		}
		return nil, err
	}
	if len(data) == 0 {
		return state, nil
	}
	if err := json.Unmarshal(data, state); err != nil {
		return nil, fmt.Errorf("decode hook state: %w", err)
	}
	if state.Sessions == nil {
		state.Sessions = map[string]codexHookSessionRecord{}
	}
	now := time.Now().Add(-codexHookMaxStateAge).Unix()
	for sessionID, record := range state.Sessions {
		if int64(record.UpdatedAt) < now {
			delete(state.Sessions, sessionID)
		}
	}
	return state, nil
}

func (s *codexHookSessionStore) save(state *codexHookSessionStoreFile) error {
	parentDir := filepath.Dir(s.statePath)
	if err := os.MkdirAll(parentDir, 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(state, "", "  ")
	if err != nil {
		return err
	}
	return writeFileAtomic(s.statePath, append(data, '\n'), 0o600)
}

func (s *codexHookSessionStore) withLockedState(readOnly bool, fn func(state *codexHookSessionStoreFile) error) error {
	lockFile, err := s.lock()
	if err != nil {
		return err
	}
	defer func() {
		_ = syscall.Flock(int(lockFile.Fd()), syscall.LOCK_UN)
		_ = lockFile.Close()
	}()

	state, err := s.load()
	if err != nil {
		return err
	}
	if err := fn(state); err != nil {
		return err
	}
	if readOnly {
		return nil
	}
	return s.save(state)
}

func (s *codexHookSessionStore) lock() (*os.File, error) {
	parentDir := filepath.Dir(s.statePath)
	if err := os.MkdirAll(parentDir, 0o700); err != nil {
		return nil, err
	}
	lockPath := s.statePath + ".lock"
	lockFile, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(lockFile.Fd()), syscall.LOCK_EX); err != nil {
		_ = lockFile.Close()
		return nil, err
	}
	return lockFile, nil
}

func writeFileAtomic(path string, data []byte, mode os.FileMode) error {
	parentDir := filepath.Dir(path)
	if err := os.MkdirAll(parentDir, 0o700); err != nil {
		return err
	}
	tempFile, err := os.CreateTemp(parentDir, filepath.Base(path)+".tmp.*")
	if err != nil {
		return err
	}
	tempPath := tempFile.Name()
	defer func() { _ = os.Remove(tempPath) }()
	if err := tempFile.Chmod(mode); err != nil {
		_ = tempFile.Close()
		return err
	}
	if _, err := tempFile.Write(data); err != nil {
		_ = tempFile.Close()
		return err
	}
	if err := tempFile.Close(); err != nil {
		return err
	}
	if err := os.Rename(tempPath, path); err != nil {
		return err
	}
	return os.Chmod(path, mode)
}

func codexHookContext(sessionID string, store *codexHookSessionStore) (string, string) {
	var workspaceID string
	var surfaceID string
	if record, err := store.lookup(sessionID); err == nil && record != nil {
		workspaceID = record.WorkspaceID
		surfaceID = record.SurfaceID
	}
	if workspaceID == "" {
		workspaceID = normalizeCodexHookString(os.Getenv("CMUX_WORKSPACE_ID"))
	}
	if surfaceID == "" {
		surfaceID = normalizeCodexHookString(os.Getenv("CMUX_SURFACE_ID"))
	}
	return workspaceID, surfaceID
}

func setCodexStatusRemote(socketPath, workspaceID, value, icon, color string, refreshAddr func() string) error {
	command := fmt.Sprintf("set_status codex %s --icon=%s --color=%s --tab=%s", value, icon, color, workspaceID)
	return sendV1CommandRemote(socketPath, command, refreshAddr)
}

func sendV1CommandRemote(socketPath, command string, refreshAddr func() string) error {
	response, err := socketRoundTrip(socketPath, command, refreshAddr)
	if err != nil {
		return err
	}
	if strings.HasPrefix(response, "ERROR:") {
		return fmt.Errorf("%s", response)
	}
	return nil
}

func shouldIgnoreCodexHookError(err error) bool {
	if err == nil {
		return false
	}
	lower := strings.ToLower(err.Error())
	return strings.Contains(lower, "tabmanager not available") ||
		strings.Contains(lower, "server error [unavailable]") ||
		strings.Contains(lower, "workspace not found") ||
		strings.Contains(lower, "surface not found")
}

func codexProjectName(cwd string) string {
	normalized := normalizeCodexHookString(cwd)
	if normalized == "" {
		return ""
	}
	expanded := expandTildeCodex(normalized)
	base := filepath.Base(expanded)
	if base == "." || base == string(filepath.Separator) {
		return expanded
	}
	return base
}

func normalizedSingleLineCodex(value string) string {
	return strings.Join(strings.Fields(value), " ")
}

func truncateCodexHook(value string, maxLength int) string {
	runes := []rune(value)
	if len(runes) <= maxLength {
		return value
	}
	if maxLength <= 1 {
		return "…"
	}
	return string(runes[:maxLength-1]) + "…"
}

func normalizeCodexHookString(value string) string {
	return strings.TrimSpace(value)
}

func expandTildeCodex(path string) string {
	trimmed := strings.TrimSpace(path)
	if trimmed == "" || trimmed[0] != '~' {
		return trimmed
	}
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return trimmed
	}
	if trimmed == "~" {
		return home
	}
	if strings.HasPrefix(trimmed, "~/") {
		return filepath.Join(home, strings.TrimPrefix(trimmed, "~/"))
	}
	return trimmed
}

func readFileIfExists(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	return string(data)
}
