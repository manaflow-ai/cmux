package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestEnsureClaudeNodeOptionsRestoreModuleUsesPrivateRandomDirectory(t *testing.T) {
	first, err := ensureClaudeNodeOptionsRestoreModule()
	if err != nil {
		t.Fatal(err)
	}
	second, err := ensureClaudeNodeOptionsRestoreModule()
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{first, second} {
		t.Cleanup(func() { _ = os.RemoveAll(filepath.Dir(path)) })
		if filepath.Dir(first) == filepath.Dir(second) {
			t.Fatalf("restore module directories are not randomized: %q", filepath.Dir(first))
		}
		info, err := os.Stat(filepath.Dir(path))
		if err != nil {
			t.Fatal(err)
		}
		if mode := info.Mode().Perm(); mode != 0700 {
			t.Fatalf("directory mode = %o, want 700", mode)
		}
		if _, err := os.Stat(path); err != nil {
			t.Fatal(err)
		}
	}
}
