//go:build linux

// The production remote daemon runs on Linux, so this is the authoritative
// foreground-process probe; the darwin sibling is a degraded fallback for
// local development.

package main

import (
	"os"
	"strconv"
	"strings"
)

// foregroundProcessInfo resolves the command name and working directory of a
// foreground process group leader from /proc. /proc races (the process
// exiting between reads) are tolerated silently, like ptySessionMemberPIDs:
// an unreadable comm reports ok=false and an unreadable cwd stays empty.
func foregroundProcessInfo(pgid int) (string, string, bool) {
	pid := strconv.Itoa(pgid)
	comm, err := os.ReadFile("/proc/" + pid + "/comm")
	if err != nil {
		return "", "", false
	}
	command := strings.TrimRight(string(comm), "\n")
	cwd, err := os.Readlink("/proc/" + pid + "/cwd")
	if err != nil {
		cwd = ""
	}
	return command, cwd, true
}
