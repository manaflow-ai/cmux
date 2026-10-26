#!/usr/bin/env bash
# Rust PGO without a build (plans/cmux-next/chrome-parity/p08-startup.md, section F, task 056):
# rust-pgo.sh rustflags gives -Cprofile-use only for a pinned profile of this target and rustc's LLVM major whose
# sha256 matches, and nothing at all without a pointer (every build as before); bundle-source names the PGO
# cmux-tui only when it was built for this tree, profile and architecture. A copy of the script in a scratch repo
# layout, with a stub rustc and a stub pin-cmux-tui.sh, so no cargo, rustc or git runs.
#   bash scripts/cmux-next/tests/rust-pgo.test.sh
# shellcheck disable=SC2015 # every `A && B || fail`: fail exits, so it runs only when A or B fails
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/cmux-rust-pgo.XXXXXX"); trap 'rm -rf "$TMP"' EXIT
fail() { printf 'FAIL: %s\n' "$1"; cat "$TMP/err" 2>/dev/null || true; exit 1; }
sha_of() { if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

repo="$TMP/repo"
mkdir -p "$repo/scripts/cmux-next/pgo" "$repo/cmux-tui/crates/cmux-app-ffi" "$TMP/bin" "$TMP/src/cmux-tui" \
  "$TMP/src/cmux-app-ffi"
cp "$ROOT/scripts/cmux-next/pgo/rust-pgo.sh" "$repo/scripts/cmux-next/pgo/"
cat > "$repo/scripts/cmux-next/pin-cmux-tui.sh" <<'EOF'
#!/bin/sh
[ "$1" = key ] && echo 0123456789abcdef0123456789abcdef01234567
EOF
cat > "$TMP/bin/rustc" <<'EOF'
#!/bin/sh
echo "$*" >> "$STUB_LOG"
printf 'rustc 1.95.0\nhost: %s\nrelease: 1.95.0\nLLVM version: %s\n' "$STUB_HOST" "$STUB_LLVM"
EOF
chmod +x "$repo/scripts/cmux-next/pin-cmux-tui.sh" "$TMP/bin/rustc"
PGO="$repo/scripts/cmux-next/pgo/rust-pgo.sh"

printf 'profile tui\n' > "$TMP/src/cmux-tui/raw"
printf 'profile ffi\n' > "$TMP/src/cmux-app-ffi/raw"
tui_sha=$(sha_of "$TMP/src/cmux-tui/raw"); ffi_sha=$(sha_of "$TMP/src/cmux-app-ffi/raw")
mv "$TMP/src/cmux-tui/raw" "$TMP/src/cmux-tui/$tui_sha.profdata"
mv "$TMP/src/cmux-app-ffi/raw" "$TMP/src/cmux-app-ffi/$ffi_sha.profdata"

# run ARGS...: the copied script with the stubs; sets $out and $status, stderr in $TMP/err.
run() {
  status=0
  out=$(env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP/home" RUSTC="$TMP/bin/rustc" STUB_LOG="$TMP/rustc.log" \
    STUB_HOST="${STUB_HOST:-aarch64-apple-darwin}" STUB_LLVM="${STUB_LLVM:-22.1.2}" \
    CMUX_PGO_CACHE_DIR="$TMP/cache" CMUX_RUST_PGO_SOURCE="$TMP/src" ${EXTRA:+"$EXTRA"} \
    NATIVE_ARCH_ACTUAL="${ARCH:-arm64}" /bin/bash "$PGO" "$@" 2>"$TMP/err") || status=$?
}
pointer() { # PART SHA LLVM TARGET
  local file="$repo/scripts/cmux-next/pgo/cmux-tui.pgo.txt"
  [[ "$1" == cmux-app-ffi ]] && file="$repo/cmux-tui/crates/cmux-app-ffi/pgo.txt"
  printf '# test pointer\nsha256=%s\nllvm=%s\nrustc=1.95.0\ntarget=%s\ncommit=abc\n' "$2" "$3" "$4" > "$file"
}

# 1. No pointer: no flag, no warning and no rustc run (Debug and an unpinned Release are as before).
: > "$TMP/rustc.log"
for part in cmux-tui cmux-app-ffi; do
  run rustflags "$part" --target aarch64-apple-darwin
  [[ $status -eq 0 && -z "$out" && ! -s "$TMP/err" ]] || fail "$part without a pointer: exit $status, '$out'"
done
[[ ! -s "$TMP/rustc.log" ]] || fail "rustflags ran rustc without a pointer"
run bundle-source
[[ $status -eq 0 && -z "$out" && ! -s "$TMP/err" ]] || fail "bundle-source without a pointer: exit $status, '$out'"

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
run rustflags cmux-app-ffi --target aarch64-apple-darwin
[[ "$out" == "-Cprofile-use=$cached" ]] || fail "cached profile not reused: '$out'"
mv "$TMP/ffi.saved" "$TMP/src/cmux-app-ffi/$ffi_sha.profdata"

# 3. Another target (the x86_64 slice of a universal FFI build) builds without PGO.
run rustflags cmux-app-ffi --target x86_64-apple-darwin
[[ $status -eq 0 && -z "$out" ]] || fail "other target got '$out'"
grep -q 'building x86_64-apple-darwin without PGO' "$TMP/err" || fail "other target does not say why"

# 4. A profile from another LLVM is never handed to rustc.
STUB_LLVM=23.0.0 run rustflags cmux-app-ffi --target aarch64-apple-darwin
[[ $status -eq 0 && -z "$out" ]] || fail "other LLVM got '$out'"
grep -q 'from LLVM 22, rustc is LLVM 23' "$TMP/err" || fail "other LLVM does not say why"

# 5. A cached or fetched file whose sha256 differs is refused and replaced only by a matching one.
printf 'tampered\n' > "$cached"
mv "$TMP/src/cmux-app-ffi/$ffi_sha.profdata" "$TMP/ffi.saved"
printf 'wrong bytes\n' > "$TMP/src/cmux-app-ffi/$ffi_sha.profdata"
run rustflags cmux-app-ffi --target aarch64-apple-darwin
[[ $status -eq 0 && -z "$out" ]] || fail "mismatched sha256 got '$out'"
grep -q "does not have sha256 $ffi_sha" "$TMP/err" || fail "mismatched sha256 does not say why"
[[ -z "$(find "$TMP/cache/rust/cmux-app-ffi" -name '.*' -type f)" ]] || fail "a refused download left a temporary file"
mv "$TMP/ffi.saved" "$TMP/src/cmux-app-ffi/$ffi_sha.profdata"
run rustflags cmux-app-ffi --target aarch64-apple-darwin
[[ "$out" == "-Cprofile-use=$cached" ]] && cmp -s "$cached" "$TMP/src/cmux-app-ffi/$ffi_sha.profdata" \
  || fail "a matching source does not replace a bad cache entry: '$out'"

# 6. CMUX_RUST_PGO=off and a pointer without a sha256.
EXTRA=CMUX_RUST_PGO=off run rustflags cmux-app-ffi --target aarch64-apple-darwin
[[ $status -eq 0 && -z "$out" ]] || fail "CMUX_RUST_PGO=off got '$out'"
pointer cmux-app-ffi "" 22 aarch64-apple-darwin
run rustflags cmux-app-ffi
[[ $status -eq 0 && -z "$out" ]] && grep -q 'has no sha256' "$TMP/err" || fail "pointer without sha256: '$out'"
rm "$repo/cmux-tui/crates/cmux-app-ffi/pgo.txt"

# 7. bundle-source: a pinned cmux-tui profile without its use build bundles the regular cmux-tui, with a warning.
pointer cmux-tui "$tui_sha" 22 aarch64-apple-darwin
run bundle-source
[[ $status -eq 0 && -z "$out" ]] && grep -q 'no PGO cmux-tui for this tree' "$TMP/err" || fail "bundle-source without a build: '$out'"
use="$repo/cmux-tui/target/rust-pgo-use/0123456789abcdef0123456789abcdef01234567-${tui_sha:0:12}"
mkdir -p "$use"
printf '#!/bin/sh\n' > "$use/cmux-tui"; chmod +x "$use/cmux-tui"
printf 'profile=%s\nkey=k\ntarget=aarch64-apple-darwin\n' "$tui_sha" > "$use/complete"
: > "$TMP/rustc.log"
run bundle-source
[[ $status -eq 0 && "$out" == "$use/cmux-tui" ]] || fail "bundle-source with a build: exit $status, '$out'"
[[ ! -s "$TMP/rustc.log" ]] || fail "bundle-source ran rustc (the Xcode phase must not need a toolchain)"
ARCH=x86_64 run bundle-source
[[ $status -eq 0 && -z "$out" ]] && grep -q 'not x86_64' "$TMP/err" || fail "bundle-source for another arch: '$out'"
EXTRA=CMUX_RUST_PGO=off run bundle-source
[[ $status -eq 0 && -z "$out" ]] || fail "bundle-source with CMUX_RUST_PGO=off: '$out'"

# 8. Usage errors.
run rustflags nonsense
[[ $status -eq 1 ]] && grep -q "unknown part 'nonsense'" "$TMP/err" || fail "unknown part: exit $status"
run frobnicate
[[ $status -eq 2 ]] || fail "unknown command: exit $status"

echo "ok: rust-pgo.sh rustflags and bundle-source"
