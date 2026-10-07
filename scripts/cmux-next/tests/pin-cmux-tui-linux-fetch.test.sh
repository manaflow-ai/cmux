#!/usr/bin/env bash
# pin-cmux-tui.sh fetch picks the host platform's cmux-tui from the tree:
#   Linux x86_64  -> cmux-tui-x86_64-unknown-linux-musl (+ its app host)
#   Linux aarch64 -> cmux-tui-aarch64-unknown-linux-musl (+ its app host)
#   macOS         -> cmux-tui-aarch64-apple-darwin, as before
# A tree published before the Linux targets fails at once on Linux instead of
# waiting for a binary that will never appear. The cmux-next gate commands
# (probe, wait, resolve-commit) keep reading the macOS binary on any host.
# No network: a curl shim serves the CDN from files; a uname shim plays the host.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
git_q() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | awk '{print $1}'; }

git_q init "$TMP/src"
mkdir -p "$TMP/src/cmux-tui" "$TMP/src/scripts/cmux-next" "$TMP/src/scripts/ci"
cp "$ROOT/scripts/cmux-next/pin-cmux-tui.sh" "$TMP/src/scripts/cmux-next/"
cp "$ROOT/scripts/ci/cmux_tui_tree_key.py" "$TMP/src/scripts/ci/"
cp "$ROOT/scripts/cmux-next/cmux-tui-tree-inputs.txt" "$TMP/src/scripts/cmux-next/"
echo reducer > "$TMP/src/scripts/cmux-next/build-layout-reducer-ffi.sh"
echo one > "$TMP/src/cmux-tui/a"
git_q -C "$TMP/src" add -A
git_q -C "$TMP/src" commit -m one
git_q -C "$TMP/src" branch -M feat-cmux-next
git_q clone --bare "$TMP/src" "$TMP/origin.git"
git_q -C "$TMP/src" remote add origin "$TMP/origin.git"
git_q -C "$TMP/src" fetch origin
sha=$(git -C "$TMP/src" rev-parse HEAD)
key=$(cd "$TMP/src" && bash scripts/cmux-next/pin-cmux-tui.sh key)

# The CDN: https://cdn.test/cmux-tui/<path> serves $TMP/cdn/<path>, else 404.
mkdir -p "$TMP/bin" "$TMP/cdn/tree/$key" "$TMP/cdn/$sha"
real_curl=$(command -v curl)
cat > "$TMP/bin/curl" <<SHIM
#!/usr/bin/env bash
out=""; url=""; args=("\$@")
for ((i = 0; i < \${#args[@]}; i++)); do
  case "\${args[i]}" in
    -o) out="\${args[i+1]}" ;;
    https://cdn.test/*) url="\${args[i]}" ;;
  esac
done
if [[ -z "\$url" ]]; then exec "$real_curl" "\$@"; fi
path="$TMP/cdn/\${url#https://cdn.test/cmux-tui/}"; path="\${path%%\\?*}"
[[ -f "\$path" ]] || exit 22
if [[ -n "\$out" ]]; then cp "\$path" "\$out"; else cat "\$path"; fi
SHIM
cat > "$TMP/bin/uname" <<'SHIM'
#!/usr/bin/env bash
case "${1:-}" in
  -s) echo "${FAKE_UNAME_S:?}" ;;
  -m) echo "${FAKE_UNAME_M:?}" ;;
  *) echo "${FAKE_UNAME_S:?}" ;;
esac
SHIM
chmod +x "$TMP/bin/curl" "$TMP/bin/uname"

publish() { # <name> <bytes>: commit-addressed and tree objects plus manifest entry
  printf '%s' "$2" > "$TMP/cdn/$sha/$1"
  if [[ "$1" != cmux-tui-app-host-* && "$1" != cmux-tui-cloud-server-* ]]; then
    printf '%s' "$2" > "$TMP/cdn/tree/$key/$1"
    printf '%s  %s\n' "$(sha256 "$TMP/cdn/tree/$key/$1")" "$1" > "$TMP/cdn/tree/$key/$1.sha256"
  fi
}
write_manifest() {
  python3 - "$TMP/cdn/$sha" "$sha" > "$TMP/cdn/$sha/manifest.json" <<'PY'
import hashlib, json, pathlib, sys
d = pathlib.Path(sys.argv[1])
print(json.dumps({"commit": sys.argv[2], "binaries": {
    p.name: hashlib.sha256(p.read_bytes()).hexdigest()
    for p in sorted(d.iterdir()) if p.name.startswith("cmux-tui")}}))
PY
  printf '{"key":"%s","commit":"%s"}\n' "$key" "$sha" > "$TMP/cdn/tree/$key/source.json"
}

run() { # <uname -s> <uname -m> <command...>
  local s="$1" m="$2"; shift 2
  (cd "$TMP/src" && env -u GITHUB_ACTIONS -u CI_JOB_DIR -u CMUX_TUI_TREE_TARGET PATH="$TMP/bin:$PATH" \
    FAKE_UNAME_S="$s" FAKE_UNAME_M="$m" CMUX_TUI_PIN_BASE=https://cdn.test/cmux-tui \
    CMUX_TUI_TREE_WAIT_SECONDS=60 CMUX_TUI_TREE_POLL_SECONDS=1 \
    bash scripts/cmux-next/pin-cmux-tui.sh "$@" 2>&1)
}
fail() { printf '%s\n' "$1" >&2; exit 1; }

# A tree published before the Linux targets: macOS only.
publish cmux-tui-aarch64-apple-darwin mac-daemon
publish cmux-tui-app-host-aarch64-apple-darwin mac-app-host
write_manifest
status=0; started=$(date +%s)
out=$(run Linux x86_64 fetch) || status=$?
[[ "$status" != 0 ]] || fail "fetch on Linux succeeded for a macOS-only tree:
$out"
(( $(date +%s) - started < 30 )) || fail "fetch on Linux waited for a target the tree will never have:
$out"
grep -q 'x86_64-unknown-linux-musl' <<<"$out" || fail "the macOS-only refusal does not name the Linux target:
$out"

# Gate commands keep reading the macOS binary on a Linux runner.
out=$(run Linux x86_64 probe) || true
grep -q 'tree_state=ready' <<<"$out" || fail "probe on a Linux runner no longer reads the macOS tree:
$out"

# The tree now carries both Linux targets.
publish cmux-tui-x86_64-unknown-linux-musl linux-x86_64-daemon
publish cmux-tui-aarch64-unknown-linux-musl linux-aarch64-daemon
publish cmux-tui-app-host-x86_64-unknown-linux-musl linux-x86_64-app-host
publish cmux-tui-app-host-aarch64-unknown-linux-musl linux-aarch64-app-host
write_manifest

for host in "x86_64 x86_64" "aarch64 aarch64" "arm64 aarch64"; do
  set -- $host
  out=$(run Linux "$1" fetch) || fail "fetch on Linux $1 failed:
$out"
  bin=$(run Linux "$1" path)
  host_dir=$(run Linux "$1" app-host-path)
  [[ "$(cat "$bin")" == "linux-$2-daemon" ]] || fail "Linux $1 fetched $(cat "$bin" 2>/dev/null) into $bin, not the $2 musl daemon:
$out"
  [[ "$(cat "$host_dir")" == "linux-$2-app-host" ]] || fail "Linux $1 app host is $(cat "$host_dir" 2>/dev/null), not the $2 one:
$out"
done

# macOS keeps its path and binary.
out=$(run Darwin arm64 fetch) || fail "fetch on macOS failed:
$out"
bin=$(run Darwin arm64 path)
[[ "$bin" == "$TMP/src/cmux-tui/target/hosted/tree/$key/cmux-tui" ]] || fail "macOS path moved to $bin"
[[ "$(cat "$bin")" == mac-daemon ]] || fail "macOS fetched $(cat "$bin")"

echo "pin-cmux-tui-linux-fetch.test.sh: ok"
