//go:build !darwin

package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// parent reads the parent PID from /proc/<pid>/stat.
func (procClaudeProcessTree) parent(pid int) int {
	data, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "stat"))
	if err != nil {
		return 0
	}
	// The command name can contain spaces and parentheses; fields resume
	// after the last ')': state, then ppid.
	closing := bytes.LastIndexByte(data, ')')
	if closing < 0 {
		return 0
	}
	fields := strings.Fields(string(data[closing+1:]))
	if len(fields) < 2 {
		return 0
	}
	parent, err := strconv.Atoi(fields[1])
	if err != nil {
		return 0
	}
	return parent
}

// argv reads the NUL-separated argv from /proc/<pid>/cmdline.
func (procClaudeProcessTree) argv(pid int) []string {
	data, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "cmdline"))
	if err != nil || len(data) == 0 {
		return nil
	}
	return strings.Split(strings.TrimRight(string(data), "\x00"), "\x00")
}

// readProcEnviron parses /proc/<pid>/environ. It is readable only for
// processes of the same user.
func readProcEnviron(pid int) map[string]string {
	data, err := os.ReadFile(filepath.Join("/proc", strconv.Itoa(pid), "environ"))
	if err != nil {
		return nil
	}
	environment := map[string]string{}
	for _, entry := range strings.Split(string(data), "\x00") {
		if key, value, ok := strings.Cut(entry, "="); ok && key != "" {
			environment[key] = value
		}
	}
	return environment
}

// claudeHookProcessTTY reports the terminal on one of a process's standard
// descriptors, read from /proc/<pid>/fd.
func claudeHookProcessTTY(pid string) string {
	for _, fd := range []string{"0", "1", "2"} {
		target, err := os.Readlink(filepath.Join("/proc", pid, "fd", fd))
		if err == nil && (strings.HasPrefix(target, "/dev/pts/") || strings.HasPrefix(target, "/dev/tty")) {
			return target
		}
	}
	return ""
}
