# Sourced through BASH_ENV (set at the top of the PR workflows) by every bash step, for a few
# hours of REST budget attribution. Every GitHub API request a step makes, from Python or from
# gh, becomes one `gh-call` line in the job log (the format scripts/ci/gh_call_log.py reads).
# Each line holds the method, the path with no query string, the X-RateLimit headers
# Python already received, GITHUB_WORKFLOW/GITHUB_JOB, and `tok=`: the first 8 hex digits of the
# SHA-256 of the token the call sent, so a gh line and a Python line on the same App token group
# together and the Python line's X-RateLimit-Reset names that token's installation pool. It
# never logs a header value besides those, a body, a flag value or a token.
#
# It switches itself off at 2026-11-23 00:00 UTC (below). The third window (to 2026-11-22) was for the
# routing App installation 164690637 (manaflow-glaeda-route); this day is for the repository's GITHUB_TOKEN
# hour that ran dry about hourly on 2026-11-21 (about 8,000 calls an hour, ci-token-budget-sampler.yml),
# whose calls the first three windows could not see. The first window ended 2026-11-05, the second
# (cmux-bot's pool, hq docs/handbook/app-installation-spend-per-caller.md) 2026-11-19. A follow-up removes
# it and the BASH_ENV lines.
#
# This file must never fail, never print, and never change what a step does. It does these things:
#   - puts scripts/ci/api_call_log/gh first on PATH, a shim that logs one line and execs the real gh with the same
#     argv; the first call on each token also logs that token's hour (GET /rate_limit, which costs no quota);
#   - puts sitecustomize.py on PYTHONPATH, which wraps http.client to log requests to api.github.com;
#   - defines python3/python in the step's own shell, which give `-I`/`-E` programs (they ignore PYTHONPATH) the
#     same hook (isolated.py), and curl, which names a request to api.github.com with its X-RateLimit headers (it
#     adds -D, unless the caller already reads its own headers);
#   - points the lines at the step shell's own stderr (the runner's pipe), so a child that captures
#     or redirects its own stderr never sees them; on macOS (no /proc) they wait in a file and are
#     printed when the next bash step starts.
# Copies live in $RUNNER_TEMP, never the checkout: no stray files in the tree (git status stays
# clean), and BASH_ENV moves to the copy. A script that appends to $BASH_ENV
# (scripts/install-rust-ci.sh) then appends to the copy.
_api_call_log_setup() {
  # Returns 1 when it does not switch on, and the caller then unsets BASH_ENV, so the step
  # runs exactly as it would without this file. A nested shell of an active step returns 0.
  [ -z "${API_CALL_LOG_DIR:-}" ] || return 0
  case "${RUNNER_OS:-}" in Linux | macOS) ;; *) return 1 ;; esac
  [ -n "${RUNNER_TEMP:-}" ] && [ -n "${BASH_SOURCE[0]:-}" ] || return 1
  # Self-expiring: after this hour (UTC) it does nothing, whether or not the cleanup PR has landed.
  [ "$(date -u +%Y%m%d%H 2>/dev/null || echo 9999999999)" -lt 2026112300 ] || return 1
  local src dir sink
  src=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || src=""
  dir="$RUNNER_TEMP/api-call-log"
  if [ -n "$src" ] && mkdir -p "$dir/bin" "$dir/py" 2>/dev/null &&
    cp "$src/gh" "$dir/bin/gh" 2>/dev/null && chmod +x "$dir/bin/gh" 2>/dev/null &&
    cp "$src/sitecustomize.py" "$dir/py/sitecustomize.py" 2>/dev/null &&
    cp "$src/isolated.py" "$dir/py/isolated.py" 2>/dev/null &&
    cp "$src/env.sh" "$dir/env.sh" 2>/dev/null; then
    sink="$dir/pending.log"
    case $_api_call_log_fd2 in pipe:*) sink="/proc/$$/fd/2"; export API_CALL_LOG_PIPE="$_api_call_log_fd2" ;; esac
    [ -s "$dir/pending.log" ] && _api_call_log_flush="$dir/pending.log"
    export API_CALL_LOG_DIR="$dir" API_CALL_LOG_SINK="$sink"
    # Only where gh is installed: a shim on a machine with no gh would turn `command -v gh` true.
    if command -v gh >/dev/null 2>&1; then export PATH="$dir/bin:$PATH"; fi
    export PYTHONPATH="$dir/py${PYTHONPATH:+:$PYTHONPATH}"
    export BASH_ENV="$dir/env.sh"
    return 0
  fi
  return 1
}
# xtrace off while this runs (a `bash -x` step would trace these lines); the group's own trace goes nowhere.
{ case $- in *x*) _api_call_log_x=1 ;; *) _api_call_log_x="" ;; esac; set +x; } 2>/dev/null
# The step shell's own stderr, read before the call below redirects it (readlink runs in a subshell).
_api_call_log_fd2=$(readlink "/proc/$$/fd/2" 2>/dev/null) || _api_call_log_fd2=""
_api_call_log_flush=""
_api_call_log_setup >/dev/null 2>&1 || unset BASH_ENV 2>/dev/null || true
if [ -n "$_api_call_log_flush" ]; then
  # macOS: the lines earlier steps wrote, printed to this step's stderr (the only line this file prints).
  cat "$_api_call_log_flush" >&2 2>/dev/null && : >"$_api_call_log_flush" 2>/dev/null || true
fi
# The step shell's own functions, only in the shell the runner starts on the step's file ($RUNNER_TEMP/<guid>.sh):
# a script the step runs keeps python3 and curl as PATH has them, since `command -v python3` names a function by
# its bare name (scripts/install-git-hooks.sh refuses that, and tests keep `real_curl=$(command -v curl)`). Each
# runs with xtrace off and returns the wrapped command's own status; a trace still shows the step's own
# `python3 ...` or `curl ...`.
case $0 in
  "${RUNNER_TEMP:-/nonexistent}"/????????-????-????-????-????????????.sh) _api_call_log_step=1 ;;
  *) _api_call_log_step="" ;;
esac
if [ -n "$_api_call_log_step" ] && [ -n "${API_CALL_LOG_DIR:-}" ] && [ -f "$API_CALL_LOG_DIR/py/isolated.py" ]; then
  _api_call_log_write() {
    local sink=${API_CALL_LOG_SINK:-}
    [ -n "$sink" ] || return 0
    case $sink in
      /proc/*) [ "$(readlink "$sink" 2>/dev/null)" = "${API_CALL_LOG_PIPE:-}" ] || sink="$API_CALL_LOG_DIR/pending.log" ;;
    esac
    printf '%s\n' "$1" >>"$sink" 2>/dev/null || printf '%s\n' "$1" >>"$API_CALL_LOG_DIR/pending.log" 2>/dev/null || true
  }
  # `python3 [-I|-E ...] FILE|-m MOD|-c CODE ARGS`: isolated.py runs the hook, then the program. Anything else,
  # an option it does not know included, runs as typed.
  # Sets _api_call_log_ran=1 when it ran the program (its status is then the program's); 0 when the caller must.
  _api_call_log_python() {
    local exe=$1 a t iso="" mode="" rc
    _api_call_log_ran=0
    shift
    local -a opts=()
    local -a rest=()
    while [ $# -gt 0 ]; do
      a=$1
      case $a in
        -X | -W) [ $# -ge 2 ] || break; opts+=("$a" "$2"); shift 2; continue ;;
        -m | -c) [ $# -ge 2 ] && [ -n "$iso" ] && { mode=$a; t=$2; shift 2; }; break ;;
        -* ) case $a in -- | - | --* | *[!A-Za-z-]* | -*[XWmc]*) break ;; esac
             case $a in -*[IE]*) iso=1 ;; esac
             opts+=("$a"); shift; continue ;;
        *) [ -n "$iso" ] && [ -f "$a" ] && { mode=file; t=$a; shift; }; break ;;
      esac
    done
    if [ -n "$mode" ]; then
      rest=("$@")
      _api_call_log_ran=1
      command "$exe" ${opts[@]+"${opts[@]}"} -c "$(cat "$API_CALL_LOG_DIR/py/isolated.py" 2>/dev/null)" "$mode" "$t" \
        ${rest[@]+"${rest[@]}"} && rc=0 || rc=$?
      return $rc
    fi
    return 0
  }
  # Each wrapper exists only where its program does: a function named curl would make `command -v curl` true on a
  # PATH with no curl (workers/iroh-v2's deploy guard checks exactly that).
  if type -P python3 >/dev/null 2>&1; then python3() {
    { local _x=$-; set +x; } 2>/dev/null
    local rc
    _api_call_log_python python3 "$@" && rc=0 || rc=$?
    if [ "$_api_call_log_ran" != 1 ]; then command python3 "$@" && rc=0 || rc=$?; fi
    case $_x in *x*) set -x ;; esac
    return $rc
  }; fi
  if type -P python >/dev/null 2>&1; then python() {
    { local _x=$-; set +x; } 2>/dev/null
    local rc
    _api_call_log_python python "$@" && rc=0 || rc=$?
    if [ "$_api_call_log_ran" != 1 ]; then command python "$@" && rc=0 || rc=$?; fi
    case $_x in *x*) set -x ;; esac
    return $rc
  }; fi
  if type -P curl >/dev/null 2>&1; then curl() {
    { local _x=$-; set +x; } 2>/dev/null
    local a prev="" url="" meth="" auth="" own="" data="" tmp="" rc
    for a in "$@"; do
      case $prev in
        -X | --request) meth=$a ;;
        -H | --header) case $a in [Aa]uthorization:*) auth=${a#*:} ;; esac ;;
      esac
      prev=$a
      case $a in
        https://api.github.com/* | https://uploads.github.com/*) [ -n "$url" ] || url=$a ;;
        -D | --dump-header | --dump-header=* | -K | --config | --config=* | --next | -: ) own=1 ;;
        --request=*) meth=${a#--request=} ;;
        -d | --data | --data-* | --json | -F | --form | --form-string) data=1 ;;
        -[!-]*) case $a in *D* | *K* | *:*) own=1 ;; esac
                case $a in -*X?*) meth=${a#*X} ;; esac ;;
      esac
    done
    if [ -z "$url" ] || [ -n "$own" ] || ! tmp=$(mktemp "$API_CALL_LOG_DIR/curl.XXXXXX" 2>/dev/null); then
      command curl "$@" && rc=0 || rc=$?
      case $_x in *x*) set -x ;; esac
      return $rc
    fi
    command curl -D "$tmp" "$@" && rc=0 || rc=$?
    {
      local path status res used left reset fp cred stamp
      path=${url#https://*/}
      path="/${path%%[?#]*}"
      path=$(printf '%s' "$path" | awk -F/ '{ out = ""; for (i = 2; i <= NF; i++) { p = $i; if (p == "") continue;
        if (p ~ /^[0-9]+$/) p = "{n}"; else if (p ~ /^[0-9a-f]+$/ && length(p) == 40) p = "{sha}";
        else if (p ~ /gh[pousr]_|github_pat_/ || p !~ /^[A-Za-z0-9_.:{}-]+$/) p = "{x}"; out = out "/" p }
        print (out == "" ? "/" : out) }')
      read -r status res used left reset <<EOF_API_CALL_LOG
$(tr -d '\r' <"$tmp" | awk 'BEGIN { IGNORECASE = 1 }
  /^HTTP\// { if (!done) st = $2; next }
  tolower($0) ~ /^x-ratelimit-resource:/ && !done { r = $2 }
  tolower($0) ~ /^x-ratelimit-used:/ && !done { u = $2 }
  tolower($0) ~ /^x-ratelimit-remaining:/ && !done { l = $2 }
  tolower($0) ~ /^x-ratelimit-reset:/ && !done { z = $2 }
  /^$/ { if (u != "") done = 1 }
  END { printf "%s %s %s %s %s\n", st ? st : "-", r ? r : "-", u ? u : "-", l ? l : "-", z ? z : "-" }')
EOF_API_CALL_LOG
      cred=$(printf '%s' "$auth" | awk '{ print $NF }')
      if [ -n "$cred" ]; then
        fp=$(printf '%s' "$cred" | { sha256sum 2>/dev/null || shasum -a 256 2>/dev/null; } | cut -c1-8)
        case $fp in *[!0-9a-f]* | "") fp="?" ;; esac
      else
        fp=none
      fi
      unset cred auth
      if [ -z "$meth" ]; then [ -n "$data" ] && meth=POST || meth=GET; fi
      meth=$(printf '%s' "$meth" | tr '[:lower:]' '[:upper:]'); case $meth in *[!A-Z]* | "") meth="?" ;; esac
      [ "$path" = /graphql ] && meth=GRAPHQL
      stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      _api_call_log_write "$(printf 'gh-call\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s %s %s [curl tok=%s]' "$stamp" \
        "$(printf '%s' "${GITHUB_WORKFLOW:-}" | tr '\t\r\n' '   ')" "$(printf '%s' "${GITHUB_JOB:-}" | tr '\t\r\n' '   ')" \
        "${res:--}" "${used:--}" "${left:--}" "${reset:--}" "$meth" "$path" "${status:--}" "$fp")"
      rm -f "$tmp"
    } >/dev/null 2>&1 </dev/null || true
    case $_x in *x*) set -x ;; esac
    return $rc
  }; fi
fi
unset -f _api_call_log_setup 2>/dev/null || true
unset _api_call_log_fd2 _api_call_log_flush _api_call_log_step 2>/dev/null || true
if [ -n "$_api_call_log_x" ]; then unset _api_call_log_x; set -x; else unset _api_call_log_x; fi
