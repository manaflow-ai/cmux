# cmux shell defaults for cloud VMs (/etc/profile.d/cmux-shell.sh).
# Sourced once per shell (login shells via /etc/profile, interactive
# non-login shells via /etc/bash.bashrc). POSIX sh, builtins only: nothing
# here forks, and nothing runs per prompt.

[ -n "${LANG:-}" ] || export LANG=C.UTF-8
[ -n "${COLORTERM:-}" ] || export COLORTERM=truecolor

# TERM fallback, like Ghostty's ssh-env: a client that sends a TERM this
# machine has no terminfo entry for (xterm-ghostty from an older image,
# wezterm, kitty...) gets xterm-256color, so htop, vim, less and tmux start
# instead of failing with "Error opening terminal". Plain file tests over
# ncurses' search path; no infocmp fork.
case "${TERM:-}" in
  "" | dumb | */*) ;;
  *)
    __cmux_t=$TERM
    __cmux_f=${__cmux_t%"${__cmux_t#?}"}
    __cmux_found=
    __cmux_ifs=$IFS
    IFS=:
    for __cmux_d in ${TERMINFO_DIRS:-} ${TERMINFO:-} /etc/terminfo /lib/terminfo /usr/share/terminfo ${HOME:-/nonexistent}/.terminfo; do
      [ -n "$__cmux_d" ] && [ -d "$__cmux_d" ] || continue
      # Linux ncurses files by first letter (x/xterm-ghostty); macOS and
      # some builds by its hex code (78/xterm-ghostty): a glob, no fork.
      for __cmux_p in "$__cmux_d/$__cmux_f/$__cmux_t" "$__cmux_d"/??/"$__cmux_t"; do
        [ -e "$__cmux_p" ] && { __cmux_found=1; break; }
      done
      [ -n "$__cmux_found" ] && break
    done
    IFS=$__cmux_ifs
    [ -n "$__cmux_found" ] || export TERM=xterm-256color
    unset __cmux_t __cmux_f __cmux_found __cmux_ifs __cmux_d __cmux_p
    ;;
esac
