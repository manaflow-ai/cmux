package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const persistentDaemonShutdownMethod = "daemon.shutdown"

const (
	persistentDaemonStopWaitTimeout = 5 * time.Second
	persistentDaemonStopRetryStep   = 25 * time.Millisecond
)

func existingPersistentDaemonPathsForSlot(slot string) (persistentDaemonPaths, bool, error) {
	paths, err := persistentDaemonPathsForSlot(slot)
	if err != nil {
		return persistentDaemonPaths{}, false, err
	}
	if err := verifyPrivateDaemonDirectory(paths.root); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return paths, false, nil
		}
		return paths, false, err
	}
	if storedSocketDir, err := readPersistentDaemonSocketDir(paths.root); err == nil {
		paths.socket = filepath.Join(storedSocketDir, filepath.Base(paths.socket))
		if err := verifyPrivateDaemonDirectory(storedSocketDir); err != nil {
			if errors.Is(err, os.ErrNotExist) {
				return paths, true, nil
			}
			return paths, false, err
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return paths, false, err
	}
	return paths, true, nil
}

func stopPersistentDaemon(slot string) error {
	paths, exists, err := existingPersistentDaemonPathsForSlot(slot)
	if err != nil || !exists {
		return err
	}
	token, err := readPersistentDaemonTokenFile(paths.tokenFile)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			if stopErr := waitForPersistentDaemonStop(paths.lockFile); stopErr != nil {
				return stopErr
			}
			_ = os.Remove(paths.socket)
			return nil
		}
		return err
	}
	conn, err := dialPersistentDaemon(paths.socket, token)
	if err != nil {
		if shouldRemovePersistentSocketAfterDialError(err) {
			_ = os.Remove(paths.socket)
			return waitForPersistentDaemonStop(paths.lockFile)
		}
		return err
	}
	if err := requestPersistentDaemonShutdown(conn); err != nil {
		_ = conn.Close()
		return err
	}
	_ = conn.Close()
	return waitForPersistentDaemonStop(paths.lockFile)
}

func requestPersistentDaemonShutdown(conn net.Conn) error {
	if err := conn.SetDeadline(time.Now().Add(persistentDaemonAuthTimeout)); err != nil {
		return err
	}
	defer conn.SetDeadline(time.Time{})

	request, err := json.Marshal(rpcRequest{
		ID:     "shutdown",
		Method: persistentDaemonShutdownMethod,
		Params: map[string]any{},
	})
	if err != nil {
		return err
	}
	writer := bufio.NewWriter(conn)
	if _, err := writer.Write(append(request, '\n')); err != nil {
		return err
	}
	if err := writer.Flush(); err != nil {
		return err
	}
	line, oversized, err := readRPCFrame(bufio.NewReaderSize(conn, 64*1024), maxRPCFrameBytes)
	if err != nil {
		return err
	}
	if oversized {
		return errors.New("persistent daemon shutdown response exceeds maximum size")
	}
	var response rpcResponse
	if err := json.Unmarshal(bytes.TrimSpace(line), &response); err != nil {
		return err
	}
	if !response.OK {
		return errors.New("persistent daemon shutdown rejected")
	}
	return nil
}

func waitForPersistentDaemonStop(lockPath string) error {
	return waitForPersistentDaemonStopWithTimeout(
		lockPath,
		persistentDaemonStopWaitTimeout,
		persistentDaemonStopRetryStep,
	)
}

func waitForPersistentDaemonStopWithTimeout(lockPath string, timeout time.Duration, retryStep time.Duration) error {
	if timeout <= 0 || retryStep <= 0 {
		return errors.New("persistent daemon stop wait requires positive timeout and retry step")
	}
	lockFile, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer lockFile.Close()
	deadline := time.Now().Add(timeout)
	for {
		err := syscall.Flock(int(lockFile.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			return syscall.Flock(int(lockFile.Fd()), syscall.LOCK_UN)
		}
		if !errors.Is(err, syscall.EWOULDBLOCK) && !errors.Is(err, syscall.EAGAIN) {
			return err
		}

		remaining := time.Until(deadline)
		if remaining <= 0 {
			return fmt.Errorf("timed out waiting for persistent daemon ownership release after %s", timeout)
		}
		wait := retryStep
		if remaining < wait {
			wait = remaining
		}
		timer := time.NewTimer(wait)
		<-timer.C
	}
}

func persistentDaemonRelayPath(leasePort int, suffix string) (string, error) {
	if leasePort <= 0 || leasePort > 65535 {
		return "", fmt.Errorf("invalid persistent daemon lease port %d", leasePort)
	}
	home, err := os.UserHomeDir()
	if err != nil || strings.TrimSpace(home) == "" {
		return "", errors.New("cannot resolve remote home directory")
	}
	return filepath.Join(home, ".cmux", "relay", strconv.Itoa(leasePort)+suffix), nil
}

func persistentDaemonSlotLeasePresent(slot string, leasePort int) (bool, error) {
	leasePath, err := persistentDaemonRelayPath(leasePort, ".slot")
	if err != nil {
		return false, err
	}
	info, err := os.Lstat(leasePath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return false, nil
		}
		return false, err
	}
	if !info.Mode().IsRegular() || !daemonDirectoryOwnedByCurrentUser(info) {
		return false, fmt.Errorf("persistent daemon lease %q is not a private regular file", leasePath)
	}
	data, err := os.ReadFile(leasePath)
	if err != nil {
		return false, err
	}
	return strings.TrimSpace(string(data)) == slot, nil
}

func removePersistentDaemonRelayShellDirectoryIfUnleased(leasePort int) error {
	leasePath, err := persistentDaemonRelayPath(leasePort, ".slot")
	if err != nil {
		return err
	}
	if _, err := os.Lstat(leasePath); err == nil {
		return nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	shellPath, err := persistentDaemonRelayPath(leasePort, ".shell")
	if err != nil {
		return err
	}
	return os.RemoveAll(shellPath)
}

func earliestNonzeroTime(a time.Time, b time.Time) time.Time {
	if a.IsZero() || (!b.IsZero() && b.Before(a)) {
		return b
	}
	return a
}
