package main

import (
	"context"
	"crypto/sha256"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestRestoredCloudBridgeIsPrivate(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	path := makeShortUnixSocketPath(t)
	if err := newCloudCLIBridge().start(ctx, path, io.Discard); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if info.Mode().Perm() != 0600 {
		t.Fatalf("bridge socket mode = %o, want 600", info.Mode().Perm())
	}
}

func TestRestoredWaitSignalRejectsSymlink(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	name := fmt.Sprintf("review-%x", sha256.Sum256([]byte(home)))
	path, err := tmuxWaitForSignalPath(name)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Remove(path) })
	victim := filepath.Join(home, "must-not-change")
	if err := os.WriteFile(victim, []byte("preserve me"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(victim, path); err != nil {
		t.Fatal(err)
	}
	if err := tmuxWaitFor(nil, []string{"-S", name}); err == nil {
		t.Error("signal creation accepted a symlink")
	}
	data, err := os.ReadFile(victim)
	if err != nil || string(data) != "preserve me" {
		t.Fatalf("signal creation changed the symlink target: %q, %v", data, err)
	}
}

func TestRestoredOMOInfoDoesNotInstallPlugin(t *testing.T) {
	if arg := os.Getenv("CMUX_TEST_OMO_NON_LAUNCH_ARG"); arg != "" {
		os.Exit(runOMORelay("", []string{arg}, nil))
	}
	for _, arg := range []string{"--help", "models"} {
		t.Run(arg, func(t *testing.T) {
			home := t.TempDir()
			bin := t.TempDir()
			writeAgentLaunchTestExecutable(t, filepath.Join(bin, "opencode"), "#!/bin/sh\nprintf 'OMO_INFO_OK\\n'\n")
			command := exec.Command(os.Args[0], "-test.run=^TestRestoredOMOInfoDoesNotInstallPlugin$")
			command.Env = append(os.Environ(), "HOME="+home, "PATH="+bin, "CMUX_TEST_OMO_NON_LAUNCH_ARG="+arg)
			output, err := command.CombinedOutput()
			if err != nil || !strings.Contains(string(output), "OMO_INFO_OK") {
				t.Fatalf("informational invocation needed plugin installation: %v\n%s", err, output)
			}
		})
	}
}

func TestWaitSignalIsPrivateAndDoesNotTruncateExistingSignal(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	path, err := tmuxWaitForSignalPath("private-signal")
	if err != nil {
		t.Fatal(err)
	}
	if err := createTmuxWaitForSignal(path); err != nil {
		t.Fatal(err)
	}
	for _, item := range []struct {
		path string
		mode os.FileMode
	}{{filepath.Dir(path), 0700}, {path, 0600}} {
		info, err := os.Stat(item.path)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm() != item.mode {
			t.Fatalf("mode %o, want %o", info.Mode().Perm(), item.mode)
		}
	}
	if err := os.WriteFile(path, []byte("already signaled"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := createTmuxWaitForSignal(path); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(path)
	if err != nil || string(data) != "already signaled" {
		t.Fatalf("existing signal changed: %q, %v", data, err)
	}
	if err := tmuxWaitFor(nil, []string{"private-signal"}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Lstat(path); !os.IsNotExist(err) {
		t.Fatalf("signal not consumed: %v", err)
	}
}

func TestWaitSignalRejectsSymlinkedParent(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := os.Symlink(t.TempDir(), filepath.Join(home, ".cmux")); err != nil {
		t.Fatal(err)
	}
	if _, err := tmuxWaitForSignalPath("unsafe-parent"); err == nil {
		t.Fatal("accepted symlinked parent")
	}
}

func TestCurrentWorkspaceEnvironmentUsesFallbackInsteadOfRecursing(t *testing.T) {
	t.Setenv("CMUX_WORKSPACE_ID", "current")
	rc := &rpcContext{socketPath: filepath.Join(t.TempDir(), "unavailable.sock")}
	if _, err := tmuxResolveWorkspaceId(rc, "current"); err == nil || !strings.Contains(err.Error(), "no workspace selected") {
		t.Fatalf("expected normal workspace lookup failure, got %v", err)
	}
}

func TestAdminLeaseIgnoresRetiredRPCClientPayload(t *testing.T) {
	leasePath := filepath.Join(t.TempDir(), "lease.json")
	sum := sha256.Sum256([]byte("admin-token"))
	handler := newWebSocketPTYHandler(wsPTYServerConfig{
		PTYAuthLeaseFile: leasePath,
		AdminTokenSHA256: fmt.Sprintf("%x", sum),
	}, io.Discard)
	request := httptest.NewRequest(http.MethodPost, "/admin/leases", strings.NewReader(`{"pty_lease":{"version":1},"rpc_client":0}`))
	request.Header.Set("Authorization", "Bearer admin-token")
	response := httptest.NewRecorder()
	handler.ServeHTTP(response, request)
	if response.Code != http.StatusOK {
		t.Fatalf("lease install failed: %d %s", response.Code, response.Body.String())
	}
	if _, err := os.Stat(leasePath); err != nil {
		t.Fatal(err)
	}
}
