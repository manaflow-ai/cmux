//go:build darwin

package main

import (
	"encoding/binary"
	"os"
	"os/exec"
	"reflect"
	"strconv"
	"strings"
	"testing"
	"time"
)

// procArgs2 builds a kern.procargs2 buffer the way the kernel lays it out.
func procArgs2(argc int32, execPath string, padding int, strs ...string) []byte {
	data := binary.NativeEndian.AppendUint32(nil, uint32(argc))
	data = append(data, execPath...)
	data = append(data, make([]byte, 1+padding)...)
	for _, value := range strs {
		data = append(data, value...)
		data = append(data, 0)
	}
	return data
}

// TestParseDarwinProcArgsLayout decodes argc, the padded executable path, argv and the environment.
func TestParseDarwinProcArgsLayout(t *testing.T) {
	data := procArgs2(3, "/opt/homebrew/bin/tmux", 6,
		"tmux", "attach", "-t=main",
		"CMUX_SOCKET_PATH=127.0.0.1:62357", "CMUX_SURFACE_ID=s=1", "TERM=xterm-ghostty", "",
		"executable_path=/opt/homebrew/bin/tmux")
	argv, environment, ok := parseDarwinProcArgs(data)
	if !ok {
		t.Fatal("parse failed")
	}
	if !reflect.DeepEqual(argv, []string{"tmux", "attach", "-t=main"}) {
		t.Fatalf("argv = %q", argv)
	}
	want := map[string]string{"CMUX_SOCKET_PATH": "127.0.0.1:62357", "CMUX_SURFACE_ID": "s=1", "TERM": "xterm-ghostty"}
	if !reflect.DeepEqual(environment, want) {
		t.Fatalf("environment = %v, want %v (stop at the empty string)", environment, want)
	}

	// No padding, no environment, and a final string without its NUL.
	data = append(procArgs2(1, "/bin/sh", 0, "sh"), "A=b"...)
	argv, environment, ok = parseDarwinProcArgs(data)
	if !ok || !reflect.DeepEqual(argv, []string{"sh"}) || environment["A"] != "b" || len(environment) != 1 {
		t.Fatalf("argv=%q environment=%v ok=%v", argv, environment, ok)
	}
}

// TestParseDarwinProcArgsRejectsMalformedBuffers refuses truncated or inconsistent buffers.
func TestParseDarwinProcArgsRejectsMalformedBuffers(t *testing.T) {
	for name, data := range map[string][]byte{
		"empty":          nil,
		"short argc":     {1, 0},
		"negative argc":  procArgs2(-1, "/bin/sh", 0, "sh"),
		"unterminated":   binary.NativeEndian.AppendUint32(nil, 1),
		"argv truncated": procArgs2(3, "/bin/sh", 2, "sh", "-c"),
		"path no argv":   append(binary.NativeEndian.AppendUint32(nil, 1), "/bin/sh"...),
	} {
		if _, _, ok := parseDarwinProcArgs(data); ok {
			t.Fatalf("%s: parsed a malformed buffer", name)
		}
	}
}

// TestDarwinProcessTreeReadsLiveProcesses inspects this test and a child it starts, as the hook inspects a tmux client.
func TestDarwinProcessTreeReadsLiveProcesses(t *testing.T) {
	tree := procClaudeProcessTree{}
	if got := tree.argv(os.Getpid()); !reflect.DeepEqual(got, os.Args) {
		t.Fatalf("argv of this process = %q, want %q", got, os.Args)
	}
	if got := tree.parent(os.Getpid()); got != os.Getppid() {
		t.Fatalf("parent of this process = %d, want %d", got, os.Getppid())
	}

	// The child re-runs this test binary: macOS withholds the environment of
	// platform binaries such as /bin/sleep, but not of a tmux client.
	childArgs := []string{os.Args[0], "-test.run=^TestDarwinProcessTreeHelperProcess$"}
	child := exec.Command(childArgs[0], childArgs[1:]...)
	child.Env = []string{"CMUX_DARWIN_PROC_HELPER=1", "CMUX_SOCKET_PATH=127.0.0.1:62357", "CMUX_WORKSPACE_ID=w", "CMUX_SURFACE_ID=s"}
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = child.Process.Kill(); _ = child.Wait() })
	pid := child.Process.Pid
	// The child's arguments appear once it has exec'd.
	deadline := time.Now().Add(5 * time.Second)
	for !reflect.DeepEqual(tree.argv(pid), childArgs) {
		if time.Now().After(deadline) {
			t.Fatalf("argv of child = %q", tree.argv(pid))
		}
		time.Sleep(10 * time.Millisecond)
	}
	if got := tree.parent(pid); got != os.Getpid() {
		t.Fatalf("parent of child = %d, want %d", got, os.Getpid())
	}
	environment := readProcEnviron(pid)
	if environment["CMUX_SOCKET_PATH"] != "127.0.0.1:62357" || environment["CMUX_WORKSPACE_ID"] != "w" || environment["CMUX_SURFACE_ID"] != "s" {
		t.Fatalf("environment of child = %v", environment)
	}

	if tree.parent(-1) != 0 || tree.argv(-1) != nil || readProcEnviron(0) != nil {
		t.Fatal("an invalid pid must report nothing")
	}
}

// TestDarwinProcessTTYMatchesPS names the same controlling terminal as ps.
func TestDarwinProcessTTYMatchesPS(t *testing.T) {
	pid := strconv.Itoa(os.Getpid())
	output, err := exec.Command("/bin/ps", "-o", "tty=", "-p", pid).Output()
	if err != nil {
		t.Skipf("ps: %v", err)
	}
	want := strings.TrimSpace(string(output))
	got := claudeHookProcessTTY(pid)
	if want == "" || want == "??" {
		if got != "" {
			t.Fatalf("tty = %q, want none", got)
		}
		return
	}
	if got != "/dev/"+want {
		t.Fatalf("tty = %q, want /dev/%s", got, want)
	}
	if claudeHookProcessTTY("0") != "" || claudeHookProcessTTY("x") != "" {
		t.Fatal("an invalid pid must have no tty")
	}
}

// TestDarwinProcessTreeHelperProcess is the child process for TestDarwinProcessTreeReadsLiveProcesses.
func TestDarwinProcessTreeHelperProcess(t *testing.T) {
	if os.Getenv("CMUX_DARWIN_PROC_HELPER") != "1" {
		t.Skip("helper process")
	}
	time.Sleep(30 * time.Second)
}
