package compat

import (
	"encoding/base64"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/creack/pty"
)

func TestSessionCLIListAndHistory(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	socketPath := startUnixDaemon(t, bin)

	openAndSeedCatSession(t, socketPath, "dev", "hello\n")

	listCmd := exec.Command(bin, "session", "ls", "--socket", socketPath)
	listCmd.Dir = daemonRemoteRoot()
	listOutput, err := listCmd.CombinedOutput()
	if err != nil {
		t.Fatalf("session ls failed: %v\n%s", err, listOutput)
	}
	listText := string(listOutput)
	if !strings.Contains(listText, "session dev 80x24 attachments=1") {
		t.Fatalf("session ls missing summary: %s", listOutput)
	}
	if !strings.Contains(listText, "└── att-1 80x24") {
		t.Fatalf("session ls missing attachment detail: %s", listOutput)
	}

	historyCmd := exec.Command(bin, "session", "history", "dev", "--socket", socketPath)
	historyCmd.Dir = daemonRemoteRoot()
	historyOutput, err := historyCmd.CombinedOutput()
	if err != nil {
		t.Fatalf("session history failed: %v\n%s", err, historyOutput)
	}
	if !strings.Contains(string(historyOutput), "hello") {
		t.Fatalf("session history missing hello: %s", historyOutput)
	}
}

func TestSessionCLIListAlias(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	socketPath := startUnixDaemon(t, bin)

	openAndSeedCatSession(t, socketPath, "dev", "")

	listCmd := exec.Command(bin, "session", "list", "--socket", socketPath)
	listCmd.Dir = daemonRemoteRoot()
	listOutput, err := listCmd.CombinedOutput()
	if err != nil {
		t.Fatalf("session list failed: %v\n%s", err, listOutput)
	}
	if !strings.Contains(string(listOutput), "session dev 80x24 attachments=1") {
		t.Fatalf("session list missing formatted dev entry: %s", listOutput)
	}
}

func TestSessionCLIListUsesEnvSocket(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	socketPath := startUnixDaemon(t, bin)

	openAndSeedCatSession(t, socketPath, "env-dev", "")

	listCmd := exec.Command(bin, "session", "list")
	listCmd.Dir = daemonRemoteRoot()
	listCmd.Env = append(os.Environ(), "CMUXD_UNIX_PATH="+socketPath)
	listOutput, err := listCmd.CombinedOutput()
	if err != nil {
		t.Fatalf("session list with env socket failed: %v\n%s", err, listOutput)
	}
	if !strings.Contains(string(listOutput), "session env-dev 80x24 attachments=1") {
		t.Fatalf("session list with env socket missing env-dev summary: %s", listOutput)
	}
}

func TestSessionCLITopLevelListAlias(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	socketPath := startUnixDaemon(t, bin)

	openAndSeedCatSession(t, socketPath, "top-dev", "")

	listCmd := exec.Command(bin, "list", "--socket", socketPath)
	listCmd.Dir = daemonRemoteRoot()
	listOutput, err := listCmd.CombinedOutput()
	if err != nil {
		t.Fatalf("top-level list failed: %v\n%s", err, listOutput)
	}
	if !strings.Contains(string(listOutput), "session top-dev 80x24 attachments=1") {
		t.Fatalf("top-level list missing top-dev summary: %s", listOutput)
	}
}

func TestSessionCLITopLevelListUsesEnvSocket(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	socketPath := startUnixDaemon(t, bin)

	openAndSeedCatSession(t, socketPath, "env-top-dev", "")

	listCmd := exec.Command(bin, "list")
	listCmd.Dir = daemonRemoteRoot()
	listCmd.Env = append(os.Environ(), "CMUXD_UNIX_PATH="+socketPath)
	listOutput, err := listCmd.CombinedOutput()
	if err != nil {
		t.Fatalf("top-level list with env socket failed: %v\n%s", err, listOutput)
	}
	if !strings.Contains(string(listOutput), "session env-top-dev 80x24 attachments=1") {
		t.Fatalf("top-level list with env socket missing env-top-dev summary: %s", listOutput)
	}
}

func TestSessionCLITopLevelStatusUsesEnvSocket(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	socketPath := startUnixDaemon(t, bin)

	openAndSeedCatSession(t, socketPath, "status-env-dev", "")

	statusCmd := exec.Command(bin, "status", "status-env-dev")
	statusCmd.Dir = daemonRemoteRoot()
	statusCmd.Env = append(os.Environ(), "CMUXD_UNIX_PATH="+socketPath)
	statusOutput, err := statusCmd.CombinedOutput()
	if err != nil {
		t.Fatalf("top-level status with env socket failed: %v\n%s", err, statusOutput)
	}
	if strings.TrimSpace(string(statusOutput)) != "status-env-dev 80x24" {
		t.Fatalf("top-level status with env socket output = %q, want %q", strings.TrimSpace(string(statusOutput)), "status-env-dev 80x24")
	}
}

func TestSessionCLITopLevelHistoryUsesEnvSocket(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	socketPath := startUnixDaemon(t, bin)

	openAndSeedCatSession(t, socketPath, "history-env-dev", "hello\n")

	historyCmd := exec.Command(bin, "history", "history-env-dev")
	historyCmd.Dir = daemonRemoteRoot()
	historyCmd.Env = append(os.Environ(), "CMUXD_UNIX_PATH="+socketPath)
	historyOutput, err := historyCmd.CombinedOutput()
	if err != nil {
		t.Fatalf("top-level history with env socket failed: %v\n%s", err, historyOutput)
	}
	if !strings.Contains(string(historyOutput), "hello") {
		t.Fatalf("top-level history with env socket missing hello: %s", historyOutput)
	}
}

func TestSessionCLINewQuietDetachedSuppressesSessionID(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	socketPath := startUnixDaemon(t, bin)

	newCmd := exec.Command(bin, "session", "new", "quiet-dev", "--socket", socketPath, "--quiet", "--detached", "--", "cat")
	newCmd.Dir = daemonRemoteRoot()
	newOutput, err := newCmd.CombinedOutput()
	if err != nil {
		t.Fatalf("session new --quiet --detached failed: %v\n%s", err, newOutput)
	}
	if strings.TrimSpace(string(newOutput)) != "" {
		t.Fatalf("session new --quiet should not print session id: %q", string(newOutput))
	}

	listCmd := exec.Command(bin, "session", "ls", "--socket", socketPath)
	listCmd.Dir = daemonRemoteRoot()
	listOutput, err := listCmd.CombinedOutput()
	if err != nil {
		t.Fatalf("session ls failed: %v\n%s", err, listOutput)
	}
	if !strings.Contains(string(listOutput), "session quiet-dev 80x24 [detached]") {
		t.Fatalf("session ls missing quiet-dev detached entry: %s", listOutput)
	}
}

func TestSessionCLINewDropsBootstrapAttachmentAfterAttach(t *testing.T) {
	t.Parallel()

	bin := daemonBinary(t)
	socketPath := startUnixDaemon(t, bin)
	client := newUnixJSONRPCClient(t, socketPath)
	defer func() {
		if err := client.Close(); err != nil {
			t.Fatalf("close unix client: %v", err)
		}
	}()

	cmd := exec.Command(
		bin,
		"session", "new", "grow-dev",
		"--socket", socketPath,
		"--quiet",
		"--",
		"printf READY; exec cat",
	)
	cmd.Dir = daemonRemoteRoot()
	ptmx, err := pty.StartWithSize(cmd, &pty.Winsize{Cols: 90, Rows: 24})
	if err != nil {
		t.Fatalf("pty start session new: %v", err)
	}
	defer ptmx.Close()

	output := readUntilContains(t, ptmx, "READY", 3*time.Second)
	if !strings.Contains(output, "READY") {
		t.Fatalf("session new output missing READY: %q", output)
	}

	status := client.Call(t, map[string]any{
		"id":     "1",
		"method": "session.status",
		"params": map[string]any{
			"session_id": "grow-dev",
		},
	})
	if ok, _ := status["ok"].(bool); !ok {
		t.Fatalf("session.status should succeed: %+v", status)
	}
	result := status["result"].(map[string]any)
	attachments := result["attachments"].([]any)
	if len(attachments) != 1 {
		t.Fatalf("expected exactly one live attachment after session new handoff, got %+v", attachments)
	}
	attachmentID := attachments[0].(map[string]any)["attachment_id"].(string)
	if strings.HasPrefix(attachmentID, "att-") {
		t.Fatalf("expected bootstrap attachment to be dropped, got %+v", attachments)
	}

	if err := pty.Setsize(ptmx, &pty.Winsize{Cols: 140, Rows: 40}); err != nil {
		t.Fatalf("pty setsize grow: %v", err)
	}
	waitForSessionSize(t, bin, socketPath, "grow-dev", 140, 40, 3*time.Second)

	writePTY(t, ptmx, "\x1c")
	waitForCommandExit(t, cmd, 5*time.Second)
}

func TestSessionCLIListShowsMultipleAttachments(t *testing.T) {
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
			"session_id": "tree-dev",
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
				"session_id":    "tree-dev",
				"attachment_id": attachment.id,
				"cols":          attachment.cols,
				"rows":          attachment.rows,
			},
		})
		if ok, _ := resp["ok"].(bool); !ok {
			t.Fatalf("session.attach %s should succeed: %+v", attachment.id, resp)
		}
	}

	listCmd := exec.Command(bin, "list", "--socket", socketPath)
	listCmd.Dir = daemonRemoteRoot()
	listOutput, err := listCmd.CombinedOutput()
	if err != nil {
		t.Fatalf("top-level list failed: %v\n%s", err, listOutput)
	}

	listText := string(listOutput)
	if !strings.Contains(listText, "session tree-dev 90x24 attachments=3") {
		t.Fatalf("list missing tree-dev summary: %s", listOutput)
	}
	for _, want := range []string{
		"att-1 120x40",
		"cli-large 160x50",
		"cli-small 90x24",
	} {
		if !strings.Contains(listText, want) {
			t.Fatalf("list missing attachment detail %q: %s", want, listOutput)
		}
	}
}

func openAndSeedCatSession(t *testing.T, socketPath, sessionID, text string) {
	t.Helper()

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
			"session_id": sessionID,
			"command":    "cat",
			"cols":       80,
			"rows":       24,
		},
	})
	if ok, _ := open["ok"].(bool); !ok {
		t.Fatalf("terminal.open should succeed: %+v", open)
	}

	if text == "" {
		return
	}

	write := client.Call(t, map[string]any{
		"id":     "2",
		"method": "terminal.write",
		"params": map[string]any{
			"session_id": sessionID,
			"data":       base64.StdEncoding.EncodeToString([]byte(text)),
		},
	})
	if ok, _ := write["ok"].(bool); !ok {
		t.Fatalf("terminal.write should succeed: %+v", write)
	}

	_ = client.Call(t, map[string]any{
		"id":     "3",
		"method": "terminal.read",
		"params": map[string]any{
			"session_id": sessionID,
			"offset":     0,
			"max_bytes":  len(text) * 2,
			"timeout_ms": int((2 * time.Second).Milliseconds()),
		},
	})
}
