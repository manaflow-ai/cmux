# Sourced through BASH_ENV (set at the top of the PR workflows) by every bash step, for a few
# hours of REST budget attribution. Every GitHub API request a step makes, from Python or from
# gh, becomes one `gh-call` line in the job log (the format scripts/ci/gh_call_log.py reads).
# Each line holds the method, the path with no query string, the X-RateLimit headers
# Python already received, and GITHUB_WORKFLOW/GITHUB_JOB. It never logs a header value
# besides those, a body, a flag value or a token.
#
# It switches itself off at 2026-11-05 00:00 UTC (below); a follow-up removes it and the BASH_ENV lines.
#
# This file must never fail, never print, and never change what a step does. It does three things:
#   - puts scripts/ci/api_call_log/gh first on PATH, a shim that logs one line and execs the real gh with the same argv;
#   - puts sitecustomize.py on PYTHONPATH, which wraps http.client to log requests to api.github.com;
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
  [ "$(date -u +%Y%m%d%H 2>/dev/null || echo 9999999999)" -lt 2026110500 ] || return 1
  local src dir sink
  src=$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd) || src=""
  dir="$RUNNER_TEMP/api-call-log"
  if [ -n "$src" ] && mkdir -p "$dir/bin" "$dir/py" 2>/dev/null &&
    cp "$src/gh" "$dir/bin/gh" 2>/dev/null && chmod +x "$dir/bin/gh" 2>/dev/null &&
    cp "$src/sitecustomize.py" "$dir/py/sitecustomize.py" 2>/dev/null &&
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
unset -f _api_call_log_setup 2>/dev/null || true
unset _api_call_log_fd2 _api_call_log_flush 2>/dev/null || true
if [ -n "$_api_call_log_x" ]; then unset _api_call_log_x; set -x; else unset _api_call_log_x; fi
