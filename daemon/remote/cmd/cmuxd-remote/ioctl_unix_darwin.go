//go:build darwin

package main

import "syscall"

func ioctlReadTermiosRequest() uintptr {
	return syscall.TIOCGETA
}

func ioctlWriteTermiosRequest() uintptr {
	return syscall.TIOCSETA
}
