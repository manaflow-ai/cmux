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
			[]string{"start a team"},
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
	originalShell := filepath.Join(root, "zsh")
	writeAgentLaunchTestExecutable(t, originalShell, `#!/bin/sh
set -eu
if [ "${1:-}" != "-lc" ]; then
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
"${CLAUDE_CODE_SHELL:-$SHELL}" -c -l 'printf "%s\n" "$PATH" > "$CMUX_TEST_SNAPSHOT_PATH_LOG"'
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
		"SHELL=/bin/sh",
		"CLAUDE_CODE_SHELL="+originalShell,
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

func TestClaudeTeamsShellWrapperKeepsFishIdentity(t *testing.T) {
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
	t.Setenv("CLAUDE_CODE_SHELL", "")
	t.Setenv("CMUX_CLAUDE_TEAMS_ORIGINAL_SHELL", "")
	t.Setenv("CMUX_CLAUDE_TEAMS_SHIM_DIR", "")
	t.Setenv("CMUX_TEST_PROFILE_BIN", profileBin)
	t.Setenv("XDG_CONFIG_HOME", filepath.Join(root, "config"))
	if err := configureClaudeTeamsShellWrapper(shimDir); err != nil {
		t.Fatal(err)
	}
	if got := os.Getenv("SHELL"); got != fishPath {
		t.Fatalf("SHELL = %q, want original fish path %q", got, fishPath)
	}
	wrapperPath := os.Getenv("CLAUDE_CODE_SHELL")
	if filepath.Base(wrapperPath) != "bash" {
		t.Fatalf("wrapper shell name = %q, want bash", filepath.Base(wrapperPath))
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

func TestClaudeTeamsShellWrapperSupportsNonPOSIXLoginShell(t *testing.T) {
	tcshPath, err := exec.LookPath("tcsh")
	if err != nil {
		t.Skip("tcsh is not installed")
	}

	root := t.TempDir()
	shimDir := filepath.Join(root, "claude-teams-bin")
	profileBin := filepath.Join(root, "profile-bin")
	for _, directory := range []string{shimDir, profileBin} {
		if err := os.MkdirAll(directory, 0755); err != nil {
			t.Fatal(err)
		}
	}
	writeAgentLaunchTestExecutable(t, filepath.Join(shimDir, "tmux"), "#!/bin/sh\nexit 0\n")
	if err := os.WriteFile(
		filepath.Join(root, ".tcshrc"),
		[]byte(`setenv PATH "${CMUX_TEST_PROFILE_BIN}:/usr/bin:/bin"`+"\n"),
		0644,
	); err != nil {
		t.Fatal(err)
	}

	t.Setenv("HOME", root)
	t.Setenv("SHELL", tcshPath)
	t.Setenv("CLAUDE_CODE_SHELL", "")
	t.Setenv("CMUX_CLAUDE_TEAMS_ORIGINAL_SHELL", "")
	t.Setenv("CMUX_CLAUDE_TEAMS_SHIM_DIR", "")
	t.Setenv("CMUX_TEST_PROFILE_BIN", profileBin)
	if err := configureClaudeTeamsShellWrapper(shimDir); err != nil {
		t.Fatal(err)
	}
	if got := os.Getenv("SHELL"); got != tcshPath {
		t.Fatalf("SHELL = %q, want original tcsh path %q", got, tcshPath)
	}
	wrapperPath := os.Getenv("CLAUDE_CODE_SHELL")
	if filepath.Base(wrapperPath) != "bash" {
		t.Fatalf("wrapper shell name = %q, want bash", filepath.Base(wrapperPath))
	}

	command := exec.Command(wrapperPath, "-lic", "/usr/bin/which tmux")
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("tcsh shell wrapper failed: %v\n%s", err, output)
	}
	if resolved := strings.TrimSpace(string(output)); resolved != filepath.Join(shimDir, "tmux") {
		t.Fatalf("tcsh shell wrapper resolved tmux = %q", resolved)
	}
}

func TestClaudeTeamsShellWrapperRejectsUnknownDialectBeforeReplacingShell(t *testing.T) {
	root := t.TempDir()
	unknownShell := filepath.Join(root, "unknown-shell")
	writeAgentLaunchTestExecutable(t, unknownShell, "#!/bin/sh\nexit 0\n")
	t.Setenv("SHELL", unknownShell)
	t.Setenv("CLAUDE_CODE_SHELL", "")
	t.Setenv("CMUX_CLAUDE_TEAMS_ORIGINAL_SHELL", "")
	t.Setenv("CMUX_CLAUDE_TEAMS_SHIM_DIR", "")

	err := configureClaudeTeamsShellWrapper(filepath.Join(root, "claude-teams-bin"))
	if err == nil || !strings.Contains(err.Error(), "unsupported SHELL") {
		t.Fatalf("configureClaudeTeamsShellWrapper error = %v", err)
	}
	if got := os.Getenv("SHELL"); got != unknownShell {
		t.Fatalf("unsupported SHELL was replaced with %q", got)
	}
}

func TestClaudeTeamsShellWrapperRejectsReentryWithoutOriginalShell(t *testing.T) {
	root := t.TempDir()
	shimDir := filepath.Join(root, "claude-teams-bin")
	wrapperPath := filepath.Join(shimDir, "shell", "bash")
	t.Setenv("SHELL", "/bin/zsh")
	t.Setenv("CLAUDE_CODE_SHELL", wrapperPath)
	t.Setenv("CMUX_CLAUDE_TEAMS_ORIGINAL_SHELL", "")
	t.Setenv("CMUX_CLAUDE_TEAMS_SHIM_DIR", "")

	err := configureClaudeTeamsShellWrapper(shimDir)
	if err == nil || !strings.Contains(err.Error(), "CMUX_CLAUDE_TEAMS_ORIGINAL_SHELL is missing") {
		t.Fatalf("configureClaudeTeamsShellWrapper error = %v", err)
	}
	if got := os.Getenv("CLAUDE_CODE_SHELL"); got != wrapperPath {
		t.Fatalf("re-entrant wrapper was replaced with %q", got)
	}
	if _, statErr := os.Stat(wrapperPath); !os.IsNotExist(statErr) {
		t.Fatalf("re-entrant wrapper was unexpectedly written: %v", statErr)
	}
}

func TestClaudeTeamsShellWrapperDefaultsInitialLaunchToBinSh(t *testing.T) {
	shimDir := filepath.Join(t.TempDir(), "claude-teams-bin")
	t.Setenv("SHELL", "")
	t.Setenv("CLAUDE_CODE_SHELL", "")
	t.Setenv("CMUX_CLAUDE_TEAMS_ORIGINAL_SHELL", "")
	t.Setenv("CMUX_CLAUDE_TEAMS_SHIM_DIR", "")

	if err := configureClaudeTeamsShellWrapper(shimDir); err != nil {
		t.Fatal(err)
	}
	if got := os.Getenv("CMUX_CLAUDE_TEAMS_ORIGINAL_SHELL"); got != "/bin/sh" {
		t.Fatalf("original shell = %q, want /bin/sh", got)
	}
}

func TestClaudeTeamsNonLaunchRelayLeavesUnknownShellUntouched(t *testing.T) {
	if os.Getenv("CMUX_TEST_CLAUDE_TEAMS_NON_LAUNCH_RELAY") == "1" {
		os.Exit(runClaudeTeamsRelay("/tmp/cmux-missing-test.sock", []string{"--version"}, nil))
	}

	root := t.TempDir()
	home := filepath.Join(root, "home")
	binDir := filepath.Join(root, "bin")
	for _, directory := range []string{home, binDir} {
		if err := os.MkdirAll(directory, 0755); err != nil {
			t.Fatal(err)
		}
	}
	shellLog := filepath.Join(root, "shell.log")
	unknownShell := filepath.Join(root, "nu")
	writeAgentLaunchTestExecutable(t, unknownShell, "#!/bin/sh\nexit 0\n")
	writeAgentLaunchTestExecutable(t, filepath.Join(binDir, "claude"), `#!/bin/sh
set -eu
printf '%s\n' "$SHELL" > "$CMUX_TEST_CLAUDE_SHELL_LOG"
`)

	command := exec.Command(os.Args[0], "-test.run=^TestClaudeTeamsNonLaunchRelayLeavesUnknownShellUntouched$")
	command.Env = append(os.Environ(),
		"CMUX_TEST_CLAUDE_TEAMS_NON_LAUNCH_RELAY=1",
		"CMUX_TEST_CLAUDE_SHELL_LOG="+shellLog,
		"CMUX_WORKSPACE_ID=",
		"CMUX_SURFACE_ID=",
		"HOME="+home,
		"PATH="+binDir+":/usr/bin:/bin",
		"SHELL="+unknownShell,
	)
	output, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("non-launch relay failed: %v\n%s", err, output)
	}
	loggedShell, err := os.ReadFile(shellLog)
	if err != nil {
		t.Fatal(err)
	}
	if got := strings.TrimSpace(string(loggedShell)); got != unknownShell {
		t.Fatalf("non-launch relay replaced SHELL with %q", got)
	}
}

func writeAgentLaunchTestExecutable(t *testing.T, path string, content string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(content), 0755); err != nil {
		t.Fatal(err)
	}
}
