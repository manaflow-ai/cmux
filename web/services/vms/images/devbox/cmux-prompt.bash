# Default only. Set PS1 after sourcing /etc/cmux/bashrc in ~/.bashrc to
# replace it, or remove that source line to use your own shell setup.
# Only builtins run before each prompt. The name lives in a file, so open
# shells see renames without an environment update or a child process.
if ! declare -F __cmux_prompt_name >/dev/null; then
  __cmux_read_vm_name() {
    IFS= read -r __cmux_vm_name 2>/dev/null < /etc/cmux/vm-name || __cmux_vm_name=cmux
  }
  # Report the working directory to the cmux-tui daemon with OSC 7 so the
  # Cloud workspace row follows `cd`. The daemon accepts only a file URL on
  # this host, so every byte outside the unreserved set is percent-encoded.
  __cmux_report_cwd() {
    local LC_ALL=C rest="$PWD" safe encoded=""
    while [ -n "$rest" ]; do
      safe="${rest%%[!a-zA-Z0-9/_.~-]*}"
      encoded+="$safe"
      rest="${rest#"$safe"}"
      if [ -n "$rest" ]; then
        printf -v safe '%%%02X' "'${rest:0:1}"
        encoded+="$safe"
        rest="${rest#?}"
      fi
    done
    printf '\e]7;file://%s%s\a' "${HOSTNAME:-localhost}" "$encoded"
  }
  # Warm template shell. The Cloud snapshot keeps the first terminal's shell
  # running; the bake arms it (/run/cmux/template-arm) and this shell's first
  # prompt waits here until the clone's daemon has adopted the terminal and
  # written the new session and terminal ids (/run/cmux/bound). The ids in
  # this shell's environment name the snapshot builder until then, so no
  # prompt, command or agent hook may run before they are replaced. After a
  # clone starts (/run/cmux/clone-started) the wait is bounded: on timeout the
  # builder's ids are removed rather than kept. It then waits up to 1.5 s for
  # the machine name, so the first prompt normally shows cmux@<slug> and
  # cmux-prompt-sync does not need to clear and interrupt it.
  __cmux_template_gate() {
    local waited=0 run=${CMUX_PROMPT_RUN_DIR:-/run/cmux} since=
    : > "$run"/template-shell-ready 2>/dev/null
    while [ ! -e "$run"/bound ]; do
      if [ -e "$run"/clone-started ]; then
        # Wall-clock bound (EPOCHREALTIME, microseconds): 3 s after the
        # clone started. Counting iterations would include fork time.
        [ -n "$since" ] || since=${EPOCHREALTIME/./}
        [ $((${EPOCHREALTIME/./} - since)) -gt 3000000 ] && break
      fi
      sleep 0.05
    done
    unset CMUX_TUI_SESSION_ID CMUX_TUI_TERMINAL_ID
    local key value
    if [ -r "$run"/bound ]; then
      while IFS='=' read -r key value; do
        case $key in
          CMUX_TUI_SESSION_ID | CMUX_TUI_TERMINAL_ID) export "$key=$value" ;;
        esac
      done < "$run"/bound
    fi
    waited=0
    while [ "$waited" -lt 30 ]; do
      __cmux_read_vm_name
      [ "$__cmux_vm_name" != cmux ] && break
      sleep 0.05
      waited=$((waited + 1))
    done
    [ "$__cmux_vm_name" != cmux ] && : > "$run"/first-prompt-named 2>/dev/null
    return 0
  }
  __cmux_prompt_name() {
    local status=$?
    if [[ ${__cmux_template_shell:-} ]]; then
      __cmux_template_shell=
      __cmux_template_gate
    fi
    __cmux_read_vm_name
    __cmux_report_cwd
    return "$status"
  }
  PROMPT_COMMAND=(__cmux_prompt_name "${PROMPT_COMMAND[@]}")
  # Exactly one shell consumes the bake's arm file and becomes the template.
  if [ -e "${CMUX_PROMPT_RUN_DIR:-/run/cmux}/template-arm" ] \
    && rm "${CMUX_PROMPT_RUN_DIR:-/run/cmux}/template-arm" 2>/dev/null; then
    __cmux_template_shell=1
  fi
fi
__cmux_read_vm_name
PS1='\[\e[35m\]\u@${__cmux_vm_name}\[\e[0m\] in \[\e[32m\]\w\[\e[0m\]\[\e[33m\] λ\[\e[0m\] '
