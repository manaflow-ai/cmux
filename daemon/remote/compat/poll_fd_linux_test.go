//go:build linux

package compat

import (
	"syscall"
	"time"
)

func pollPTYReadable(fd int, timeout time.Duration) (bool, error) {
	var readFDs syscall.FdSet
	readFDs.Bits[fd/64] |= 1 << (uint(fd) % 64)
	tv := syscall.Timeval{
		Sec:  int64(timeout / time.Second),
		Usec: int64((timeout % time.Second) / time.Microsecond),
	}
	ready, err := syscall.Select(fd+1, &readFDs, nil, nil, &tv)
	if err != nil {
		return false, err
	}
	return ready > 0, nil
}
