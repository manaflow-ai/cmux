package state

import (
	"os"
	"path/filepath"
	"testing"
)

func TestStoreRoundTripAndAtomicWrite(t *testing.T) {
	home := t.TempDir()
	env := map[string]string{"CMUX_VAULT_STATE_DIR": filepath.Join(home, "state")}
	store, err := Load(home, env)
	if err != nil {
		t.Fatal(err)
	}
	store.Entries[Key("codex", "sessions/a.jsonl")] = Entry{
		SizeBytes:    12,
		MtimeUnixNs:  34,
		SHA256:       "abc",
		RemoteSHA256: "abc",
	}
	if err := store.Save(); err != nil {
		t.Fatal(err)
	}
	store.Entries[Key("codex", "sessions/a.jsonl")] = Entry{
		SizeBytes:    56,
		MtimeUnixNs:  78,
		SHA256:       "def",
		RemoteSHA256: "def",
	}
	if err := store.Save(); err != nil {
		t.Fatal(err)
	}

	loaded, err := Load(home, env)
	if err != nil {
		t.Fatal(err)
	}
	got := loaded.Entries[Key("codex", "sessions/a.jsonl")]
	if got.SizeBytes != 56 || got.MtimeUnixNs != 78 || got.SHA256 != "def" || got.RemoteSHA256 != "def" {
		t.Fatalf("round trip entry = %#v", got)
	}
	matches, err := filepath.Glob(filepath.Join(home, "state", ".state-*.tmp"))
	if err != nil {
		t.Fatal(err)
	}
	if len(matches) != 0 {
		t.Fatalf("temporary files left behind: %#v", matches)
	}
	info, err := os.Stat(filepath.Join(home, "state", "state.json"))
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %v", info.Mode().Perm())
	}
}
