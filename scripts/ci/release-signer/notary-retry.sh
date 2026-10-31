# Sourced by notarize-dmg.sh and notarize-app.sh, after signer-env.sh.
#
#   notary_submit <output-file> run_signer <signer-binary> notary-submit <args...>
#
# Runs the command (the signer notary submit, through run_signer) with its output in <output-file> (stdout and
# stderr) and returns its status. Apple notary API sometimes answers the
# submission POST with a 5xx (run 41109803857: 502 Bad Gateway on POST
# /notary/v2/submissions), so a failure is tried again, up to three tries in
# all, but only when the output shows a 5xx answer and names no submission
# and no verdict: a submission Apple created is never submitted twice, and a
# 4xx or an Invalid or Rejected verdict fails at once. Each failed try is
# printed to stderr before the wait. NOTARY_RETRY_DELAYS (seconds, default
# "20 60") sets the waits between tries.

# Whether <file> shows a 5xx from the notary service before any submission or verdict.
notary_server_error() {
  local file="$1"
  grep -qiE "submission id:? *[0-9a-f-]{36}" "$file" && return 1
  grep -qiE "notarization rejected|package is invalid|\\b(Invalid|Rejected)\\b" "$file" && return 1
  grep -qiE "Bad Gateway|Service Unavailable|Gateway Time-?out|Internal Server Error|\"status\" *: *\"5[0-9]{2}\"|HTTP(/[0-9.]+)? +5[0-9]{2}\\b" "$file"
}

notary_submit() {
  local out="$1" delays=() attempt=1 rc
  shift
  read -r -a delays <<<"${NOTARY_RETRY_DELAYS-20 60}"
  local delay
  for delay in ${delays[@]+"${delays[@]}"}; do
    [[ "$delay" =~ ^[0-9]+$ ]] || { echo "error: NOTARY_RETRY_DELAYS holds a wait that is not whole seconds ($delay)" >&2; return 2; }
  done
  while :; do
    rc=0
    "$@" > "$out" 2>&1 || rc=$?
    [[ "$rc" -ne 0 ]] || return 0
    if (( attempt > ${#delays[@]} )) || ! notary_server_error "$out"; then
      return "$rc"
    fi
    cat "$out" >&2
    delay="${delays[attempt - 1]}"
    echo "::warning title=notary submit::Apple notary service answered 5xx before it created a submission (try $attempt of $(( ${#delays[@]} + 1 ))); trying again in ${delay}s" >&2
    sleep "$delay"
    attempt=$(( attempt + 1 ))
  done
}
