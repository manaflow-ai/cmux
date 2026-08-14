//go:build darwin

// The production remote daemon runs on Linux; this darwin implementation is a
// degraded fallback for local development. It resolves only the command name
// via ps and cannot report a working directory.

package main

import (
	"os/exec"
	"path"
	"strconv"
	"strings"
)

func foregroundProcessInfo(pgid int) (string, string, bool) {
	output, err := exec.Command("/bin/ps", "-o", "comm=", "-p", strconv.Itoa(pgid)).Output()
	if err != nil {
		return "", "", false
	}
	command := strings.TrimSpace(string(output))
	if command == "" {
		return "", "", false
	}
	return path.Base(command), "", true
}
