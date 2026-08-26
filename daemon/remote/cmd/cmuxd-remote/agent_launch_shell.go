package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

const claudeTeamsShellWrapperScript = `#!/bin/sh
set -eu

original_shell=${CMUX_CLAUDE_TEAMS_ORIGINAL_SHELL:-/bin/sh}
shim_dir=${CMUX_CLAUDE_TEAMS_SHIM_DIR:-}

case "${1:-}" in
  -c|-lc|-ic|-lic|-ilc)
    shell_flags=$1
    shift
    # Claude Code passes login mode as a separate token when capturing a shell
    # snapshot: "$SHELL" -c -l <script>. Fold separate shell options back into
    # the command-mode flag before selecting the script argument.
    while [ "$#" -gt 1 ]; do
      case "$1" in
        -l|-i)
          shell_flags="-${1#-}${shell_flags#-}"
          shift
          ;;
        *)
          break
          ;;
      esac
    done
    if [ "$#" -eq 0 ] || [ -z "$shim_dir" ]; then
      exec "$original_shell" "$shell_flags" "$@"
    fi
    shell_command=$1
    shift
    original_shell_flags=$shell_flags
    case "${original_shell##*/}" in
      fish)
        shell_command='if test -n "$CMUX_CLAUDE_TEAMS_SHIM_DIR"; and test -d "$CMUX_CLAUDE_TEAMS_SHIM_DIR"; set -gx PATH "$CMUX_CLAUDE_TEAMS_SHIM_DIR" $PATH; end; '"$shell_command"
        ;;
      csh|tcsh)
        # csh-family shells reject combined login/interactive flags. Their
        # command mode still sources the interactive rc file before this prefix.
        original_shell_flags=-c
        shell_command='if ( -d "$CMUX_CLAUDE_TEAMS_SHIM_DIR" ) setenv PATH "${CMUX_CLAUDE_TEAMS_SHIM_DIR}:${PATH}"; '"$shell_command"
        ;;
      *)
        shell_command='if [ -n "${CMUX_CLAUDE_TEAMS_SHIM_DIR:-}" ] && [ -d "$CMUX_CLAUDE_TEAMS_SHIM_DIR" ]; then PATH="$CMUX_CLAUDE_TEAMS_SHIM_DIR${PATH:+:$PATH}"; export PATH; fi; '"$shell_command"
        ;;
    esac
    exec "$original_shell" "$original_shell_flags" "$shell_command" "$@"
    ;;
  *)
    exec "$original_shell" "$@"
    ;;
esac
`

// configureClaudeTeamsShellWrapper makes the managed tmux directory part of
// Claude's shell contract. Claude invokes CLAUDE_CODE_SHELL (falling back to
// SHELL) to create a snapshot after login profiles have run; the wrapper
// prepends the shim inside that command, so a profile that rebuilds PATH cannot
// evict it from the captured snapshot.
func configureClaudeTeamsShellWrapper(shimDir string) error {
	currentShell := strings.TrimSpace(os.Getenv("CLAUDE_CODE_SHELL"))
	if currentShell == "" {
		currentShell = strings.TrimSpace(os.Getenv("SHELL"))
	}
	wrapperDir := filepath.Join(shimDir, "shell")
	originalShell := currentShell
	reentrant := filepath.Clean(filepath.Dir(currentShell)) == filepath.Clean(wrapperDir)
	if reentrant {
		originalShell = strings.TrimSpace(os.Getenv("CMUX_CLAUDE_TEAMS_ORIGINAL_SHELL"))
		if originalShell == "" {
			return fmt.Errorf("managed Claude Teams shell wrapper is active but CMUX_CLAUDE_TEAMS_ORIGINAL_SHELL is missing")
		}
	}
	if originalShell == "" {
		originalShell = "/bin/sh"
	}
	if !filepath.IsAbs(originalShell) {
		return fmt.Errorf("SHELL must be an absolute path, got %q", originalShell)
	}
	info, err := os.Stat(originalShell)
	if err != nil {
		return fmt.Errorf("resolve original shell %q: %w", originalShell, err)
	}
	if info.IsDir() || info.Mode()&0111 == 0 {
		return fmt.Errorf("original shell is not executable: %q", originalShell)
	}
	if !claudeTeamsShellWrapperSupports(filepath.Base(originalShell)) {
		return fmt.Errorf("unsupported SHELL for managed Claude Teams snapshots: %q", originalShell)
	}

	if err := os.MkdirAll(wrapperDir, 0755); err != nil {
		return err
	}
	// Claude's shell discovery accepts bash/zsh paths and gives
	// CLAUDE_CODE_SHELL priority over SHELL. Give the wrapper an accepted name
	// regardless of the user's real shell; the script still translates and
	// delegates each command to originalShell below.
	wrapperName := "bash"
	wrapperPath := filepath.Join(wrapperDir, wrapperName)
	if err := writeShimIfChanged(wrapperPath, claudeTeamsShellWrapperScript); err != nil {
		return err
	}

	os.Setenv("CMUX_CLAUDE_TEAMS_ORIGINAL_SHELL", originalShell)
	os.Setenv("CMUX_CLAUDE_TEAMS_SHIM_DIR", shimDir)
	os.Setenv("CLAUDE_CODE_SHELL", wrapperPath)
	return nil
}

func claudeTeamsShellWrapperSupports(shellName string) bool {
	switch shellName {
	case "ash", "bash", "csh", "dash", "fish", "ksh", "mksh", "sh", "tcsh", "zsh":
		return true
	default:
		return false
	}
}
