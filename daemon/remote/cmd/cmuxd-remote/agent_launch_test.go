package main

import (
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

func TestOpenCodeNativeLaunchArgs(t *testing.T) {
	t.Setenv("OPENCODE_PORT", "")
	port := openCodeNativeEffectivePort(nil)
	if parsed, err := strconv.Atoi(port); err != nil || parsed <= 0 {
		t.Fatalf("expected an available numeric port, got %q", port)
	}
	if got := openCodeNativeLaunchArgs([]string{"--continue"}, port); !reflect.DeepEqual(got, []string{"--port", port, "--continue"}) {
		t.Fatalf("unexpected launch args: %v", got)
	}
	if got := openCodeNativeLaunchArgs([]string{"--port=5000"}, port); !reflect.DeepEqual(got, []string{"--port=5000"}) {
		t.Fatalf("explicit port changed: %v", got)
	}
}

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
