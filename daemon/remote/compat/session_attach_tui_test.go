package compat

import (
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"github.com/creack/pty"
)

func TestSessionAttachTUIResizeAndReattach(t *testing.T) {
	if _, err := exec.LookPath("python3"); err != nil {
		t.Skip("python3 not available")
	}

	bin := daemonBinary(t)
	socketPath := startUnixDaemon(t, bin)
	client := newUnixJSONRPCClient(t, socketPath)
	defer func() {
		if err := client.Close(); err != nil {
			t.Fatalf("close unix client: %v", err)
		}
	}()

	open := client.Call(t, map[string]any{
		"id":     "1",
		"method": "terminal.open",
		"params": map[string]any{
			"session_id": "tui-attach",
			"command":    "/usr/bin/env python3 -u " + fixturePath(t, "fake_tui.py"),
			"cols":       80,
			"rows":       24,
		},
	})
	if ok, _ := open["ok"].(bool); !ok {
		t.Fatalf("terminal.open should succeed: %+v", open)
	}
	result := open["result"].(map[string]any)
	attachmentID := result["attachment_id"].(string)

	detach := client.Call(t, map[string]any{
		"id":     "2",
		"method": "session.detach",
		"params": map[string]any{
			"session_id":    "tui-attach",
			"attachment_id": attachmentID,
		},
	})
	if ok, _ := detach["ok"].(bool); !ok {
		t.Fatalf("session.detach should succeed: %+v", detach)
	}

	cmd := exec.Command(bin, "session", "attach", "tui-attach", "--socket", socketPath)
	cmd.Dir = daemonRemoteRoot()
	ptmx, err := pty.StartWithSize(cmd, &pty.Winsize{Cols: 80, Rows: 24})
	if err != nil {
		t.Fatalf("pty start attach: %v", err)
	}
	defer ptmx.Close()

	output := readUntilContainsAll(t, ptmx, 3*time.Second, "FAKE-TUI 24 80", "Press q to quit")
	if !containsAll(output, "FAKE-TUI 24 80", "Press q to quit") {
		t.Fatalf("initial tui attach output missing expected markers: %q", output)
	}

	writePTY(t, ptmx, "abc")
	output = readUntilContains(t, ptmx, "INPUT abc", 3*time.Second)
	if !containsAll(output, "INPUT abc") {
		t.Fatalf("tui attach output missing typed input: %q", output)
	}

	if err := pty.Setsize(ptmx, &pty.Winsize{Cols: 91, Rows: 31}); err != nil {
		t.Fatalf("pty setsize: %v", err)
	}
	waitForSessionSize(t, bin, socketPath, "tui-attach", 91, 31, 3*time.Second)
	output = readUntilContainsAll(t, ptmx, 3*time.Second, "FAKE-TUI 31 91", "INPUT abc")
	if !containsAll(output, "FAKE-TUI 31 91", "INPUT abc") {
		t.Fatalf("tui resize did not repaint expected markers: %q", output)
	}

	writePTY(t, ptmx, "\x1c")
	waitForCommandExit(t, cmd, 5*time.Second)

	second := exec.Command(bin, "session", "attach", "tui-attach", "--socket", socketPath)
	second.Dir = daemonRemoteRoot()
	ptmx2, err := pty.StartWithSize(second, &pty.Winsize{Cols: 91, Rows: 31})
	if err != nil {
		t.Fatalf("pty start reattach: %v", err)
	}
	defer ptmx2.Close()

	output = readUntilContainsAll(t, ptmx2, 3*time.Second, "FAKE-TUI 31 91", "INPUT abc")
	if !containsAll(output, "FAKE-TUI 31 91", "INPUT abc") {
		t.Fatalf("reattach output missing expected markers: %q", output)
	}

	writePTY(t, ptmx2, "q\n")
	waitForCommandExit(t, second, 5*time.Second)
}

func containsAll(haystack string, needles ...string) bool {
	for _, needle := range needles {
		if !strings.Contains(haystack, needle) {
			return false
		}
	}
	return true
}

func readUntilContainsAll(t *testing.T, ptmx *os.File, timeout time.Duration, needles ...string) string {
	t.Helper()

	ensurePTYNonblocking(t, ptmx)
	deadline := time.Now().Add(timeout)
	var out strings.Builder
	buf := make([]byte, 4096)
	for time.Now().Before(deadline) {
		n, err := readPTYChunk(ptmx, buf)
		if n > 0 {
			out.Write(buf[:n])
			if containsAll(out.String(), needles...) {
				return out.String()
			}
		}
		if err != nil {
			t.Fatalf("read pty: %v", err)
		}
		time.Sleep(20 * time.Millisecond)
	}

	return out.String()
}
