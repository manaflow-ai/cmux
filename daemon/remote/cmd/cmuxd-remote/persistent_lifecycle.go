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
		if err := verifyPrivateDaemonDirectory(storedSocketDir); err != nil {
			return paths, false, err
		}
		paths.socket = filepath.Join(storedSocketDir, filepath.Base(paths.socket))
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
			if _, socketErr := os.Lstat(paths.socket); errors.Is(socketErr, os.ErrNotExist) {
				return waitForPersistentDaemonStop(paths.lockFile)
			}
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
		if response.Error != nil {
			return fmt.Errorf("persistent daemon shutdown rejected: %s: %s", response.Error.Code, response.Error.Message)
		}
		return errors.New("persistent daemon shutdown rejected")
	}
	return nil
}

func waitForPersistentDaemonStop(lockPath string) error {
	lockFile, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer lockFile.Close()
	if err := syscall.Flock(int(lockFile.Fd()), syscall.LOCK_EX); err != nil {
		return err
	}
	return syscall.Flock(int(lockFile.Fd()), syscall.LOCK_UN)
}

func persistentDaemonSlotLeasePresent(slot string) (bool, error) {
	home, err := os.UserHomeDir()
	if err != nil || strings.TrimSpace(home) == "" {
		return false, errors.New("cannot resolve remote home directory")
	}
	relayDirectory := filepath.Join(home, ".cmux", "relay")
	entries, err := os.ReadDir(relayDirectory)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return false, nil
		}
		return false, err
	}
	for _, entry := range entries {
		name := entry.Name()
		if !strings.HasSuffix(name, ".slot") {
			continue
		}
		port, err := strconv.Atoi(strings.TrimSuffix(name, ".slot"))
		if err != nil || port <= 0 || port > 65535 {
			continue
		}
		info, err := entry.Info()
		if err != nil {
			return false, err
		}
		if !info.Mode().IsRegular() || !daemonDirectoryOwnedByCurrentUser(info) {
			continue
		}
		data, err := os.ReadFile(filepath.Join(relayDirectory, name))
		if err != nil {
			return false, err
		}
		if strings.TrimSpace(string(data)) == slot {
			return true, nil
		}
	}
	return false, nil
}

func earliestNonzeroTime(a time.Time, b time.Time) time.Time {
	if a.IsZero() || (!b.IsZero() && b.Before(a)) {
		return b
	}
	return a
}
