# shellcheck shell=bash
# Sourced by the steps that fetch from github.com through git on a self-hosted
# Mac: swiftpm-binary-module-guard.sh (swift package resolve, xcodebuild
# -resolvePackageDependencies) and run-xcodebuild-with-diagnostics.sh (the
# package graph xcodebuild resolves before it builds).
#
# Why: a self-hosted mini reaches github.com through a loopback CONNECT proxy
# that its git config names (http.https://github.com/.proxy, an ssh -R tunnel
# to a fleet VM's egress proxy). When that tunnel is half-dead it accepts and
# never answers, or it is gone and refuses at once, and every package fetch
# fails while github.com answers the same mini directly. cmux runs 45830236598
# (SPM: "HTTP 408" on sentry-cocoa, "curl 18" on Sparkle, after 18 minutes),
# 45836332236 ("Recv failure: Connection reset by peer" on swift-atomics,
# sentry-cocoa and Sparkle; "Failed to connect to 127.0.0.1 port 18434 after
# 0 ms" in the same window) and 45839650010 (checkout: "Proxy CONNECT aborted",
# "Operation too slow"), 2026-11-26. The proxy stays the default path; these
# helpers only step around it when it does not work:
#
# github_egress_probe
#   One CONNECT to github.com through the proxy git would use, bounded at
#   CMUX_GITHUB_EGRESS_PROBE_S seconds (default 10). No answer: this shell and
#   its children go direct (github_egress_go_direct). While the proxy is the
#   route, a git transfer that moves no byte for CMUX_GITHUB_EGRESS_STALL_S
#   seconds (default 60) ends, so a stalled tunnel fails in a minute rather
#   than in curl's own timeouts (run 45830236598 held one clone 18 minutes).
#   No proxy configured, CMUX_GITHUB_EGRESS_PROBE=0, or no curl: nothing.
# github_egress_retry_direct LOG
#   LOG is a failed fetch's output. When the proxy was the route and LOG shows
#   a proxy- or tunnel-shaped failure, go direct and return 0: the caller tries
#   once more. Otherwise (already direct, no proxy, another failure) return 1.
#
# Going direct sets an empty http.proxy and http.https://github.com/.proxy
# through GIT_CONFIG_COUNT (kept configs such as pack.threads or the
# github_git_auth_env header stay; command-scope config wins over the global
# file) and unsets the proxy environment variables, for this shell and every
# child: xcodebuild's package clones run Xcode's own git, never a PATH shim, so
# the environment is the one route that reaches them.

github_egress__proxy() {
  local proxy
  proxy="$(git config --get-urlmatch http.proxy https://github.com/ 2>/dev/null || true)"
  [ -n "$proxy" ] || proxy="${HTTPS_PROXY:-${https_proxy:-${ALL_PROXY:-${all_proxy:-}}}}"
  printf '%s' "$proxy"
}

github_egress__config() {  # KEY VALUE: one more command-scope git config for this shell and its children
  local n="${GIT_CONFIG_COUNT:-0}"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  export "GIT_CONFIG_KEY_$n=$1"
  export "GIT_CONFIG_VALUE_$n=$2"
  export GIT_CONFIG_COUNT=$((n + 1))
}

# github_egress_go_direct WHY
github_egress_go_direct() {
  [ "${CMUX_GITHUB_EGRESS_DIRECT:-0}" != 1 ] || return 0
  local proxy
  proxy="$(github_egress__proxy)"
  github_egress__config http.proxy ""
  github_egress__config http.https://github.com/.proxy ""
  unset HTTPS_PROXY https_proxy ALL_PROXY all_proxy
  export CMUX_GITHUB_EGRESS_DIRECT=1
  echo "github egress: the github.com proxy ${proxy:-(none)} $1; going direct to github.com"
}

github_egress_probe() {
  local proxy probe_s="${CMUX_GITHUB_EGRESS_PROBE_S:-10}" stall_s="${CMUX_GITHUB_EGRESS_STALL_S:-60}"
  [ "${CMUX_GITHUB_EGRESS_PROBE:-1}" != 0 ] || return 0
  [ "${CMUX_GITHUB_EGRESS_DIRECT:-0}" != 1 ] || return 0
  [ "${CMUX_GITHUB_EGRESS_PROBED:-0}" != 1 ] || return 0
  proxy="$(github_egress__proxy)"
  [ -n "$proxy" ] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  export CMUX_GITHUB_EGRESS_PROBED=1
  if ! curl -sS -o /dev/null --head --connect-timeout "$probe_s" -m "$probe_s" -x "$proxy" https://github.com/ \
      </dev/null >/dev/null 2>&1; then
    github_egress_go_direct "did not answer a CONNECT in ${probe_s} s"
    return 0
  fi
  if [ "$stall_s" != 0 ]; then
    github_egress__config http.lowSpeedLimit 1
    github_egress__config http.lowSpeedTime "$stall_s"
  fi
}

# A proxy or tunnel that failed, in curl's and git's words: the loopback proxy
# refused, the CONNECT got no answer or a non-200, or the tunnel dropped or
# starved the transfer (reset, partial file, 408 from the proxy's idle cut).
github_egress__proxy_failure() {
  grep -qE 'Proxy CONNECT aborted|CONNECT tunnel failed|Received HTTP code [0-9]+ from proxy|Failed to connect to (127\.0\.0\.1|localhost|::1|\[::1\]) port|Operation too slow|Recv failure|Connection reset by peer|curl 18|Transferred a partial file|returned error: 408|HTTP 408|Couldn.{1,3}t connect to proxy|Proxy handshake|early EOF|unexpected disconnect' "$1" 2>/dev/null
}

github_egress_retry_direct() {
  local log="$1" line
  [ "${CMUX_GITHUB_EGRESS_DIRECT:-0}" != 1 ] || return 1
  [ -n "$(github_egress__proxy)" ] || return 1
  github_egress__proxy_failure "$log" || return 1
  line="$(grep -m1 -E 'Proxy CONNECT|CONNECT tunnel|from proxy|Failed to connect to|Operation too slow|Recv failure|Connection reset|curl 18|partial file|408|connect to proxy|early EOF|unexpected disconnect' "$log" 2>/dev/null | cut -c1-200)"
  github_egress_go_direct "failed a fetch (${line:-a proxy-shaped error}); trying once more"
  return 0
}
