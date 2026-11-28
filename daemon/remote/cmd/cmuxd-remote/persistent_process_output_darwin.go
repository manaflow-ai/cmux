//go:build darwin

package main

import "syscall"

func replacePersistentDaemonFD(from int, to int) error {
	return syscall.Dup2(from, to)
}
