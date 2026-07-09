package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestOmoEnsurePluginInvalidJSONErrorDoesNotExposeUserPath(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	userDir := filepath.Join(home, ".config", "opencode")
	if err := os.MkdirAll(userDir, 0755); err != nil {
		t.Fatalf("failed to create user config dir: %v", err)
	}
	userJSONPath := filepath.Join(userDir, "opencode.json")
	if err := os.WriteFile(userJSONPath, []byte("{"), 0644); err != nil {
		t.Fatalf("failed to write invalid config: %v", err)
	}

	err := omoEnsurePlugin(os.Getenv("PATH"))
	if err == nil {
		t.Fatal("omoEnsurePlugin returned nil for invalid opencode.json")
	}

	msg := err.Error()
	if strings.Contains(msg, home) || strings.Contains(msg, userJSONPath) {
		t.Fatalf("error %q exposes user config path %q", msg, userJSONPath)
	}
	if !strings.Contains(msg, "invalid opencode.json") {
		t.Fatalf("error = %q, want generic invalid opencode.json message", msg)
	}
}

func TestOmoSlimEnsurePluginInvalidJSONErrorDoesNotExposeUserPath(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	userDir := filepath.Join(home, ".config", "opencode")
	if err := os.MkdirAll(userDir, 0755); err != nil {
		t.Fatalf("failed to create user config dir: %v", err)
	}
	userJSONPath := filepath.Join(userDir, "opencode.json")
	if err := os.WriteFile(userJSONPath, []byte("{"), 0644); err != nil {
		t.Fatalf("failed to write invalid config: %v", err)
	}

	err := omoSlimEnsurePlugin(os.Getenv("PATH"))
	if err == nil {
		t.Fatal("omoSlimEnsurePlugin returned nil for invalid opencode.json")
	}

	msg := err.Error()
	if strings.Contains(msg, home) || strings.Contains(msg, userJSONPath) {
		t.Fatalf("error %q exposes user config path %q", msg, userJSONPath)
	}
	if !strings.Contains(msg, "invalid opencode.json") {
		t.Fatalf("error = %q, want generic invalid opencode.json message", msg)
	}
}

func TestOmoSlimEnsurePluginConfiguresShadowTmuxMultiplexer(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("OPENCODE_CONFIG_DIR", "")

	userDir := filepath.Join(home, ".config", "opencode")
	pluginDir := filepath.Join(userDir, "node_modules", omoSlimPluginName)
	if err := os.MkdirAll(pluginDir, 0755); err != nil {
		t.Fatalf("failed to create plugin dir: %v", err)
	}
	userConfig := filepath.Join(userDir, "opencode.json")
	if err := os.WriteFile(userConfig, []byte(`{"plugin":["existing","oh-my-opencode","oh-my-openagent"]}`), 0644); err != nil {
		t.Fatalf("failed to write user config: %v", err)
	}

	if err := omoSlimEnsurePlugin(os.Getenv("PATH")); err != nil {
		t.Fatalf("omoSlimEnsurePlugin returned error: %v", err)
	}

	shadowDir := omoSlimShadowConfigDir()
	if got := os.Getenv("OPENCODE_CONFIG_DIR"); got != shadowDir {
		t.Fatalf("OPENCODE_CONFIG_DIR = %q, want %q", got, shadowDir)
	}

	var openCodeConfig map[string]any
	data, err := os.ReadFile(filepath.Join(shadowDir, "opencode.json"))
	if err != nil {
		t.Fatalf("read shadow opencode.json: %v", err)
	}
	if err := json.Unmarshal(data, &openCodeConfig); err != nil {
		t.Fatalf("parse shadow opencode.json: %v", err)
	}
	plugins, _ := openCodeConfig["plugin"].([]any)
	if !stringSliceContainsAny(plugins, "existing") || !stringSliceContainsAny(plugins, omoSlimPluginName) {
		t.Fatalf("shadow plugin list = %#v, want existing and %s", plugins, omoSlimPluginName)
	}
	if stringSliceContainsAny(plugins, "oh-my-opencode") || stringSliceContainsAny(plugins, "oh-my-openagent") {
		t.Fatalf("shadow plugin list = %#v, want full OMO plugins removed", plugins)
	}

	var slimConfig map[string]any
	data, err = os.ReadFile(filepath.Join(shadowDir, "oh-my-opencode-slim.json"))
	if err != nil {
		t.Fatalf("read slim config: %v", err)
	}
	if err := json.Unmarshal(data, &slimConfig); err != nil {
		t.Fatalf("parse slim config: %v", err)
	}
	muxConfig, _ := slimConfig["multiplexer"].(map[string]any)
	if muxConfig["type"] != "tmux" {
		t.Fatalf("multiplexer.type = %#v, want tmux", muxConfig["type"])
	}
	if muxConfig["layout"] != "main-vertical" {
		t.Fatalf("multiplexer.layout = %#v, want main-vertical", muxConfig["layout"])
	}
	if muxConfig["main_pane_size"] != float64(60) {
		t.Fatalf("multiplexer.main_pane_size = %#v, want 60", muxConfig["main_pane_size"])
	}

	var manifest map[string]any
	data, err = os.ReadFile(filepath.Join(shadowDir, "package.json"))
	if err != nil {
		t.Fatalf("read shadow package.json: %v", err)
	}
	if err := json.Unmarshal(data, &manifest); err != nil {
		t.Fatalf("parse shadow package.json: %v", err)
	}
	if manifest["name"] != "cmux-omo-slim-shadow" {
		t.Fatalf("shadow package name = %#v, want cmux-omo-slim-shadow", manifest["name"])
	}
}

func TestOpenCodeRelayLaunchArgsUsesConfiguredDefaultPort(t *testing.T) {
	t.Setenv("OPENCODE_PORT", "")

	got := openCodeRelayLaunchArgs([]string{"--continue"}, "4097")
	want := []string{"--port", "4097", "--continue"}
	if strings.Join(got, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("launch args = %#v, want %#v", got, want)
	}
}

func TestOpenCodeRelayLaunchArgsPreservesExplicitPort(t *testing.T) {
	t.Setenv("OPENCODE_PORT", "")

	got := openCodeRelayLaunchArgs([]string{"--port", "5010", "--continue"}, "4097")
	want := []string{"--port", "5010", "--continue"}
	if strings.Join(got, "\x00") != strings.Join(want, "\x00") {
		t.Fatalf("launch args = %#v, want %#v", got, want)
	}
}

func TestOpenCodeRelayEffectivePortUsesExplicitPort(t *testing.T) {
	t.Setenv("OPENCODE_PORT", "")

	if got := openCodeRelayEffectivePort([]string{"--port", "5010"}, "4097"); got != "5010" {
		t.Fatalf("effective port = %q, want 5010", got)
	}
	if got := openCodeRelayEffectivePort([]string{"--port=5011"}, "4097"); got != "5011" {
		t.Fatalf("effective port = %q, want 5011", got)
	}
}

func TestConfigureOMOSlimPluginReadsJSONC(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	userDir := filepath.Join(home, ".config", "opencode")
	shadowDir := omoSlimShadowConfigDir()
	if err := os.MkdirAll(userDir, 0755); err != nil {
		t.Fatalf("create user dir: %v", err)
	}
	if err := os.MkdirAll(shadowDir, 0755); err != nil {
		t.Fatalf("create shadow dir: %v", err)
	}
	jsonc := `{
	  // Preserve user settings while cmux adds multiplexer defaults.
	  "custom": "kept",
	  "multiplexer": {
	    "layout": "even-horizontal"
	  }
	}`
	if err := os.WriteFile(filepath.Join(userDir, "oh-my-opencode-slim.jsonc"), []byte(jsonc), 0644); err != nil {
		t.Fatalf("write user jsonc: %v", err)
	}

	if err := configureOMOSlimPlugin(shadowDir); err != nil {
		t.Fatalf("configureOMOSlimPlugin: %v", err)
	}

	var slimConfig map[string]any
	data, err := os.ReadFile(filepath.Join(shadowDir, "oh-my-opencode-slim.json"))
	if err != nil {
		t.Fatalf("read generated slim config: %v", err)
	}
	if err := json.Unmarshal(data, &slimConfig); err != nil {
		t.Fatalf("parse generated slim config: %v", err)
	}
	if slimConfig["custom"] != "kept" {
		t.Fatalf("custom = %#v, want kept", slimConfig["custom"])
	}
	muxConfig, _ := slimConfig["multiplexer"].(map[string]any)
	if muxConfig["layout"] != "even-horizontal" {
		t.Fatalf("multiplexer.layout = %#v, want preserved even-horizontal", muxConfig["layout"])
	}
	if muxConfig["type"] != "tmux" {
		t.Fatalf("multiplexer.type = %#v, want tmux", muxConfig["type"])
	}
}

func stringSliceContainsAny(values []any, needle string) bool {
	for _, value := range values {
		if s, ok := value.(string); ok && s == needle {
			return true
		}
	}
	return false
}
