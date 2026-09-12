/** Shared shell fragment for terminal-initiated browser opens in a Cloud VM. */
export const GUEST_CMUX_OPEN_URL_PATH = "/usr/local/bin/cmux-open-url";

export const GUEST_CMUX_OPEN_URL_SCRIPT = `#!/bin/sh
# cmux Cloud browser opener. The devbox deliberately owns the common Linux
# browser entry points so terminal tools cannot target the hidden VNC Chrome.
# Chrome, agent-browser, xdotool, and CUA launch their browser explicitly and
# never pass through this shim.
set -eu

cmux_open_url="\${1:-}"
if [ "\$cmux_open_url" = "--" ]; then cmux_open_url="\${2:-}"; fi
if [ -z "\$cmux_open_url" ]; then
  case "\${LC_ALL:-\${LC_MESSAGES:-\${LANG:-en}}}" in
    ja*) printf '%s\\n' "この URL を開いてください: (URL がありません)" ;;
    *) printf '%s\\n' "Open this URL: (missing URL)" ;;
  esac
  exit 0
fi

if cmux_open_cli="\$(command -v cmux 2>/dev/null)" && [ -x "\$cmux_open_cli" ]; then
  exec "\$cmux_open_cli" open "\$cmux_open_url"
fi

# The guest CLI is installed by the driver on attach. Until that happens, keep
# browser-opening callers alive and give the person a usable handoff instead of
# falling through to Chrome on DISPLAY=:1.
case "\${LC_ALL:-\${LC_MESSAGES:-\${LANG:-en}}}" in
  ja*) printf 'この URL を開いてください: %s\\n' "\$cmux_open_url" ;;
  *) printf 'Open this URL: %s\\n' "\$cmux_open_url" ;;
esac
`;

export const GUEST_CMUX_OPEN_SHELL = `
# Ask the Mac to open a URL through the daemon's durable notification stream.
# The caller's terminal and native-mirror attachment are required, so a
# headless exec cannot accidentally create a request in an unrelated workspace.
# A browser-resource fallback keeps older hosts usable when the request verb is
# not available yet.
guest_open_url() {
  case "\${1:-}" in
    --help|-h|help) cmux_message openHelp; return 0 ;;
  esac
  [ "\$#" -eq 1 ] && [ -n "\$1" ] || { cmux_message openUsage >&2; return 2; }
  cmux_open_url="\$1"
  cmux_open_terminal="\${CMUX_TUI_TERMINAL_ID:-}"
  if [ -x "\$CMUX_TUI_BIN" ] && [ -n "\$cmux_open_terminal" ]; then
    cmux_open_snapshot="\$(tui --json session current snapshot 2>/dev/null || true)"
    cmux_open_pane="\$(printf '%s\\n' "\$cmux_open_snapshot" | jq -r --arg term "\$cmux_open_terminal" '
      (.value // .) as \$s
      | select(any((\$s.clients // [])[]?; .client_kind == "native-mirror" and any((.attached_terminal_ids // [])[]?; . == \$term)))
      | [\$s.tabs[]? | select(.content_kind == "terminal" and .content_id == \$term) | .pane_id] | unique
      | select(length == 1) | .[0] // empty
    ' 2>/dev/null || true)"
    if [ -n "\$cmux_open_pane" ]; then
      if cmux_open_result="\$(tui --json notification create --title cmux.open-url --body "\$cmux_open_url" --terminal "\$cmux_open_terminal" 2>/dev/null)"; then
        cmux_open_notification_id="\$(printf '%s\\n' "\$cmux_open_result" | jq -r '(.value // .) | .notification_id // .id // empty' 2>/dev/null || true)"
        case "\$cmux_open_notification_id" in
          notification_*) return 0 ;;
        esac
      fi
      # Older hosts can still materialize a daemon browser resource when a
      # provider is present. Keep this compatibility path bounded and verify
      # the resource is retained before claiming success.
      if cmux_open_result="\$(tui --json pane "\$cmux_open_pane" tab create browser --url "\$cmux_open_url" 2>/dev/null)"; then
        cmux_open_browser_id="\$(printf '%s\\n' "\$cmux_open_result" | jq -r '(.value // .) | .browser_id // empty' 2>/dev/null || true)"
        if [ -n "\$cmux_open_browser_id" ]; then
          cmux_open_snapshot="\$(tui --json session current snapshot 2>/dev/null || true)"
          if printf '%s\\n' "\$cmux_open_snapshot" | jq -e --arg id "\$cmux_open_browser_id" 'any(((.value // .).browsers // [])[]; .id == \$id)' >/dev/null 2>&1; then
            return 0
          fi
        fi
      fi
    fi
  fi
  cmux_message openFallback "\$cmux_open_url"
  return 0
}
`;
