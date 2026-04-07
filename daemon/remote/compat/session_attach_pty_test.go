package compat

import (
	"bytes"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/creack/pty"
)

func TestSessionAttachRoundTripAndReattach(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	socketPath := startUnixDaemon(t, bin)
	openAndSeedCatSession(t, socketPath, "dev", "hello\n")

	cmd := exec.Command(bin, "session", "attach", "dev", "--socket", socketPath)
	cmd.Dir = daemonRemoteRoot()
	ptmx, err := pty.Start(cmd)
	if err != nil {
		t.Fatalf("pty start attach: %v", err)
	}
	defer ptmx.Close()

	writePTY(t, ptmx, "hello\n")
	read1 := readUntilContains(t, ptmx, "hello", 3*time.Second)
	if !strings.Contains(read1, "hello") {
		t.Fatalf("attach output missing hello: %q", read1)
	}

	writePTY(t, ptmx, "\x1c")
	waitForCommandExit(t, cmd, 5*time.Second)

	second := exec.Command(bin, "session", "attach", "dev", "--socket", socketPath)
	second.Dir = daemonRemoteRoot()
	ptmx2, err := pty.Start(second)
	if err != nil {
		t.Fatalf("pty start reattach: %v", err)
	}
	defer ptmx2.Close()

	read2 := readUntilContains(t, ptmx2, "hello", 3*time.Second)
	if !strings.Contains(read2, "hello") {
		t.Fatalf("reattach missing prior output: %q", read2)
	}
}

func TestSessionAttachZshLoginShellStaysAlive(t *testing.T) {
	t.Parallel()

	if _, err := os.Stat("/bin/zsh"); err != nil {
		t.Skip("/bin/zsh not available")
	}

	bin := daemonBinary(t)
	socketPath := startUnixDaemon(t, bin)

	create := exec.Command(
		bin,
		"session", "new", "zsh-login",
		"--socket", socketPath,
		"--detached",
		"--",
		"exec /bin/zsh -l",
	)
	create.Dir = daemonRemoteRoot()
	output, err := create.CombinedOutput()
	if err != nil {
		t.Fatalf("create zsh session: %v\n%s", err, output)
	}

	attach := exec.Command(bin, "session", "attach", "zsh-login", "--socket", socketPath)
	attach.Dir = daemonRemoteRoot()
	ptmx, err := pty.Start(attach)
	if err != nil {
		t.Fatalf("pty start attach: %v", err)
	}
	defer ptmx.Close()

	var buf bytes.Buffer
	done := make(chan error, 1)
	go func() {
		_, copyErr := buf.ReadFrom(ptmx)
		done <- copyErr
	}()

	select {
	case err := <-done:
		t.Fatalf("attach exited unexpectedly: %v\n%s", err, buf.String())
	case <-time.After(2 * time.Second):
	}

	writePTY(t, ptmx, "\x1c")
	waitForCommandExit(t, attach, 5*time.Second)
	if strings.Contains(buf.String(), "UnexpectedEndOfInput") {
		t.Fatalf("attach output contains daemon crash marker: %q", buf.String())
	}
}

func TestSessionAttachPropagatesPTYResize(t *testing.T) {
	bin := daemonBinary(t)
	socketPath := startUnixDaemon(t, bin)

	client := newUnixJSONRPCClient(t, socketPath)

	open := client.Call(t, map[string]any{
		"id":     "1",
		"method": "terminal.open",
		"params": map[string]any{
			"session_id": "resize-dev",
			"command":    "cat",
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
			"session_id":    "resize-dev",
			"attachment_id": attachmentID,
		},
	})
	if ok, _ := detach["ok"].(bool); !ok {
		t.Fatalf("session.detach should succeed: %+v", detach)
	}
	if err := client.Close(); err != nil {
		t.Fatalf("close unix client: %v", err)
	}

	cmd := exec.Command(bin, "session", "attach", "resize-dev", "--socket", socketPath)
	cmd.Dir = daemonRemoteRoot()
	ptmx, err := pty.StartWithSize(cmd, &pty.Winsize{Cols: 132, Rows: 43})
	if err != nil {
		t.Fatalf("pty start attach: %v", err)
	}
	defer ptmx.Close()

	waitForSessionSize(t, bin, socketPath, "resize-dev", 132, 43, 3*time.Second)

	if err := pty.Setsize(ptmx, &pty.Winsize{Cols: 90, Rows: 20}); err != nil {
		t.Fatalf("pty setsize shrink-both: %v", err)
	}
	waitForSessionSize(t, bin, socketPath, "resize-dev", 90, 20, 3*time.Second)

	writePTY(t, ptmx, "\x1c")
	waitForCommandExit(t, cmd, 5*time.Second)
}

func TestSessionAttachSmallestLiveClientWinsAcrossMultipleAttachments(t *testing.T) {
	t.Parallel()

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
			"session_id": "multi-live-size",
			"command":    "cat",
			"cols":       120,
			"rows":       40,
		},
	})
	if ok, _ := open["ok"].(bool); !ok {
		t.Fatalf("terminal.open should succeed: %+v", open)
	}

	for i, attachment := range []struct {
		id   string
		cols int
		rows int
	}{
		{id: "cli-small", cols: 90, rows: 24},
		{id: "cli-large", cols: 160, rows: 50},
	} {
		resp := client.Call(t, map[string]any{
			"id":     strconv.Itoa(i + 2),
			"method": "session.attach",
			"params": map[string]any{
				"session_id":    "multi-live-size",
				"attachment_id": attachment.id,
				"cols":          attachment.cols,
				"rows":          attachment.rows,
			},
		})
		if ok, _ := resp["ok"].(bool); !ok {
			t.Fatalf("session.attach %s should succeed: %+v", attachment.id, resp)
		}
	}

	status := client.Call(t, map[string]any{
		"id":     "4",
		"method": "session.status",
		"params": map[string]any{
			"session_id": "multi-live-size",
		},
	})
	if ok, _ := status["ok"].(bool); !ok {
		t.Fatalf("session.status should succeed: %+v", status)
	}
	result := status["result"].(map[string]any)
	if got := int(result["effective_cols"].(float64)); got != 90 {
		t.Fatalf("effective_cols = %d, want 90 with smaller live client attached: %+v", got, status)
	}
	if got := int(result["effective_rows"].(float64)); got != 24 {
		t.Fatalf("effective_rows = %d, want 24 with smaller live client attached: %+v", got, status)
	}
	if got := len(result["attachments"].([]any)); got != 3 {
		t.Fatalf("attachments = %d, want 3 live clients: %+v", got, status)
	}
}

func TestSessionAttachDetachingSmallestClientLetsSessionGrow(t *testing.T) {
	t.Parallel()

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
			"session_id": "multi-grow-size",
			"command":    "cat",
			"cols":       120,
			"rows":       40,
		},
	})
	if ok, _ := open["ok"].(bool); !ok {
		t.Fatalf("terminal.open should succeed: %+v", open)
	}
	openResult := open["result"].(map[string]any)
	openAttachmentID := openResult["attachment_id"].(string)

	for i, attachment := range []struct {
		id   string
		cols int
		rows int
	}{
		{id: "cli-small", cols: 90, rows: 24},
		{id: "cli-large", cols: 160, rows: 50},
	} {
		resp := client.Call(t, map[string]any{
			"id":     strconv.Itoa(i + 2),
			"method": "session.attach",
			"params": map[string]any{
				"session_id":    "multi-grow-size",
				"attachment_id": attachment.id,
				"cols":          attachment.cols,
				"rows":          attachment.rows,
			},
		})
		if ok, _ := resp["ok"].(bool); !ok {
			t.Fatalf("session.attach %s should succeed: %+v", attachment.id, resp)
		}
	}

	detachSmall := client.Call(t, map[string]any{
		"id":     "4",
		"method": "session.detach",
		"params": map[string]any{
			"session_id":    "multi-grow-size",
			"attachment_id": "cli-small",
		},
	})
	if ok, _ := detachSmall["ok"].(bool); !ok {
		t.Fatalf("session.detach cli-small should succeed: %+v", detachSmall)
	}

	statusAfterSmall := client.Call(t, map[string]any{
		"id":     "5",
		"method": "session.status",
		"params": map[string]any{
			"session_id": "multi-grow-size",
		},
	})
	if ok, _ := statusAfterSmall["ok"].(bool); !ok {
		t.Fatalf("session.status after cli-small detach should succeed: %+v", statusAfterSmall)
	}
	resultAfterSmall := statusAfterSmall["result"].(map[string]any)
	if got := int(resultAfterSmall["effective_cols"].(float64)); got != 120 {
		t.Fatalf("effective_cols = %d, want 120 after smallest detach: %+v", got, statusAfterSmall)
	}
	if got := int(resultAfterSmall["effective_rows"].(float64)); got != 40 {
		t.Fatalf("effective_rows = %d, want 40 after smallest detach: %+v", got, statusAfterSmall)
	}

	detachOpen := client.Call(t, map[string]any{
		"id":     "6",
		"method": "session.detach",
		"params": map[string]any{
			"session_id":    "multi-grow-size",
			"attachment_id": openAttachmentID,
		},
	})
	if ok, _ := detachOpen["ok"].(bool); !ok {
		t.Fatalf("session.detach %s should succeed: %+v", openAttachmentID, detachOpen)
	}

	statusAfterOpen := client.Call(t, map[string]any{
		"id":     "7",
		"method": "session.status",
		"params": map[string]any{
			"session_id": "multi-grow-size",
		},
	})
	if ok, _ := statusAfterOpen["ok"].(bool); !ok {
		t.Fatalf("session.status after open attachment detach should succeed: %+v", statusAfterOpen)
	}
	resultAfterOpen := statusAfterOpen["result"].(map[string]any)
	if got := int(resultAfterOpen["effective_cols"].(float64)); got != 160 {
		t.Fatalf("effective_cols = %d, want 160 after only large client remains: %+v", got, statusAfterOpen)
	}
	if got := int(resultAfterOpen["effective_rows"].(float64)); got != 50 {
		t.Fatalf("effective_rows = %d, want 50 after only large client remains: %+v", got, statusAfterOpen)
	}
}

func TestSessionAttachResizeDeliversSigwinch(t *testing.T) {
	t.Parallel()

	if _, err := os.Stat("/bin/zsh"); err != nil {
		t.Skip("/bin/zsh not available")
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
			"session_id": "resize-sigwinch",
			"command":    `exec /bin/zsh -lc 'print -r -- READY:$(stty size); trap '\''print -r -- WINCH:$(stty size)'\'' WINCH; while true; do sleep 1; done'`,
			"cols":       80,
			"rows":       24,
		},
	})
	if ok, _ := open["ok"].(bool); !ok {
		t.Fatalf("terminal.open should succeed: %+v", open)
	}
	result := open["result"].(map[string]any)
	attachmentID := result["attachment_id"].(string)

	output, offset := waitForTerminalReadContains(t, client, "resize-sigwinch", 0, "READY:24 80", 3*time.Second)
	if !strings.Contains(output, "READY:24 80") {
		t.Fatalf("terminal did not report initial stty size: %q", output)
	}

	resize := client.Call(t, map[string]any{
		"id":     "2",
		"method": "session.resize",
		"params": map[string]any{
			"session_id":    "resize-sigwinch",
			"attachment_id": attachmentID,
			"cols":          120,
			"rows":          40,
		},
	})
	if ok, _ := resize["ok"].(bool); !ok {
		t.Fatalf("session.resize should succeed: %+v", resize)
	}

	output, _ = waitForTerminalReadContains(t, client, "resize-sigwinch", offset, "WINCH:40 120", 3*time.Second)
	if !strings.Contains(output, "WINCH:40 120") {
		t.Fatalf("terminal did not receive SIGWINCH resize notice: %q", output)
	}
}

func TestSessionAttachDetachesCleanlyWithExistingAttachment(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	socketPath := startUnixDaemon(t, bin)

	client := newUnixJSONRPCClient(t, socketPath)
	open := client.Call(t, map[string]any{
		"id":     "1",
		"method": "terminal.open",
		"params": map[string]any{
			"session_id": "multi-attach-dev",
			"command":    "cat",
			"cols":       80,
			"rows":       24,
		},
	})
	if ok, _ := open["ok"].(bool); !ok {
		t.Fatalf("terminal.open should succeed: %+v", open)
	}
	if err := client.Close(); err != nil {
		t.Fatalf("close unix client: %v", err)
	}

	cmd := exec.Command(bin, "session", "attach", "multi-attach-dev", "--socket", socketPath)
	cmd.Dir = daemonRemoteRoot()
	ptmx, err := pty.Start(cmd)
	if err != nil {
		t.Fatalf("pty start attach: %v", err)
	}
	defer ptmx.Close()

	writePTY(t, ptmx, "hello\n")
	read := readUntilContains(t, ptmx, "hello", 3*time.Second)
	if !strings.Contains(read, "hello") {
		t.Fatalf("attach output missing hello: %q", read)
	}

	writePTY(t, ptmx, "\x1c")
	waitForCommandExit(t, cmd, 5*time.Second)
}

func writePTY(t *testing.T, ptmx *os.File, text string) {
	t.Helper()
	if _, err := ptmx.WriteString(text); err != nil {
		t.Fatalf("write pty: %v", err)
	}
}

func readUntilContains(t *testing.T, ptmx *os.File, want string, timeout time.Duration) string {
	t.Helper()

	ensurePTYNonblocking(t, ptmx)
	deadline := time.Now().Add(timeout)
	var out strings.Builder
	buf := make([]byte, 4096)
	for time.Now().Before(deadline) {
		n, err := readPTYChunk(ptmx, buf)
		if n > 0 {
			out.Write(buf[:n])
			if strings.Contains(out.String(), want) {
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

func ensurePTYNonblocking(t *testing.T, ptmx *os.File) {
	t.Helper()
	if err := syscall.SetNonblock(int(ptmx.Fd()), true); err != nil {
		t.Fatalf("set pty nonblocking: %v", err)
	}
}

func readPTYChunk(ptmx *os.File, buf []byte) (int, error) {
	ready, err := pollPTYReadable(int(ptmx.Fd()), 20*time.Millisecond)
	if err != nil {
		if err == syscall.EINTR {
			return 0, nil
		}
		return 0, err
	}
	if !ready {
		return 0, nil
	}
	n, err := syscall.Read(int(ptmx.Fd()), buf)
	if err == nil || err == syscall.EAGAIN || err == syscall.EWOULDBLOCK || err == syscall.EINTR {
		return n, nil
	}
	return n, err
}

func waitForSessionSize(t *testing.T, bin, socketPath, sessionID string, cols, rows int, timeout time.Duration) {
	t.Helper()

	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		gotCols, gotRows, err := sessionStatusDims(bin, socketPath, sessionID)
		if err == nil && gotCols == cols && gotRows == rows {
			return
		}
		time.Sleep(50 * time.Millisecond)
	}

	gotCols, gotRows, err := sessionStatusDims(bin, socketPath, sessionID)
	if err != nil {
		t.Fatalf("session size did not reach %dx%d: %v", cols, rows, err)
	}
	t.Fatalf("session size did not reach %dx%d: got %dx%d", cols, rows, gotCols, gotRows)
}

func waitForTerminalReadContains(t *testing.T, client *unixJSONRPCClient, sessionID string, offset uint64, want string, timeout time.Duration) (string, uint64) {
	t.Helper()

	deadline := time.Now().Add(timeout)
	var out strings.Builder
	currentOffset := offset
	for time.Now().Before(deadline) {
		read := client.Call(t, map[string]any{
			"id":     "read",
			"method": "terminal.read",
			"params": map[string]any{
				"session_id": sessionID,
				"offset":     currentOffset,
				"max_bytes":  32 * 1024,
				"timeout_ms": 200,
			},
		})
		if ok, _ := read["ok"].(bool); !ok {
			if errPayload, _ := read["error"].(map[string]any); errPayload != nil {
				if code, _ := errPayload["code"].(string); code == "deadline_exceeded" {
					time.Sleep(50 * time.Millisecond)
					continue
				}
			}
			t.Fatalf("terminal.read should succeed: %+v", read)
		}
		result := read["result"].(map[string]any)
		chunk := string(decodeBase64Field(t, result, "data"))
		if chunk != "" {
			out.WriteString(chunk)
		}
		if next, ok := result["offset"].(float64); ok {
			currentOffset = uint64(next)
		}
		if strings.Contains(out.String(), want) {
			return out.String(), currentOffset
		}
		time.Sleep(50 * time.Millisecond)
	}

	return out.String(), currentOffset
}

func waitForCommandExit(t *testing.T, cmd *exec.Cmd, timeout time.Duration) {
	t.Helper()

	done := make(chan error, 1)
	go func() {
		done <- cmd.Wait()
	}()

	select {
	case <-done:
	case <-time.After(timeout):
		_ = cmd.Process.Kill()
		<-done
		t.Fatalf("command did not exit within %s", timeout)
	}
}

func sessionStatusDims(bin, socketPath, sessionID string) (int, int, error) {
	cmd := exec.Command(bin, "session", "status", sessionID, "--socket", socketPath)
	cmd.Dir = daemonRemoteRoot()
	output, err := cmd.CombinedOutput()
	if err != nil {
		return 0, 0, err
	}

	fields := strings.Fields(strings.TrimSpace(string(output)))
	if len(fields) < 2 {
		return 0, 0, exec.ErrNotFound
	}
	dims := strings.SplitN(fields[1], "x", 2)
	if len(dims) != 2 {
		return 0, 0, exec.ErrNotFound
	}

	cols, err := strconv.Atoi(dims[0])
	if err != nil {
		return 0, 0, err
	}
	rows, err := strconv.Atoi(dims[1])
	if err != nil {
		return 0, 0, err
	}
	return cols, rows, nil
}
