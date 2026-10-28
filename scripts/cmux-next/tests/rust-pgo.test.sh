#!/usr/bin/env bash
# Rust PGO without a build (plans/cmux-next/chrome-parity/p08-startup.md, section F, task 056):
# rust-pgo.sh rustflags gives -Cprofile-use only for a pinned profile of this target and rustc's LLVM major whose
# sha256 matches, nothing at all without a pointer (every build as before), and --strict (the publishing builds)
# fails rather than publish without the pinned profile. merge --pin writes both pointers, and ab then builds and
# runs with the merged profile while the pointers are still uncommitted. A copy of the script in a scratch git
# repo, with stub rustc, llvm-profdata, cargo and scenario driver, so no real toolchain runs.
#   bash scripts/cmux-next/tests/rust-pgo.test.sh
# shellcheck disable=SC2015 # every `A && B || fail`: fail exits, so it runs only when A or B fails
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cmux-rust-pgo.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1"; cat "$TMP/err" 2>/dev/null || true; exit 1; }
sha_of() { if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

repo="$TMP/repo"
mkdir -p "$repo/scripts/cmux-next/pgo" "$repo/cmux-tui/crates/cmux-app-ffi" "$repo/cmux-tui/crates/cmux-tui" "$TMP/bin" \
  "$TMP/src/cmux-tui" "$TMP/src/cmux-app-ffi"
cp "$ROOT/scripts/cmux-next/pgo/rust-pgo.sh" "$repo/scripts/cmux-next/pgo/"
# The scenario driver: records its arguments.
cat > "$repo/scripts/cmux-next/pgo/rust_pgo_scenarios.py" <<'EOF'
import os, sys
with open(os.environ["STUB_LOG"], "a") as log:
    log.write("scenarios " + " ".join(sys.argv[1:]) + "\n")
EOF
cat > "$TMP/bin/rustc" <<'EOF'
#!/bin/sh
echo "rustc $*" >> "$STUB_LOG"
if [ "$1" = --print ]; then echo "$STUB_SYSROOT"; exit 0; fi
printf 'rustc 1.95.0\nhost: %s\nrelease: 1.95.0\nLLVM version: %s\n' "$STUB_HOST" "$STUB_LLVM"
EOF
# cargo build: logs RUSTFLAGS and makes the two binaries in CARGO_TARGET_DIR/<target>/release.
cat > "$TMP/bin/cargo" <<'EOF'
#!/bin/sh
target=""
while [ $# -gt 0 ]; do [ "$1" = --target ] && target="$2"; shift; done
echo "cargo target=$target dir=$CARGO_TARGET_DIR rustflags=$RUSTFLAGS" >> "$STUB_LOG"
mkdir -p "$CARGO_TARGET_DIR/$target/release"
for bin in cmux-tui cmux-tui-host; do printf '#!/bin/sh\n' > "$CARGO_TARGET_DIR/$target/release/$bin"; chmod +x "$CARGO_TARGET_DIR/$target/release/$bin"; done
EOF
sysroot="$TMP/sysroot"
mkdir -p "$sysroot/lib/rustlib/aarch64-apple-darwin/bin"
# llvm-profdata: its version, and merge as concatenation.
cat > "$sysroot/lib/rustlib/aarch64-apple-darwin/bin/llvm-profdata" <<'EOF'
#!/bin/sh
case "$1" in
  --version) echo "LLVM (http://llvm.org/):"; echo "  LLVM version 22.1.2" ;;
  merge) shift; [ "$1" = -o ] || exit 2; out="$2"; shift 2; cat "$@" > "$out" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$TMP/bin/rustc" "$TMP/bin/cargo" "$sysroot/lib/rustlib/aarch64-apple-darwin/bin/llvm-profdata"
PGO="$repo/scripts/cmux-next/pgo/rust-pgo.sh"
TUI_POINTER="$repo/cmux-tui/crates/cmux-tui/pgo.txt"
FFI_POINTER="$repo/cmux-tui/crates/cmux-app-ffi/pgo.txt"

printf 'profile tui\n' > "$TMP/src/cmux-tui/raw"
printf 'profile ffi\n' > "$TMP/src/cmux-app-ffi/raw"
tui_sha=$(sha_of "$TMP/src/cmux-tui/raw"); ffi_sha=$(sha_of "$TMP/src/cmux-app-ffi/raw")
mv "$TMP/src/cmux-tui/raw" "$TMP/src/cmux-tui/$tui_sha.profdata"
mv "$TMP/src/cmux-app-ffi/raw" "$TMP/src/cmux-app-ffi/$ffi_sha.profdata"

# run ARGS...: the copied script with the stubs; sets $out and $status, stderr in $TMP/err.
run() {
  status=0
  out=$(env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP/home" RUSTC="$TMP/bin/rustc" STUB_LOG="$TMP/stub.log" \
    STUB_HOST="${STUB_HOST:-aarch64-apple-darwin}" STUB_LLVM="${STUB_LLVM:-22.1.2}" STUB_SYSROOT="$sysroot" \
    CMUX_PGO_CACHE_DIR="$TMP/cache" CMUX_RUST_PGO_SOURCE="${SOURCE:-$TMP/src}" CMUX_CI_STEP_KEY=test \
    ${EXTRA:+"$EXTRA"} /bin/bash "$PGO" "$@" 2>"$TMP/err") || status=$?
}
pointer() { # PART SHA LLVM TARGET
  local file="$TUI_POINTER"
  [[ "$1" == cmux-app-ffi ]] && file="$FFI_POINTER"
  printf '# test pointer\nsha256=%s\nllvm=%s\nrustc=1.95.0\ntarget=%s\ncommit=abc\n' "$2" "$3" "$4" > "$file"
}

# 1. No pointer: no flag, no warning and no rustc run (Debug and an unpinned Release are as before), strict too.
: > "$TMP/stub.log"
for part in cmux-tui cmux-app-ffi; do
  for strict in "" --strict; do
    run rustflags "$part" --target aarch64-apple-darwin $strict
    [[ $status -eq 0 && -z "$out" && ! -s "$TMP/err" ]] || fail "$part $strict without a pointer: exit $status, '$out'"
  done
done
[[ ! -s "$TMP/stub.log" ]] || fail "rustflags ran rustc without a pointer"

# 2. A pinned profile for this target and LLVM: fetched by sha256 into the cache, then the flag names the cache.
pointer cmux-app-ffi "$ffi_sha" 22 aarch64-apple-darwin
run rustflags cmux-app-ffi --target aarch64-apple-darwin
cached="$TMP/cache/rust/cmux-app-ffi/$ffi_sha.profdata"
[[ $status -eq 0 && "$out" == "-Cprofile-use=$cached" ]] || fail "matching profile: exit $status, '$out'"
cmp -s "$cached" "$TMP/src/cmux-app-ffi/$ffi_sha.profdata" || fail "the cached profile is not the source"
# The default target is rustc's host.
run rustflags cmux-app-ffi
[[ "$out" == "-Cprofile-use=$cached" ]] || fail "host target: '$out'"
# A cached profile is reused when the source is gone.
mv "$TMP/src/cmux-app-ffi/$ffi_sha.profdata" "$TMP/ffi.saved"
run rustflags cmux-app-ffi --target aarch64-apple-darwin --strict
[[ "$out" == "-Cprofile-use=$cached" ]] || fail "cached profile not reused: '$out'"
mv "$TMP/ffi.saved" "$TMP/src/cmux-app-ffi/$ffi_sha.profdata"

# 3. Another target (the x86_64 slice of a universal build) builds without PGO, strict or not.
for strict in "" --strict; do
  run rustflags cmux-app-ffi --target x86_64-apple-darwin $strict
  [[ $status -eq 0 && -z "$out" ]] || fail "other target $strict got '$out' (exit $status)"
  grep -q 'building x86_64-apple-darwin without PGO' "$TMP/err" || fail "other target does not say why"
done

# 4. A profile from another LLVM is never handed to rustc (a toolchain bump, in the tree key, warns).
STUB_LLVM=23.0.0 run rustflags cmux-app-ffi --target aarch64-apple-darwin --strict
[[ $status -eq 0 && -z "$out" ]] || fail "other LLVM got '$out'"
grep -q 'from LLVM 22, rustc is LLVM 23' "$TMP/err" || fail "other LLVM does not say why"

# 5. A cached or fetched file whose sha256 differs is refused and replaced only by a matching one; a strict
# (publishing) build fails instead of building without the profile.
printf 'tampered\n' > "$cached"
mv "$TMP/src/cmux-app-ffi/$ffi_sha.profdata" "$TMP/ffi.saved"
printf 'wrong bytes\n' > "$TMP/src/cmux-app-ffi/$ffi_sha.profdata"
run rustflags cmux-app-ffi --target aarch64-apple-darwin
[[ $status -eq 0 && -z "$out" ]] || fail "mismatched sha256 got '$out'"
grep -q "does not have sha256 $ffi_sha" "$TMP/err" || fail "mismatched sha256 does not say why"
[[ -z "$(find "$TMP/cache/rust/cmux-app-ffi" -name '.*' -type f)" ]] || fail "a refused download left a temporary file"
run rustflags cmux-app-ffi --target aarch64-apple-darwin --strict
[[ $status -eq 1 && -z "$out" ]] && grep -q 'never falls back' "$TMP/err" || fail "strict build without its profile: exit $status"
SOURCE=https://127.0.0.1:9/pgo run rustflags cmux-app-ffi --target aarch64-apple-darwin --strict
[[ $status -eq 1 ]] || fail "strict build with an unreachable source: exit $status"
mv "$TMP/ffi.saved" "$TMP/src/cmux-app-ffi/$ffi_sha.profdata"
run rustflags cmux-app-ffi --target aarch64-apple-darwin
[[ "$out" == "-Cprofile-use=$cached" ]] && cmp -s "$cached" "$TMP/src/cmux-app-ffi/$ffi_sha.profdata" \
  || fail "a matching source does not replace a bad cache entry: '$out'"

# 6. CMUX_RUST_PGO=off and a pointer without a sha256.
EXTRA=CMUX_RUST_PGO=off run rustflags cmux-app-ffi --target aarch64-apple-darwin --strict
[[ $status -eq 0 && -z "$out" ]] || fail "CMUX_RUST_PGO=off got '$out'"
pointer cmux-app-ffi "" 22 aarch64-apple-darwin
run rustflags cmux-app-ffi
[[ $status -eq 0 && -z "$out" ]] && grep -q 'has no sha256' "$TMP/err" || fail "pointer without sha256: '$out'"
run rustflags cmux-app-ffi --strict
[[ $status -eq 1 ]] || fail "strict pointer without sha256: exit $status"
rm "$FFI_POINTER"

# 7. The cmux-tui pointer is read from inside the cmux-tui tree (so the tree key covers it).
pointer cmux-tui "$tui_sha" 22 aarch64-apple-darwin
run rustflags cmux-tui --target aarch64-apple-darwin --strict
[[ "$out" == "-Cprofile-use=$TMP/cache/rust/cmux-tui/$tui_sha.profdata" ]] || fail "cmux-tui pointer: '$out'"
rm "$TUI_POINTER"

# 8. The test-phase flow: merge --pin writes both pointers (uncommitted), then ab builds the regular and the PGO
# daemon with the merged profile and runs the A/B; no committed pointer or clean tree is needed.
git -C "$repo" init -q
git -C "$repo" -c user.email=t@t -c user.name=t add -A
git -C "$repo" -c user.email=t@t -c user.name=t commit -q -m base
pgo_out="$TMP/pgo-out"
mkdir -p "$pgo_out/generate" "$pgo_out/profraw/cmux-tui" "$pgo_out/profraw/cmux-app-ffi"
printf 'commit=abc\nrustc=1.95.0\nllvm=22\ntarget=aarch64-apple-darwin\n' > "$pgo_out/generate/build.txt"
printf 'tui counts\n' > "$pgo_out/profraw/cmux-tui/a.profraw"
printf 'ffi counts\n' > "$pgo_out/profraw/cmux-app-ffi/a.profraw"
run merge --out "$pgo_out" --pin
[[ $status -eq 0 ]] || fail "merge --pin: exit $status"
[[ "$(sed -n 's/^sha256=//p' "$TUI_POINTER")" == "$(sha_of "$pgo_out/cmux-tui.profdata")" ]] || fail "merge --pin wrote no cmux-tui pointer"
[[ "$(sed -n 's/^target=//p' "$FFI_POINTER")" == aarch64-apple-darwin ]] || fail "merge --pin wrote no FFI pointer"
[[ -n "$(git -C "$repo" status --porcelain)" ]] || fail "the pinned pointers should be uncommitted here"
: > "$TMP/stub.log"
run ab --out "$pgo_out" --rounds 1 --tabs 1
[[ $status -eq 0 ]] || fail "ab after merge --pin with uncommitted pointers: exit $status"
grep -q "cargo target=aarch64-apple-darwin dir=$pgo_out/target-base rustflags=$" "$TMP/stub.log" || fail "ab built no regular daemon"
grep -q "cargo target=aarch64-apple-darwin dir=$pgo_out/target-pgo rustflags=-Cprofile-use=$pgo_out/cmux-tui.profdata$" "$TMP/stub.log" \
  || fail "ab did not build the PGO daemon with the merged profile: $(cat "$TMP/stub.log")"
grep -q "scenarios ab --base $pgo_out/target-base/aarch64-apple-darwin/release/cmux-tui --pgo $pgo_out/target-pgo/aarch64-apple-darwin/release/cmux-tui --rounds 1 --tabs 1" \
  "$TMP/stub.log" || fail "ab did not run the scenario on both builds: $(cat "$TMP/stub.log")"
run ab --out "$TMP/nothing"
[[ $status -eq 1 ]] && grep -q 'run rust-pgo.sh merge first' "$TMP/err" || fail "ab without a profile: exit $status"

# 9. Usage errors.
run rustflags nonsense
[[ $status -eq 1 ]] && grep -q "unknown part 'nonsense'" "$TMP/err" || fail "unknown part: exit $status"
run frobnicate
[[ $status -eq 2 ]] || fail "unknown command: exit $status"

echo "ok: rust-pgo.sh rustflags, merge --pin and ab"
