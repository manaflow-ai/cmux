package main

import (
	"errors"
	"os"
	"path/filepath"
	"syscall"
)

// Signal files belong to the remote user, just like persistent daemon sockets.
// Validate each directory below HOME before creating or consuming a signal.
func tmuxWaitForSignalDirectory() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	directory := home
	for _, component := range []string{".cmux", "wait-for"} {
		directory = filepath.Join(directory, component)
		if err := ensurePrivateDaemonLeafDirectory(directory); err != nil {
			return "", err
		}
	}
	return directory, nil
}

func privateTmuxWaitForSignal(info os.FileInfo) bool {
	return info.Mode().IsRegular() && info.Mode().Perm()&0077 == 0 && daemonDirectoryOwnedByCurrentUser(info)
}

func createTmuxWaitForSignal(path string) error {
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL|syscall.O_NOFOLLOW, 0600)
	if err != nil {
		if !errors.Is(err, os.ErrExist) {
			return err
		}
		info, statErr := os.Lstat(path)
		if statErr != nil {
			return statErr
		}
		if !privateTmuxWaitForSignal(info) {
			return os.ErrPermission
		}
		return nil
	}
	if err := file.Chmod(0600); err != nil {
		_ = file.Close()
		return err
	}
	return file.Close()
}
