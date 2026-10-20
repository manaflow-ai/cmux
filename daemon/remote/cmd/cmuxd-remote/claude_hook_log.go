package main

import (
	"fmt"
	"os"
	"path/filepath"
	"time"
)

// A hook always prints `{}` and exits 0, so Claude never shows why an event
// went nowhere. The reason goes to ~/.cmux/claude-hook.log instead, which
// keeps one previous generation.
const claudeHookLogMaxBytes = 256 * 1024

func claudeHookLogPath() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	return filepath.Join(home, ".cmux", "claude-hook.log")
}

// logClaudeHookDrop appends one line explaining why a hook event was dropped.
// Failures to log are ignored: the hook must still return promptly.
func logClaudeHookDrop(format string, args ...any) {
	path := claudeHookLogPath()
	if path == "" {
		return
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return
	}
	if info, err := os.Stat(path); err == nil && info.Size() >= claudeHookLogMaxBytes {
		_ = os.Rename(path, path+".1")
	}
	file, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return
	}
	defer file.Close()
	fmt.Fprintf(file, "%s pid=%d %s\n", time.Now().UTC().Format(time.RFC3339), os.Getpid(), fmt.Sprintf(format, args...))
}
