package agentconv

import (
	"bytes"
	"errors"
	"io"
	"os"
	"sync"
	"time"
)

// A Subscription replays a transcript as a snapshot event and then tails the
// file for growth, emitting incremental item events. Tailing polls at a
// bounded, injectable interval (deliberate: line-granularity latency is
// invisible at agent output cadence, and polling behaves identically across
// macOS/Linux and atomic-rewrite filesystems; the daemon is not in any
// keystroke hot path).

// maxTranscriptLineBytes bounds a single JSONL line (tool results can embed
// whole files); longer lines are dropped as malformed.
const maxTranscriptLineBytes = 8 * 1024 * 1024

const defaultPollInterval = 300 * time.Millisecond

// defaultMaxSnapshotBytes caps the initial replay read; larger transcripts
// replay only their tail, starting at the first complete line.
const defaultMaxSnapshotBytes = int64(32 * 1024 * 1024)

type Config struct {
	Provider       ProviderID
	TranscriptPath string
	// PollInterval overrides the tail poll cadence (tests use ~1ms).
	PollInterval time.Duration
	// MaxSnapshotBytes overrides the initial replay cap.
	MaxSnapshotBytes int64
}

type Subscription struct {
	// Events delivers the snapshot and every subsequent event. Closed when the
	// subscription stops.
	Events <-chan Event

	events   chan Event
	hooks    chan HookFrame
	stop     chan struct{}
	stopOnce sync.Once
	done     chan struct{}
}

// InjectHookFrame hands a live hook frame to the subscription's merge loop.
// Hooks are advisory: frames are dropped (returning false) when the
// subscription is stopping or its buffer is full.
func (s *Subscription) InjectHookFrame(frame HookFrame) bool {
	select {
	case <-s.stop:
		return false
	default:
	}
	select {
	case s.hooks <- frame:
		return true
	default:
		return false
	}
}

// Session returns the session reference resolved at open time.
func Open(config Config) (*Subscription, SessionRef, error) {
	if config.PollInterval <= 0 {
		config.PollInterval = defaultPollInterval
	}
	if config.MaxSnapshotBytes <= 0 {
		config.MaxSnapshotBytes = defaultMaxSnapshotBytes
	}
	reader := &transcriptReader{path: config.TranscriptPath}
	parser := newTranscriptParser(config.Provider, config.TranscriptPath)
	if err := reader.seekForSnapshot(config.MaxSnapshotBytes); err != nil {
		return nil, SessionRef{}, err
	}
	headSkipped := reader.offset > 0
	lines, _, err := reader.readNewLines()
	if err != nil {
		return nil, SessionRef{}, err
	}
	for _, line := range lines {
		parser.consumeLine(line)
	}
	if headSkipped {
		// The snapshot cap cut off the transcript head, which is where Codex
		// writes its session_meta line: a tail-only replay would report an
		// empty session id/cwd/title. Recover them with the same bounded head
		// scan discovery uses; fields the tail replay already produced win.
		conversation := parser.conv()
		head := scanTranscriptHead(config.Provider, config.TranscriptPath)
		if conversation.session.SessionID == "" {
			conversation.session.SessionID = head.SessionID
		}
		if conversation.session.Cwd == "" {
			conversation.session.Cwd = head.Cwd
		}
		if conversation.session.Title == "" {
			conversation.session.Title = head.Title
		}
	}
	session := snapshotSessionRef(parser, config.TranscriptPath)

	events := make(chan Event, 256)
	subscription := &Subscription{
		Events: events,
		events: events,
		hooks:  make(chan HookFrame, 64),
		stop:   make(chan struct{}),
		done:   make(chan struct{}),
	}
	go subscription.run(config, parser, reader, session)
	return subscription, session, nil
}

func (s *Subscription) Close() {
	s.stopOnce.Do(func() { close(s.stop) })
	<-s.done
}

func (s *Subscription) run(config Config, parser transcriptParser, reader *transcriptReader, session SessionRef) {
	defer close(s.done)
	defer close(s.events)

	var seq uint64
	nextSeq := func() uint64 { seq++; return seq }
	emit := func(event Event) bool {
		select {
		case s.events <- event:
			return true
		case <-s.stop:
			return false
		}
	}

	conversation := parser.conv()
	conversation.sessionDirty = false
	snapshotItems := make([]Item, len(conversation.items))
	copy(snapshotItems, conversation.items)
	sessionCopy := session
	if !emit(Event{Type: EventSnapshot, Seq: nextSeq(), Session: &sessionCopy, Items: snapshotItems}) {
		return
	}

	// merger is where the hook source and the transcript source meet; it owns
	// the dedup state (see hook.go). Rebuilt whenever the conversation is.
	merger := newHookMerger(conversation)

	ticker := time.NewTicker(config.PollInterval)
	defer ticker.Stop()
	for {
		select {
		case <-s.stop:
			return
		case frame := <-s.hooks:
			for _, event := range merger.consumeHookFrame(frame) {
				event.Seq = nextSeq()
				if !emit(event) {
					return
				}
			}
			continue
		case <-ticker.C:
		}
		lines, truncated, err := reader.readNewLines()
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				// Transcript can disappear (cleanup); report and keep waiting.
				if !emit(Event{Type: EventError, Seq: nextSeq(), Message: "transcript not found", Recoverable: true}) {
					return
				}
				continue
			}
			if !emit(Event{Type: EventError, Seq: nextSeq(), Message: err.Error(), Recoverable: true}) {
				return
			}
			continue
		}
		if truncated {
			// The file shrank or was replaced: re-parse from scratch and
			// resynchronize the client with a fresh snapshot. Hook merge state
			// resets with it (pending requests and turn state are ephemeral).
			parser = newTranscriptParser(config.Provider, config.TranscriptPath)
			conversation = parser.conv()
			merger = newHookMerger(conversation)
			lines, _, err = reader.readNewLines()
			if err != nil {
				if !emit(Event{Type: EventError, Seq: nextSeq(), Message: err.Error(), Recoverable: true}) {
					return
				}
				continue
			}
			for _, line := range lines {
				parser.consumeLine(line)
			}
			refreshed := snapshotSessionRef(parser, config.TranscriptPath)
			conversation.sessionDirty = false
			items := make([]Item, len(conversation.items))
			copy(items, conversation.items)
			if !emit(Event{Type: EventSnapshot, Seq: nextSeq(), Session: &refreshed, Items: items}) {
				return
			}
			continue
		}
		for _, line := range lines {
			for _, lineChange := range parser.consumeLine(line) {
				event := merger.transcriptChange(lineChange)
				event.Seq = nextSeq()
				if !emit(event) {
					return
				}
			}
		}
		if conversation.sessionDirty {
			conversation.sessionDirty = false
			refreshed := snapshotSessionRef(parser, config.TranscriptPath)
			if !emit(Event{Type: EventSessionMeta, Seq: nextSeq(), Session: &refreshed}) {
				return
			}
		}
	}
}

func snapshotSessionRef(parser transcriptParser, transcriptPath string) SessionRef {
	session := parser.conv().session
	session.TranscriptPath = transcriptPath
	if info, err := os.Stat(transcriptPath); err == nil {
		session.UpdatedAt = info.ModTime().UTC().Format(time.RFC3339)
	}
	return session
}

// transcriptReader reads complete lines appended past its offset. It reopens
// the file per read (robust against rotation) and reports truncation when the
// file shrinks below the consumed offset.
type transcriptReader struct {
	path    string
	offset  int64
	partial []byte
}

// seekForSnapshot positions the reader so the initial replay reads at most
// maxBytes, starting at the first complete line past the cut.
func (r *transcriptReader) seekForSnapshot(maxBytes int64) error {
	info, err := os.Stat(r.path)
	if err != nil {
		return err
	}
	if info.Size() <= maxBytes {
		return nil
	}
	file, err := os.Open(r.path)
	if err != nil {
		return err
	}
	defer file.Close()
	r.offset = info.Size() - maxBytes
	if _, err := file.Seek(r.offset, io.SeekStart); err != nil {
		return err
	}
	// Discard the partial line at the cut.
	buffer := make([]byte, 64*1024)
	for {
		n, readErr := file.Read(buffer)
		if n > 0 {
			if index := bytes.IndexByte(buffer[:n], '\n'); index >= 0 {
				r.offset += int64(index) + 1
				return nil
			}
			r.offset += int64(n)
		}
		if readErr != nil {
			if errors.Is(readErr, io.EOF) {
				return nil
			}
			return readErr
		}
	}
}

func (r *transcriptReader) readNewLines() ([][]byte, bool, error) {
	info, err := os.Stat(r.path)
	if err != nil {
		return nil, false, err
	}
	if info.Size() < r.offset {
		r.offset = 0
		r.partial = nil
		return nil, true, nil
	}
	if info.Size() == r.offset {
		return nil, false, nil
	}
	file, err := os.Open(r.path)
	if err != nil {
		return nil, false, err
	}
	defer file.Close()
	if _, err := file.Seek(r.offset, io.SeekStart); err != nil {
		return nil, false, err
	}
	data, err := io.ReadAll(io.LimitReader(file, info.Size()-r.offset))
	if err != nil {
		return nil, false, err
	}
	r.offset += int64(len(data))
	combined := append(r.partial, data...)
	var lines [][]byte
	for {
		index := bytes.IndexByte(combined, '\n')
		if index < 0 {
			break
		}
		line := bytes.TrimSuffix(combined[:index], []byte{'\r'})
		if len(line) > 0 && len(line) <= maxTranscriptLineBytes {
			lines = append(lines, append([]byte(nil), line...))
		}
		combined = combined[index+1:]
	}
	if len(combined) > maxTranscriptLineBytes {
		combined = nil
	}
	r.partial = append([]byte(nil), combined...)
	return lines, false, nil
}
