# Sourced by the release signer scripts.
#
#   run_signer <binary> <args...>
#
# The signer reads every RCODESIGN_* environment variable as its own
# configuration and stops on one it does not know. Bash cannot unset an
# exported name that is not a valid identifier (RCODESIGN_-X), and compgen -e
# does not list one, so the names come from the raw environment and env -u
# removes each for the signer's process only. A value with a newline can make a
# line that only looks like a name; env -u of a name that is not set is a no-op.
run_signer() {
  local bin="$1" name
  shift
  local unset_args=()
  while IFS= read -r name; do
    unset_args+=(-u "$name")
  done < <(env | grep -oE '^RCODESIGN_[^=]*' || true)
  env ${unset_args[@]+"${unset_args[@]}"} "$bin" "$@"
}
