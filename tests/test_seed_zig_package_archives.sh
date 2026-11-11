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
# The upstream pass: no mirror lock, and not mirror only (CI=true turns it on).
export CMUX_ZIG_MIRROR_ONLY=0 CMUX_ZIG_LOCK="$TMP/no.lock"

mkdir -p "$TMP/www" "$TMP/src/pkg/a" "$TMP/src/zig-pkg/N-dep" "$TMP/cache/p"
mkdir -p "$TMP/tree/pkg-1.0" && echo hello > "$TMP/tree/pkg-1.0/file"
tar -C "$TMP/tree" -czf "$TMP/www/one.tar.gz" pkg-1.0
cp "$TMP/www/one.tar.gz" "$TMP/www/two.tgz"
head -c 100 "$TMP/www/one.tar.gz" > "$TMP/www/cut.tar.gz"
# A host that answers 200 with a gzipped error page: whole gzip, no tar.
echo '<html>502 Bad Gateway</html>' | gzip > "$TMP/www/page.tar.gz"
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
        .page = .{
            .url = "$base/page.tar.gz",
            .hash = "N-page",
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
# A package already in zig-pkg/ names its own dependencies: they are seeded in the next round.
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
[[ ! -e "$TMP/cache/p/N-page.tar.gz" ]] || fail "a gzipped page that is no tar took the final name"
[[ ! -e "$TMP/cache/p/N-dep.tar.gz" ]] || fail "a package already in zig-pkg/ was downloaded again"
[[ ! -e "$TMP/cache/p/N-git.tar.gz" ]] || fail "a git dependency was seeded"
cmp -s "$TMP/cache/p/N-inner.tar.gz" "$TMP/www/one.tar.gz" || fail "a package in zig-pkg/ named a dependency that was not seeded"
grep -q "Seeded 1 of 1 Zig package archives that other packages name" "$TMP/out" || fail "the second round's summary miscounts"
[[ -z "$(ls -A "$TMP/cache/p" | grep '^\.seed-' || true)" ]] || fail "a partial download was left in p/"
if [[ "$have_xz" == true ]]; then
  gzip -t "$TMP/cache/p/N-three.tar.gz" 2>/dev/null || fail "a .tar.xz package was not re-compressed to gzip"
  [[ "$(tar -xzOf "$TMP/cache/p/N-three.tar.gz" pkg-1.0/file)" == hello ]] || fail "the re-compressed archive lost its contents"
  grep -q "Seeded 5 of 8 Zig package archives" "$TMP/out" || fail "the summary miscounts"
else
  grep -q "Seeded 4 of 7 Zig package archives" "$TMP/out" || fail "the summary miscounts"
fi

# The mirror pass: the lock's packages tagged with the source's name, each
# checked against its sha256; mirror only, nothing comes from an upstream URL.
mkdir -p "$TMP/www/m" "$TMP/mirror-src" "$TMP/mirror-cache"
cp "$TMP/www/one.tar.gz" "$TMP/www/m/N-m1.tar.gz"
cp "$TMP/www/one.tar.gz" "$TMP/www/m/N-other.tar.gz"
mkdir -p "$TMP/tree2/pkg-2.0" && echo other > "$TMP/tree2/pkg-2.0/file"
tar -C "$TMP/tree2" -czf "$TMP/www/m/N-bad.tar.gz" pkg-2.0
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }
one_sha="$(sha "$TMP/www/one.tar.gz")"
cat > "$TMP/mirror.lock" <<EOF
# HASH SHA256 TAGS UPSTREAM DEPS
mirror $base/m/
N-m1 $one_sha mirror-src,vt git+https://codeberg.example/x#abc -
N-other $one_sha ghostty $base/one.tar.gz -
N-bad $one_sha mirror-src $base/two.tgz -
N-absent $one_sha mirror-src $base/absent.tar.gz -
EOF
cp "$TMP/src/build.zig.zon" "$TMP/mirror-src/build.zig.zon"
for mode in explicit ci; do
  rm -rf "$TMP/mirror-cache"; mkdir -p "$TMP/mirror-cache"
  if [[ $mode == explicit ]]; then
    CMUX_ZIG_LOCK="$TMP/mirror.lock" CMUX_ZIG_MIRROR_ONLY=1 "$SEED" "$TMP/mirror-cache" "$TMP/mirror-src" > "$TMP/out" 2>&1 \
      || fail "a mirror-only seed did not exit 0"
  else
    env -u CMUX_ZIG_MIRROR_ONLY CI=true CMUX_ZIG_LOCK="$TMP/mirror.lock" "$SEED" "$TMP/mirror-cache" "$TMP/mirror-src" > "$TMP/out" 2>&1 \
      || fail "a CI seed did not exit 0"
  fi
  cmp -s "$TMP/mirror-cache/p/N-m1.tar.gz" "$TMP/www/one.tar.gz" || fail "$mode: a mirrored package of the source was not seeded"
  [[ ! -e "$TMP/mirror-cache/p/N-other.tar.gz" ]] || fail "$mode: a package of another source was seeded"
  [[ ! -e "$TMP/mirror-cache/p/N-bad.tar.gz" ]] || fail "$mode: a copy whose sha256 differs from the lock took the final name"
  grep -q "the lock pins" "$TMP/out" || fail "$mode: a sha256 mismatch was not reported"
  [[ ! -e "$TMP/mirror-cache/p/N-one.tar.gz" ]] || fail "$mode: mirror only, an upstream URL was fetched"
  grep -q "Seeded 1 of 3 Zig package archives from the mirror" "$TMP/out" || fail "$mode: the mirror summary miscounts"
  grep -q "Mirror only" "$TMP/out" || fail "$mode: mirror only was not reported"
done
# Not mirror only: the mirror first, then the upstream URLs for the rest.
rm -rf "$TMP/mirror-cache"; mkdir -p "$TMP/mirror-cache"
CMUX_ZIG_LOCK="$TMP/mirror.lock" "$SEED" "$TMP/mirror-cache" "$TMP/mirror-src" > "$TMP/out" 2>&1 || fail "a mirror-then-upstream seed failed"
cmp -s "$TMP/mirror-cache/p/N-m1.tar.gz" "$TMP/www/one.tar.gz" && cmp -s "$TMP/mirror-cache/p/N-one.tar.gz" "$TMP/www/one.tar.gz" \
  || fail "not mirror only, the mirror and then the upstream URLs were not both seeded"

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
        # The test waits for this file: a download has started.
        open(sys.argv[2], "a").close()
        time.sleep(600)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
slow_port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 "$TMP/slow.py" "$slow_port" "$TMP/started" >/dev/null 2>&1 &
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
python3 "$TMP/slow.py" "$slow_port" "$TMP/started" >/dev/null 2>&1 &
server_pid=$!
for _ in $(seq 1 50); do curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$slow_port/later.tar.gz" && break; sleep 0.1; done
rm -rf "$TMP/slow-cache"; mkdir -p "$TMP/slow-cache"
rm -f "$TMP/started"
CMUX_ZIG_SEED_TIMEOUT=120 "$SEED" "$TMP/slow-cache" "$TMP/slow-src" > "$TMP/out" 2>&1 &
seed_pid=$!
# Cancel only once a download runs, or the check below would pass with none started.
for _ in $(seq 1 100); do [[ -e "$TMP/started" ]] && break; sleep 0.1; done
[[ -e "$TMP/started" ]] || fail "no seed download reached the server"
kill -TERM "$seed_pid"
wait "$seed_pid" 2>/dev/null || true
sleep 2
left="$(pgrep -f "seed-zig-package-archives.sh --one $TMP/slow-cache" || true)"
[[ -z "$left" ]] || { kill $left 2>/dev/null; fail "cancelling the seed left downloads running: $left"; }
kill "$server_pid" 2>/dev/null; wait "$server_pid" 2>/dev/null || true; server_pid=""

# Packages a seeded archive names, git+ ones as the commit's archive (cmux#41132:
# translate_c's git+https://codeberg.org/ziglang/arocc failed every Zig fetch while
# codeberg's git server was down), from a mirror when the origin does not answer.
mkdir -p "$TMP/www2/org" "$TMP/www2/mirror/aro/archive" "$TMP/deep-src" "$TMP/deep-cache"
mkdir -p "$TMP/tree2/aro-1" "$TMP/tree2/tc-1" "$TMP/tree2/deeper-1"
echo aro > "$TMP/tree2/aro-1/file"; echo deeper > "$TMP/tree2/deeper-1/file"
tar -C "$TMP/tree2" -czf "$TMP/www2/org/deeper.tar.gz" deeper-1
port2="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
base2="http://127.0.0.1:$port2"
cat > "$TMP/tree2/tc-1/build.zig.zon" <<ZON
.{ .dependencies = .{
    .aro = .{ .url = "git+$base2/org/aro.git#0123456789abcdef", .hash = "N-aro" },
    .branch = .{ .url = "git+$base2/org/aro#main", .hash = "N-branch" },
} }
ZON
tar -C "$TMP/tree2" -czf "$TMP/www2/org/tc.tar.gz" tc-1
# The mirror's archive names one more package: a third round seeds it.
cat > "$TMP/tree2/aro-1/build.zig.zon" <<ZON
.{ .dependencies = .{ .deeper = .{ .url = "$base2/org/deeper.tar.gz", .hash = "N-deeper" } } }
ZON
tar -C "$TMP/tree2" -czf "$TMP/www2/mirror/aro/archive/0123456789abcdef.tar.gz" aro-1
echo ".{ .dependencies = .{ .tc = .{ .url = \"$base2/org/tc.tar.gz\", .hash = \"N-tc\" } } }" > "$TMP/deep-src/build.zig.zon"
(cd "$TMP/www2" && exec python3 -m http.server "$port2" --bind 127.0.0.1 >/dev/null 2>&1) &
server_pid=$!
for _ in $(seq 1 50); do curl -fs "$base2/org/tc.tar.gz" -o /dev/null && break; sleep 0.1; done
CMUX_ZIG_SEED_MIRRORS="$base2/org/aro/=$base2/mirror/aro/" "$SEED" "$TMP/deep-cache" "$TMP/deep-src" > "$TMP/out" 2>&1 \
  || fail "a seed of named packages did not exit 0"
cmp -s "$TMP/deep-cache/p/N-tc.tar.gz" "$TMP/www2/org/tc.tar.gz" || fail "the source's package was not seeded"
cmp -s "$TMP/deep-cache/p/N-aro.tar.gz" "$TMP/www2/mirror/aro/archive/0123456789abcdef.tar.gz" \
  || fail "a git+ package a seeded archive names was not seeded from its mirror"
cmp -s "$TMP/deep-cache/p/N-deeper.tar.gz" "$TMP/www2/org/deeper.tar.gz" || fail "a package two levels down was not seeded"
[[ ! -e "$TMP/deep-cache/p/N-branch.tar.gz" ]] || fail "a git+ URL with a branch, not a commit, was seeded"
grep -q "Seeded 2 of 2 Zig package archives that other packages name" "$TMP/out" || fail "the named packages' summary miscounts"
# CMUX_ZIG_SEED_DEPTH=1 stops after the source's packages and what they name.
rm -rf "$TMP/deep-cache"; mkdir -p "$TMP/deep-cache"
CMUX_ZIG_SEED_DEPTH=1 CMUX_ZIG_SEED_MIRRORS="$base2/org/aro/=$base2/mirror/aro/" "$SEED" "$TMP/deep-cache" "$TMP/deep-src" > "$TMP/out" 2>&1 \
  || fail "a depth-1 seed did not exit 0"
[[ -e "$TMP/deep-cache/p/N-aro.tar.gz" && ! -e "$TMP/deep-cache/p/N-deeper.tar.gz" ]] || fail "CMUX_ZIG_SEED_DEPTH=1 did not stop after one named round"
kill "$server_pid" 2>/dev/null; wait "$server_pid" 2>/dev/null || true; server_pid=""
# The built-in mirror for codeberg's arocc names a GitHub repository holding the same commits.
grep -q 'https://codeberg.org/ziglang/arocc/=https://github.com/Vexu/arocc/' "$SEED" || fail "the arocc mirror is gone"

# The fetch seeds before Zig runs, unless CMUX_ZIG_SEED=0.
grep -q 'seed-zig-package-archives.sh" "$cache"' "$ROOT/scripts/ci/fetch-ghostty-zig-packages.sh" \
  || fail "fetch-ghostty-zig-packages.sh no longer seeds the archives with curl"

echo "PASS: Zig package archives are seeded with curl, whole or not at all"
