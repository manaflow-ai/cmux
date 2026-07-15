package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (
	runtimeStateProtocolVersion = 1
	maxRuntimeStateBytes        = 3 * 1024 * 1024
)

var errRuntimeStateRevisionConflict = errors.New("runtime state revision conflict")

type runtimeStateDocument struct {
	ProtocolVersion int             `json:"protocol_version"`
	SchemaVersion   int             `json:"schema_version"`
	Revision        uint64          `json:"revision"`
	UpdatedAtUnixMS int64           `json:"updated_at_unix_ms"`
	State           json.RawMessage `json:"state"`
}

type runtimeStateSnapshot struct {
	Present         bool             `json:"present"`
	ProtocolVersion int              `json:"protocol_version"`
	SchemaVersion   int              `json:"schema_version,omitempty"`
	Revision        uint64           `json:"revision"`
	UpdatedAtUnixMS int64            `json:"updated_at_unix_ms,omitempty"`
	State           *json.RawMessage `json:"state,omitempty"`
	PTYSessions     []map[string]any `json:"pty_sessions"`
}

type runtimeStateSubscriberCallback func(runtimeStateDocument)

type runtimeStateSubscriber struct {
	updates  chan runtimeStateDocument
	done     chan struct{}
	stopOnce sync.Once
	callback runtimeStateSubscriberCallback
}

func newRuntimeStateSubscriber(callback runtimeStateSubscriberCallback) *runtimeStateSubscriber {
	subscriber := &runtimeStateSubscriber{
		updates:  make(chan runtimeStateDocument, 1),
		done:     make(chan struct{}),
		callback: callback,
	}
	go subscriber.run()
	return subscriber
}

func (s *runtimeStateSubscriber) run() {
	for {
		select {
		case <-s.done:
			return
		default:
		}
		select {
		case <-s.done:
			return
		case document := <-s.updates:
			s.callback(document)
		}
	}
}

func (s *runtimeStateSubscriber) offer(document runtimeStateDocument) {
	select {
	case <-s.done:
		return
	default:
	}
	select {
	case s.updates <- document:
		return
	default:
	}
	select {
	case <-s.updates:
	default:
	}
	select {
	case <-s.done:
	case s.updates <- document:
	default:
	}
}

func (s *runtimeStateSubscriber) stop() {
	s.stopOnce.Do(func() { close(s.done) })
}

type runtimeStateStore struct {
	mu               sync.Mutex
	filePath         string
	document         *runtimeStateDocument
	nextSubscriberID uint64
	subscribers      map[uint64]*runtimeStateSubscriber
}

func newRuntimeStateStore(filePath string) (*runtimeStateStore, error) {
	store := &runtimeStateStore{
		filePath:    filePath,
		subscribers: map[uint64]*runtimeStateSubscriber{},
	}
	if filePath == "" {
		return store, nil
	}
	document, err := loadRuntimeStateDocument(filePath)
	if err != nil {
		return nil, err
	}
	store.document = document
	return store, nil
}

func (s *runtimeStateStore) snapshot() *runtimeStateDocument {
	s.mu.Lock()
	defer s.mu.Unlock()
	return cloneRuntimeStateDocument(s.document)
}

func (s *runtimeStateStore) put(
	schemaVersion int,
	state json.RawMessage,
	expectedRevision *uint64,
) (runtimeStateDocument, error) {
	if schemaVersion <= 0 {
		return runtimeStateDocument{}, errors.New("schema_version must be greater than zero")
	}
	state = bytes.TrimSpace(state)
	if len(state) == 0 || len(state) > maxRuntimeStateBytes || state[0] != '{' || !json.Valid(state) {
		return runtimeStateDocument{}, errors.New("state must be a valid JSON object within the size limit")
	}

	s.mu.Lock()
	currentRevision := uint64(0)
	if s.document != nil {
		currentRevision = s.document.Revision
	}
	if expectedRevision != nil && *expectedRevision != currentRevision {
		s.mu.Unlock()
		return runtimeStateDocument{}, errRuntimeStateRevisionConflict
	}
	document := runtimeStateDocument{
		ProtocolVersion: runtimeStateProtocolVersion,
		SchemaVersion:   schemaVersion,
		Revision:        currentRevision + 1,
		UpdatedAtUnixMS: time.Now().UnixMilli(),
		State:           append(json.RawMessage(nil), state...),
	}
	if s.filePath != "" {
		if err := persistRuntimeStateDocument(s.filePath, document); err != nil {
			s.mu.Unlock()
			return runtimeStateDocument{}, err
		}
	}
	s.document = cloneRuntimeStateDocument(&document)
	subscribers := make([]*runtimeStateSubscriber, 0, len(s.subscribers))
	for _, subscriber := range s.subscribers {
		subscribers = append(subscribers, subscriber)
	}
	s.mu.Unlock()

	for _, subscriber := range subscribers {
		subscriber.offer(document)
	}
	return document, nil
}

func (s *runtimeStateStore) subscribe(callback runtimeStateSubscriberCallback) (uint64, *runtimeStateDocument) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.nextSubscriberID++
	id := s.nextSubscriberID
	s.subscribers[id] = newRuntimeStateSubscriber(callback)
	return id, cloneRuntimeStateDocument(s.document)
}

func (s *runtimeStateStore) unsubscribe(id uint64) {
	if id == 0 {
		return
	}
	s.mu.Lock()
	subscriber := s.subscribers[id]
	delete(s.subscribers, id)
	s.mu.Unlock()
	if subscriber != nil {
		subscriber.stop()
	}
}

func cloneRuntimeStateDocument(document *runtimeStateDocument) *runtimeStateDocument {
	if document == nil {
		return nil
	}
	clone := *document
	clone.State = append(json.RawMessage(nil), document.State...)
	return &clone
}

func loadRuntimeStateDocument(path string) (*runtimeStateDocument, error) {
	data, err := os.ReadFile(path)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("read runtime state: %w", err)
	}
	if len(data) > maxRuntimeStateBytes+64*1024 {
		return nil, errors.New("runtime state file exceeds maximum size")
	}
	var document runtimeStateDocument
	if err := json.Unmarshal(data, &document); err != nil {
		return nil, fmt.Errorf("decode runtime state: %w", err)
	}
	state := bytes.TrimSpace(document.State)
	if document.ProtocolVersion != runtimeStateProtocolVersion ||
		document.SchemaVersion <= 0 ||
		document.Revision == 0 ||
		len(state) == 0 ||
		len(state) > maxRuntimeStateBytes ||
		state[0] != '{' ||
		!json.Valid(state) {
		return nil, errors.New("runtime state file has an unsupported or invalid document")
	}
	document.State = append(json.RawMessage(nil), state...)
	return &document, nil
}

func persistRuntimeStateDocument(path string, document runtimeStateDocument) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return fmt.Errorf("create runtime state directory: %w", err)
	}
	data, err := json.Marshal(document)
	if err != nil {
		return fmt.Errorf("encode runtime state: %w", err)
	}
	data = append(data, '\n')
	temporary, err := os.CreateTemp(filepath.Dir(path), ".runtime-state-*.tmp")
	if err != nil {
		return fmt.Errorf("create runtime state temporary file: %w", err)
	}
	temporaryPath := temporary.Name()
	defer os.Remove(temporaryPath)
	if err := temporary.Chmod(0o600); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("secure runtime state temporary file: %w", err)
	}
	if _, err := temporary.Write(data); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("write runtime state: %w", err)
	}
	if err := temporary.Sync(); err != nil {
		_ = temporary.Close()
		return fmt.Errorf("sync runtime state: %w", err)
	}
	if err := temporary.Close(); err != nil {
		return fmt.Errorf("close runtime state: %w", err)
	}
	if err := os.Rename(temporaryPath, path); err != nil {
		return fmt.Errorf("install runtime state: %w", err)
	}
	return nil
}
