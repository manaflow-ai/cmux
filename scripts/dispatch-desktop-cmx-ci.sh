#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/dispatch-desktop-cmx-ci.sh [options]

Dispatch the manual GitHub Actions gates for the desktop CMX backend cutover.
The target ref must already exist on GitHub, because workflow_dispatch cannot
run against unpushed local commits.

Options:
  --ref <branch-or-sha>            Ref to test. Defaults to the upstream branch.
  --runner <label>                 Runner label. Default: depot-macos-latest.
  --tests-v2-filter <tests>        Space-separated tests_v2 files/globs.
  --remote-filter <tests>          Space-separated remote fixture tests_v2 files/globs.
  --include-external-ssh           Also run external SSH fixture tests from repo secrets.
  --external-ssh-filter <tests>    Space-separated external SSH tests_v2 files/globs.
  --ui-only-testing <filters>      Space-separated cmuxUITests filters.
  --skip-ci                        Do not dispatch the main CI workflow.
  --skip-tests-v2                  Do not dispatch Desktop CMX tests_v2.
  --skip-remote                    Do not dispatch Desktop CMX remote fixtures.
  --skip-ui                        Do not dispatch Desktop CMX UI tests.
  --dry-run                        Print gh commands without dispatching.
  -h, --help                       Show this help.
EOF
}

runner="depot-macos-latest"
target_ref=""
tests_v2_filter="test_desktop_cmx_workspace_split_tab.py test_workspace_create_layout.py test_browser_cli_agent_port.py test_tmux_compat_matrix.py test_remote_rust_state.py test_browser_api_p0.py test_browser_api_unsupported_matrix.py test_windows_api.py test_surface_split_window_scope.py test_pane_window_scope.py"
remote_filter="test_remote_rust_state.py test_ssh_remote_cli_metadata.py test_ssh_remote_daemon_resize_stdio.py test_ssh_remote_docker_bootstrap_nonlogin_shell.py test_ssh_remote_cli_relay.py test_ssh_remote_docker_forwarding.py test_ssh_remote_docker_reconnect.py test_ssh_remote_port_detection.py test_ssh_remote_proxy_bind_conflict.py test_ssh_remote_shell_integration.py"
external_ssh_filter="test_ssh_remote_browser_favicon_uses_proxy.py test_ssh_remote_browser_move_rebinds_proxy.py test_ssh_remote_interactive_cmux_command_regression.py test_ssh_remote_last_surface_clears_remote_state.py test_ssh_remote_resize_scrollback_regression.py test_ssh_remote_second_session_mux_regression.py test_ssh_remote_shortcuts_stay_remote.py"
ui_only_testing="BonsplitTabDragUITests/testCmxBackendMinimalModeKeepsTabReorderWorking BonsplitTabDragUITests/testCmxBackendMinimalModeDragToSplitCreatesPane"
run_ci=1
run_tests_v2=1
run_remote=1
run_external_ssh=false
run_ui=1
dry_run=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --ref)
      target_ref="${2:-}"
      shift 2
      ;;
    --runner)
      runner="${2:-}"
      shift 2
      ;;
    --tests-v2-filter)
      tests_v2_filter="${2:-}"
      shift 2
      ;;
    --remote-filter)
      remote_filter="${2:-}"
      shift 2
      ;;
    --include-external-ssh)
      run_external_ssh=true
      shift
      ;;
    --external-ssh-filter)
      external_ssh_filter="${2:-}"
      shift 2
      ;;
    --ui-only-testing)
      ui_only_testing="${2:-}"
      shift 2
      ;;
    --skip-ci)
      run_ci=0
      shift
      ;;
    --skip-tests-v2)
      run_tests_v2=0
      shift
      ;;
    --skip-remote)
      run_remote=0
      shift
      ;;
    --skip-ui)
      run_ui=0
      shift
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [ "$run_ci" -eq 0 ] && [ "$run_tests_v2" -eq 0 ] && [ "$run_remote" -eq 0 ] && [ "$run_ui" -eq 0 ]; then
  echo "Nothing to dispatch: --skip-ci, --skip-tests-v2, --skip-remote, and --skip-ui were all provided." >&2
  exit 2
fi

if [ -z "$target_ref" ]; then
  if upstream_ref=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null); then
    target_ref="${upstream_ref#origin/}"
  else
    current_branch=$(git branch --show-current 2>/dev/null || true)
    echo "No --ref provided and the current branch has no upstream." >&2
    if [ -n "$current_branch" ]; then
      echo "Push it first, for example: git push -u origin $current_branch" >&2
    fi
    exit 2
  fi
fi

if [ "$dry_run" -eq 0 ] && ! command -v gh >/dev/null 2>&1; then
  echo "gh is required to dispatch workflows." >&2
  exit 127
fi

run_or_print() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  if [ "$dry_run" -eq 0 ]; then
    local output
    local status
    set +e
    output="$("$@" 2>&1)"
    status=$?
    set -e
    if [ -n "$output" ]; then
      printf '%s\n' "$output"
    fi
    if [ "$status" -ne 0 ]; then
      if [[ "$output" == *"not found on the default branch"* ]]; then
        echo "WARN: GitHub cannot manually dispatch new workflow files until they exist on the default branch." >&2
        echo "WARN: On this feature branch, the Desktop CMX workflows also run from the branch push trigger." >&2
        return 0
      fi
      return "$status"
    fi
  fi
}

if [ "$run_ci" -eq 1 ]; then
  run_or_print gh workflow run ci.yml \
    --ref "$target_ref" \
    -f "run_warpbuild_macos=false"
fi

if [ "$run_tests_v2" -eq 1 ]; then
  run_or_print gh workflow run desktop-cmx-tests-v2.yml \
    --ref "$target_ref" \
    -f "ref=$target_ref" \
    -f "runner=$runner" \
    -f "test_filter=$tests_v2_filter"
fi

if [ "$run_remote" -eq 1 ]; then
  run_or_print gh workflow run desktop-cmx-remote-fixtures.yml \
    --ref "$target_ref" \
    -f "ref=$target_ref" \
    -f "runner=$runner" \
    -f "test_filter=$remote_filter" \
    -f "run_external_ssh=$run_external_ssh" \
    -f "external_ssh_filter=$external_ssh_filter"
fi

if [ "$run_ui" -eq 1 ]; then
  run_or_print gh workflow run desktop-cmx-ui.yml \
    --ref "$target_ref" \
    -f "ref=$target_ref" \
    -f "runner=$runner" \
    -f "only_testing=$ui_only_testing"
fi
