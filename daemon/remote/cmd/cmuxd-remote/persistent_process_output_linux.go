//go:build linux

package main

import "syscall"

func replacePersistentDaemonFD(from int, to int) error {
	if from == to {
		return nil
	}
	return syscall.Dup3(from, to, 0)
}
