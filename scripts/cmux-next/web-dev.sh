#!/usr/bin/env bash
# Run the cmux-next webviews and a private acpmux daemon in a normal browser.
# This script never builds Rust locally. A missing SHA cache is built by cmux-ci
# and downloaded into ~/.cache/cmux-web-dev/acpmux/<sha>/.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
webviews_root="$repo_root/webviews"
sha="$(git -C "$repo_root" rev-parse HEAD)"
home_root="${HOME:?HOME is required}"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-next-web-dev.XXXXXX")"
index_dir="$work_dir/index"
mkdir -p "$index_dir"

# One stable port per surface. They are all loopback-only; the index is separate so its links can
# carry the daemon token in a URL fragment (fragments never reach a server or appear in Vite logs).
base_port="${CMUX_WEB_DEV_BASE_PORT:-4200}"
agent_port="${CMUX_WEB_DEV_AGENT_PORT:-4176}"
preview_port="${CMUX_WEB_DEV_PREVIEW_PORT:-4175}"
settings_port="${CMUX_WEB_DEV_SETTINGS_PORT:-4177}"
gallery_port="${CMUX_WEB_DEV_GALLERY_PORT:-4178}"
index_port="${CMUX_WEB_DEV_INDEX_PORT:-4199}"
base_origin="http://127.0.0.1:$base_port"
agent_origin="http://127.0.0.1:$agent_port"
preview_origin="http://127.0.0.1:$preview_port"
settings_origin="http://127.0.0.1:$settings_port"
gallery_origin="http://127.0.0.1:$gallery_port"
index_origin="http://127.0.0.1:$index_port"

server_pids=()
daemon_pid=""
index_pid=""
hmr_pid=""
daemon_home="$home_root/.acpmux/web-dev"
acpmux_bin=""
fleet_seconds="cached"
daemon_seconds="unmeasured"
hmr_seconds="unmeasured"

now_ms() {
  python3 -c 'import time; print(time.time_ns() // 1_000_000)'
}

cleanup() {
  local status=$?
  trap - EXIT INT TERM
  if [[ -n "$daemon_pid" ]] && kill -0 "$daemon_pid" 2>/dev/null; then
    # The daemon owns its socket and agent children; ask it to close those first. This is scoped
    # by ACPMUX_HOME and never searches for or kills another process.
    ACPMUX_HOME="$daemon_home" "$acpmux_bin" daemon shutdown >/dev/null 2>&1 || true
    if kill -0 "$daemon_pid" 2>/dev/null; then kill -TERM "$daemon_pid" 2>/dev/null || true; fi
    wait "$daemon_pid" 2>/dev/null || true
  fi
  if [[ -n "$index_pid" ]] && kill -0 "$index_pid" 2>/dev/null; then kill -TERM "$index_pid" 2>/dev/null || true; fi
  if [[ -n "$hmr_pid" ]] && kill -0 "$hmr_pid" 2>/dev/null; then kill -TERM "$hmr_pid" 2>/dev/null || true; fi
  for pid in "${server_pids[@]}"; do
    if kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid" 2>/dev/null || true; fi
  done
  for pid in "${server_pids[@]}"; do wait "$pid" 2>/dev/null || true; done
  [[ -z "$index_pid" ]] || wait "$index_pid" 2>/dev/null || true
  rm -rf "$work_dir"
  exit "$status"
}
trap cleanup EXIT INT TERM

wait_http() {
  local url="$1"
  local deadline=$(( $(date +%s) + 30 ))
  while (( $(date +%s) < deadline )); do
    if curl -fsS --max-time 1 "$url" >/dev/null 2>&1; then return 0; fi
    for pid in "${server_pids[@]}"; do
      if ! kill -0 "$pid" 2>/dev/null; then
        echo "error: a Vite server exited while waiting for $url (logs: $work_dir/*.log)" >&2
        exit 1
      fi
    done
    sleep 0.1
  done
  echo "error: dev server did not answer at $url" >&2
  exit 1
}

start_vite() {
  local name="$1" log="$work_dir/$1.log"
  shift
  echo "starting $name (log: $log)"
  (cd "$webviews_root" && "$@") >"$log" 2>&1 &
  server_pids+=("$!")
}

find_acpmux() {
  local cache="$home_root/.cache/cmux-web-dev/acpmux/$sha/acpmux"
  if [[ -x "$cache" ]]; then
    acpmux_bin="$cache"
    return
  fi
  if [[ -n "${CMUX_NEXT_ACPMUX_BIN:-}" && -x "$CMUX_NEXT_ACPMUX_BIN" ]]; then
    acpmux_bin="$CMUX_NEXT_ACPMUX_BIN"
    echo "warning: using CMUX_NEXT_ACPMUX_BIN; it is not the SHA cache" >&2
    return
  fi

  local ci="${CMUX_CI_BIN:-$home_root/.local/bin/cmux-ci}"
  local artifact_rel=".cmux-web-dev-acpmux-$sha"
  local fleet_log="$work_dir/acpmux-fleet.log"
  local artifact_tmp="$work_dir/acpmux"
  if [[ -x "$ci" ]]; then
    local started job
    started="$(now_ms)"
    echo "no cached acpmux for $sha; requesting a macOS fleet build"
    if (cd "$repo_root" && "$ci" run --class light --script scripts/cmux-next/build-acpmux.sh \
      --ref "$sha" --repo "$(git -C "$repo_root" remote get-url canonical 2>/dev/null || git -C "$repo_root" remote get-url origin)" \
      --arg=--output --arg="$artifact_rel" --artifact "$artifact_rel" \
      --label cmux --label ram48 --timeout 1800) >"$fleet_log" 2>&1; then
      job="$(sed -n 's/.*cmux-ci: step \([0-9a-f][0-9a-f]*\).*/\1/p' "$fleet_log" | tail -1)"
      if [[ "$job" =~ ^[0-9a-f]{24}$ ]] && "$ci" artifact "$job" "$artifact_tmp" >/dev/null 2>&1; then
        mkdir -p "$(dirname "$cache")"
        install -m 755 "$artifact_tmp" "$cache"
        printf 'sha=%s\n' "$sha" >"$cache.ref"
        fleet_seconds="$(( ($(now_ms) - started) / 1000 ))s"
        acpmux_bin="$cache"
        return
      fi
    fi
    echo "warning: fleet acpmux build did not produce an artifact; see $fleet_log" >&2
  else
    echo "warning: cmux-ci is unavailable; using the local acpmux fallback" >&2
  fi
  if [[ -x "$home_root/.local/bin/acpmux" ]]; then
    acpmux_bin="$home_root/.local/bin/acpmux"
    echo "warning: using ~/.local/bin/acpmux; it may not match SHA $sha" >&2
    return
  fi
  echo "error: no SHA-cached acpmux, fleet client, or ~/.local/bin/acpmux" >&2
  exit 1
}

start_daemon() {
  local ready_file="$work_dir/daemon.ready"
  local token
  mkdir -p "$daemon_home"
  token="$(openssl rand -hex 32 2>/dev/null || python3 -c 'import secrets; print(secrets.token_hex(32))')"
  rm -f "$ready_file"
  exec {ready_fd}>"$ready_file"
  local started
  started="$(now_ms)"
  local -a origin_args=(
    --allow-dev-origin "$base_origin"
    --allow-dev-origin "$agent_origin"
    --allow-dev-origin "$preview_origin"
    --allow-dev-origin "$settings_origin"
  )
  if [[ "${gallery_enabled:-0}" -eq 1 ]]; then origin_args+=(--allow-dev-origin "$gallery_origin"); fi
  ACPMUX_HOME="$daemon_home" "$acpmux_bin" daemon run --listen 127.0.0.1:0 --token "$token" \
    --ready-fd "$ready_fd" --dev "${origin_args[@]}" \
    >"$work_dir/acpmux.log" 2>&1 &
  daemon_pid="$!"
  exec {ready_fd}>&-
  for _ in $(seq 1 300); do
    if [[ -s "$ready_file" ]]; then break; fi
    if ! kill -0 "$daemon_pid" 2>/dev/null; then
      echo "error: acpmux exited before readiness (log: $work_dir/acpmux.log)" >&2
      exit 1
    fi
    sleep 0.1
  done
  [[ -s "$ready_file" ]] || { echo "error: acpmux did not become ready" >&2; exit 1; }
  local listen
  listen="$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["listen"])' <"$ready_file")"
  daemon_endpoint="ws://$listen/"
  daemon_fragment="endpoint=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$daemon_endpoint")&token=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$token")&new&cwd=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$repo_root")&editor=$(python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$base_origin")"
  daemon_seconds="$(( ($(now_ms) - started) / 1000 ))s"
}

measure_hmr() {
  local ready="$work_dir/hmr.ready"
  local probe="$work_dir/hmr-probe.ts"
  cat >"$probe" <<'BUN'
const url = process.env.CMUX_HMR_URL.replace(/^http/, "ws") + "/";
const ready = process.env.CMUX_HMR_READY;
const socket = new WebSocket(url);
socket.onopen = () => Bun.write(ready, "connected\n");
socket.onmessage = (event) => {
  try {
    if (JSON.parse(String(event.data)).type === "update") process.exit(0);
  } catch {}
};
setTimeout(() => process.exit(2), 5000);
BUN
  local started
  started="$(now_ms)"
  CMUX_HMR_URL="$agent_origin" CMUX_HMR_READY="$ready" bun "$probe" >"$work_dir/hmr.log" 2>&1 &
  hmr_pid="$!"
  for _ in $(seq 1 50); do
    [[ -s "$ready" ]] && break
    sleep 0.1
  done
  if [[ -s "$ready" ]]; then
    touch "$webviews_root/src/agent-session/acpmux/dev.tsx"
    if wait "$hmr_pid"; then hmr_seconds="$(( ($(now_ms) - started) / 1000 ))s"; fi
  else
    kill -TERM "$hmr_pid" 2>/dev/null || true
    wait "$hmr_pid" 2>/dev/null || true
  fi
  hmr_pid=""
}

find_acpmux
start_vite "webviews" env CMUX_WEBVIEWS_DEV_PORT="$base_port" bun run dev
start_vite "agent-pane" env CMUX_AGENT_PANE_DEV_PORT="$agent_port" bun run dev:agent-pane
start_vite "preview" env CMUX_PREVIEW_DEV_PORT="$preview_port" bun run preview:dev
start_vite "settings" env CMUX_SETTINGS_DEV_PORT="$settings_port" bun run dev:settings
gallery_enabled=0
# The live gallery dev server (vite.config.gallery-dev.ts) serves /gallery/ on loopback.
if [[ -f "$webviews_root/vite.config.gallery-dev.ts" ]]; then
  gallery_enabled=1
  start_vite "gallery" env CMUX_GALLERY_DEV_PORT="$gallery_port" bun run gallery:dev
fi
wait_http "$base_origin/"
wait_http "$agent_origin/"
wait_http "$preview_origin/"
wait_http "$settings_origin/"
if [[ "$gallery_enabled" -eq 1 ]]; then wait_http "$gallery_origin/gallery/"; fi
measure_hmr

start_daemon

cat >"$index_dir/index.html" <<EOF
<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>cmux-next web dev</title>
<style>body{font:15px system-ui,sans-serif;line-height:1.6;margin:2rem;max-width:60rem}li{margin:.35rem 0}code{font-size:.9em}</style>
<h1>cmux-next web dev</h1>
<p>All surfaces are local and hot reload through Vite. Capture the gallery matrix remotely with <code>scripts/gallery-matrix</code>; do not run a headless browser on this laptop.</p>
<ul>
  <li><a href="$agent_origin/#$daemon_fragment">Agent pane (real local acpmux)</a></li>
  <li><a href="$preview_origin/">Agent pane preview fixtures</a></li>
  <li><a href="$base_origin/diff/?pick">Diff viewer</a></li>
  <li><a href="$base_origin/markdown?pick">Markdown editor</a></li>
  <li><a href="$base_origin/editor?pick">Code editor</a></li>
  <li><a href="$settings_origin/">Settings</a></li>
$(if [[ "$gallery_enabled" -eq 1 ]]; then printf '  <li><a href="%s/gallery/">Gallery</a> (manual inspection; matrix captures run remotely)</li>\n' "$gallery_origin"; fi)
  <li><a href="$base_origin/history/?mock">History</a> · <a href="$base_origin/apps/?mock">Apps</a> · <a href="$base_origin/cloud/?mock">Cloud</a> · <a href="$base_origin/keybindings/?mock">Keyboard shortcuts</a></li>
</ul>
<p><small>Measured React edit → Vite HMR update: <strong>$hmr_seconds</strong>. ACPMUX iteration: fleet build + artifact fetch <strong>$fleet_seconds</strong>, daemon readiness <strong>$daemon_seconds</strong>.</small></p>
EOF
python3 -m http.server "$index_port" --bind 127.0.0.1 --directory "$index_dir" >"$work_dir/index.log" 2>&1 &
index_pid="$!"
wait_http "$index_origin/"

echo
echo "cmux-next web dev ready"
echo "INDEX_URL=$index_origin/"
echo "timing: React edit -> Vite HMR update $hmr_seconds (visible change is normally about 1 s)"
echo "timing: acpmux fleet build + fetch $fleet_seconds; daemon restart/readiness $daemon_seconds"
echo "Press Ctrl-C to stop Vite, the index server, and this ACPMUX_HOME daemon."
wait
