#!/usr/bin/env bash
# try-pr.sh measured end to end on a Mac with a screen: downloads the cmux NEXT nightly, then for each
# PR runs `try-pr.sh PR --from <nightly>` and times it to the side instance (cmux PR #N) loading the
# PR's page from the PR's dev server (the first client of that port other than the server), with a screenshot a second
# later. Each side instance is removed after (try-pr.sh PR --stop).
#   scripts/measure/try-pr-side-instance.sh OUT PR...   (OUT: a folder for the logs, PNGs and result.json)
set -uo pipefail
out="${1:?usage: try-pr-side-instance.sh OUT PR...}"; shift
[[ $# -gt 0 ]] || { echo "usage: try-pr-side-instance.sh OUT PR..." >&2; exit 1; }
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
mkdir -p "$out"
now() { python3 -c 'import time; print(f"{time.time():.3f}")'; }
work="$(mktemp -d "${TMPDIR:-/tmp}/try-pr-measure.XXXXXX")"
# Physical, as side-instance.sh and try-pr.sh resolve it ($TMPDIR is under a /var link).
mkdir -p "$work/side"; CMUX_SIDE_ROOT="$(cd "$work/side" && pwd -P)"; export CMUX_SIDE_ROOT
trap 'rm -rf "$work"' EXIT

# try-pr.sh reads the base branch's history for the merge base.
git -C "$root" fetch -q origin "+refs/heads/${CMUX_TRY_PR_BASE:-feat-cmux-next}:refs/remotes/origin/${CMUX_TRY_PR_BASE:-feat-cmux-next}"
git -C "$root" rev-parse --is-shallow-repository | grep -q true && git -C "$root" fetch -q --unshallow origin

start=$(now)
curl -fsSL -o "$work/nightly.dmg" https://github.com/manaflow-ai/cmux/releases/download/nightly-next/cmux-nightly-next-macos.dmg
mkdir -p "$work/mnt" "$work/app"
hdiutil attach -nobrowse -readonly -mountpoint "$work/mnt" "$work/nightly.dmg" >/dev/null
ditto "$(find "$work/mnt" -maxdepth 1 -name '*.app' | head -1)" "$work/app/cmux NEXT.app"
hdiutil detach "$work/mnt" >/dev/null
app="$work/app/cmux NEXT.app"
echo "nightly $(plutil -extract CMUXCommit raw "$app/Contents/Info.plist" 2>/dev/null || echo '?') in $(python3 -c "print(round($(now)-$start,1))") s"

results=()
for pr in "$@"; do
  echo "=== #$pr"
  port=$((20000 + pr % 10000))
  t0=$(now)
  "$root/scripts/cmux-next/try-pr.sh" "$pr" --from "$app" >"$out/try-$pr.log" 2>&1 &
  try=$!
  pid="" loaded="" done_at=""
  for _ in $(seq 1 3000); do
    [[ -z "$pid" && -f "$CMUX_SIDE_ROOT/pr-$pr/pid" ]] && pid="$(cat "$CMUX_SIDE_ROOT/pr-$pr/pid")"
    # try-pr.sh takes the next free port when the usual one is in use, and records it.
    if [[ -f "$CMUX_SIDE_ROOT/pr-$pr/port" ]]; then port="$(cat "$CMUX_SIDE_ROOT/pr-$pr/port")"; fi
    # A client of the dev server other than the server itself: the app or its web content.
    if [[ -n "$pid" ]] && lsof -nP -iTCP:"$port" -sTCP:ESTABLISHED -Fc 2>/dev/null | sed -n 's/^c//p' | grep -qv -E '^(bun|node)$'; then
      loaded=$(now); break
    fi
    if [[ -z "$done_at" ]] && ! kill -0 "$try" 2>/dev/null; then done_at=$(now); fi
    [[ -n "$done_at" ]] && python3 -c "import sys; sys.exit(0 if $(now)-$done_at > 60 else 1)" && break
    sleep 0.1
  done
  wait "$try"; rc=$?
  [[ -z "$done_at" ]] && done_at=$(now)
  sleep 1; screencapture -x "$out/pr-$pr.png" 2>/dev/null || true
  sed 's/^/  /' "$out/try-$pr.log" | tail -8
  verdict="$(sed -n "s/^#$pr at [0-9a-f]*: //p" "$out/try-$pr.log")"
  to_loaded=null; [[ -n "$loaded" ]] && to_loaded=$(python3 -c "print(round($loaded-$t0,2))")
  row="{\"pr\": $pr, \"verdict\": \"$verdict\", \"rc\": $rc, \"try_pr_s\": $(python3 -c "print(round($done_at-$t0,2))"), \"to_page_loaded_s\": $to_loaded}"
  results+=("$row"); echo "$row"
  "$root/scripts/cmux-next/try-pr.sh" "$pr" --stop 2>&1 | tail -2
done
( IFS=,; echo "[${results[*]}]" ) | python3 -m json.tool >"$out/result.json"
echo "result:"; cat "$out/result.json"
