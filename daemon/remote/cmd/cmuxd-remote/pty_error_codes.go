package main

import (
	"context"
	"errors"
	"strings"
)

// PTY error codes are part of the app/daemon wire contract. Keep the human
// message separate: clients use these values for retry/respawn decisions.
const (
	remotePTYTimeoutCode         = "remote_pty_timeout"
	remoteConnectionInactiveCode = "remote_connection_inactive"
	ptySessionNotFoundCode       = "pty_session_not_found"
	ptyStartFailedCode           = "pty_start_failed"
	ptyInputQueueFullCode        = "pty_input_queue_full"
	ptyInputSeqGapCode           = "pty_input_seq_gap"
)

func ptyAttachErrorMessage(err error) string {
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return "RPC connection closed before PTY attachment completed"
	}
	if err == nil {
		return "RPC connection closed before PTY attachment completed"
	}
	return err.Error()
}

func ptyAttachErrorCode(err error, requireExisting bool) string {
	if err == nil {
		return remoteConnectionInactiveCode
	}
	if errors.Is(err, errWSPTYStartOwnersSaturated) ||
		errors.Is(err, errWSPTYStartWaitersSaturated) {
		return "unavailable"
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return remotePTYTimeoutCode
	}
	if errors.Is(err, context.Canceled) || errors.Is(err, errWSPTYHubClosed) {
		return remoteConnectionInactiveCode
	}

	lowered := strings.ToLower(strings.TrimSpace(errString(err)))
	if (strings.Contains(lowered, "persistent pty session") ||
		strings.Contains(lowered, "persistent ssh pty session")) &&
		(strings.Contains(lowered, "not running") || strings.Contains(lowered, "not found")) {
		return ptySessionNotFoundCode
	}
	// `require_existing` has historically used the session-not-found code for
	// any non-transient attach rejection. Preserve that wire contract for older
	// clients; transient context errors were handled above.
	if requireExisting {
		return ptySessionNotFoundCode
	}
	return ptyStartFailedCode
}

func errString(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}
