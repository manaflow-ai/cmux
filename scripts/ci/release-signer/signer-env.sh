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

#   notary_submit <binary> <notary-submit args...>
#
# run_signer <binary> notary-submit, except that when Apple refuses the
# submission with 429 RATE_LIMIT ("Exceeded daily limit for notarizations. Try
# again in 0:04:11.") it waits the time Apple names and submits again, within
# CMUX_NOTARY_RATE_LIMIT_SECONDS (600 by default). Apple keeps nothing from a
# refused submission, so the retry duplicates nothing. Every attempt's output
# goes to stdout as the signer wrote it; the exit code is the last attempt's.
notary_submit() {
  local bin="$1" out rc delay hms h m s waited=0 budget="${CMUX_NOTARY_RATE_LIMIT_SECONDS:-600}"
  shift
  out="$(mktemp "${TMPDIR:-/tmp}/cmux-notary-submit.XXXXXX")"
  while :; do
    rc=0
    run_signer "$bin" notary-submit "$@" > "$out" 2>&1 || rc=$?
    cat "$out"
    { [[ "$rc" -ne 0 ]] && grep -q '"RATE_LIMIT"' "$out"; } || break
    hms="$(grep -oE 'Try again in [0-9]+:[0-9]{2}:[0-9]{2}' "$out" | head -n 1 | grep -oE '[0-9]+:[0-9]{2}:[0-9]{2}' || true)"
    if [[ -n "$hms" ]]; then
      IFS=: read -r h m s <<<"$hms"
      delay=$((10#$h * 3600 + 10#$m * 60 + 10#$s + 15))
    else
      delay=60
    fi
    if (( waited + delay > budget )); then
      echo "error: Apple's notarization rate limit asks for ${delay}s more; ${waited}s of the ${budget}s budget already waited" >&2
      break
    fi
    echo "==> Apple's notary service is rate limited (429 RATE_LIMIT); submitting again in ${delay}s" >&2
    sleep "$delay"
    waited=$((waited + delay))
  done
  rm -f "$out"
  return "$rc"
}
