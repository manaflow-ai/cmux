//go:build darwin

package main

import (
	"os/exec"
	"strconv"
	"strings"
	"syscall"
)

func ptySessionMemberPIDs(sessionID int) []int {
	output, err := exec.Command("/bin/ps", "-axo", "pid=").Output()
	if err != nil {
		return nil
	}
	members := make([]int, 0)
	for _, field := range strings.Fields(string(output)) {
		pid, err := strconv.Atoi(field)
		if err != nil {
			continue
		}
		processSessionID, ok := darwinProcessSessionID(pid)
		if ok && processSessionID == sessionID {
			members = append(members, pid)
		}
	}
	return members
}

func darwinProcessSessionID(pid int) (int, bool) {
	sessionID, _, errno := syscall.RawSyscall(syscall.SYS_GETSID, uintptr(pid), 0, 0)
	if errno != 0 {
		return 0, false
	}
	return int(sessionID), true
}
