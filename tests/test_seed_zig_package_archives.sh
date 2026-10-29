#!/usr/bin/env bash
# scripts/ci/seed-zig-package-archives.sh pre-downloads the hashed packages of
# a Zig source's build.zig.zon files with curl into Zig's cache as
# p/<hash>.tar.gz, which Zig 0.16 unpacks offline (and hash-checks). Zig's own
# read failed mid-stream on every attempt of a job (ReadFailed, cmux-tui
# publisher run 40651931144). This serves archives from a local HTTP server.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SEED="$ROOT/scripts/ci/seed-zig-package-archives.sh"
TMP="$(mktemp -d)"
server_pid=""
trap '[[ -n "$server_pid" ]] && kill "$server_pid" 2>/dev/null; rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; [[ -f "$TMP/out" ]] && cat "$TMP/out" >&2; exit 1; }

mkdir -p "$TMP/www" "$TMP/src/pkg/a" "$TMP/src/zig-pkg/N-dep" "$TMP/cache/p"
mkdir -p "$TMP/tree/pkg-1.0" && echo hello > "$TMP/tree/pkg-1.0/file"
tar -C "$TMP/tree" -czf "$TMP/www/one.tar.gz" pkg-1.0
cp "$TMP/www/one.tar.gz" "$TMP/www/two.tgz"
head -c 100 "$TMP/www/one.tar.gz" > "$TMP/www/cut.tar.gz"
have_xz=false
if command -v xz >/dev/null 2>&1; then
  have_xz=true
  tar -C "$TMP/tree" -cf - pkg-1.0 | xz > "$TMP/www/three.tar.xz"
fi

port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
(cd "$TMP/www" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) &
server_pid=$!
for _ in $(seq 1 50); do curl -fs "http://127.0.0.1:$port/one.tar.gz" -o /dev/null && break; sleep 0.1; done
base="http://127.0.0.1:$port"

cat > "$TMP/src/build.zig.zon" <<EOF
.{
    .dependencies = .{
        .one = .{
            .url = "$base/one.tar.gz",
            .hash = "N-one", // was .url = "$base/cut.tar.gz"
        },
        .four = .{ .url = "$base/one.tar.gz", .hash = "N-four" }, .five = .{ .url = "$base/two.tgz", .hash = "N-five" },
        // .commented = .{ .url = "$base/never.tar.gz", .hash = "N-never" },
        .two = .{ .url = "$base/two.tgz", .hash = "N-two" },
        .gone = .{
            .url = "$base/missing.tar.gz",
            .hash = "N-gone",
        },
        .cut = .{
            .url = "$base/cut.tar.gz",
            .hash = "N-cut",
        },
        .here = .{
            .url = "$base/never.tar.gz",
            .hash = "N-dep",
        },
        .gitdep = .{
            .url = "git+https://example.invalid/x#abc",
            .hash = "N-git",
        },
        .path = .{ .path = "pkg/a" },
    },
}
EOF
cat > "$TMP/src/pkg/a/build.zig.zon" <<EOF
.{ .dependencies = .{ .three = .{
    .url = "$base/three.tar.xz",
    .hash = "N-three",
} } }
EOF
# A dependency's own build.zig.zon is not the source's: it is left to Zig.
echo ".{ .dependencies = .{ .inner = .{ .url = \"$base/one.tar.gz\", .hash = \"N-inner\" } } }" > "$TMP/src/zig-pkg/N-dep/build.zig.zon"

status=0
"$SEED" "$TMP/cache" "$TMP/src" > "$TMP/out" 2>&1 || status=$?
[[ "$status" == 0 ]] || fail "seeding exits 0 even when a package cannot be seeded (got $status)"
cmp -s "$TMP/cache/p/N-one.tar.gz" "$TMP/www/one.tar.gz" || fail "a .tar.gz package was not seeded as p/<hash>.tar.gz"
cmp -s "$TMP/cache/p/N-two.tar.gz" "$TMP/www/two.tgz" || fail "a .tgz package was not seeded"
cmp -s "$TMP/cache/p/N-four.tar.gz" "$TMP/www/one.tar.gz" && cmp -s "$TMP/cache/p/N-five.tar.gz" "$TMP/www/two.tgz" \
  || fail "two dependencies on one line were not both seeded"
[[ ! -e "$TMP/cache/p/N-never.tar.gz" ]] || fail "a commented-out dependency was seeded"
[[ ! -e "$TMP/cache/p/N-gone.tar.gz" ]] || fail "a missing download left an archive"
[[ ! -e "$TMP/cache/p/N-cut.tar.gz" ]] || fail "a cut-short download took the final name"
[[ ! -e "$TMP/cache/p/N-dep.tar.gz" ]] || fail "a package already in zig-pkg/ was downloaded again"
[[ ! -e "$TMP/cache/p/N-git.tar.gz" ]] || fail "a git dependency was seeded"
[[ ! -e "$TMP/cache/p/N-inner.tar.gz" ]] || fail "a dependency's own build.zig.zon was read"
[[ -z "$(ls -A "$TMP/cache/p" | grep '^\.seed-' || true)" ]] || fail "a partial download was left in p/"
if [[ "$have_xz" == true ]]; then
  gzip -t "$TMP/cache/p/N-three.tar.gz" 2>/dev/null || fail "a .tar.xz package was not re-compressed to gzip"
  [[ "$(tar -xzOf "$TMP/cache/p/N-three.tar.gz" pkg-1.0/file)" == hello ]] || fail "the re-compressed archive lost its contents"
  grep -q "Seeded 5 of 7 Zig package archives" "$TMP/out" || fail "the summary miscounts"
else
  grep -q "Seeded 4 of 6 Zig package archives" "$TMP/out" || fail "the summary miscounts"
fi

# A second run downloads nothing: everything seeded is already there.
kill "$server_pid"; wait "$server_pid" 2>/dev/null || true; server_pid=""
"$SEED" "$TMP/cache" "$TMP/src" > "$TMP/out" 2>&1 || fail "a second run failed"
cmp -s "$TMP/cache/p/N-one.tar.gz" "$TMP/www/one.tar.gz" || fail "a second run replaced a seeded archive"

# A server that answers 503 with Retry-After: 3600, or never answers, cannot
# hold the seed past its deadline: the rest is left to Zig.
cat > "$TMP/slow.py" <<'PY'
import http.server, sys, time
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if "later" in self.path:
            self.send_response(503); self.send_header("Retry-After", "3600")
            self.send_header("Content-Length", "0"); self.end_headers(); return
        time.sleep(600)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
slow_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 "$TMP/slow.py" "$slow_port" >/dev/null 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$slow_port/later.tar.gz" && break; sleep 0.1; done
mkdir -p "$TMP/slow-src" "$TMP/slow-cache"
cat > "$TMP/slow-src/build.zig.zon" <<EOF
.{ .dependencies = .{
    .later = .{ .url = "http://127.0.0.1:$slow_port/later.tar.gz", .hash = "N-later" },
    .hang = .{ .url = "http://127.0.0.1:$slow_port/hang.tar.gz", .hash = "N-hang" },
} }
EOF
start=$SECONDS
CMUX_ZIG_SEED_TIMEOUT=4 "$SEED" "$TMP/slow-cache" "$TMP/slow-src" > "$TMP/out" 2>&1 || fail "a slow seed did not exit 0"
(( SECONDS - start < 15 )) || fail "a slow host held the seed for $((SECONDS - start))s past its 4 s deadline"
[[ -z "$(ls -A "$TMP/slow-cache/p")" ]] || fail "a stopped seed left files in p/: $(ls -A "$TMP/slow-cache/p")"
grep -q "stopped after 4s" "$TMP/out" || fail "the seed deadline was not reported"
kill "$server_pid" 2>/dev/null; wait "$server_pid" 2>/dev/null || true; server_pid=""

# Cancelling the seed (its fetch stopped) stops its downloads too.
python3 "$TMP/slow.py" "$slow_port" >/dev/null 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$slow_port/later.tar.gz" && break; sleep 0.1; done
rm -rf "$TMP/slow-cache"; mkdir -p "$TMP/slow-cache"
CMUX_ZIG_SEED_TIMEOUT=120 "$SEED" "$TMP/slow-cache" "$TMP/slow-src" > "$TMP/out" 2>&1 &
seed_pid=$!
sleep 2
kill -TERM "$seed_pid"
wait "$seed_pid" 2>/dev/null || true
sleep 2
left="$(pgrep -f "seed-zig-package-archives.sh --one $TMP/slow-cache" || true)"
[[ -z "$left" ]] || { kill $left 2>/dev/null; fail "cancelling the seed left downloads running: $left"; }
kill "$server_pid" 2>/dev/null; wait "$server_pid" 2>/dev/null || true; server_pid=""

# The fetch seeds before Zig runs, unless CMUX_ZIG_SEED=0.
grep -q 'seed-zig-package-archives.sh" "$cache"' "$ROOT/scripts/ci/fetch-ghostty-zig-packages.sh" \
  || fail "fetch-ghostty-zig-packages.sh no longer seeds the archives with curl"

echo "PASS: Zig package archives are seeded with curl, whole or not at all"
