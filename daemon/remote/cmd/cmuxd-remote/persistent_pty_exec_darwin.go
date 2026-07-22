package main

import (
	"syscall"
	"unsafe"
)

func blockPersistentPTYHangup() error {
	const darwinSignalBlock = 1
	mask := uint32(1) << uint(syscall.SIGHUP-1)
	_, _, errno := syscall.RawSyscall(
		syscall.SYS___PTHREAD_SIGMASK,
		darwinSignalBlock,
		uintptr(unsafe.Pointer(&mask)),
		0,
	)
	if errno != 0 {
		return errno
	}
	return nil
}
