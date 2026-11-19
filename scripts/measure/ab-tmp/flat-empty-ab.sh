#!/usr/bin/env bash
# Temporary A/B (cmux#47055, not for merge): chat-100k-flat's empty_x20 launch at two commits' webviews, interleaved,
# pinned to 4 CPUs like the perf cron's runner, with one chrome-headless-shell for every round.
#   flat-empty-ab.sh ROUNDS NAME... : each NAME is a to-NAME.patch.xz beside this file (head = no patch).
# CASES=grown-many at 2000 rows: its empty_x20 launch is the cron's (one-turn chats; ROWS only sizes the grown launch).
set -uo pipefail
rounds="$1"; shift
here="$(cd "$(dirname "$0")" && pwd)"
root="$(git -C "$here" rev-parse --show-toplevel)"
out="${FAST_CHECKS_OUT:-/tmp/flat-empty-ab}"
mkdir -p "$out"
echo "flat-empty-ab: $(nproc) CPUs; rounds $rounds; trees $*"
shell_line="$("$root/scripts/ci/ensure-system-chrome.sh" | grep '^CMUX_CHROME_HEADLESS_SHELL=' | tail -n 1)"
export "${shell_line?}"
echo "flat-empty-ab: $CMUX_CHROME_HEADLESS_SHELL ($("$CMUX_CHROME_HEADLESS_SHELL" --version 2>/dev/null))"
for name in "$@"; do
  tree="/tmp/ab-$name"
  rm -rf "$tree" && mkdir -p "$tree"
  for entry in "$root"/* "$root"/.[!.]*; do
    base="${entry##*/}"
    [ "$base" = webviews ] || [ "$base" = .git ] || ln -s "$entry" "$tree/$base"
  done
  (cd "$root" && tar --exclude=webviews/node_modules -cf - webviews) | tar -xf - -C "$tree"
  if [ "$name" != head ]; then
    xz -dc "$here/to-$name.patch.xz" > "$tree/to.patch"
    (cd "$tree" && git apply --unsafe-paths -p1 to.patch) || { echo "flat-empty-ab: $name: patch failed"; exit 2; }
  fi
  (cd "$tree/webviews" && bun install --frozen-lockfile >/dev/null 2>&1 || bun install >/dev/null 2>&1) \
    || { echo "flat-empty-ab: $name: bun install failed"; exit 2; }
done
for round in $(seq 1 "$rounds"); do
  for name in "$@"; do
    log="$out/$name-$round.log"
    start=$SECONDS
    (cd "/tmp/ab-$name/webviews" && CASES=grown-many IDLE_S=5 STREAM_S=5 timeout 1500 taskset -c 0-3 \
      bun bench/chat-100k-flat.bench.ts 2000 20 > "$log" 2>&1)
    code=$?
    echo "flat-empty-ab: round $round $name exit $code in $((SECONDS - start)) s"
    grep -E "^empty_x20|^grown_x20|empty_x20: CPU settled|empty_x20: idle windows|empty_x20_after: CPU settled|empty_x20_after: idle windows|baseline idle" "$log" | sed "s/^/  $name $round: /"
  done
done
