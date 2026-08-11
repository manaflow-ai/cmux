package main

import (
	"errors"
	"io"
	"os"
	"sync"
	"syscall"
)

// persistentDaemonProcessOutputRoute keeps process-level stdout and stderr on
// the same rotating writer as structured daemon diagnostics. The persistent
// server is a detached child, so routing must be owned by that child rather
// than by the short-lived stdio proxy that launched it.
type persistentDaemonProcessOutputRoute struct {
	reader        *os.File
	savedStdoutFD int
	savedStderrFD int
	drained       chan struct{}
	closeOnce     sync.Once
	closeErr      error
}

func shouldRoutePersistentDaemonProcessOutput(stderr io.Writer) bool {
	file, ok := stderr.(*os.File)
	return ok &&
		file.Fd() == os.Stderr.Fd() &&
		os.Getenv(persistentDaemonReadyFDEnv) != ""
}

func routePersistentDaemonProcessOutput(writer io.Writer) (*persistentDaemonProcessOutputRoute, error) {
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

	savedStdoutFD, err := syscall.Dup(int(os.Stdout.Fd()))
	if err != nil {
		return nil, err
	}
	savedStderrFD, err := syscall.Dup(int(os.Stderr.Fd()))
	if err != nil {
		_ = syscall.Close(savedStdoutFD)
		return nil, err
	}
	closeSaved := true
	defer func() {
		if closeSaved {
			_ = syscall.Close(savedStdoutFD)
			_ = syscall.Close(savedStderrFD)
		}
	}()

	if err := replacePersistentDaemonFD(int(pipeWriter.Fd()), int(os.Stdout.Fd())); err != nil {
		return nil, err
	}
	if err := replacePersistentDaemonFD(int(pipeWriter.Fd()), int(os.Stderr.Fd())); err != nil {
		_ = replacePersistentDaemonFD(savedStdoutFD, int(os.Stdout.Fd()))
		return nil, err
	}
	if err := pipeWriter.Close(); err != nil {
		_ = replacePersistentDaemonFD(savedStdoutFD, int(os.Stdout.Fd()))
		_ = replacePersistentDaemonFD(savedStderrFD, int(os.Stderr.Fd()))
		return nil, err
	}

	route := &persistentDaemonProcessOutputRoute{
		reader:        reader,
		savedStdoutFD: savedStdoutFD,
		savedStderrFD: savedStderrFD,
		drained:       make(chan struct{}),
	}
	go route.drain(writer)
	closePipe = false
	closeSaved = false
	return route, nil
}

func (r *persistentDaemonProcessOutputRoute) drain(writer io.Writer) {
	defer close(r.drained)
	if _, err := io.Copy(writer, r.reader); err != nil {
		// Keep draining after a log-write failure so an unrelated diagnostic can
		// never fill the pipe and stall the daemon.
		_, _ = io.Copy(io.Discard, r.reader)
	}
}

func (r *persistentDaemonProcessOutputRoute) Close() error {
	if r == nil {
		return nil
	}
	r.closeOnce.Do(func() {
		stdoutErr := replacePersistentDaemonFD(r.savedStdoutFD, int(os.Stdout.Fd()))
		stderrErr := replacePersistentDaemonFD(r.savedStderrFD, int(os.Stderr.Fd()))
		_ = syscall.Close(r.savedStdoutFD)
		_ = syscall.Close(r.savedStderrFD)
		if stdoutErr != nil || stderrErr != nil {
			// A failed restore may leave a pipe writer open. Closing the reader
			// guarantees shutdown cannot deadlock waiting for the drain goroutine.
			_ = r.reader.Close()
		}
		<-r.drained
		_ = r.reader.Close()
		r.closeErr = errors.Join(stdoutErr, stderrErr)
	})
	return r.closeErr
}
