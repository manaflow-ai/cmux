package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestClaudeTeamsShellSnapshotKeepsManagedTmuxAheadOfRebuiltPath(t *testing.T) {
	if os.Getenv("CMUX_TEST_CLAUDE_TEAMS_RELAY") == "1" {
		code := runClaudeTeamsRelay(
			os.Getenv("CMUX_TEST_CLAUDE_TEAMS_SOCKET"),
			[]string{"--version"},
			nil,
		)
		os.Exit(code)
	}

	socketPath, _ := startAgentLaunchContextSocket(t, true)
	root := t.TempDir()
	home := filepath.Join(root, "home")
	agentBin := filepath.Join(root, "agent-bin")
	profileBin := filepath.Join(root, "profile-bin")
	for _, directory := range []string{home, agentBin, profileBin} {
		if err := os.MkdirAll(directory, 0755); err != nil {
			t.Fatal(err)
		}
	}

	snapshotPathLog := filepath.Join(root, "snapshot-path.log")
	resolvedTmuxLog := filepath.Join(root, "resolved-tmux.log")
	originalShell := filepath.Join(root, "profile-shell")
	writeAgentLaunchTestExecutable(t, originalShell, `#!/bin/sh
set -eu
if [ "${1:-}" != "-lic" ]; then
  echo "unexpected shell argv: $*" >&2
  exit 64
fi
shift
PATH="$CMUX_TEST_PROFILE_BIN:/usr/bin:/bin"
export PATH
exec /bin/sh -c "$1"
`)
	writeAgentLaunchTestExecutable(t, filepath.Join(profileBin, "tmux"), `#!/bin/sh
exit 0
`)
	writeAgentLaunchTestExecutable(t, filepath.Join(agentBin, "claude"), `#!/bin/sh
set -eu
"$SHELL" -lic 'printf "%s\n" "$PATH" > "$CMUX_TEST_SNAPSHOT_PATH_LOG"'
PATH="$(cat "$CMUX_TEST_SNAPSHOT_PATH_LOG")"
export PATH
command -v tmux > "$CMUX_TEST_RESOLVED_TMUX_LOG"
`)

	command := exec.Command(os.Args[0], "-test.run=^TestClaudeTeamsShellSnapshotKeepsManagedTmuxAheadOfRebuiltPath$")
	command.Env = append(os.Environ(),
		"CMUX_TEST_CLAUDE_TEAMS_RELAY=1",
		"CMUX_TEST_CLAUDE_TEAMS_SOCKET="+socketPath,
		"CMUX_TEST_PROFILE_BIN="+profileBin,
		"CMUX_TEST_SNAPSHOT_PATH_LOG="+snapshotPathLog,
		"CMUX_TEST_RESOLVED_TMUX_LOG="+resolvedTmuxLog,
		"CMUX_WORKSPACE_ID="+agentLaunchTestWorkspaceId,
		"CMUX_SURFACE_ID="+agentLaunchTestSurfaceId,
		"HOME="+home,
		"PATH="+agentBin+":"+profileBin+":/usr/bin:/bin",
		"SHELL="+originalShell,
	)
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("remote claude-teams relay failed: %v\n%s", err, output)
	}

	resolvedBytes, err := os.ReadFile(resolvedTmuxLog)
	if err != nil {
		t.Fatal(err)
	}
	resolvedTmux := strings.TrimSpace(string(resolvedBytes))
	wantTmux := filepath.Join(home, ".cmuxterm", "claude-teams-bin", "tmux")
	if resolvedTmux != wantTmux {
		snapshotBytes, _ := os.ReadFile(snapshotPathLog)
		t.Fatalf("snapshot resolved tmux = %q, want %q; PATH=%q", resolvedTmux, wantTmux, strings.TrimSpace(string(snapshotBytes)))
	}
}

func TestClaudeTeamsShellWrapperUsesFishSyntaxWithoutChangingShellIdentity(t *testing.T) {
	fishPath, err := exec.LookPath("fish")
	if err != nil {
		t.Skip("fish is not installed")
	}

	root := t.TempDir()
	shimDir := filepath.Join(root, "claude-teams-bin")
	profileBin := filepath.Join(root, "profile-bin")
	configDir := filepath.Join(root, "config", "fish")
	for _, directory := range []string{shimDir, profileBin, configDir} {
		if err := os.MkdirAll(directory, 0755); err != nil {
			t.Fatal(err)
		}
	}
	writeAgentLaunchTestExecutable(t, filepath.Join(shimDir, "tmux"), "#!/bin/sh\nexit 0\n")
	if err := os.WriteFile(
		filepath.Join(configDir, "config.fish"),
		[]byte(`set -gx PATH "$CMUX_TEST_PROFILE_BIN" /usr/bin /bin`+"\n"),
		0644,
	); err != nil {
		t.Fatal(err)
	}

	t.Setenv("SHELL", fishPath)
	t.Setenv("CMUX_CLAUDE_TEAMS_ORIGINAL_SHELL", "")
	t.Setenv("CMUX_CLAUDE_TEAMS_SHIM_DIR", "")
	t.Setenv("CMUX_TEST_PROFILE_BIN", profileBin)
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(root, "config"))
	if err := configureClaudeTeamsShellWrapper(shimDir); err != nil {
		t.Fatal(err)
	}
	wrapperPath := os.Getenv("SHELL")
	if filepath.Base(wrapperPath) != filepath.Base(fishPath) {
		t.Fatalf("wrapper shell name = %q, want %q", filepath.Base(wrapperPath), filepath.Base(fishPath))
	}

	command := exec.Command(wrapperPath, "-lc", "command -v tmux")
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("fish shell wrapper failed: %v\n%s", err, output)
	}
	if resolved := strings.TrimSpace(string(output)); resolved != filepath.Join(shimDir, "tmux") {
		t.Fatalf("fish shell wrapper resolved tmux = %q", resolved)
	}
}

func writeAgentLaunchTestExecutable(t *testing.T, path string, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0755); err != nil {
		t.Fatal(err)
	}
}
