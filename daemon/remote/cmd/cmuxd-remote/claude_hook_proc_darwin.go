//go:build darwin

package main

import (
	"bytes"
	"encoding/binary"
	"path/filepath"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

// macOS has no /proc. Parents and controlling terminals come from
// kern.proc.pid, and argv and environment from kern.procargs2, which (like
// `ps -E`) shows another process's environment only to its own user.

// parent reads the parent PID from kern.proc.pid.
func (procClaudeProcessTree) parent(pid int) int {
	info, err := unix.SysctlKinfoProc("kern.proc.pid", pid)
	if err != nil || info.Proc.P_pid != int32(pid) {
		return 0
	}
	return int(info.Eproc.Ppid)
}

// argv reads the argument vector from kern.procargs2.
func (procClaudeProcessTree) argv(pid int) []string {
	argv, _, ok := darwinProcessArguments(pid)
	if !ok {
		return nil
	}
	return argv
}

// readProcEnviron reads a process's environment from kern.procargs2.
func readProcEnviron(pid int) map[string]string {
	_, environment, ok := darwinProcessArguments(pid)
	if !ok {
		return nil
	}
	return environment
}

func darwinProcessArguments(pid int) ([]string, map[string]string, bool) {
	if pid <= 0 {
		return nil, nil, false
	}
	data, err := unix.SysctlRaw("kern.procargs2", pid)
	if err != nil {
		return nil, nil, false
	}
	return parseDarwinProcArgs(data)
}

// parseDarwinProcArgs decodes a kern.procargs2 buffer: a native-endian
// int32 argc, the executable path, NUL padding, argc NUL-terminated
// arguments, then NUL-terminated KEY=VALUE environment strings up to an empty
// string or the end of the buffer.
func parseDarwinProcArgs(data []byte) ([]string, map[string]string, bool) {
	if len(data) < 4 {
		return nil, nil, false
	}
	argc := int(int32(binary.NativeEndian.Uint32(data[:4])))
	if argc < 0 {
		return nil, nil, false
	}
	rest := data[4:]
	pathEnd := bytes.IndexByte(rest, 0)
	if pathEnd < 0 {
		return nil, nil, false
	}
	rest = rest[pathEnd:]
	for len(rest) > 0 && rest[0] == 0 {
		rest = rest[1:]
	}
	argv := make([]string, 0, argc)
	for len(argv) < argc {
		end := bytes.IndexByte(rest, 0)
		if end < 0 {
			return nil, nil, false
		}
		argv = append(argv, string(rest[:end]))
		rest = rest[end+1:]
	}
	environment := map[string]string{}
	for len(rest) > 0 {
		end := bytes.IndexByte(rest, 0)
		if end < 0 {
			end = len(rest)
		}
		if end == 0 {
			break
		}
		if key, value, ok := strings.Cut(string(rest[:end]), "="); ok && key != "" {
			environment[key] = value
		}
		if end == len(rest) {
			break
		}
		rest = rest[end+1:]
	}
	return argv, environment, true
}

// claudeHookProcessTTY reports a process's controlling terminal: the
// /dev/tty* device whose number kern.proc.pid records.
func claudeHookProcessTTY(pid string) string {
	number, err := strconv.Atoi(pid)
	if err != nil || number <= 0 {
		return ""
	}
	info, err := unix.SysctlKinfoProc("kern.proc.pid", number)
	if err != nil || info.Proc.P_pid != int32(number) || info.Eproc.Tdev == -1 {
		return ""
	}
	return darwinTTYName(info.Eproc.Tdev, "/dev")
}

// darwinTTYName finds the terminal device in dir with device number dev.
func darwinTTYName(dev int32, dir string) string {
	candidates, _ := filepath.Glob(filepath.Join(dir, "tty*"))
	for _, candidate := range candidates {
		var stat unix.Stat_t
		if unix.Stat(candidate, &stat) == nil && stat.Mode&unix.S_IFMT == unix.S_IFCHR && stat.Rdev == dev {
			return candidate
		}
	}
	return ""
}
