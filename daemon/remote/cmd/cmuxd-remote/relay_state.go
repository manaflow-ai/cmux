package main

import (
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

type relayLogger struct {
	mu     sync.Mutex
	writer io.WriteCloser
}

func newRelayLogger(path string) (*relayLogger, error) {
	trimmed := strings.TrimSpace(path)
	if trimmed == "" {
		return &relayLogger{}, nil
	}

	if err := os.MkdirAll(filepath.Dir(trimmed), 0o700); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(trimmed, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}
	return &relayLogger{writer: file}, nil
}

func (l *relayLogger) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.writer == nil {
		return nil
	}
	err := l.writer.Close()
	l.writer = nil
	return err
}

func (l *relayLogger) Log(level string, event string, fields map[string]any) {
	if l == nil {
		return
	}

	l.mu.Lock()
	defer l.mu.Unlock()
	if l.writer == nil {
		return
	}

	keys := make([]string, 0, len(fields))
	for key := range fields {
		keys = append(keys, key)
	}
	sort.Strings(keys)

	var builder strings.Builder
	builder.Grow(128)
	builder.WriteString(time.Now().UTC().Format(time.RFC3339Nano))
	builder.WriteByte(' ')
	builder.WriteString(strings.ToLower(strings.TrimSpace(level)))
	builder.WriteByte(' ')
	builder.WriteString(strings.TrimSpace(event))
	for _, key := range keys {
		builder.WriteByte(' ')
		builder.WriteString(key)
		builder.WriteByte('=')
		builder.WriteString(formatRelayLogValue(fields[key]))
	}
	builder.WriteByte('\n')
	_, _ = io.WriteString(l.writer, builder.String())
}

func formatRelayLogValue(value any) string {
	switch typed := value.(type) {
	case nil:
		return "null"
	case string:
		return quoteRelayLogString(typed)
	case error:
		return quoteRelayLogString(typed.Error())
	case fmt.Stringer:
		return quoteRelayLogString(typed.String())
	case bool:
		if typed {
			return "true"
		}
		return "false"
	case int:
		return strconv.Itoa(typed)
	case int8:
		return strconv.FormatInt(int64(typed), 10)
	case int16:
		return strconv.FormatInt(int64(typed), 10)
	case int32:
		return strconv.FormatInt(int64(typed), 10)
	case int64:
		return strconv.FormatInt(typed, 10)
	case uint:
		return strconv.FormatUint(uint64(typed), 10)
	case uint8:
		return strconv.FormatUint(uint64(typed), 10)
	case uint16:
		return strconv.FormatUint(uint64(typed), 10)
	case uint32:
		return strconv.FormatUint(uint64(typed), 10)
	case uint64:
		return strconv.FormatUint(typed, 10)
	case time.Duration:
		return quoteRelayLogString(typed.String())
	default:
		return quoteRelayLogString(fmt.Sprint(typed))
	}
}

func quoteRelayLogString(value string) string {
	if value == "" {
		return `""`
	}
	for _, r := range value {
		if !(r >= 'a' && r <= 'z') &&
			!(r >= 'A' && r <= 'Z') &&
			!(r >= '0' && r <= '9') &&
			!strings.ContainsRune("._:/-@", r) {
			return strconv.Quote(value)
		}
	}
	return value
}

type relaySessionState struct {
	sessionID string
	dir       string
	lockFile  *os.File
	logger    *relayLogger
}

type relayCleanupSummary struct {
	removedSessionDirs   int
	removedPortArtifacts int
}

func beginRelaySession(sessionID string, logger *relayLogger) (*relaySessionState, error) {
	trimmed, err := sanitizeRelaySessionID(sessionID)
	if err != nil {
		return nil, err
	}
	if trimmed == "" {
		return nil, nil
	}

	rootDir, err := relayRootDir()
	if err != nil {
		return nil, err
	}
	dir := filepath.Join(rootDir, trimmed)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, err
	}

	lockPath := filepath.Join(dir, ".lock")
	lockFile, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(lockFile.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = lockFile.Close()
		return nil, fmt.Errorf("failed to lock relay session %s: %w", trimmed, err)
	}

	pidPath := filepath.Join(dir, "pid")
	pidText := strconv.Itoa(os.Getpid())
	if err := os.WriteFile(pidPath, []byte(pidText), 0o600); err != nil {
		_ = syscall.Flock(int(lockFile.Fd()), syscall.LOCK_UN)
		_ = lockFile.Close()
		return nil, err
	}

	return &relaySessionState{
		sessionID: trimmed,
		dir:       dir,
		lockFile:  lockFile,
		logger:    logger,
	}, nil
}

func (s *relaySessionState) Close() {
	if s == nil {
		return
	}
	_ = os.Remove(filepath.Join(s.dir, "pid"))
	if s.lockFile != nil {
		_ = syscall.Flock(int(s.lockFile.Fd()), syscall.LOCK_UN)
		_ = s.lockFile.Close()
		s.lockFile = nil
	}
	_ = os.Remove(filepath.Join(s.dir, ".lock"))
	removeRelayDirIfEmpty(s.dir)
}

func sanitizeRelaySessionID(sessionID string) (string, error) {
	trimmed := strings.TrimSpace(sessionID)
	if trimmed == "" {
		return "", nil
	}
	if trimmed == "." || trimmed == ".." {
		return "", fmt.Errorf("invalid relay session id %q", trimmed)
	}
	for _, r := range trimmed {
		if (r >= 'a' && r <= 'z') ||
			(r >= 'A' && r <= 'Z') ||
			(r >= '0' && r <= '9') ||
			r == '.' ||
			r == '_' ||
			r == '-' {
			continue
		}
		return "", fmt.Errorf("invalid relay session id %q", trimmed)
	}
	return trimmed, nil
}

func removeRelayDirIfEmpty(dir string) {
	entries, err := os.ReadDir(dir)
	if err != nil || len(entries) != 0 {
		return
	}
	_ = os.Remove(dir)
}

func sweepRelayState(logger *relayLogger) (relayCleanupSummary, error) {
	var summary relayCleanupSummary
	rootDir, err := relayRootDir()
	if err != nil {
		return summary, err
	}

	entries, err := os.ReadDir(rootDir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return summary, nil
		}
		return summary, err
	}

	portArtifacts := map[int][]string{}
	for _, entry := range entries {
		name := entry.Name()
		fullPath := filepath.Join(rootDir, name)
		if sessionID, ok := relaySessionIDFromEntry(entry, fullPath); ok {
			removed, pid, cleanupErr := cleanupDeadRelaySessionDir(sessionID, fullPath)
			if cleanupErr != nil {
				logger.Log("error", "relay.cleanup.error", map[string]any{
					"error":      cleanupErr,
					"path":       fullPath,
					"session_id": sessionID,
				})
				continue
			}
			if removed {
				summary.removedSessionDirs += 1
				logger.Log("info", "relay.cleanup.removed", map[string]any{
					"path":       fullPath,
					"pid":        pid,
					"reason":     "dead_pid",
					"session_id": sessionID,
				})
			}
			continue
		}

		if port, ok := relayArtifactPort(name); ok {
			portArtifacts[port] = append(portArtifacts[port], fullPath)
		}
	}

	for port, paths := range portArtifacts {
		if isLoopbackPortReachable(port) {
			continue
		}
		sort.Strings(paths)
		for _, path := range paths {
			if err := os.RemoveAll(path); err != nil && !errors.Is(err, os.ErrNotExist) {
				logger.Log("error", "relay.cleanup.error", map[string]any{
					"error":  err,
					"path":   path,
					"port":   port,
					"reason": "stale_port_metadata",
				})
				continue
			}
			summary.removedPortArtifacts += 1
			logger.Log("info", "relay.cleanup.removed", map[string]any{
				"path":   path,
				"port":   port,
				"reason": "stale_port_metadata",
			})
		}
	}

	return summary, nil
}

func relayRootDir() (string, error) {
	homeDir, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(homeDir, ".cmux", "relay"), nil
}

func relaySessionIDFromEntry(entry os.DirEntry, fullPath string) (string, bool) {
	if !entry.IsDir() {
		return "", false
	}
	if _, ok := relayArtifactPort(entry.Name()); ok {
		return "", false
	}
	if _, err := os.Stat(filepath.Join(fullPath, "pid")); err != nil {
		return "", false
	}
	return entry.Name(), true
}

func cleanupDeadRelaySessionDir(sessionID string, dir string) (removed bool, pid int, err error) {
	pidPath := filepath.Join(dir, "pid")
	data, err := os.ReadFile(pidPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return false, 0, nil
		}
		return false, 0, err
	}
	trimmed := strings.TrimSpace(string(data))
	if trimmed == "" {
		if removeErr := os.RemoveAll(dir); removeErr != nil && !errors.Is(removeErr, os.ErrNotExist) {
			return false, 0, removeErr
		}
		return true, 0, nil
	}
	parsedPID, parseErr := strconv.Atoi(trimmed)
	if parseErr != nil || parsedPID <= 0 {
		if removeErr := os.RemoveAll(dir); removeErr != nil && !errors.Is(removeErr, os.ErrNotExist) {
			return false, 0, removeErr
		}
		return true, 0, nil
	}
	if pidIsAlive(parsedPID) {
		return false, parsedPID, nil
	}
	lockFile, locked, err := tryLockRelaySessionDir(dir)
	if err != nil {
		return false, parsedPID, err
	}
	if !locked {
		return false, parsedPID, nil
	}
	defer func() {
		_ = syscall.Flock(int(lockFile.Fd()), syscall.LOCK_UN)
		_ = lockFile.Close()
	}()
	if err := os.RemoveAll(dir); err != nil && !errors.Is(err, os.ErrNotExist) {
		return false, parsedPID, err
	}
	return true, parsedPID, nil
}

func tryLockRelaySessionDir(dir string) (*os.File, bool, error) {
	lockPath := filepath.Join(dir, ".lock")
	lockFile, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, false, nil
		}
		return nil, false, err
	}
	if err := syscall.Flock(int(lockFile.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		_ = lockFile.Close()
		if errors.Is(err, syscall.EWOULDBLOCK) || errors.Is(err, syscall.EAGAIN) {
			return nil, false, nil
		}
		return nil, false, err
	}
	return lockFile, true, nil
}

func pidIsAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}

func relayArtifactPort(name string) (int, bool) {
	trimmed := strings.TrimSpace(name)
	suffixes := []string{
		".auth",
		".daemon_path",
		".tty",
		".shell",
		".bootstrap.sh",
	}
	for _, suffix := range suffixes {
		if !strings.HasSuffix(trimmed, suffix) {
			continue
		}
		prefix := strings.TrimSuffix(trimmed, suffix)
		port, err := strconv.Atoi(prefix)
		if err == nil && port > 0 && port <= 65535 {
			return port, true
		}
	}
	return 0, false
}

func isLoopbackPortReachable(port int) bool {
	if port <= 0 || port > 65535 {
		return false
	}
	conn, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), 500*time.Millisecond)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}
