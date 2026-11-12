package main

import (
	"net"
	"syscall"
)

func cloudCLIConnectionUserID(conn net.Conn) (uint32, error) {
	unixConn, ok := conn.(*net.UnixConn)
	if !ok {
		return 0, syscall.EINVAL
	}
	raw, err := unixConn.SyscallConn()
	if err != nil {
		return 0, err
	}
	var uid uint32
	var credentialErr error
	if err := raw.Control(func(fd uintptr) {
		uid, credentialErr = cloudCLIUserIDFromFD(int(fd))
	}); err != nil {
		return 0, err
	}
	return uid, credentialErr
}
