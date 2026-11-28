package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestEnsureClaudeNodeOptionsRestoreModuleLivesInPrivateHomeDirectory(t *testing.T) {
	home := filepath.Join(t.TempDir(), "home with space")
	t.Setenv("HOME", home)
	t.Setenv("TMPDIR", t.TempDir())

	path, err := ensureClaudeNodeOptionsRestoreModule()
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(home, ".cmuxterm", "cmux-claude-node-options", "restore-node-options.cjs")
	if path != want {
		t.Fatalf("restore module path = %q, want %q", path, want)
	}
	info, err := os.Stat(filepath.Dir(path))
	if err != nil {
		t.Fatal(err)
	}
	if mode := info.Mode().Perm(); mode != 0700 {
		t.Fatalf("directory mode = %o, want 700", mode)
	}
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != claudeNodeOptionsRestoreModuleScript {
		t.Fatalf("restore module content mismatch")
	}
	// Concurrent launches share this file, so loading it must not delete it.
	if strings.Contains(claudeNodeOptionsRestoreModuleScript, "unlinkSync") ||
		strings.Contains(claudeNodeOptionsRestoreModuleScript, "rmdirSync") {
		t.Fatalf("restore module deletes itself; a concurrent launch would lose it")
	}

	// Reuse is stable across launches, so a purged TMPDIR cannot strand it.
	again, err := ensureClaudeNodeOptionsRestoreModule()
	if err != nil {
		t.Fatal(err)
	}
	if again != path {
		t.Fatalf("second restore module path = %q, want %q", again, path)
	}

	if got, want := mergeNodeOptions("", path), `--require="`+path+`" --max-old-space-size=4096`; got != want {
		t.Fatalf("mergeNodeOptions with spaced path = %q, want %q", got, want)
	}
}

func TestEnsureClaudeNodeOptionsRestoreModuleRefusesSymlinkedDirectory(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	target := t.TempDir()
	if err := os.MkdirAll(filepath.Join(home, ".cmuxterm"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(target, filepath.Join(home, ".cmuxterm", "cmux-claude-node-options")); err != nil {
		t.Fatal(err)
	}
	if path, err := ensureClaudeNodeOptionsRestoreModule(); err == nil {
		t.Fatalf("expected symlinked directory to be refused, got %q", path)
	}
	if _, err := os.Stat(filepath.Join(target, "restore-node-options.cjs")); !os.IsNotExist(err) {
		t.Fatalf("restore module was written through the symlink: %v", err)
	}
}
