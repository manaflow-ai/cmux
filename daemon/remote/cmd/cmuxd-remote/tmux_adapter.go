package main

import (
	"context"
	"fmt"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// validNewTmuxName restricts names for newly created tmux sessions to characters
// that are safe, portable, and unambiguous in tmux targets. This is enforced
// only when the user creates a new session via the picker; existing sessions
// discovered by tmux.session.list may have any name and are never validated —
// all tmux calls use exec.CommandContext (not a shell), so injection is not
// possible regardless of the session name.
var validNewTmuxName = regexp.MustCompile(`^[a-zA-Z0-9_-]+$`)

func isValidNewTmuxName(s string) bool { return s != "" && validNewTmuxName.MatchString(s) }

// tmuxExactTarget returns a tmux target string for the given session name.
// On tmux ≥2.5, the "=" prefix forces exact-match semantics so that names
// containing ":" or "." are not parsed as "session:window(.pane)" targets.
// On older versions (which lack the "=" prefix), we fall back to the raw name;
// in that case names with ":" or "." may resolve incorrectly, but such session
// names are extremely rare and would be pre-existing user configuration.
func tmuxExactTarget(name string) string {
	out, err := tmuxOutput("-V")
	if err != nil {
		return name // can't probe version; use raw name as safe fallback
	}
	version := strings.TrimSpace(string(out))
	if parts := strings.SplitN(version, " ", 2); len(parts) == 2 {
		version = parts[1]
	}
	if tmuxVersionAtLeast(version, 2, 5) {
		return "=" + name
	}
	return name
}

// tmuxVersionAtLeast returns true if the tmux version string is >= major.minor.
func tmuxVersionAtLeast(version string, major, minor int) bool {
	// Strip any trailing non-numeric suffix (e.g. "3.4a" → "3.4").
	clean := strings.TrimRight(version, "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
	parts := strings.SplitN(clean, ".", 2)
	maj, err := strconv.Atoi(parts[0])
	if err != nil {
		return false
	}
	if maj != major {
		return maj > major
	}
	if len(parts) < 2 {
		return minor == 0
	}
	min, err := strconv.Atoi(parts[1])
	if err != nil {
		return false
	}
	return min >= minor
}

// tmuxExecTimeout is the maximum time to wait for a one-shot tmux command.
const tmuxExecTimeout = 15 * time.Second

// tmuxOutput runs "tmux <args>" with a hard timeout and returns stdout.
func tmuxOutput(args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), tmuxExecTimeout)
	defer cancel()
	return exec.CommandContext(ctx, "tmux", args...).Output()
}

// tmuxRun runs "tmux <args>" with a hard timeout and returns only the error.
func tmuxRun(args ...string) error {
	ctx, cancel := context.WithTimeout(context.Background(), tmuxExecTimeout)
	defer cancel()
	return exec.CommandContext(ctx, "tmux", args...).Run()
}

// tmuxCombinedOutput runs "tmux <args>" with a hard timeout and returns combined stdout+stderr.
func tmuxCombinedOutput(args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), tmuxExecTimeout)
	defer cancel()
	return exec.CommandContext(ctx, "tmux", args...).CombinedOutput()
}

// --- RPC handlers ---

func (s *rpcServer) handleTmuxProbe(req rpcRequest) rpcResponse {
	out, err := tmuxOutput("-V")
	if err != nil {
		return rpcResponse{
			ID: req.ID,
			OK: true,
			Result: map[string]any{
				"available": false,
				"version":   "",
			},
		}
	}
	version := strings.TrimSpace(string(out))
	// "tmux 3.4" → "3.4"
	if parts := strings.SplitN(version, " ", 2); len(parts) == 2 {
		version = parts[1]
	}

	// Gate availability on control-mode support. tmux -CC was introduced in tmux 1.8.
	// Advertising available=true on older builds would let the picker proceed, then
	// fail silently when the control-mode SSH process exits immediately.
	if !tmuxVersionAtLeast(version, 1, 8) {
		return rpcResponse{
			ID: req.ID,
			OK: true,
			Result: map[string]any{
				"available": false,
				"version":   version,
			},
		}
	}

	// Also probe UTF-8 mode to surface potential encoding issues.
	// Use "show-options -gv utf8" rather than "display-message -p #{client_utf8}"
	// because the latter requires an attached client and always fails when probed
	// before any client connects (which is the common case on fresh tmux servers).
	utf8OK := true // default true; only flag false when explicitly disabled
	if out2, err2 := tmuxOutput("show-options", "-gv", "utf8"); err2 == nil {
		v := strings.TrimSpace(string(out2))
		utf8OK = v != "off" && v != "0"
	}

	return rpcResponse{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"available": true,
			"version":   version,
			"utf8":      utf8OK,
		},
	}
}

func (s *rpcServer) handleTmuxSessionList(req rpcRequest) rpcResponse {
	// Format: session_name TAB windows TAB attached TAB created (seconds since epoch)
	format := "#{session_name}\t#{session_windows}\t#{session_attached}\t#{session_created}"
	out, err := tmuxOutput("list-sessions", "-F", format)
	if err != nil {
		// tmux not running or no sessions — return empty list, not an error.
		return rpcResponse{
			ID: req.ID,
			OK: true,
			Result: map[string]any{
				"sessions": []any{},
			},
		}
	}

	var sessions []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "\t", 4)
		if len(parts) == 0 || parts[0] == "" {
			continue
		}
		session := map[string]any{
			"name":     parts[0],
			"windows":  0,
			"attached": false,
		}
		if len(parts) > 1 {
			if n, err := strconv.Atoi(parts[1]); err == nil {
				session["windows"] = n
			}
		}
		if len(parts) > 2 {
			session["attached"] = parts[2] != "0"
		}
		sessions = append(sessions, session)
	}
	if sessions == nil {
		sessions = []map[string]any{}
	}

	return rpcResponse{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"sessions": sessions,
		},
	}
}

func (s *rpcServer) handleTmuxSessionEnsure(req rpcRequest) rpcResponse {
	session, ok := getStringParam(req.Params, "session")
	if !ok || session == "" {
		return errResponse(req.ID, "invalid_params", "tmux.session.ensure requires session")
	}

	// Use an exact-match target (tmux ≥2.5) so that session names containing ":"
	// or "." are not resolved as "session:window(.pane)" targets.
	exactTarget := tmuxExactTarget(session)

	// Helper: get the session's stable $-prefixed ID after ensure succeeds.
	getSessionID := func() string {
		out, err := tmuxOutput("display-message", "-t", exactTarget, "-p", "#{session_id}")
		if err != nil {
			return ""
		}
		return strings.TrimSpace(string(out))
	}

	// Check if session already exists.
	if tmuxRun("has-session", "-t", exactTarget) == nil {
		return rpcResponse{
			ID: req.ID,
			OK: true,
			Result: map[string]any{
				"session":    session,
				"session_id": getSessionID(),
				"created":    false,
			},
		}
	}

	// Session does not exist — create it. Only allow safe names for new sessions
	// so they can be referenced unambiguously in future tmux targets.
	if !isValidNewTmuxName(session) {
		return errResponse(req.ID, "invalid_params", fmt.Sprintf("invalid tmux session name: %q (new sessions must use letters, digits, _ and - only)", session))
	}

	// Create detached session. Use -x 220 -y 50 as initial size; will be
	// resized when the first pane attaches.
	if out, err := tmuxCombinedOutput("new-session", "-d", "-s", session, "-x", "220", "-y", "50"); err != nil {
		return errResponse(req.ID, "tmux_error",
			fmt.Sprintf("failed to create tmux session: %v: %s", err, strings.TrimSpace(string(out))))
	}

	return rpcResponse{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"session":    session,
			"session_id": getSessionID(),
			"created":    true,
		},
	}
}

func (s *rpcServer) handleTmuxPaneNew(req rpcRequest) rpcResponse {
	session, ok := getStringParam(req.Params, "session")
	if !ok || session == "" {
		return errResponse(req.ID, "invalid_params", "tmux.pane.new requires session")
	}
	cwd, _ := getStringParam(req.Params, "cwd")

	// Use exact-match target (tmux ≥2.5) so that session names containing ":" or "."
	// are not mis-parsed as "session:window(.pane)" targets.
	exactTarget := tmuxExactTarget(session)
	args := []string{"new-window", "-t", exactTarget, "-P", "-F", "#{pane_id}"}
	if cwd != "" {
		args = append(args, "-c", cwd)
	}
	out, err := tmuxOutput(args...)
	if err != nil {
		return errResponse(req.ID, "tmux_error",
			fmt.Sprintf("tmux new-window failed: %v", err))
	}
	paneID := strings.TrimSpace(string(out))
	if paneID == "" {
		return errResponse(req.ID, "tmux_error", "tmux new-window returned empty pane_id")
	}

	return rpcResponse{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"pane_id": paneID,
		},
	}
}

func (s *rpcServer) handleTmuxPaneList(req rpcRequest) rpcResponse {
	session, ok := getStringParam(req.Params, "session")
	if !ok || session == "" {
		return errResponse(req.ID, "invalid_params", "tmux.pane.list requires session")
	}

	// Use exact-match target (tmux ≥2.5) so that session names containing ":" or "."
	// are not mis-parsed as "session:window(.pane)" targets.
	exactTarget := tmuxExactTarget(session)

	// List all panes across all windows in the session.
	// Format: pane_id TAB pane_current_path TAB pane_title TAB pane_current_command
	format := "#{pane_id}\t#{pane_current_path}\t#{pane_title}\t#{pane_current_command}"
	out, err := tmuxOutput("list-panes", "-s", "-t", exactTarget, "-F", format)
	if err != nil {
		// Session may not exist yet; return empty list rather than error.
		return rpcResponse{
			ID: req.ID,
			OK: true,
			Result: map[string]any{
				"panes": []any{},
			},
		}
	}

	var panes []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(string(out)), "\n") {
		if line == "" {
			continue
		}
		parts := strings.SplitN(line, "\t", 4)
		if len(parts) == 0 || parts[0] == "" {
			continue
		}
		pane := map[string]any{
			"pane_id": parts[0],
			"cwd":     "",
			"title":   "",
			"command": "",
		}
		if len(parts) > 1 {
			pane["cwd"] = parts[1]
		}
		if len(parts) > 2 {
			pane["title"] = parts[2]
		}
		if len(parts) > 3 {
			pane["command"] = parts[3]
		}
		panes = append(panes, pane)
	}
	if panes == nil {
		panes = []map[string]any{}
	}

	return rpcResponse{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"panes": panes,
		},
	}
}

func (s *rpcServer) handleTmuxPaneExists(req rpcRequest) rpcResponse {
	paneID, ok := getStringParam(req.Params, "pane_id")
	if !ok || paneID == "" {
		return errResponse(req.ID, "invalid_params", "tmux.pane.exists requires pane_id")
	}
	err := tmuxRun("display-message", "-t", paneID, "-p", "")
	return rpcResponse{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"exists": err == nil,
		},
	}
}

// handleTmuxControlSubscribe starts tmux control mode for the given session and
// streams control-mode lines back to the client as push events named
// "tmux.control.line". Each event carries the raw line base64-encoded.
//
// If a subscription for the same session already exists, the existing stream ID
// is returned. If a subscription for a different session exists, it is stopped
// and a new one is started.
// --- helpers ---

func errResponse(id any, code, message string) rpcResponse {
	return rpcResponse{
		ID: id,
		OK: false,
		Error: &rpcError{
			Code:    code,
			Message: message,
		},
	}
}
