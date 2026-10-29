package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"runtime"
	"strings"
	"syscall"
)

const (
	persistentPTYExecHelperArgument    = "--internal-persistent-pty-exec"
	persistentPTYExecHelperEnvironment = "CMUX_PERSISTENT_PTY_EXEC_HELPER"
)

func init() {
	if len(os.Args) < 2 || os.Args[1] != persistentPTYExecHelperArgument {
		return
	}
	os.Exit(runPersistentPTYExecHelper(os.Args[2:], os.Stderr))
}

func runPersistentPTYExecHelper(arguments []string, stderr io.Writer) int {
	if len(arguments) < 2 {
		_, _ = fmt.Fprintln(stderr, "persistent PTY exec helper requires an executable and argv")
		return 2
	}
	executable := arguments[0]
	argv := arguments[1:]
	if !strings.ContainsRune(executable, os.PathSeparator) {
		resolved, err := exec.LookPath(executable)
		if err != nil {
			_, _ = fmt.Fprintf(stderr, "persistent PTY exec helper could not resolve %s through PATH: %v\n", executable, err)
			return 126
		}
		executable = resolved
	}

	// Keep the ignored disposition as a second layer for shells that explicitly
	// unblock job-control signals. Agent runtimes that reset the disposition are
	// still protected by the inherited mask below.
	signal.Ignore(syscall.SIGHUP)

	// Signal masks belong to OS threads. Pin this goroutine from the mask
	// change through exec so the new program inherits the mask we set.
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	if err := blockPersistentPTYHangup(); err != nil {
		_, _ = fmt.Fprintf(stderr, "persistent PTY exec helper could not block SIGHUP: %v\n", err)
		return 126
	}
	if err := syscall.Exec(executable, argv, os.Environ()); err != nil {
		_, _ = fmt.Fprintf(stderr, "persistent PTY exec helper could not exec %s: %v\n", executable, err)
		return 126
	}
	return 0
}
