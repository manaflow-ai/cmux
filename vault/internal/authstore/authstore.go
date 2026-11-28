package authstore

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

type Tokens struct {
	AccessToken  string `json:"accessToken"`
	RefreshToken string `json:"refreshToken"`
}

func DefaultDir(home string, env map[string]string) (string, error) {
	if dir := strings.TrimSpace(env["CMUX_VAULT_CONFIG_DIR"]); dir != "" {
		return dir, nil
	}
	if strings.TrimSpace(home) == "" {
		return "", errors.New("home directory is empty")
	}
	return filepath.Join(home, ".config", "cmux-vault"), nil
}

func path(home string, env map[string]string) (string, error) {
	dir, err := DefaultDir(home, env)
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "auth.json"), nil
}

func Load(home string, env map[string]string) (*Tokens, error) {
	path, err := path(home, env)
	if err != nil {
		return nil, err
	}
	data, err := os.ReadFile(path)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	var tokens Tokens
	if err := json.Unmarshal(data, &tokens); err != nil {
		return nil, err
	}
	if strings.TrimSpace(tokens.AccessToken) == "" || strings.TrimSpace(tokens.RefreshToken) == "" {
		return nil, nil
	}
	return &tokens, nil
}

func Save(home string, env map[string]string, tokens Tokens) error {
	path, err := path(home, env)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(tokens, "", "  ")
	if err != nil {
		return err
	}
	data = append(data, '\n')
	tmp, err := os.CreateTemp(filepath.Dir(path), ".auth-*.tmp")
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
	return os.Rename(tmpPath, path)
}

func Delete(home string, env map[string]string) error {
	path, err := path(home, env)
	if err != nil {
		return err
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}
