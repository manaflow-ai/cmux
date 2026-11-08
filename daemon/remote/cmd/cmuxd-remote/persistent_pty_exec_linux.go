package main

import (
	"syscall"
	"unsafe"
)

func blockPersistentPTYHangup() error {
	const linuxSignalBlock = 0
	mask := uint64(1) << uint(syscall.SIGHUP-1)
	_, _, errno := syscall.RawSyscall6(
		syscall.SYS_RT_SIGPROCMASK,
		linuxSignalBlock,
		uintptr(unsafe.Pointer(&mask)),
		0,
		unsafe.Sizeof(mask),
		0,
		0,
	)
	if errno != 0 {
		return errno
	}
	return nil
}
