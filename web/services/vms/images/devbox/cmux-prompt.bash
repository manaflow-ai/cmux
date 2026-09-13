# Default only. Set PS1 after sourcing /etc/cmux/bashrc in ~/.bashrc to
# replace it, or remove that source line to use your own shell setup.
# Only builtins run before each prompt. The name lives in a file, so open
# shells see renames without an environment update or a child process.
if ! declare -F __cmux_prompt_name >/dev/null; then
  __cmux_prompt_name() {
    local status=$?
    IFS= read -r __cmux_vm_name 2>/dev/null < /etc/cmux/vm-name || __cmux_vm_name=cmux
    return "$status"
  }
  PROMPT_COMMAND=(__cmux_prompt_name "${PROMPT_COMMAND[@]}")
fi
__cmux_prompt_name
PS1='\[\e[35m\]\u@${__cmux_vm_name}\[\e[0m\] in \[\e[32m\]\w\[\e[0m\]\[\e[33m\] λ\[\e[0m\] '
