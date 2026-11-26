package syncer

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/manaflow-ai/cmux/vault/internal/agentdirs"
)

func redactSession(t *testing.T, content []byte) (agentdirs.Session, string) {
	t.Helper()
	home := t.TempDir()
	rel := filepath.Join("sessions", "2026", "07", "04", "rollout-2026-07-04T00-00-00-11111111-1111-4111-8111-111111111111.jsonl")
	path := filepath.Join(home, ".codex", rel)
	writeTestFile(t, path, content)
	return agentdirs.Session{
		AgentName:      "codex",
		AgentSessionID: "11111111-1111-4111-8111-111111111111",
		AbsPath:        path,
		RelPath:        filepath.ToSlash(rel),
		SizeBytes:      int64(len(content)),
		ModTime:        time.Now(),
	}, filepath.Join(home, "tmp")
}

func writeFilter(t *testing.T, body string) *Redactor {
	t.Helper()
	path := filepath.Join(t.TempDir(), "fake-redact")
	if err := os.WriteFile(path, []byte("#!/bin/sh\n"+body+"\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	return &Redactor{Path: path}
}

// The token is built at run time so no scanner flags this file.
func TestCompressFileUploadsTheMaskedBytes(t *testing.T) {
	token := "gh" + "p_" + strings.Repeat("aZ3kQ9mX7p", 4)
	session, tmp := redactSession(t, []byte(`{"m":"token `+token+`"}`+"\n"))
	redactor := writeFilter(t, `sed 's/gh[p]_[A-Za-z0-9]*/[masked]/g'`)
	result, err := compressFile(session, tmp, redactor)
	if err != nil {
		t.Fatal(err)
	}
	raw, err := os.ReadFile(result.path)
	if err != nil {
		t.Fatal(err)
	}
	got := decompressZstd(t, raw)
	if bytes.Contains(got, []byte(token)) || !bytes.Contains(got, []byte("[masked]")) {
		t.Fatalf("uploaded bytes are not masked: %s", got)
	}
	if result.plainSize != int64(len(got)) {
		t.Fatalf("size %d is not the masked size %d", result.plainSize, len(got))
	}
}

func TestCompressFileFailsWhenTheFilterFails(t *testing.T) {
	session, tmp := redactSession(t, []byte("{}\n"))
	if _, err := compressFile(session, tmp, writeFilter(t, "cat >/dev/null; exit 3")); err == nil {
		t.Fatal("a failing filter must fail the upload, not ship partial bytes")
	}
	if _, err := compressFile(session, tmp, &Redactor{Path: "/nonexistent/cmux-redact"}); err == nil {
		t.Fatal("a missing filter binary must fail")
	}
}

func TestFindRedactorMissingIsAnError(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	_, err := FindRedactor(func(string) string { return "" })
	if !errors.Is(err, ErrRedactorMissing) {
		t.Fatalf("got %v", err)
	}
}
