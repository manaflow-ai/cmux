# nvm, loaded on first use (/etc/profile.d/nvm.sh, written by the cmux bake).
# The Freestyle base sourced all of nvm.sh in every login shell: about 300 ms
# per shell on a Chief VM, for a node that is already on PATH. Now a login
# shell only puts node on PATH when it is missing (a glob, no fork), and the
# first `nvm` call loads the real thing. The provider's file is kept at
# /etc/cmux/nvm.sh.orig.
export NVM_DIR="${NVM_DIR:-/usr/local/nvm}"
if ! command -v node >/dev/null 2>&1; then
  for __cmux_nvm_d in "$NVM_DIR"/versions/node/*/bin; do
    [ -d "$__cmux_nvm_d" ] && __cmux_nvm_bin=$__cmux_nvm_d
  done
  [ -n "${__cmux_nvm_bin:-}" ] && PATH="$__cmux_nvm_bin:$PATH"
  unset __cmux_nvm_d __cmux_nvm_bin
fi
nvm() {
  unset -f nvm
  [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
  nvm "$@"
}
