package main

import (
	"errors"
	"io"
	"os"
	"strconv"
	"sync"
	"syscall"
	"time"
)

const persistentDaemonProcessOutputSummaryInterval = time.Second

// persistentDaemonProcessOutputRoute keeps process-level stdout and stderr on
// the same rotating writer as structured daemon diagnostics. The persistent
// server is a detached child, so routing must be owned by that child rather
// than by the short-lived stdio proxy that launched it.
type persistentDaemonProcessOutputRoute struct {
	streams   []*persistentDaemonProcessOutputStream
	closeOnce sync.Once
	closeErr  error
}

type persistentDaemonProcessOutputStream struct {
	name     string
	reader   *os.File
	savedFD  int
	targetFD int
	drained  chan struct{}
}

type persistentDaemonProcessOutputSummary struct {
	minimumInterval time.Duration
	pendingBytes    int64
	lastEmittedAt   time.Time
}

func (s *persistentDaemonProcessOutputSummary) record(byteCount int, now time.Time) (int64, bool) {
	if byteCount <= 0 {
		return 0, false
	}
	s.pendingBytes += int64(byteCount)
	if s.lastEmittedAt.IsZero() || now.Sub(s.lastEmittedAt) >= s.minimumInterval {
		return s.flush(now)
	}
	return 0, false
}

func (s *persistentDaemonProcessOutputSummary) flush(now time.Time) (int64, bool) {
	if s.pendingBytes <= 0 {
		return 0, false
	}
	byteCount := s.pendingBytes
	s.pendingBytes = 0
	s.lastEmittedAt = now
	return byteCount, true
}

func shouldRoutePersistentDaemonProcessOutput(stderr io.Writer) bool {
	file, ok := stderr.(*os.File)
	return ok &&
		file.Fd() == os.Stderr.Fd() &&
		os.Getenv(persistentDaemonReadyFDEnv) != ""
}

func routePersistentDaemonProcessOutput(writer io.Writer) (*persistentDaemonProcessOutputRoute, error) {
	stdout, err := routePersistentDaemonProcessOutputStream(
		"stdout",
		int(os.Stdout.Fd()),
		writer,
	)
	if err != nil {
		return nil, err
	}
	stderr, err := routePersistentDaemonProcessOutputStream(
		"stderr",
		int(os.Stderr.Fd()),
		writer,
	)
	if err != nil {
		return nil, errors.Join(err, stdout.restoreAndDrain())
	}
	return &persistentDaemonProcessOutputRoute{streams: []*persistentDaemonProcessOutputStream{stdout, stderr}}, nil
}

func routePersistentDaemonProcessOutputStream(
	name string,
	targetFD int,
	writer io.Writer,
) (*persistentDaemonProcessOutputStream, error) {
	savedFD, err := syscall.Dup(targetFD)
	if err != nil {
		return nil, err
	}
	closeSaved := true
	defer func() {
		if closeSaved {
			_ = syscall.Close(savedFD)
		}
	}()

	reader, pipeWriter, err := os.Pipe()
	if err != nil {
		return nil, err
	}
	closePipe := true
	defer func() {
		if closePipe {
			_ = reader.Close()
			_ = pipeWriter.Close()
		}
	}()

	if err := replacePersistentDaemonFD(int(pipeWriter.Fd()), targetFD); err != nil {
		return nil, err
	}
	if err := pipeWriter.Close(); err != nil {
		_ = replacePersistentDaemonFD(savedFD, targetFD)
		return nil, err
	}

	stream := &persistentDaemonProcessOutputStream{
		name:     name,
		reader:   reader,
		savedFD:  savedFD,
		targetFD: targetFD,
		drained:  make(chan struct{}),
	}
	go stream.drain(writer)
	closePipe = false
	closeSaved = false
	return stream, nil
}

func (s *persistentDaemonProcessOutputStream) drain(writer io.Writer) {
	summary := persistentDaemonProcessOutputSummary{
		minimumInterval: persistentDaemonProcessOutputSummaryInterval,
	}
	emitSummary := func(byteCount int64) {
		logPersistentDaemonEvent(
			writer,
			"process_output",
			"stream", s.name,
			"bytes", strconv.FormatInt(byteCount, 10),
		)
	}
	defer func() {
		if byteCount, emit := summary.flush(time.Now()); emit {
			emitSummary(byteCount)
		}
		close(s.drained)
	}()
	buffer := make([]byte, 32*1024)
	for {
		count, err := s.reader.Read(buffer)
		if count > 0 {
			// Process output is arbitrary and may contain terminal input, commands,
			// or credentials. Record rate-limited byte summaries and discard the bytes.
			if byteCount, emit := summary.record(count, time.Now()); emit {
				emitSummary(byteCount)
			}
		}
		if err != nil {
			return
		}
	}
}

func (r *persistentDaemonProcessOutputRoute) Close() error {
	if r == nil {
		return nil
	}
	r.closeOnce.Do(func() {
		var restoreErrors []error
		for _, stream := range r.streams {
			if err := stream.restore(); err != nil {
				restoreErrors = append(restoreErrors, err)
			}
		}
		for _, stream := range r.streams {
			stream.waitForDrain()
		}
		r.closeErr = errors.Join(restoreErrors...)
	})
	return r.closeErr
}

func (s *persistentDaemonProcessOutputStream) restore() error {
	err := replacePersistentDaemonFD(s.savedFD, s.targetFD)
	_ = syscall.Close(s.savedFD)
	if err != nil {
		// A failed restore may leave a pipe writer open. Closing the reader
		// guarantees shutdown cannot deadlock waiting for the drain goroutine.
		_ = s.reader.Close()
	}
	return err
}

func (s *persistentDaemonProcessOutputStream) waitForDrain() {
	<-s.drained
	_ = s.reader.Close()
}

func (s *persistentDaemonProcessOutputStream) restoreAndDrain() error {
	err := s.restore()
	s.waitForDrain()
	return err
}
