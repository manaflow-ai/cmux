set -u
# The probe VM's browser path with the real daemon on a fleet runner: the image's pinned cmux-tui runs
# `server start` and starts cmux-browser-host 1.0.0-r1 itself (supervised, socket-activated, the history link)
# on the first browser_repl_eval, sent over `cmux-tui mcp` as the probe sends it. Each round: a fresh Chrome
# copy unzipped into a new directory with caches dropped (a first-use install), a fresh daemon and runtime dir.
# Everything (daemon, host, both Chromes, load) runs in one scope capped at CPUS cpus and MEM of memory, the
# probe VM's size. Modes: plain, cua (a display Chrome started 5 s before). LOAD=1: 4 busy processes per cpu
# and 2 fsync writers inside the scope.
self=$(readlink -f "$0")
if [ "${INNER:-0}" != 1 ]; then
  work=$(mktemp -d)
  cd "$work" || exit 1
  curl -fsSL -o chrome.zip https://storage.googleapis.com/chrome-for-testing-public/156.0.8078.47/linux64/chrome-linux64.zip
  curl -fsSL -o host.tgz https://github.com/manaflow-ai/cmux/releases/download/cmux-browser-host-v1.0.0-r1/cmux-browser-host-1.0.0-r1-x86_64-unknown-linux-gnu.tar.gz
  curl -fsSL -o cmux-tui https://files.cmux.com/cmux-tui/69400ff148b20f0f79d350134e4a6f720e08d5cf/cmux-tui-x86_64-unknown-linux-musl
  chmod +x cmux-tui
  mkdir host && tar -xzf host.tgz -C host
  sudo -n sysctl -w kernel.apparmor_restrict_unprivileged_userns=0 >/dev/null 2>&1 || true
  command -v Xvfb >/dev/null || { sudo -n apt-get -qq update >/dev/null && sudo -n apt-get -qq install -y xvfb >/dev/null; }
  ./cmux-tui --version; "$(find host -type f -name cmux-browser-host | head -1)" version
  last=$(( ${CPUS:-2} - 1 ))
  exec sudo -n systemd-run --scope --quiet -p "AllowedCPUs=0-$last" -p "MemoryMax=${MEM:-4G}" -- \
    setpriv --reuid="$(id -u)" --regid="$(id -g)" --init-groups \
    env HOME="$HOME" PATH="$PATH" INNER=1 WORK="$work" LOAD="${LOAD:-0}" ROUNDS="${ROUNDS:-30}" MODES="${MODES:-plain cua}" CPUS="${CPUS:-2}" \
    bash "$self"
fi

cd "$WORK" || exit 1
nproc; grep MemTotal /proc/meminfo; cat /sys/fs/cgroup/$(sed -n 's/^0:://p' /proc/self/cgroup)/memory.max 2>/dev/null
host=$(find "$WORK/host" -type f -name cmux-browser-host | head -1)
Xvfb :99 -screen 0 1280x800x24 -nolisten tcp >/dev/null 2>&1 &
xvfb=$!
printf '<title>cmux agent tools probe</title>probe' > index.html
python3 -I -m http.server 18080 --bind 127.0.0.1 --directory "$WORK" >/dev/null 2>&1 &
web=$!
cat > mcp-client.mjs <<'EOF'
// One MCP tools/call browser_repl_eval over `cmux-tui mcp` stdio, as the probe's client does; prints ms and text.
import { spawn } from "node:child_process";
const [bin] = process.argv.slice(2);
const p = spawn(bin, ["mcp"], { stdio: ["pipe", "pipe", "inherit"] });
let buf = "", t0 = 0;
const send = (m) => p.stdin.write(JSON.stringify(m) + "\n");
p.stdout.on("data", (d) => {
  buf += d;
  let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i); buf = buf.slice(i + 1);
    if (!line.trim()) continue;
    const m = JSON.parse(line);
    if (m.id === 1) {
      send({ jsonrpc: "2.0", method: "notifications/initialized" });
      t0 = performance.now();
      send({ jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "browser_repl_eval", arguments: { session: "probe",
        code: 'await page.goto("http://127.0.0.1:18080/"); console.log(await page.title())' } } });
    } else if (m.id === 2) {
      const text = (m.result?.content ?? []).map((c) => c.text ?? "").join(" ") || JSON.stringify(m.error ?? m.result);
      console.log(JSON.stringify({ ms: Math.round(performance.now() - t0), text: text.slice(0, 400) }));
      p.kill(); process.exit(0);
    }
  }
});
send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "bench", version: "1" } } });
setTimeout(() => { console.log(JSON.stringify({ ms: null, text: "client timeout 150 s" })); p.kill(); process.exit(0); }, 150000);
EOF

load_pids=()
if [ "$LOAD" = 1 ]; then
  for _ in $(seq $(( CPUS * 4 ))); do sh -c 'while :; do :; done' & load_pids+=($!); done
  for _ in 1 2; do sh -c 'while :; do dd if=/dev/zero of=/tmp/fsync-$$ bs=1M count=1 conv=fsync 2>/dev/null; done' & load_pids+=($!); done
fi

descendants() {  # pid: every descendant pid
  local child
  for child in $(pgrep -P "$1"); do echo "$child"; descendants "$child"; done
}

round() {  # mode n
  local mode=$1 n=$2 dir="$WORK/r$n-$mode" cua= daemon out ok ms
  mkdir -p "$dir/run" "$dir/home" && chmod 700 "$dir/run"
  unzip -q "$WORK/chrome.zip" -d "$dir"
  sync; echo 3 | sudo -n tee /proc/sys/vm/drop_caches >/dev/null 2>&1
  local env=(HOME="$dir/home" XDG_RUNTIME_DIR="$dir/run" CMUX_BROWSER_HOST_BIN="$host"
    CMUX_BROWSER_HOST_CHROMIUM="$dir/chrome-linux64/chrome" CMUX_BROWSER_HOST_BACKGROUND_FULL_RATE=0)
  if [ "$mode" = cua ]; then
    DISPLAY=:99 setsid "$dir/chrome-linux64/chrome" --no-first-run --user-data-dir="$dir/cua-profile" --window-position=0,0 --window-size=1280,800 --app=http://127.0.0.1:18080/ >/dev/null 2>&1 < /dev/null &
    cua=$!
    sleep 5
  fi
  env "${env[@]}" setsid "$WORK/cmux-tui" server start >"$dir/daemon.log" 2>&1 < /dev/null &
  daemon=$!
  for _ in $(seq 300); do [ -n "$(find "$dir/run" -type s 2>/dev/null | head -1)" ] && break; sleep 0.1; done
  out=$(env "${env[@]}" node "$WORK/mcp-client.mjs" "$WORK/cmux-tui" 2>"$dir/mcp.stderr")
  ms=$(printf '%s' "$out" | sed -n 's/.*"ms":\([0-9]*\).*/\1/p'); ms=${ms:-150000}
  ok=false; case "$out" in *"cmux agent tools probe"*) ok=true;; esac
  echo "$ms" >> "$WORK/ms-$mode"; [ "$ok" = false ] && echo x >> "$WORK/fail-$mode"
  if [ "$ok" = false ] || [ "$ms" -gt 5000 ]; then
    echo "{\"mode\":\"$mode\",\"round\":$n,\"ok\":$ok,\"ms\":$ms} $out"
    echo "--- daemon log"; grep -iE 'browser|chrom|cdp|permission|error' "$dir/daemon.log" | tail -30 | cut -c1-300
    echo "--- mcp stderr"; tail -c 600 "$dir/mcp.stderr"
    echo "--- processes"; ps -eo pid,stat,wchan:32,etimes,args | grep -E '[c]hrome-linux64/chrome|[c]mux-browser-host' | cut -c1-200 | head -12
  fi
  # The host runs in its own process group (the daemon starts it so): end the daemon's descendants by pid first.
  local pids; pids=$(descendants "$daemon")
  kill -KILL -- "-$daemon" 2>/dev/null
  for pid in $pids; do kill -KILL "$pid" 2>/dev/null; done
  # A daemon that forked away: its host's socket and Chrome's binary are under this round's own directory.
  for pid in $(pgrep -f -- "$dir/"); do kill -KILL "$pid" 2>/dev/null; done
  [ -n "$cua" ] && kill -KILL -- "-$cua" 2>/dev/null
  rm -rf "$dir"
}

for mode in $MODES; do
  for n in $(seq "$ROUNDS"); do round "$mode" "$n"; done
done
for mode in $MODES; do
  sort -n "$WORK/ms-$mode" > "$WORK/sorted"; rows=$(wc -l < "$WORK/sorted")
  printf 'SUMMARY daemon mode=%s load=%s cpus=%s rounds=%d red=%d p50=%s p90=%s max=%s ms\n' "$mode" "$LOAD" "$CPUS" "$rows" \
    "$(cat "$WORK/fail-$mode" 2>/dev/null | wc -l)" "$(sed -n "$(( rows / 2 + 1 ))p" "$WORK/sorted")" \
    "$(sed -n "$(( rows * 9 / 10 + 1 ))p" "$WORK/sorted")" "$(tail -1 "$WORK/sorted")"
done
for p in "${load_pids[@]}"; do kill -KILL "$p" 2>/dev/null; done
kill "$xvfb" "$web" 2>/dev/null
true
