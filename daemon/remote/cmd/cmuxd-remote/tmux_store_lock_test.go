package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestTmuxCompatStoreRejectsSymlinkedLock(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	directory := filepath.Dir(tmuxCompatStoreURL())
	if err := os.MkdirAll(directory, 0700); err != nil {
		t.Fatal(err)
	}
	victim := filepath.Join(t.TempDir(), "victim")
	if err := os.WriteFile(victim, []byte("untouched"), 0644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(victim, tmuxCompatStoreURL()+".lock"); err != nil {
		t.Fatal(err)
	}
	called := false
	err := withLockedTmuxCompatStore(func(store *tmuxCompatStore) error {
		called = true
		store.Buffers["unsafe"] = "payload"
		return nil
	})
	if err == nil || called {
		t.Fatalf("symlinked lock accepted: err=%v mutation=%v", err, called)
	}
	data, err := os.ReadFile(victim)
	if err != nil || string(data) != "untouched" {
		t.Fatalf("lock target changed: %q, %v", data, err)
	}
	info, err := os.Stat(victim)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0644 {
		t.Fatalf("lock target permissions changed: %o", info.Mode().Perm())
	}
	if _, err := os.Stat(tmuxCompatStoreURL()); !os.IsNotExist(err) {
		t.Fatalf("store was created despite unsafe lock: %v", err)
	}
}
