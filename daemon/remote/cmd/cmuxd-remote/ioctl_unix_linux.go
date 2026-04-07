//go:build linux

package main

import "syscall"

func ioctlReadTermiosRequest() uintptr {
	return syscall.TCGETS
}

func ioctlWriteTermiosRequest() uintptr {
	return syscall.TCSETS
}
