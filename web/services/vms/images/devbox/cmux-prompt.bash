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
  __cmux_prompt_name() {
    local status=$?
    __cmux_read_vm_name
    __cmux_report_cwd
    return "$status"
  }
  PROMPT_COMMAND=(__cmux_prompt_name "${PROMPT_COMMAND[@]}")
fi
__cmux_read_vm_name
PS1='\[\e[35m\]\u@${__cmux_vm_name}\[\e[0m\] in \[\e[32m\]\w\[\e[0m\]\[\e[33m\] λ\[\e[0m\] '
