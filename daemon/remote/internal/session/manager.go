package session

import (
	"errors"
	"fmt"
	"sort"
	"sync"
	"time"
)

var (
	ErrSessionNotFound    = errors.New("session not found")
	ErrSessionExists      = errors.New("session already exists")
	ErrAttachmentNotFound = errors.New("attachment not found")
	ErrInvalidSize        = errors.New("cols and rows must be greater than zero")
)

type AttachmentStatus struct {
	AttachmentID string
	Cols         int
	Rows         int
	UpdatedAt    time.Time
}

type SessionStatus struct {
	SessionID     string
	Attachments   []AttachmentStatus
	EffectiveCols int
	EffectiveRows int
	LastKnownCols int
	LastKnownRows int
}

type attachmentState struct {
	cols      int
	rows      int
	updatedAt time.Time
}

type sessionState struct {
	attachments   map[string]attachmentState
	effectiveCols int
	effectiveRows int
	lastKnownCols int
	lastKnownRows int
}

type Manager struct {
	mu               sync.Mutex
	nextSessionID    uint64
	nextAttachmentID uint64
	sessions         map[string]*sessionState
}

func NewManager() *Manager {
	return &Manager{
		nextSessionID:    1,
		nextAttachmentID: 1,
		sessions:         map[string]*sessionState{},
	}
}

func (m *Manager) Open(sessionID string, cols, rows int) (resolvedSessionID, attachmentID string, err error) {
	cols, rows = normalizeSize(cols, rows)
	m.mu.Lock()
	defer m.mu.Unlock()

	resolvedSessionID, state, err := m.openLocked(sessionID)
	if err != nil {
		return "", "", err
	}
	attachmentID = m.nextAttachmentIDLocked()
	state.attachments[attachmentID] = attachmentState{
		cols:      cols,
		rows:      rows,
		updatedAt: time.Now().UTC(),
	}
	recomputeSessionSize(state)

	return resolvedSessionID, attachmentID, nil
}

func (m *Manager) Ensure(sessionID string) SessionStatus {
	m.mu.Lock()
	defer m.mu.Unlock()

	sessionID, state := m.ensureLocked(sessionID)
	return snapshotLocked(sessionID, state)
}

func (m *Manager) Close(sessionID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	if _, ok := m.sessions[sessionID]; !ok {
		return ErrSessionNotFound
	}
	delete(m.sessions, sessionID)
	return nil
}

func (m *Manager) Attach(sessionID, attachmentID string, cols, rows int) error {
	if cols <= 0 || rows <= 0 {
		return ErrInvalidSize
	}
	cols, rows = normalizeSize(cols, rows)

	m.mu.Lock()
	defer m.mu.Unlock()

	state, ok := m.sessions[sessionID]
	if !ok {
		return ErrSessionNotFound
	}

	state.attachments[attachmentID] = attachmentState{
		cols:      cols,
		rows:      rows,
		updatedAt: time.Now().UTC(),
	}
	recomputeSessionSize(state)
	return nil
}

func (m *Manager) Resize(sessionID, attachmentID string, cols, rows int) error {
	if cols <= 0 || rows <= 0 {
		return ErrInvalidSize
	}
	cols, rows = normalizeSize(cols, rows)

	m.mu.Lock()
	defer m.mu.Unlock()

	state, ok := m.sessions[sessionID]
	if !ok {
		return ErrSessionNotFound
	}
	if _, ok := state.attachments[attachmentID]; !ok {
		return ErrAttachmentNotFound
	}

	state.attachments[attachmentID] = attachmentState{
		cols:      cols,
		rows:      rows,
		updatedAt: time.Now().UTC(),
	}
	recomputeSessionSize(state)
	return nil
}

func (m *Manager) Detach(sessionID, attachmentID string) error {
	m.mu.Lock()
	defer m.mu.Unlock()

	state, ok := m.sessions[sessionID]
	if !ok {
		return ErrSessionNotFound
	}
	if _, ok := state.attachments[attachmentID]; !ok {
		return ErrAttachmentNotFound
	}

	delete(state.attachments, attachmentID)
	recomputeSessionSize(state)
	return nil
}

func (m *Manager) Status(sessionID string) (SessionStatus, error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	state, ok := m.sessions[sessionID]
	if !ok {
		return SessionStatus{}, ErrSessionNotFound
	}

	return snapshotLocked(sessionID, state), nil
}

func (m *Manager) List() []SessionStatus {
	m.mu.Lock()
	defer m.mu.Unlock()

	sessionIDs := make([]string, 0, len(m.sessions))
	for sessionID := range m.sessions {
		sessionIDs = append(sessionIDs, sessionID)
	}
	sort.Strings(sessionIDs)

	out := make([]SessionStatus, 0, len(sessionIDs))
	for _, sessionID := range sessionIDs {
		out = append(out, snapshotLocked(sessionID, m.sessions[sessionID]))
	}
	return out
}

func (m *Manager) ensureLocked(sessionID string) (string, *sessionState) {
	if sessionID == "" {
		for {
			sessionID = fmt.Sprintf("sess-%d", m.nextSessionID)
			m.nextSessionID++
			if _, exists := m.sessions[sessionID]; !exists {
				break
			}
		}
	}

	state, ok := m.sessions[sessionID]
	if !ok {
		state = &sessionState{
			attachments: map[string]attachmentState{},
		}
		m.sessions[sessionID] = state
	}

	return sessionID, state
}

func (m *Manager) openLocked(sessionID string) (string, *sessionState, error) {
	if sessionID == "" {
		resolvedSessionID, state := m.ensureLocked("")
		return resolvedSessionID, state, nil
	}
	if _, exists := m.sessions[sessionID]; exists {
		return "", nil, ErrSessionExists
	}
	state := &sessionState{
		attachments: map[string]attachmentState{},
	}
	m.sessions[sessionID] = state
	return sessionID, state, nil
}

func (m *Manager) nextAttachmentIDLocked() string {
	attachmentID := fmt.Sprintf("att-%d", m.nextAttachmentID)
	m.nextAttachmentID++
	return attachmentID
}

func recomputeSessionSize(state *sessionState) {
	if len(state.attachments) == 0 {
		state.effectiveCols = state.lastKnownCols
		state.effectiveRows = state.lastKnownRows
		return
	}

	minCols := 0
	minRows := 0
	for _, attachment := range state.attachments {
		if minCols == 0 || attachment.cols < minCols {
			minCols = attachment.cols
		}
		if minRows == 0 || attachment.rows < minRows {
			minRows = attachment.rows
		}
	}

	state.effectiveCols = minCols
	state.effectiveRows = minRows
	state.lastKnownCols = minCols
	state.lastKnownRows = minRows
}

func normalizeSize(cols, rows int) (int, int) {
	if cols > 0 && cols < 2 {
		cols = 2
	}
	if rows > 0 && rows < 1 {
		rows = 1
	}
	return cols, rows
}

func snapshotLocked(sessionID string, state *sessionState) SessionStatus {
	attachmentIDs := make([]string, 0, len(state.attachments))
	for attachmentID := range state.attachments {
		attachmentIDs = append(attachmentIDs, attachmentID)
	}
	sort.Strings(attachmentIDs)

	attachments := make([]AttachmentStatus, 0, len(attachmentIDs))
	for _, attachmentID := range attachmentIDs {
		attachment := state.attachments[attachmentID]
		attachments = append(attachments, AttachmentStatus{
			AttachmentID: attachmentID,
			Cols:         attachment.cols,
			Rows:         attachment.rows,
			UpdatedAt:    attachment.updatedAt,
		})
	}

	return SessionStatus{
		SessionID:     sessionID,
		Attachments:   attachments,
		EffectiveCols: state.effectiveCols,
		EffectiveRows: state.effectiveRows,
		LastKnownCols: state.lastKnownCols,
		LastKnownRows: state.lastKnownRows,
	}
}
