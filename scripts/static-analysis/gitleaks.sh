#!/usr/bin/env bash
# gitleaks: secrets in new commits. Reports (ratchet.py judges it for CI), always --redact (no secret
# value is ever written to the report or the terminal).
# Exits 0 when gitleaks ran (findings or not); nonzero only when it could not be
# installed or crashed.
#
# Env:
#   GITLEAKS_RANGE    git log range to scan (default origin/<base>..HEAD)
#   SA_BASE           base branch name for the default range; when unset, the
#                     closest of origin/feat-cmux-next, origin/main, origin/master
#   GITLEAKS_FULL=1   scan the whole history instead (slow on big repos; local one-off)
#   SA_TOOLS_DIR, FAST_CHECKS_OUT as in the other static-analysis scripts
set -uo pipefail

GITLEAKS_VERSION=8.30.1
GITLEAKS_SHA256_X64=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
GITLEAKS_SHA256_ARM64=e4a487ee7ccd7d3a7f7ec08657610aa3606637dab924210b3aee62570fb4b080

OUT_DIR="${FAST_CHECKS_OUT:-${TMPDIR:-/tmp}/static-analysis-out}"
ROOT="$(git rev-parse --show-toplevel)" || { echo "gitleaks.sh: not in a git repo" >&2; exit 2; }
cd "$ROOT" || exit 2
mkdir -p "$OUT_DIR" || exit 2
TOOLS_DIR="${SA_TOOLS_DIR:-$HOME/.cache/static-analysis/bin}"
mkdir -p "$TOOLS_DIR" || exit 2
start=$(date +%s)

sha256_of() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

install_gitleaks() {
  local bin="$TOOLS_DIR/gitleaks-$GITLEAKS_VERSION"
  if [ -x "$bin" ]; then echo "$bin"; return 0; fi
  local plat sha
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) plat=linux_x64; sha=$GITLEAKS_SHA256_X64 ;;
    Linux-aarch64|Linux-arm64) plat=linux_arm64; sha=$GITLEAKS_SHA256_ARM64 ;;
    *) echo "gitleaks.sh: unsupported platform $(uname -s)-$(uname -m)" >&2; return 1 ;;
  esac
  local tmp; tmp="$(mktemp -d)" || return 1
  local tgz="$tmp/gitleaks.tar.gz"
  curl -fsSL --retry 3 -o "$tgz" \
    "https://github.com/gitleaks/gitleaks/releases/download/v$GITLEAKS_VERSION/gitleaks_${GITLEAKS_VERSION}_${plat}.tar.gz" || { rm -rf "$tmp"; return 1; }
  if [ "$(sha256_of "$tgz")" != "$sha" ]; then echo "gitleaks.sh: sha256 mismatch" >&2; rm -rf "$tmp"; return 1; fi
  mkdir "$tmp/x" && tar -xzf "$tgz" -C "$tmp/x" gitleaks || { rm -rf "$tmp"; return 1; }
  install -m 0755 "$tmp/x/gitleaks" "$bin" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  echo "$bin"
}

GITLEAKS="$(install_gitleaks)" || { echo "gitleaks.sh: install failed" >&2; exit 3; }

pick_base() {
  if [ -n "${SA_BASE:-}" ]; then echo "origin/${SA_BASE#origin/}"; return; fi
  local best="" best_n="" c n
  for c in origin/feat-cmux-next origin/main origin/master; do
    git rev-parse -q --verify "$c^{commit}" >/dev/null || continue
    n=$(git rev-list --count "$c..HEAD" 2>/dev/null) || continue
    if [ -z "$best_n" ] || [ "$n" -lt "$best_n" ]; then best=$c; best_n=$n; fi
  done
  echo "$best"
}

args=(git --redact --no-banner --exit-code 0 --report-format json)
cfg=scripts/static-analysis/gitleaks/gitleaks.toml
[ -f "$cfg" ] && args+=(--config "$cfg")
if [ "${GITLEAKS_FULL:-0}" = 1 ]; then
  scope="full history"
else
  range="${GITLEAKS_RANGE:-}"
  if [ -z "$range" ]; then
    base="$(pick_base)"
    if [ -z "$base" ]; then
      # A CI snapshot checkout has no origin/* refs: fetch the bases' commits (no blobs) and pick again.
      for b in feat-cmux-next main master; do
        git fetch --no-recurse-submodules --quiet --no-tags --filter=blob:none origin "+refs/heads/$b:refs/remotes/origin/$b" 2>/dev/null || true
      done
      if [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
        git fetch --no-recurse-submodules --quiet --no-tags --filter=blob:none --unshallow origin 2>/dev/null || true
      fi
      base="$(pick_base)"
    fi
    if [ -z "$base" ]; then echo "gitleaks.sh: no base branch found and origin could not be fetched (a private repo's CI checkout has no credential); set SA_BASE or GITLEAKS_RANGE, or run it in a checkout that has origin/<base>" >&2; exit 2; fi
    range="$base..HEAD"
  fi
  scope="$range"
  args+=(--log-opts="$range")
fi

json="$OUT_DIR/gitleaks.json"
txt="$OUT_DIR/gitleaks.txt"
"$GITLEAKS" "${args[@]}" --report-path "$json" "$ROOT" >"$OUT_DIR/gitleaks.log" 2>&1
rc=$?
if [ "$rc" -ne 0 ] || [ ! -f "$json" ]; then
  echo "gitleaks.sh: gitleaks crashed (exit $rc)" >&2; tail -20 "$OUT_DIR/gitleaks.log" >&2; exit 4
fi

findings=$(jq 'length' "$json")
{
  echo "gitleaks $GITLEAKS_VERSION, scope: $scope, findings: $findings (values redacted)"
  echo
  echo "== by rule"
  jq -r '.[].RuleID' "$json" | sort | uniq -c | sort -rn
  echo
  echo "== findings (rule commit file:line)"
  jq -r '.[] | "\(.RuleID) \(.Commit[0:12]) \(.File):\(.StartLine)"' "$json"
} >"$txt"
head -30 "$txt"
echo "full report: $txt"
echo "SA_SUMMARY tool=gitleaks findings=$findings seconds=$(( $(date +%s) - start ))"
exit 0
