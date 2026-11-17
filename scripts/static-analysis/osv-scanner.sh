#!/usr/bin/env bash
# osv-scanner: known vulnerabilities in locked dependencies (Cargo.lock,
# bun.lock, package-lock.json, Package.resolved, requirements*.txt, go.sum, ...)
# across the whole tree, against osv.dev (which includes RustSec, GHSA, PyPA, Go).
# Report-only. Exits 0 when osv-scanner ran (vulns or not); nonzero only when it
# could not be installed or crashed.
#
# findings = vulnerability groups (aliases merged) per package per lockfile.
#
# Env: SA_TOOLS_DIR, FAST_CHECKS_OUT as in the other static-analysis scripts.
set -uo pipefail

OSV_VERSION=2.7.1
OSV_SHA256_AMD64=fb7dab19a8bd9bbe5c3189f09d4b7ee1820c9553a23bac202648a56efd2f6ee8
OSV_SHA256_ARM64=983d22fbad9724514e3fcc6acc83b5fa64c5ffa6b0d9f510028f22c1b223ff81

OUT_DIR="${FAST_CHECKS_OUT:-${TMPDIR:-/tmp}/static-analysis-out}"
ROOT="$(git rev-parse --show-toplevel)" || { echo "osv-scanner.sh: not in a git repo" >&2; exit 2; }
cd "$ROOT" || exit 2
mkdir -p "$OUT_DIR" || exit 2
TOOLS_DIR="${SA_TOOLS_DIR:-$HOME/.cache/static-analysis/bin}"
mkdir -p "$TOOLS_DIR" || exit 2
start=$(date +%s)

sha256_of() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

install_osv() {
  local bin="$TOOLS_DIR/osv-scanner-$OSV_VERSION"
  if [ -x "$bin" ]; then echo "$bin"; return 0; fi
  local plat sha
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) plat=linux_amd64; sha=$OSV_SHA256_AMD64 ;;
    Linux-aarch64|Linux-arm64) plat=linux_arm64; sha=$OSV_SHA256_ARM64 ;;
    *) echo "osv-scanner.sh: unsupported platform $(uname -s)-$(uname -m)" >&2; return 1 ;;
  esac
  local tmp; tmp="$(mktemp -d)" || return 1
  curl -fsSL --retry 3 -o "$tmp/osv" \
    "https://github.com/google/osv-scanner/releases/download/v$OSV_VERSION/osv-scanner_$plat" || { rm -rf "$tmp"; return 1; }
  if [ "$(sha256_of "$tmp/osv")" != "$sha" ]; then echo "osv-scanner.sh: sha256 mismatch" >&2; rm -rf "$tmp"; return 1; fi
  install -m 0755 "$tmp/osv" "$bin" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  echo "$bin"
}

OSV="$(install_osv)" || { echo "osv-scanner.sh: install failed" >&2; exit 3; }

json="$OUT_DIR/osv-scanner.json"
txt="$OUT_DIR/osv-scanner.txt"
args=(scan source --recursive --format json --output-file "$json")
cfg=scripts/static-analysis/osv-scanner/osv-scanner.toml
[ -f "$cfg" ] && args+=(--config "$cfg")
# Exit codes: 0 none, 1 vulns found, 128 no lockfiles found; anything else is a crash.
"$OSV" "${args[@]}" . >"$OUT_DIR/osv-scanner.log" 2>&1
rc=$?
case "$rc" in
  0|1) ;;
  128) echo '{"results":[]}' >"$json" ;;
  *) echo "osv-scanner.sh: osv-scanner crashed (exit $rc)" >&2; tail -20 "$OUT_DIR/osv-scanner.log" >&2; exit 4 ;;
esac

findings=$(jq '[.results[]?.packages[]?.groups[]?] | length' "$json")
{
  echo "osv-scanner $OSV_VERSION, findings: $findings (vuln groups per package per lockfile)"
  echo "lockfiles scanned: $(jq '[.results[]?.source.path] | length' "$json") with vulns"
  echo
  echo "== by ecosystem"
  jq -r '.results[]?.packages[]? | .package.ecosystem as $e | .groups[]? | $e' "$json" | sort | uniq -c | sort -rn
  echo
  echo "== findings (max_cvss ecosystem package@version ids lockfile)"
  jq -r --arg root "$ROOT/" '.results[]? | (.source.path | ltrimstr($root)) as $src | .packages[]? | .package as $p
      | .groups[]? | "\(.max_severity // "-") \($p.ecosystem) \($p.name)@\($p.version) \(.ids | join(",")) \($src)"' "$json" \
    | sort -t' ' -k1,1 -rn
} >"$txt"
head -40 "$txt"
echo "full report: $txt"
echo "SA_SUMMARY tool=osv-scanner findings=$findings seconds=$(( $(date +%s) - start ))"
exit 0
