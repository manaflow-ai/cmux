package state

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

type Entry struct {
	SizeBytes    int64  `json:"sizeBytes"`
	MtimeUnixNs  int64  `json:"mtimeUnixNs"`
	SHA256       string `json:"sha256"`
	RemoteSHA256 string `json:"remoteSha256"`
}

type File struct {
	Entries map[string]Entry `json:"entries"`
}

type Store struct {
	path string
	File
}

func DefaultDir(home string, env map[string]string) (string, error) {
	if dir := strings.TrimSpace(env["CMUX_VAULT_STATE_DIR"]); dir != "" {
		return dir, nil
	}
	if strings.TrimSpace(home) == "" {
		return "", errors.New("home directory is empty")
	}
	return filepath.Join(home, ".local", "state", "cmux-vault"), nil
}

func Load(home string, env map[string]string) (*Store, error) {
	dir, err := DefaultDir(home, env)
	if err != nil {
		return nil, err
	}
	path := filepath.Join(dir, "state.json")
	store := &Store{
		path: path,
		File: File{Entries: map[string]Entry{}},
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return store, nil
		}
		return nil, err
	}
	if len(data) == 0 {
		return store, nil
	}
	if err := json.Unmarshal(data, &store.File); err != nil {
		return nil, err
	}
	if store.Entries == nil {
		store.Entries = map[string]Entry{}
	}
	return store, nil
}

func Key(agent, relPath string) string {
	return strings.TrimSpace(agent) + "\x00" + strings.TrimSpace(relPath)
}

func (s *Store) Save() error {
	if s.Entries == nil {
		s.Entries = map[string]Entry{}
	}
	if err := os.MkdirAll(filepath.Dir(s.path), 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(s.File, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	tmp, err := os.CreateTemp(filepath.Dir(s.path), ".state-*.tmp")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	defer func() {
		_ = os.Remove(tmpPath)
	}()
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmpPath, s.path)
}
