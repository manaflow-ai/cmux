package main

import "golang.org/x/sys/unix"

func cloudCLIUserIDFromFD(fd int) (uint32, error) {
	credentials, err := unix.GetsockoptXucred(fd, unix.SOL_LOCAL, unix.LOCAL_PEERCRED)
	if err != nil {
		return 0, err
	}
	// XUCRED_VERSION in sys/ucred.h is not exported by this x/sys version.
	if credentials.Version != 0 {
		return 0, unix.EINVAL
	}
	return credentials.Uid, nil
}
