package main

import (
	"context"
	"fmt"
	"testing"
)

func TestPTYAttachErrorCodeUsesStableFailureCategories(t *testing.T) {
	tests := []struct {
		name            string
		err             error
		requireExisting bool
		want            string
	}{
		{
			name: "deadline is timeout",
			err:  context.DeadlineExceeded,
			want: "remote_pty_timeout",
		},
		{
			name: "cancellation is inactive connection",
			err:  context.Canceled,
			want: "remote_connection_inactive",
		},
		{
			name:            "missing required session is session not found",
			err:             fmt.Errorf("persistent PTY session %q is not running", "session-1"),
			requireExisting: true,
			want:            "pty_session_not_found",
		},
		{
			name:            "other required-session failure keeps legacy session code",
			err:             fmt.Errorf("PTY allocation failed"),
			requireExisting: true,
			want:            "pty_session_not_found",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if got := ptyAttachErrorCode(test.err, test.requireExisting); got != test.want {
				t.Fatalf("ptyAttachErrorCode() = %q, want %q", got, test.want)
			}
		})
	}
}
