package main

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestOmoShadowConfigOwnsPrivateCopies(t *testing.T) {
	for _, linkKind := range []string{"absent", "regular", "symlink", "hardlink"} {
		for _, configured := range []bool{false, true} {
			name := linkKind + "/missing-settings"
			if configured {
				name = linkKind + "/already-configured"
			}
			t.Run(name, func(t *testing.T) {
				t.Setenv("HOME", t.TempDir())
				t.Setenv("OPENCODE_CONFIG_DIR", "")
				userDir := omoUserConfigDir()
				if err := os.MkdirAll(filepath.Join(userDir, "node_modules", omoPluginName), 0700); err != nil {
					t.Fatal(err)
				}
				shadowDir := omoShadowConfigDir()
				if err := os.MkdirAll(shadowDir, 0755); err != nil {
					t.Fatal(err)
				}
				if err := os.Chmod(shadowDir, 0755); err != nil {
					t.Fatal(err)
				}
				omoJSON := `{"provider":{"apiKey":"fixture-omo-secret"},"tmux":{"enabled":false,"main_pane_size":65}}`
				if configured {
					omoJSON = `{"provider":{"apiKey":"fixture-omo-secret"},"tmux":{"enabled":true,"main_pane_min_width":72,"agent_pane_min_width":36,"main_pane_size":65}}`
				}
				originals := map[string]string{
					"opencode.json":       `{"provider":{"test":{"options":{"apiKey":"fixture-opencode-secret"}}},"plugin":["fixture-plugin"]}`,
					"oh-my-opencode.json": omoJSON,
				}
				originalInfos := map[string]os.FileInfo{}
				for filename, data := range originals {
					userPath := filepath.Join(userDir, filename)
					shadowPath := filepath.Join(shadowDir, filename)
					if err := os.WriteFile(userPath, []byte(data), 0640); err != nil {
						t.Fatal(err)
					}
					if err := os.Chmod(userPath, 0640); err != nil {
						t.Fatal(err)
					}
					info, err := os.Stat(userPath)
					if err != nil {
						t.Fatal(err)
					}
					originalInfos[filename] = info
					switch linkKind {
					case "absent":
					case "symlink":
						err = os.Symlink(userPath, shadowPath)
					case "hardlink":
						err = os.Link(userPath, shadowPath)
					default:
						err = os.WriteFile(shadowPath, []byte(data), 0644)
						if err == nil {
							err = os.Chmod(shadowPath, 0644)
						}
					}
					if err != nil {
						t.Fatal(err)
					}
				}

				if err := omoEnsurePlugin(""); err != nil {
					t.Fatal(err)
				}
				if got := os.Getenv("OPENCODE_CONFIG_DIR"); got != shadowDir {
					t.Fatalf("config directory = %q, want %q", got, shadowDir)
				}
				info, err := os.Stat(shadowDir)
				if err != nil || info.Mode().Perm() != 0700 {
					t.Fatalf("shadow directory is not private: %v, %v", info, err)
				}
				for filename := range originals {
					shadowPath := filepath.Join(shadowDir, filename)
					info, err := os.Lstat(shadowPath)
					if err != nil {
						t.Fatal(err)
					}
					if !info.Mode().IsRegular() || info.Mode().Perm() != 0600 {
						t.Errorf("shadow %s mode = %v, want a regular 0600 file", filename, info.Mode())
					}
					if os.SameFile(info, originalInfos[filename]) {
						t.Errorf("shadow %s still shares the user's file", filename)
					}
					data, err := os.ReadFile(shadowPath)
					if err != nil {
						t.Fatal(err)
					}
					var config map[string]any
					if err := json.Unmarshal(data, &config); err != nil {
						t.Fatal(err)
					}
					secret := "fixture-opencode-secret"
					if filename == "oh-my-opencode.json" {
						secret = "fixture-omo-secret"
					}
					if !bytes.Contains(data, []byte(secret)) || config["provider"] == nil {
						t.Errorf("shadow %s lost provider configuration", filename)
					}
					if filename == "oh-my-opencode.json" {
						tmux, _ := config["tmux"].(map[string]any)
						mainWidth, agentWidth := float64(60), float64(30)
						if configured {
							mainWidth, agentWidth = 72, 36
						}
						if tmux["enabled"] != true || tmux["main_pane_min_width"] != mainWidth || tmux["agent_pane_min_width"] != agentWidth || tmux["main_pane_size"] != float64(65) {
							t.Errorf("shadow tmux configuration = %v", tmux)
						}
					}
					// Consumers may update the shadow later; those writes must also
					// leave the user's original contents and permissions untouched.
					if err := os.WriteFile(shadowPath, []byte(`{"shadow":"changed"}`), 0600); err != nil {
						t.Fatal(err)
					}
				}
				for filename, original := range originals {
					userPath := filepath.Join(userDir, filename)
					data, err := os.ReadFile(userPath)
					if err != nil || string(data) != original {
						t.Errorf("user %s changed: %q, %v", filename, data, err)
					}
					info, err := os.Stat(userPath)
					if err != nil {
						t.Fatal(err)
					}
					if !os.SameFile(info, originalInfos[filename]) || info.Mode().Perm() != 0640 {
						t.Errorf("user %s identity or permissions changed: %v", filename, info)
					}
				}
			})
		}
	}
}

func TestOmoShadowConfigRejectsSymlinkDirectory(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	userDir := omoUserConfigDir()
	if err := os.MkdirAll(userDir, 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(userDir, 0755); err != nil {
		t.Fatal(err)
	}
	userPath := filepath.Join(userDir, "opencode.json")
	original := `{"provider":{"apiKey":"fixture-secret"}}`
	if err := os.WriteFile(userPath, []byte(original), 0600); err != nil {
		t.Fatal(err)
	}
	shadowDir := omoShadowConfigDir()
	if err := os.MkdirAll(filepath.Dir(shadowDir), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(userDir, shadowDir); err != nil {
		t.Fatal(err)
	}
	if err := omoEnsurePlugin(""); err == nil {
		t.Fatal("accepted symlinked shadow config directory")
	}
	data, err := os.ReadFile(userPath)
	if err != nil || string(data) != original {
		t.Fatalf("user config changed: %q, %v", data, err)
	}
	info, err := os.Stat(userDir)
	if err != nil || info.Mode().Perm() != 0755 {
		t.Fatalf("user directory permissions changed: %v, %v", info, err)
	}
}

func TestOmoShadowConfigPrivateAfterInstallFailure(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	t.Setenv("OPENCODE_CONFIG_DIR", "")
	userDir := omoUserConfigDir()
	shadowDir := omoShadowConfigDir()
	for _, dir := range []string{userDir, shadowDir} {
		if err := os.MkdirAll(dir, 0700); err != nil {
			t.Fatal(err)
		}
	}
	original := `{"provider":{"apiKey":"fixture-secret"}}`
	for _, filename := range []string{"opencode.json", "oh-my-opencode.json"} {
		userPath := filepath.Join(userDir, filename)
		if err := os.WriteFile(userPath, []byte(original), 0600); err != nil {
			t.Fatal(err)
		}
		if err := os.Link(userPath, filepath.Join(shadowDir, filename)); err != nil {
			t.Fatal(err)
		}
	}
	if err := omoEnsurePlugin(""); err == nil || !strings.Contains(err.Error(), "neither bun nor npm") {
		t.Fatalf("expected unavailable installer, got %v", err)
	}
	for _, filename := range []string{"opencode.json", "oh-my-opencode.json"} {
		userPath := filepath.Join(userDir, filename)
		userInfo, err := os.Stat(userPath)
		if err != nil {
			t.Fatal(err)
		}
		shadowInfo, err := os.Lstat(filepath.Join(shadowDir, filename))
		if err != nil {
			t.Fatal(err)
		}
		if !shadowInfo.Mode().IsRegular() || shadowInfo.Mode().Perm() != 0600 || os.SameFile(userInfo, shadowInfo) {
			t.Errorf("shadow %s was not detached privately before installation", filename)
		}
		data, err := os.ReadFile(userPath)
		if err != nil || string(data) != original {
			t.Errorf("user %s changed after failed installation: %q, %v", filename, data, err)
		}
	}
}
