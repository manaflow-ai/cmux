/**
 * The offline Cloud welcome shown by the in-VM `cmux welcome` command.
 *
 * This is intentionally a shell renderer rather than a startup profile hook:
 * the Mac starts it as the terminal's initial argv, before the user's shell
 * can accept input.  The state machine is kept here so the guest command and
 * its automatic first-use wrapper share one implementation.
 */
export const GUEST_CMUX_WELCOME_SHELL = `guest_welcome_display_available() {
  [ -n "\${DISPLAY:-}" ] && return 0
  [ -r /run/cmux-desktop/env ] && return 0
  return 1
}

guest_welcome_render() {
  cmux_welcome_reset='\\033[0m'
  cmux_welcome_subdued='\\033[2m'
  cmux_welcome_c1='\\033[38;2;0;212;255m'
  cmux_welcome_c2='\\033[38;2;24;181;250m'
  cmux_welcome_c3='\\033[38;2;48;150;245m'
  cmux_welcome_c4='\\033[38;2;72;119;241m'
  cmux_welcome_c5='\\033[38;2;96;88;239m'
  cmux_welcome_c6='\\033[38;2;110;73;238m'
  cmux_welcome_c7='\\033[38;2;124;58;237m'

  printf '\\n'
  printf '%b  ::%b\\n' "\$cmux_welcome_c1" "\$cmux_welcome_reset"
  printf '%b    ::::              %bc%bm%bu%bx cloud%b\\n' \\
    "\$cmux_welcome_c2" "\$cmux_welcome_c1" "\$cmux_welcome_c2" "\$cmux_welcome_c3" "\$cmux_welcome_c7" "\$cmux_welcome_reset"
  printf '%b      ::::::%b\\n' "\$cmux_welcome_c3" "\$cmux_welcome_reset"
  printf '%b        ::::::%b        %bCloud machine%b\\n' "\$cmux_welcome_c4" "\$cmux_welcome_reset" "\$cmux_welcome_subdued" "\$cmux_welcome_reset"
  printf '%b      ::::::%b          %bReady for coding agents%b\\n' "\$cmux_welcome_c5" "\$cmux_welcome_reset" "\$cmux_welcome_subdued" "\$cmux_welcome_reset"
  printf '%b    ::::%b\\n' "\$cmux_welcome_c6" "\$cmux_welcome_reset"
  printf '%b  ::%b\\n' "\$cmux_welcome_c7" "\$cmux_welcome_reset"
  printf '\\n'

  cmux_message welcomeIntro
  cmux_message welcomeCodeRouter
  cmux_message welcomeWorkspaces
  if guest_welcome_display_available; then
    cmux_message welcomeDisplays
  else
    cmux_message welcomeNoDisplays
  fi
  cmux_message welcomePorts
  cmux_message welcomeFiles
  cmux_message welcomeReplay
  printf '\\n'
}

# Claiming is machine-local and atomic. The marker carries the provider's
# stable VM identity so a fork/restore with a new identity gets its own guide.
# A pending claim is released when rendering fails, so a later successful
# attachment can still be the first
# welcome. A dead owner is reclaimed without polling or a sleep.
guest_welcome_auto() {
  [ "\${CMUX_CLOUD_WELCOME:-1}" != 0 ] || return 0
  cmux_welcome_state="\${CMUX_GUEST_HOME:-\${HOME:-/root}/.cmux}/cloud-welcome"
  cmux_welcome_marker="\$cmux_welcome_state/shown"
  cmux_welcome_pending="\$cmux_welcome_state/pending"
  cmux_welcome_identity="\${CMUX_VM_ID:-}"
  if [ -z "\$cmux_welcome_identity" ]; then
    for cmux_welcome_env in "\${HOME:-/root}/.config/cmux/model-plane.env" /etc/cmux/model-plane.env; do
      [ -r "\$cmux_welcome_env" ] || continue
      cmux_welcome_identity="\$(sed -n "s/^export CMUX_VM_ID='\\([^']*\\)'$/\\1/p" "\$cmux_welcome_env" | head -n 1)"
      [ -n "\$cmux_welcome_identity" ] && break
    done
  fi
  [ -n "\$cmux_welcome_identity" ] || cmux_welcome_identity=unknown
  mkdir -p "\$cmux_welcome_state" 2>/dev/null || return 0
  if [ -e "\$cmux_welcome_marker" ]; then
    [ "\$(cat "\$cmux_welcome_marker" 2>/dev/null || true)" = "\$cmux_welcome_identity" ] && return 0
    rm -f "\$cmux_welcome_marker" 2>/dev/null || return 0
  fi
  if [ -e "\$cmux_welcome_pending" ]; then
    cmux_welcome_owner="\$(cat "\$cmux_welcome_pending" 2>/dev/null || true)"
    case "\$cmux_welcome_owner" in
      ''|*[!0-9]*) rm -f "\$cmux_welcome_pending" 2>/dev/null || return 0 ;;
      *) kill -0 "\$cmux_welcome_owner" 2>/dev/null && return 0
         rm -f "\$cmux_welcome_pending" 2>/dev/null || return 0 ;;
    esac
  fi
  ( set -C; umask 077; printf '%s\\n' "\$" > "\$cmux_welcome_pending" ) 2>/dev/null || return 0
  if guest_welcome_render; then
    cmux_welcome_marker_tmp="\$cmux_welcome_marker.tmp.\$"
    if printf '%s\\n' "\$cmux_welcome_identity" > "\$cmux_welcome_marker_tmp" 2>/dev/null && mv -f "\$cmux_welcome_marker_tmp" "\$cmux_welcome_marker" 2>/dev/null; then
      rm -f "\$cmux_welcome_pending" 2>/dev/null || true
      return 0
    fi
    rm -f "\$cmux_welcome_marker_tmp" "\$cmux_welcome_pending" 2>/dev/null || true
    return 1
  fi
  rm -f "\$cmux_welcome_pending" 2>/dev/null || true
  return 1
}

guest_welcome_command() {
  cmux_welcome_auto=0
  while [ "\$#" -gt 0 ]; do
    case "\$1" in
      --auto) cmux_welcome_auto=1; shift ;;
      --help|-h) cmux_message welcomeUsage; return 0 ;;
      *) die_message 2 welcomeOption "\$1" ;;
    esac
  done
  if [ "\$cmux_welcome_auto" = 1 ]; then
    guest_welcome_auto
  else
    guest_welcome_render
  fi
}
`;
