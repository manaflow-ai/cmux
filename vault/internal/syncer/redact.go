package syncer

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
)

// RedactBinName is the filter that masks known secret shapes (cmux-tui/crates/cmux-redact).
// It reads a transcript on stdin and writes it masked to stdout, one line at a time.
const RedactBinName = "cmux-redact"

// ErrRedactorMissing means redaction is on but the filter cannot be found. Sync refuses to
// upload raw transcripts in that case; the caller passes --no-redact to opt out on purpose.
var ErrRedactorMissing = errors.New("cmux-redact not found")

// Redactor runs the Rust masker as a child process over a transcript.
type Redactor struct {
	Path string
}

// FindRedactor locates the filter: $CMUX_VAULT_REDACT_BIN, then next to this executable, then PATH.
func FindRedactor(getenv func(string) string) (*Redactor, error) {
	if p := getenv("CMUX_VAULT_REDACT_BIN"); p != "" {
		if _, err := os.Stat(p); err != nil {
			return nil, fmt.Errorf("%w: CMUX_VAULT_REDACT_BIN=%s: %v", ErrRedactorMissing, p, err)
		}
		return &Redactor{Path: p}, nil
	}
	if exe, err := os.Executable(); err == nil {
		sibling := filepath.Join(filepath.Dir(exe), RedactBinName)
		if info, err := os.Stat(sibling); err == nil && !info.IsDir() {
			return &Redactor{Path: sibling}, nil
		}
	}
	if p, err := exec.LookPath(RedactBinName); err == nil {
		return &Redactor{Path: p}, nil
	}
	return nil, fmt.Errorf("%w: install it next to cmux-vault or on PATH, or pass --no-redact to upload transcripts as they are", ErrRedactorMissing)
}

// Filter returns a reader of in's masked bytes. close waits for the child and reports a failed
// exit: a truncated masked stream must fail the upload, never ship.
func (r *Redactor) Filter(ctx context.Context, in io.Reader) (out io.Reader, closeFn func() error, err error) {
	cmd := exec.CommandContext(ctx, r.Path)
	cmd.Stdin = in
	cmd.Stderr = io.Discard
	pipe, err := cmd.StdoutPipe()
	if err != nil {
		return nil, nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, nil, err
	}
	return pipe, func() error {
		if err := cmd.Wait(); err != nil {
			return fmt.Errorf("%s failed: %w", RedactBinName, err)
		}
		return nil
	}, nil
}
