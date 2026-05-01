package terminal

import (
	"errors"
	"io"
	"os"
	"os/exec"
	"sync"
	"time"

	"github.com/creack/pty"
)

var (
	ErrSessionNotFound = errors.New("terminal session not found")
	ErrSessionExists   = errors.New("terminal session already exists")
	ErrReadTimeout     = errors.New("terminal read timed out")
	ErrInvalidCommand  = errors.New("terminal command is required")
)

const maxBufferedBytes = 1 << 20

type ReadResult struct {
	Data       []byte
	Offset     uint64
	BaseOffset uint64
	Truncated  bool
	EOF        bool
}

type Manager struct {
	mu       sync.Mutex
	sessions map[string]*sessionState
}

type sessionState struct {
	cmd *exec.Cmd
	pty *os.File

	mu         sync.Mutex
	notify     chan struct{}
	baseOffset uint64
	nextOffset uint64
	buffer     []byte
	closed     bool
}

func NewManager() *Manager {
	return &Manager{
		sessions: map[string]*sessionState{},
	}
}

func (m *Manager) Open(sessionID string, command string, cols, rows int) error {
	if command == "" {
		return ErrInvalidCommand
	}

	m.mu.Lock()
	if _, exists := m.sessions[sessionID]; exists {
		m.mu.Unlock()
		return ErrSessionExists
	}
	state := &sessionState{
		notify: make(chan struct{}),
	}
	m.sessions[sessionID] = state
	m.mu.Unlock()

	cmd := exec.Command("/bin/sh", "-lc", command)
	file, err := pty.StartWithSize(cmd, &pty.Winsize{
		Cols: uint16(max(1, cols)),
		Rows: uint16(max(1, rows)),
	})
	if err != nil {
		m.mu.Lock()
		delete(m.sessions, sessionID)
		m.mu.Unlock()
		return err
	}

	state.cmd = cmd
	state.pty = file

	go state.captureOutput()
	return nil
}

func (m *Manager) Write(sessionID string, data []byte) error {
	state, err := m.session(sessionID)
	if err != nil {
		return err
	}
	if len(data) == 0 {
		return nil
	}
	_, err = state.pty.Write(data)
	return err
}

func (m *Manager) Read(sessionID string, offset uint64, maxBytes int, timeout time.Duration) (ReadResult, error) {
	state, err := m.session(sessionID)
	if err != nil {
		return ReadResult{}, err
	}
	return state.read(offset, maxBytes, timeout)
}

func (m *Manager) Resize(sessionID string, cols, rows int) error {
	state, err := m.session(sessionID)
	if err != nil {
		return err
	}
	return pty.Setsize(state.pty, &pty.Winsize{
		Cols: uint16(max(1, cols)),
		Rows: uint16(max(1, rows)),
	})
}

func (m *Manager) Close(sessionID string) error {
	m.mu.Lock()
	state, ok := m.sessions[sessionID]
	if ok {
		delete(m.sessions, sessionID)
	}
	m.mu.Unlock()
	if !ok {
		return ErrSessionNotFound
	}
	return state.close()
}

func (m *Manager) CloseAll() {
	m.mu.Lock()
	sessions := make([]*sessionState, 0, len(m.sessions))
	for sessionID, state := range m.sessions {
		delete(m.sessions, sessionID)
		sessions = append(sessions, state)
	}
	m.mu.Unlock()

	for _, state := range sessions {
		_ = state.close()
	}
}

func (m *Manager) session(sessionID string) (*sessionState, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	state, ok := m.sessions[sessionID]
	if !ok {
		return nil, ErrSessionNotFound
	}
	return state, nil
}

func (s *sessionState) captureOutput() {
	buf := make([]byte, 32*1024)
	for {
		n, err := s.pty.Read(buf)
		if n > 0 {
			s.appendOutput(buf[:n])
		}
		if err != nil {
			s.markClosed()
			return
		}
	}
}

func (s *sessionState) appendOutput(data []byte) {
	if len(data) == 0 {
		return
	}

	s.mu.Lock()
	s.buffer = append(s.buffer, data...)
	s.nextOffset += uint64(len(data))
	if overflow := len(s.buffer) - maxBufferedBytes; overflow > 0 {
		s.buffer = append([]byte(nil), s.buffer[overflow:]...)
		s.baseOffset += uint64(overflow)
	}
	notify := s.notify
	s.notify = make(chan struct{})
	s.mu.Unlock()

	close(notify)
}

func (s *sessionState) markClosed() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	notify := s.notify
	s.notify = make(chan struct{})
	s.mu.Unlock()

	close(notify)
}

func (s *sessionState) read(offset uint64, maxBytes int, timeout time.Duration) (ReadResult, error) {
	deadline := time.Now().Add(timeout)

	for {
		s.mu.Lock()

		truncated := offset < s.baseOffset
		effectiveOffset := offset
		if effectiveOffset < s.baseOffset {
			effectiveOffset = s.baseOffset
		}

		if effectiveOffset < s.nextOffset {
			start := int(effectiveOffset - s.baseOffset)
			end := len(s.buffer)
			if maxBytes > 0 && end-start > maxBytes {
				end = start + maxBytes
			}
			result := ReadResult{
				Data:       append([]byte(nil), s.buffer[start:end]...),
				Offset:     effectiveOffset + uint64(end-start),
				BaseOffset: s.baseOffset,
				Truncated:  truncated,
				EOF:        s.closed && end == len(s.buffer),
			}
			s.mu.Unlock()
			return result, nil
		}

		if s.closed {
			result := ReadResult{
				Offset:     s.nextOffset,
				BaseOffset: s.baseOffset,
				Truncated:  truncated,
				EOF:        true,
			}
			s.mu.Unlock()
			return result, nil
		}

		notify := s.notify
		s.mu.Unlock()

		if timeout <= 0 {
			<-notify
			continue
		}

		remaining := time.Until(deadline)
		if remaining <= 0 {
			return ReadResult{}, ErrReadTimeout
		}

		timer := time.NewTimer(remaining)
		select {
		case <-notify:
			timer.Stop()
		case <-timer.C:
			return ReadResult{}, ErrReadTimeout
		}
	}
}

func (s *sessionState) close() error {
	s.markClosed()

	if s.pty != nil {
		_ = s.pty.Close()
	}
	if s.cmd != nil && s.cmd.Process != nil {
		_ = s.cmd.Process.Kill()
	}
	if s.cmd != nil {
		waitErr := s.cmd.Wait()
		var exitErr *exec.ExitError
		if waitErr != nil &&
			!errors.Is(waitErr, os.ErrProcessDone) &&
			!errors.Is(waitErr, io.EOF) &&
			!errors.As(waitErr, &exitErr) {
			return waitErr
		}
	}
	return nil
}
