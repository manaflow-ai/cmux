package main

import (
	"context"
	"crypto/sha256"
	"fmt"
	"io"
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
	path := tmuxWaitForSignalPath(name)
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
