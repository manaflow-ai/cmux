//go:build darwin

package compat

import (
	"syscall"
	"time"
)

func pollPTYReadable(fd int, timeout time.Duration) (bool, error) {
	var readFDs syscall.FdSet
	readFDs.Bits[fd/32] |= 1 << (uint(fd) % 32)
	tv := syscall.Timeval{
		Sec:  int64(timeout / time.Second),
		Usec: int32((timeout % time.Second) / time.Microsecond),
	}
	err := syscall.Select(fd+1, &readFDs, nil, nil, &tv)
	if err != nil {
		return false, err
	}
	return readFDs.Bits[fd/32]&(1<<(uint(fd)%32)) != 0, nil
}
