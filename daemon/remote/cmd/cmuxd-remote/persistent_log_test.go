package main

import (
	"bytes"
	"encoding/base64"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestPersistentDaemonLogsConnectionAndPTYLifecycle(t *testing.T) {
	const firstAttachmentToken = "secret-token-must-not-be-logged"
	const secondAttachmentToken = "second-secret-token-must-not-be-logged"
	const firstCommand = "sleep 60"
	const secondCommand = "exit 0"
	const terminalInput = "terminal-input-must-not-be-logged"
	const requestID = "request-id-must-not-be-logged"
	logOutput := newNotifyingBuffer()
	socketPath, stop := startPersistentDaemonWithVerifierAndLogForTest(
		t,
		persistentDaemonFixedTokenVerifier("lifecycle-log-token"),
		logOutput,
	)
	defer stop()

	conn, reader, writer := openPersistentTestClient(t, socketPath, "lifecycle-log-token")
	defer conn.Close()

	attach := persistentTestRPCCall(t, conn, reader, writer, rpcRequest{
		ID:     requestID + "-attach",
		Method: "pty.attach",
		Params: map[string]any{
			"session_id":              "logged-session",
			"attachment_id":           "logged-attachment",
			"client_attachment_token": firstAttachmentToken,
			"cols":                    80,
			"rows":                    24,
			"command":                 firstCommand,
		},
	})
	if ok, _ := attach["ok"].(bool); !ok {
		t.Fatalf("pty.attach failed: %v", attach)
	}
	readPersistentTestEvent(t, conn, reader, func(frame map[string]any) bool {
		return frame["event"] == "pty.ready" && frame["attachment_id"] == "logged-attachment"
	})
	writeResponse := persistentTestRPCCall(t, conn, reader, writer, rpcRequest{
		ID:     requestID + "-write",
		Method: "pty.write",
		Params: map[string]any{
			"session_id":              "logged-session",
			"attachment_id":           "logged-attachment",
			"client_attachment_token": firstAttachmentToken,
			"data_base64":             base64.StdEncoding.EncodeToString([]byte(terminalInput)),
		},
	})
	if ok, _ := writeResponse["ok"].(bool); !ok {
		t.Fatalf("pty.write failed: %v", writeResponse)
	}

	detach := persistentTestRPCCall(t, conn, reader, writer, rpcRequest{
		ID:     requestID + "-detach",
		Method: "pty.detach",
		Params: map[string]any{
			"session_id":              "logged-session",
			"attachment_id":           "logged-attachment",
			"client_attachment_token": firstAttachmentToken,
		},
	})
	if ok, _ := detach["ok"].(bool); !ok {
		t.Fatalf("pty.detach failed: %v", detach)
	}
	closeResponse := persistentTestRPCCall(t, conn, reader, writer, rpcRequest{
		ID:     requestID + "-close",
		Method: "pty.close",
		Params: map[string]any{
			"session_id": "logged-session",
		},
	})
	if ok, _ := closeResponse["ok"].(bool); !ok {
		t.Fatalf("pty.close failed: %v", closeResponse)
	}
	exitingAttach := persistentTestRPCCall(t, conn, reader, writer, rpcRequest{
		ID:     requestID + "-exit",
		Method: "pty.attach",
		Params: map[string]any{
			"session_id":              "logged-exit-session",
			"attachment_id":           "logged-exit-attachment",
			"client_attachment_token": secondAttachmentToken,
			"cols":                    80,
			"rows":                    24,
			"command":                 secondCommand,
		},
	})
	if ok, _ := exitingAttach["ok"].(bool); !ok {
		t.Fatalf("short-lived pty.attach failed: %v", exitingAttach)
	}
	readPersistentTestEvent(t, conn, reader, func(frame map[string]any) bool {
		return frame["event"] == "pty.exit" && frame["session_id"] == "logged-exit-session"
	})

	logged := logOutput.String()
	for _, event := range []string{
		"event=connection_accepted",
		"event=connection_authenticated",
		"event=pty_attach",
		"event=pty_detach",
		"event=pty_close",
		"event=pty_exit",
	} {
		if !strings.Contains(logged, event) {
			t.Fatalf("persistent daemon log = %q, want %q", logged, event)
		}
	}
	for _, secret := range []string{
		firstAttachmentToken,
		secondAttachmentToken,
		firstCommand,
		secondCommand,
		terminalInput,
		requestID,
	} {
		if strings.Contains(logged, secret) {
			t.Fatalf("persistent daemon log exposed sensitive request data %q: %q", secret, logged)
		}
	}
}

func TestPersistentDaemonLogRotationIsSizeBounded(t *testing.T) {
	const maxBytes = int64(220)
	const backups = 2
	logPath := filepath.Join(t.TempDir(), "daemon.log")
	logOutput, err := openPersistentDaemonLogWithLimit(logPath, maxBytes, backups)
	if err != nil {
		t.Fatalf("open persistent daemon log: %v", err)
	}
	for index := 0; index < 12; index++ {
		logPersistentDaemonEvent(
			logOutput,
			"rotation_probe",
			"marker", fmt.Sprintf("event-%02d-%s", index, strings.Repeat("x", 32)),
		)
	}
	if err := logOutput.Close(); err != nil {
		t.Fatalf("close persistent daemon log: %v", err)
	}

	for index, path := range []string{
		logPath,
		persistentDaemonLogBackupPath(logPath, 1),
		persistentDaemonLogBackupPath(logPath, 2),
	} {
		info, err := os.Stat(path)
		if err != nil {
			t.Fatalf("stat log generation %d: %v", index, err)
		}
		if info.Size() > maxBytes {
			t.Fatalf("log generation %d size = %d, want <= %d", index, info.Size(), maxBytes)
		}
		if info.Mode().Perm() != 0o600 {
			t.Fatalf("log generation %d mode = %o, want 600", index, info.Mode().Perm())
		}
	}
	newest, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read newest persistent daemon log: %v", err)
	}
	if !strings.Contains(string(newest), "event-11-") {
		t.Fatalf("newest persistent daemon log lost the latest event: %q", string(newest))
	}
}

func TestPersistentDaemonFaultLogsExcludeRawRequestDetails(t *testing.T) {
	const attachmentToken = "fault-token-must-not-be-logged"
	const command = "fault-command-must-not-be-logged"
	const terminalInput = "fault-input-must-not-be-logged"
	const requestID = "fault-request-id-must-not-be-logged"
	const rawFailure = "raw-failure-detail-must-not-be-logged"

	logOutput := newNotifyingBuffer()
	hub := newWebSocketPTYHub(wsPTYServerConfig{Shell: "/bin/sh"}, logOutput)
	t.Cleanup(hub.closeAll)
	hub.openPTY = func() (*os.File, *os.File, error) {
		return nil, nil, errors.New(rawFailure)
	}
	writer := &captureRPCFrameWriter{}
	server := &rpcServer{ptyHub: hub, frameWriter: writer}
	attachResponse := server.handleRequest(rpcRequest{
		ID:     requestID + "-attach",
		Method: "pty.attach",
		Params: map[string]any{
			"session_id":              "fault-session",
			"attachment_id":           "fault-attachment",
			"client_attachment_token": attachmentToken,
			"cols":                    80,
			"rows":                    24,
			"command":                 command,
		},
	})
	if attachResponse.OK {
		t.Fatalf("pty.attach unexpectedly succeeded: %+v", attachResponse)
	}

	notification := rpcRequest{
		ID:     requestID + "-write",
		Method: "pty.write",
		Params: map[string]any{
			"session_id":              "fault-session",
			"attachment_id":           "fault-attachment",
			"client_attachment_token": attachmentToken,
			"data_base64":             base64.StdEncoding.EncodeToString([]byte(terminalInput)),
		},
	}
	if err := server.handleNotificationResponse(notification, rpcResponse{
		OK: false,
		Error: &rpcError{
			Code:    "pty_input_queue_full",
			Message: rawFailure,
		},
	}); err != nil {
		t.Fatalf("handle notification failure: %v", err)
	}

	logged := logOutput.String()
	for _, event := range []string{
		"event=pty_start_fault",
		"event=pty_attach_failed",
		"event=pty_channel_fault",
	} {
		if !strings.Contains(logged, event) {
			t.Fatalf("persistent daemon log = %q, want %q", logged, event)
		}
	}
	for _, secret := range []string{
		attachmentToken,
		command,
		terminalInput,
		requestID,
		rawFailure,
	} {
		if strings.Contains(logged, secret) {
			t.Fatalf("persistent daemon fault log exposed request data %q: %q", secret, logged)
		}
	}
}

func TestPersistentDaemonProcessOutputUsesRotatingWriter(t *testing.T) {
	const helperEnvironment = "CMUX_TEST_PERSISTENT_PROCESS_OUTPUT"
	const pathEnvironment = "CMUX_TEST_PERSISTENT_PROCESS_LOG_PATH"
	const stdoutSecret = "process-stdout-secret-must-not-be-logged"
	const stderrSecret = "process-stderr-secret-must-not-be-logged"

	if os.Getenv(helperEnvironment) == "1" {
		logOutput, err := openPersistentDaemonLogWithLimit(os.Getenv(pathEnvironment), 512, 2)
		if err != nil {
			t.Fatalf("open helper process log: %v", err)
		}
		route, err := routePersistentDaemonProcessOutput(logOutput)
		if err != nil {
			t.Fatalf("route helper process output: %v", err)
		}
		_, _ = fmt.Fprintln(os.Stdout, stdoutSecret)
		_, _ = fmt.Fprintln(os.Stderr, stderrSecret)
		if err := route.Close(); err != nil {
			t.Fatalf("close helper process output route: %v", err)
		}
		if err := logOutput.Close(); err != nil {
			t.Fatalf("close helper process log: %v", err)
		}
		return
	}

	logPath := filepath.Join(t.TempDir(), "daemon.log")
	command := exec.Command(os.Args[0], "-test.run=^TestPersistentDaemonProcessOutputUsesRotatingWriter$")
	command.Env = append(
		os.Environ(),
		helperEnvironment+"=1",
		pathEnvironment+"="+logPath,
	)
	var output bytes.Buffer
	command.Stdout = &output
	command.Stderr = &output
	if err := command.Run(); err != nil {
		t.Fatalf("process-output helper failed: %v; output=%q", err, output.String())
	}
	logged, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read process-output log: %v", err)
	}
	for _, secret := range []string{stdoutSecret, stderrSecret} {
		if strings.Contains(string(logged), secret) {
			t.Fatalf("process output exposed sensitive content %q: %q", secret, string(logged))
		}
	}
	processOutputBytes := map[string][]int64{}
	for _, line := range strings.Split(string(logged), "\n") {
		if !strings.Contains(line, "event=process_output") {
			continue
		}
		fields := map[string]string{}
		for _, field := range strings.Fields(line) {
			key, value, ok := strings.Cut(field, "=")
			if !ok {
				continue
			}
			if unquoted, err := strconv.Unquote(value); err == nil {
				fields[key] = unquoted
			} else {
				fields[key] = value
			}
		}
		byteCount, err := strconv.ParseInt(fields["bytes"], 10, 64)
		if err != nil || byteCount <= 0 {
			t.Fatalf("process output byte count = %q, want a positive integer: %q", fields["bytes"], line)
		}
		processOutputBytes[fields["stream"]] = append(processOutputBytes[fields["stream"]], byteCount)
	}
	for _, stream := range []string{"stdout", "stderr"} {
		if len(processOutputBytes[stream]) == 0 {
			t.Fatalf("process output metadata missing stream %q: %q", stream, string(logged))
		}
	}
	info, err := os.Stat(logPath)
	if err != nil {
		t.Fatalf("stat process-output log: %v", err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("process-output log mode = %o, want 600", info.Mode().Perm())
	}
}

func TestPersistentDaemonProcessOutputSummaryBatchesReads(t *testing.T) {
	startedAt := time.Unix(100, 0)
	summary := persistentDaemonProcessOutputSummary{minimumInterval: time.Second}

	if byteCount, emit := summary.record(10, startedAt); !emit || byteCount != 10 {
		t.Fatalf("first record = (%d, %t), want (10, true)", byteCount, emit)
	}
	if byteCount, emit := summary.record(20, startedAt.Add(100*time.Millisecond)); emit || byteCount != 0 {
		t.Fatalf("second record = (%d, %t), want (0, false)", byteCount, emit)
	}
	if byteCount, emit := summary.record(30, startedAt.Add(999*time.Millisecond)); emit || byteCount != 0 {
		t.Fatalf("third record = (%d, %t), want (0, false)", byteCount, emit)
	}
	if byteCount, emit := summary.record(40, startedAt.Add(time.Second)); !emit || byteCount != 90 {
		t.Fatalf("interval record = (%d, %t), want (90, true)", byteCount, emit)
	}
	if byteCount, emit := summary.record(50, startedAt.Add(1100*time.Millisecond)); emit || byteCount != 0 {
		t.Fatalf("pending record = (%d, %t), want (0, false)", byteCount, emit)
	}
	if byteCount, emit := summary.flush(startedAt.Add(1200 * time.Millisecond)); !emit || byteCount != 50 {
		t.Fatalf("final flush = (%d, %t), want (50, true)", byteCount, emit)
	}
	if byteCount, emit := summary.flush(startedAt.Add(1300 * time.Millisecond)); emit || byteCount != 0 {
		t.Fatalf("empty flush = (%d, %t), want (0, false)", byteCount, emit)
	}
}

func TestPersistentDaemonProcessOutputRejectsClosedTargetDescriptor(t *testing.T) {
	const helperEnvironment = "CMUX_TEST_PERSISTENT_PROCESS_OUTPUT_CLOSED_FD"
	const targetFD = 1

	if os.Getenv(helperEnvironment) == "1" {
		if err := syscall.Close(targetFD); err != nil {
			t.Fatalf("close target descriptor: %v", err)
		}
		stream, err := routePersistentDaemonProcessOutputStream(
			"stdout",
			targetFD,
			&bytes.Buffer{},
		)
		if stream != nil {
			_ = stream.restoreAndDrain()
			t.Fatal("routing a closed target descriptor unexpectedly succeeded")
		}
		if !errors.Is(err, syscall.EBADF) {
			t.Fatalf("route closed target descriptor error = %v, want EBADF", err)
		}
		duplicate, duplicateErr := syscall.Dup(targetFD)
		if duplicateErr == nil {
			_ = syscall.Close(duplicate)
			t.Fatal("routing failure reopened the closed target descriptor")
		}
		if !errors.Is(duplicateErr, syscall.EBADF) {
			t.Fatalf("duplicate closed target descriptor error = %v, want EBADF", duplicateErr)
		}
		return
	}

	command := exec.Command(
		os.Args[0],
		"-test.run=^TestPersistentDaemonProcessOutputRejectsClosedTargetDescriptor$",
	)
	command.Env = append(os.Environ(), helperEnvironment+"=1")
	var output bytes.Buffer
	command.Stdout = &output
	command.Stderr = &output
	if err := command.Run(); err != nil {
		t.Fatalf("closed-target helper failed: %v; output=%q", err, output.String())
	}
}
