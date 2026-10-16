package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

const (
	persistentDaemonLogMaxBytes = int64(2 * 1024 * 1024)
	persistentDaemonLogBackups  = 2
)

type persistentDaemonLog struct {
	mu       sync.Mutex
	path     string
	maxBytes int64
	backups  int
	file     *os.File
	size     int64
}

func openPersistentDaemonLog(path string) (*persistentDaemonLog, error) {
	return openPersistentDaemonLogWithLimit(
		path,
		persistentDaemonLogMaxBytes,
		persistentDaemonLogBackups,
	)
}

func openPersistentDaemonLogWithLimit(path string, maxBytes int64, backups int) (*persistentDaemonLog, error) {
	if maxBytes <= 0 {
		return nil, errors.New("persistent daemon log size limit must be positive")
	}
	if backups < 0 {
		return nil, errors.New("persistent daemon log backup count must not be negative")
	}
	logFile := &persistentDaemonLog{
		path:     path,
		maxBytes: maxBytes,
		backups:  backups,
	}
	if err := logFile.openLocked(); err != nil {
		return nil, err
	}
	return logFile, nil
}

func (l *persistentDaemonLog) Write(payload []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()

	if l.file == nil {
		return 0, os.ErrClosed
	}
	if len(payload) == 0 {
		return 0, nil
	}
	originalLength := len(payload)
	if int64(len(payload)) > l.maxBytes {
		payload = payload[len(payload)-int(l.maxBytes):]
	}
	if l.size > 0 && l.size+int64(len(payload)) > l.maxBytes {
		if err := l.rotateLocked(); err != nil {
			return 0, err
		}
	}
	written, err := l.file.Write(payload)
	l.size += int64(written)
	if err != nil {
		return written, err
	}
	if written != len(payload) {
		return written, io.ErrShortWrite
	}
	return originalLength, nil
}

func (l *persistentDaemonLog) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()
	if l.file == nil {
		return nil
	}
	err := l.file.Close()
	l.file = nil
	return err
}

func (l *persistentDaemonLog) openLocked() error {
	file, err := os.OpenFile(l.path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	if err := file.Chmod(0o600); err != nil {
		_ = file.Close()
		return err
	}
	info, err := file.Stat()
	if err != nil {
		_ = file.Close()
		return err
	}
	l.file = file
	l.size = info.Size()
	return nil
}

func (l *persistentDaemonLog) rotateLocked() error {
	if err := l.file.Close(); err != nil {
		return err
	}
	l.file = nil

	if l.backups == 0 {
		if err := os.Remove(l.path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
	} else {
		oldest := persistentDaemonLogBackupPath(l.path, l.backups)
		if err := os.Remove(oldest); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		for index := l.backups - 1; index >= 1; index-- {
			from := persistentDaemonLogBackupPath(l.path, index)
			to := persistentDaemonLogBackupPath(l.path, index+1)
			if err := os.Rename(from, to); err != nil && !errors.Is(err, os.ErrNotExist) {
				return err
			}
		}
		if err := os.Rename(l.path, persistentDaemonLogBackupPath(l.path, 1)); err != nil &&
			!errors.Is(err, os.ErrNotExist) {
			return err
		}
	}
	return l.openLocked()
}

func persistentDaemonLogBackupPath(path string, index int) string {
	return path + "." + strconv.Itoa(index)
}

func logPersistentDaemonEvent(writer io.Writer, event string, fields ...string) {
	if writer == nil {
		return
	}
	var line strings.Builder
	line.WriteString("time=")
	line.WriteString(time.Now().UTC().Format(time.RFC3339Nano))
	line.WriteString(" event=")
	line.WriteString(event)
	for index := 0; index+1 < len(fields); index += 2 {
		line.WriteByte(' ')
		line.WriteString(fields[index])
		line.WriteByte('=')
		line.WriteString(strconv.Quote(fields[index+1]))
	}
	line.WriteByte('\n')
	_, _ = fmt.Fprint(writer, line.String())
}

func persistentDaemonErrorCategory(err error) string {
	if err == nil {
		return "none"
	}
	if errors.Is(err, context.Canceled) {
		return "canceled"
	}
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, os.ErrDeadlineExceeded) {
		return "timeout"
	}
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		return "timeout"
	}
	if errors.Is(err, io.EOF) {
		return "eof"
	}
	if errors.Is(err, net.ErrClosed) ||
		errors.Is(err, os.ErrClosed) ||
		errors.Is(err, io.ErrClosedPipe) ||
		errors.Is(err, syscall.EPIPE) {
		return "connection_closed"
	}
	if errors.Is(err, syscall.ECONNRESET) {
		return "connection_reset"
	}
	if errors.Is(err, syscall.ECONNREFUSED) {
		return "connection_refused"
	}
	if errors.Is(err, os.ErrNotExist) || errors.Is(err, syscall.ENOENT) {
		return "not_found"
	}
	if errors.Is(err, os.ErrPermission) ||
		errors.Is(err, syscall.EACCES) ||
		errors.Is(err, syscall.EPERM) {
		return "permission_denied"
	}
	if errors.Is(err, syscall.ENOSPC) ||
		errors.Is(err, syscall.EMFILE) ||
		errors.Is(err, syscall.ENFILE) ||
		errors.Is(err, syscall.ENOMEM) {
		return "resource_exhausted"
	}
	if errors.Is(err, syscall.EIO) {
		return "io_error"
	}
	return "unexpected"
}

func persistentDaemonDiagnosticCode(value string) string {
	value = strings.TrimSpace(value)
	if value == "" || len(value) > 64 {
		return "unknown"
	}
	for _, character := range value {
		if (character >= 'a' && character <= 'z') ||
			(character >= '0' && character <= '9') ||
			character == '_' || character == '-' || character == '.' {
			continue
		}
		return "unknown"
	}
	return value
}
