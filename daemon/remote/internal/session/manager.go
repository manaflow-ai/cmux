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
	cols       int
	rows       int
	updatedAt  time.Time
	updatedSeq uint64
}

type sessionState struct {
	attachments             map[string]attachmentState
	effectiveCols           int
	effectiveRows           int
	lastKnownCols           int
	lastKnownRows           int
	nextAttachmentUpdateSeq uint64
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

func (m *Manager) Open(cols, rows int) (sessionID, attachmentID string) {
	m.mu.Lock()
	defer m.mu.Unlock()

	sessionID, state := m.ensureLocked("")
	attachmentID = m.nextAttachmentIDLocked()
	state.attachments[attachmentID] = attachmentState{
		cols:       cols,
		rows:       rows,
		updatedAt:  time.Now().UTC(),
		updatedSeq: nextAttachmentUpdateSeq(state),
	}
	recomputeSessionSize(state)

	return sessionID, attachmentID
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

	m.mu.Lock()
	defer m.mu.Unlock()

	state, ok := m.sessions[sessionID]
	if !ok {
		return ErrSessionNotFound
	}

	state.attachments[attachmentID] = attachmentState{
		cols:       cols,
		rows:       rows,
		updatedAt:  time.Now().UTC(),
		updatedSeq: nextAttachmentUpdateSeq(state),
	}
	recomputeSessionSize(state)
	return nil
}

func (m *Manager) Resize(sessionID, attachmentID string, cols, rows int) error {
	if cols <= 0 || rows <= 0 {
		return ErrInvalidSize
	}

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
		cols:       cols,
		rows:       rows,
		updatedAt:  time.Now().UTC(),
		updatedSeq: nextAttachmentUpdateSeq(state),
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

func (m *Manager) ensureLocked(sessionID string) (string, *sessionState) {
	if sessionID == "" {
		sessionID = fmt.Sprintf("sess-%d", m.nextSessionID)
		m.nextSessionID++
	}

	state, ok := m.sessions[sessionID]
	if !ok {
		state = &sessionState{
			attachments:             map[string]attachmentState{},
			nextAttachmentUpdateSeq: 1,
		}
		m.sessions[sessionID] = state
	}

	return sessionID, state
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
		if attachment.cols <= 0 || attachment.rows <= 0 {
			continue
		}
		if minCols == 0 || attachment.cols < minCols {
			minCols = attachment.cols
		}
		if minRows == 0 || attachment.rows < minRows {
			minRows = attachment.rows
		}
	}
	if minCols == 0 {
		minCols = state.lastKnownCols
	}
	if minRows == 0 {
		minRows = state.lastKnownRows
	}

	state.effectiveCols = minCols
	state.effectiveRows = minRows
	state.lastKnownCols = minCols
	state.lastKnownRows = minRows
}

func nextAttachmentUpdateSeq(state *sessionState) uint64 {
	seq := state.nextAttachmentUpdateSeq
	state.nextAttachmentUpdateSeq++
	return seq
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
