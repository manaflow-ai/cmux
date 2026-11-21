#!/usr/bin/env bash
# Release packaging: keep Rust's bundled musl as the final libc.
# Extra flags must use RUSTFLAGS or CARGO_ENCODED_RUSTFLAGS. Cargo target/build
# rustflags configuration is intentionally replaced by these release settings.
# Zig remains the C cross-compiler.
set -euo pipefail

target="${1:?usage: build-tui-musl.sh TARGET [cargo build arguments]}"
shift
case "$target" in
  x86_64-unknown-linux-musl|aarch64-unknown-linux-musl) ;;
  *) printf 'unsupported Linux musl target: %s\n' "$target" >&2; exit 2 ;;
esac

rustc_bin="${RUSTC:-rustc}"
sysroot="$("$rustc_bin" --print sysroot)"
host="$("$rustc_bin" -vV | sed -n 's/^host: //p')"
rust_lld="$sysroot/lib/rustlib/$host/bin/rust-lld"
if [[ ! -x "$rust_lld" ]]; then
  printf 'Rust bundled linker is unavailable: %s\n' "$rust_lld" >&2
  exit 1
fi
target_env="${target//-/_}"
target_env="$(printf '%s' "$target_env" | tr '[:lower:]' '[:upper:]')"
export "CARGO_TARGET_${target_env}_LINKER=$rust_lld"
if [[ ${CARGO_ENCODED_RUSTFLAGS+x} == x ]]; then
  encoded_flags="$CARGO_ENCODED_RUSTFLAGS"
else
  # Cargo splits plain RUSTFLAGS on whitespace. Encode that same list before
  # appending a linker path, which may itself contain spaces.
  encoded_flags="$(printf '%s' "${RUSTFLAGS-}" | tr -s '[:space:]' '\037')"
  encoded_flags="${encoded_flags#$'\x1f'}"
  encoded_flags="${encoded_flags%$'\x1f'}"
fi
if [[ -n "$encoded_flags" ]]; then
  encoded_flags+=$'\x1f'
fi
export CARGO_ENCODED_RUSTFLAGS="${encoded_flags}"$'-Clinker-flavor=ld.lld\x1f-Clink-self-contained=yes\x1f'"-Clinker=$rust_lld"

# cargo-zigbuild still supplies CC/CXX and CMake cross settings. Overriding
# only the final Rust linker prevents Zig 0.16's libc malloc from replacing
# musl malloc with SmpAllocator, whose small-allocation slabs never unmap.
exec cargo zigbuild "$@" --target "$target"
