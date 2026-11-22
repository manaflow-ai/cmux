#!/usr/bin/env bash
# zizmor: security audit of GitHub Actions workflows and composite actions.
# Reports; ratchet.py judges the report for CI. Exits 0 when zizmor ran (findings or not); nonzero only when it
# could not be installed or crashed.
#
# Env:
#   SA_TOOLS_DIR      where pinned tool binaries live (default ~/.cache/static-analysis/bin)
#   FAST_CHECKS_OUT   report directory (default ${TMPDIR:-/tmp}/static-analysis-out)
#   ZIZMOR_PERSONA    regular (default) | pedantic | auditor
#   ZIZMOR_TREE       audit the workflow and action files under this directory instead of
#                     the checkout's tracked ones, each by its path there (ratchet.py's base
#                     and head copies of the files a change touches)
#   GH_TOKEN          if set, zizmor also runs its online audits (impostor commits,
#                     known-vulnerable actions, ref confusion); otherwise offline only.
set -uo pipefail

ZIZMOR_VERSION=1.32.0
ZIZMOR_SHA256_X86_64=bb110cc765eca9cd7efb2e284a956be5974c60027b0970f16397d86208a9957b
ZIZMOR_SHA256_AARCH64=cb152b207f815116d7fa1c1ee4614f61578803351395052908095e79adfd9fd0

OUT_DIR="${FAST_CHECKS_OUT:-${TMPDIR:-/tmp}/static-analysis-out}"
ROOT="$(git rev-parse --show-toplevel)" || { echo "zizmor.sh: not in a git repo" >&2; exit 2; }
cd "$ROOT" || exit 2
mkdir -p "$OUT_DIR" || exit 2
TOOLS_DIR="${SA_TOOLS_DIR:-$HOME/.cache/static-analysis/bin}"
mkdir -p "$TOOLS_DIR" || exit 2
start=$(date +%s)

sha256_of() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

install_zizmor() {
  local bin="$TOOLS_DIR/zizmor-$ZIZMOR_VERSION"
  if [ -x "$bin" ]; then echo "$bin"; return 0; fi
  local arch sha triple
  case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) triple=x86_64-unknown-linux-gnu; sha=$ZIZMOR_SHA256_X86_64 ;;
    Linux-aarch64|Linux-arm64) triple=aarch64-unknown-linux-gnu; sha=$ZIZMOR_SHA256_AARCH64 ;;
    *)
      if command -v cargo >/dev/null; then
        cargo install --locked --quiet --version "$ZIZMOR_VERSION" --root "$TOOLS_DIR/zizmor-cargo" zizmor >&2 || return 1
        ln -sf "$TOOLS_DIR/zizmor-cargo/bin/zizmor" "$bin" && echo "$bin"; return $?
      fi
      echo "zizmor.sh: unsupported platform $(uname -s)-$(uname -m) and no cargo" >&2; return 1 ;;
  esac
  local tmp; tmp="$(mktemp -d)" || return 1
  local tgz="$tmp/zizmor.tar.gz"
  curl -fsSL --retry 3 -o "$tgz" \
    "https://github.com/zizmorcore/zizmor/releases/download/v$ZIZMOR_VERSION/zizmor-$triple.tar.gz" || { rm -rf "$tmp"; return 1; }
  if [ "$(sha256_of "$tgz")" != "$sha" ]; then echo "zizmor.sh: sha256 mismatch" >&2; rm -rf "$tmp"; return 1; fi
  mkdir "$tmp/x" && tar -xzf "$tgz" -C "$tmp/x" || { rm -rf "$tmp"; return 1; }
  local found; found="$(find "$tmp/x" -type f -name zizmor | head -1)"
  [ -n "$found" ] || { rm -rf "$tmp"; return 1; }
  install -m 0755 "$found" "$bin" || { rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
  echo "$bin"
}

ZIZMOR="$(install_zizmor)" || { echo "zizmor.sh: install failed" >&2; exit 3; }

config="$ROOT/scripts/static-analysis/zizmor/zizmor.yml"
# Inputs: every workflow dir and every composite action (action.yml) tracked in git, or under ZIZMOR_TREE.
inputs=()
if [ -n "${ZIZMOR_TREE:-}" ]; then
  cd "$ZIZMOR_TREE" || exit 2
  list_inputs() { find . -type f \( -name '*.yml' -o -name '*.yaml' \) | sed 's|^\./||'; }
else
  list_inputs() { git ls-files -- '.github/workflows/*.yml' '.github/workflows/*.yaml' '*action.yml' '*action.yaml'; }
fi
while IFS= read -r f; do inputs+=("$f"); done < <(
  list_inputs | grep -E '(^\.github/workflows/[^/]+\.ya?ml$|(^|/)action\.ya?ml$)' | sort -u)

json="$OUT_DIR/zizmor.json"
txt="$OUT_DIR/zizmor.txt"
if [ "${#inputs[@]}" -eq 0 ]; then
  echo "no workflow or action files" >"$txt"; echo '[]' >"$json"
  echo "SA_SUMMARY tool=zizmor findings=0 seconds=$(( $(date +%s) - start ))"; exit 0
fi

args=(--persona "${ZIZMOR_PERSONA:-regular}" --no-progress)
[ -f "$config" ] && args+=(--config "$config")
[ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ] || args+=(--offline)

# zizmor exit codes: 0 clean, 10-14 findings by max severity, anything else a
# crash. One file whose audit crashes (zizmor aborts the whole run on it) must not
# hide the rest, so each file is its own zizmor run; crashed files are listed, not
# fatal. The runs go ZIZMOR_JOBS (default: every core) at a time and are joined in
# file order: one at a time took 17 s for 279 files on 8 cores, and the CI guard
# step (ratchet.py) runs this on every guard pass.
tmp="$(mktemp -d)" || exit 2
: >"$OUT_DIR/zizmor.stderr"
: >"$txt"
audit_one() {
  local i=$1 f=$2 rc
  "$ZIZMOR" "${args[@]}" --format json "$f" >"$tmp/$i.json" 2>"$tmp/$i.err"
  rc=$?
  if [ "$rc" -ne 0 ] && { [ "$rc" -lt 10 ] || [ "$rc" -gt 14 ]; }; then
    echo "$f (exit $rc)" >"$tmp/$i.crash"; rm -f "$tmp/$i.json"; return
  fi
  [ "$rc" -ne 0 ] && "$ZIZMOR" "${args[@]}" --format plain "$f" >"$tmp/$i.txt" 2>/dev/null
  return 0
}
jobs_max="${ZIZMOR_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
i=0
for f in "${inputs[@]}"; do
  i=$((i + 1))
  audit_one "$i" "$f" &
  # Batches, not `wait -n`: macOS ships bash 3.2.
  [ $((i % jobs_max)) -eq 0 ] && wait
done
wait
crashed=()
for i in $(seq 1 "${#inputs[@]}"); do
  [ -f "$tmp/$i.err" ] && cat "$tmp/$i.err" >>"$OUT_DIR/zizmor.stderr"
  [ -f "$tmp/$i.crash" ] && crashed+=("$(cat "$tmp/$i.crash")")
  [ -f "$tmp/$i.txt" ] && cat "$tmp/$i.txt" >>"$txt"
done
if [ "${#crashed[@]}" -eq "${#inputs[@]}" ]; then
  echo "zizmor.sh: zizmor crashed on every file" >&2; tail -20 "$OUT_DIR/zizmor.stderr" >&2; rm -rf "$tmp"; exit 4
fi
jsons=()
for i in $(seq 1 "${#inputs[@]}"); do [ -f "$tmp/$i.json" ] && jsons+=("$tmp/$i.json"); done
jq -s 'add // []' "${jsons[@]}" >"$json"
rm -rf "$tmp"

findings=$(jq 'length' "$json" 2>/dev/null || echo 0)
{
  echo
  echo "== files: ${#inputs[@]} audited, ${#crashed[@]} where zizmor itself failed"
  for c in "${crashed[@]}"; do echo "zizmor failed: $c"; done
  echo
  echo "== by severity"
  jq -r '.[] | .determinations.severity' "$json" | sort | uniq -c | sort -rn
  echo "== by audit"
  jq -r '.[] | "\(.determinations.severity) \(.ident)"' "$json" | sort | uniq -c | sort -rn
} >>"$txt"
grep -E '^ *[0-9]+ (High|Medium|Low|Informational|Unknown)' "$txt" | head -40
echo "full report: $txt"
echo "SA_SUMMARY tool=zizmor findings=$findings seconds=$(( $(date +%s) - start ))"
exit 0
