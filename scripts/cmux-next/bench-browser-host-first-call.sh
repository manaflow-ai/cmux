set -u
# The probe VM's browser path on a fleet runner, from the image's own pins: cmux-browser-host 1.0.0-r1 (the
# image's release, not this tree) launching Chrome 156 headless, a cua display Chrome on Xvfb :99 beside it,
# and the probe's call shape (page.goto + title). Each round starts a fresh host, so its Chrome is cold, and
# times the first eval. Modes: plain, cua (display Chrome started 5 s before, as the probe does), both (the
# display Chrome and the host start together). LOAD=1 adds 4 busy processes per core and 2 fsync writers.
work=$(mktemp -d)
cd "$work" || exit 1
curl -fsSL -o chrome.zip https://storage.googleapis.com/chrome-for-testing-public/156.0.8078.47/linux64/chrome-linux64.zip
unzip -q chrome.zip
curl -fsSL -o host.tgz https://github.com/manaflow-ai/cmux/releases/download/cmux-browser-host-v1.0.0-r1/cmux-browser-host-1.0.0-r1-x86_64-unknown-linux-gnu.tar.gz
mkdir host && tar -xzf host.tgz -C host
host=$(find "$work/host" -type f -name cmux-browser-host | head -1)
chrome="$work/chrome-linux64/chrome"
sudo -n sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 >/dev/null 2>&1 || true
command -v Xvfb >/dev/null || { sudo -n apt-get -qq update >/dev/null && sudo -n apt-get -qq install -y xvfb >/dev/null; }
"$host" version; "$chrome" --version; nproc
Xvfb :99 -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 &
xvfb=$!
python3 -I -m http.server 18080 --bind 127.0.0.1 --directory "$work" >/dev/null 2>&1 &
web=$!
printf '<title>cmux agent tools probe</title>probe' > "$work/index.html"
export CMUX_BROWSER_HOST_CHROMIUM="$chrome" CMUX_BROWSER_HOST_BACKGROUND_FULL_RATE=0

load_pids=()
if [ "${LOAD:-0}" = 1 ]; then
  for _ in $(seq $(( $(nproc) * 4 ))); do sh -c 'while :; do :; done' & load_pids+=($!); done
  for _ in 1 2; do sh -c 'while :; do dd if=/dev/zero of=/tmp/fsync-$$ bs=1M count=1 conv=fsync 2>/dev/null; done' & load_pids+=($!); done
fi

cua_start() {
  rm -rf "$work/cua-profile"
  DISPLAY=:99 setsid "$chrome" --no-first-run --user-data-dir="$work/cua-profile" --window-position=0,0 --window-size=1280,800 --app=http://127.0.0.1:18080/ >/dev/null 2>&1 < /dev/null &
  cua_pid=$!
}
cua_stop() { [ -n "${cua_pid:-}" ] && kill -KILL -- "-$cua_pid" 2>/dev/null; cua_pid=; }

round() {  # mode n
  local mode=$1 n=$2 sock="$work/host-$n.sock" t0 t1 out rc
  sync; echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null 2>&1
  [ "$mode" = cua ] && { cua_start; sleep 5; }
  [ "$mode" = both ] && cua_start
  t0=$(date +%s%N)
  setsid "$host" serve --socket "$sock" >"$work/host-$n.log" 2>&1 < /dev/null &
  local hpid=$!
  # eval starts a host of its own when no socket answers yet; wait for this host's socket (the clock runs).
  for _ in $(seq 200); do [ -S "$sock" ] && break; sleep 0.05; done
  out=$(timeout 120 "$host" eval --socket "$sock" --session probe --timeout-ms 60000 'await page.goto("http://127.0.0.1:18080/"); console.log(await page.title())' 2>&1)
  rc=$?
  t1=$(date +%s%N)
  local ok=false ms=$(( (t1 - t0) / 1000000 )); case "$out" in *"cmux agent tools probe"*) ok=true;; esac
  echo "$ms" >> "$work/ms-$mode"
  [ "$ok" = false ] && echo x >> "$work/fail-$mode"
  # Only a red or slow round prints in full (CI keeps the output's tail).
  if [ "$ok" = false ] || [ "$ms" -gt 5000 ]; then
    printf '{"mode":"%s","load":%s,"round":%d,"ok":%s,"rc":%d,"ms":%d}\n%s\n' "$mode" "${LOAD:-0}" "$n" "$ok" "$rc" "$ms" "$(printf '%s' "$out" | tail -c 300)"
    echo "--- host log round $n"; tail -c 1500 "$work/host-$n.log"
  fi
  kill -TERM -- "-$hpid" 2>/dev/null; sleep 0.5; kill -KILL -- "-$hpid" 2>/dev/null
  cua_stop
  rm -f "$sock"
}

for mode in ${MODES:-plain cua both}; do
  echo "== $mode load=${LOAD:-0}"
  for n in $(seq "${ROUNDS:-40}"); do round "$mode" "$n"; done
done
for mode in ${MODES:-plain cua both}; do
  sort -n "$work/ms-$mode" > "$work/sorted"
  rows=$(wc -l < "$work/sorted")
  printf 'SUMMARY mode=%s load=%s rounds=%d red=%d p50=%s p90=%s max=%s ms\n' "$mode" "${LOAD:-0}" "$rows" \
    "$(cat "$work/fail-$mode" 2>/dev/null | wc -l)" "$(sed -n "$(( rows / 2 + 1 ))p" "$work/sorted")" \
    "$(sed -n "$(( rows * 9 / 10 + 1 ))p" "$work/sorted")" "$(tail -1 "$work/sorted")"
done
for p in "${load_pids[@]}"; do kill -KILL "$p" 2>/dev/null; done
kill "$xvfb" "$web" 2>/dev/null
true
