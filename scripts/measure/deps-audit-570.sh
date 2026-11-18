#!/usr/bin/env bash
# CMUX-570 measurement vehicle: duplicate crate versions, unused deps, MB per crate
# of cmux-tui (cargo bloat), and the stripped size with and without the `tui`
# feature. Fleet only (cmux-ci test --setup rust). Writes to $FAST_CHECKS_OUT.
set -uo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
out="${FAST_CHECKS_OUT:-$root/artifacts/deps-audit-570}"
mkdir -p "$out"
cd "$root"
[[ -e ghostty-next/build.zig ]] || git submodule update --init --depth 1 ghostty-next
cd "$root/cmux-tui"
{ uname -sm; rustc -V; cargo -V; git rev-parse HEAD; nproc; } > "$out/env.txt" 2>&1
cat "$out/env.txt"

echo "==> cargo tree -d"
cargo tree -d --edges normal -p cmux-tui > "$out/tree-dups.txt" 2>&1
cargo tree -d --edges normal -p cmux-tui -e no-dev --target all > "$out/tree-dups-alltargets.txt" 2>&1
cargo tree --edges normal -p cmux-tui --prefix none -f '{p}' > "$out/tree-normal.txt" 2>&1
cargo tree --edges normal -p cmux-tui -i ratatui > "$out/tree-inv-ratatui.txt" 2>&1
cargo tree --edges normal -p cmux-tui -i crossterm > "$out/tree-inv-crossterm.txt" 2>&1
tail -n 5 "$out/tree-dups.txt"

echo "==> cargo machete"
cargo install --locked cargo-machete >"$out/install-machete.txt" 2>&1 || tail -n 20 "$out/install-machete.txt"
cargo machete > "$out/machete.txt" 2>&1
cargo machete --with-metadata > "$out/machete-with-metadata.txt" 2>&1
cat "$out/machete.txt" | head -n 200

echo "==> cargo bloat (full, default features = tui on)"
cargo install --locked cargo-bloat >"$out/install-bloat.txt" 2>&1 || tail -n 20 "$out/install-bloat.txt"
export CARGO_TARGET_DIR="$root/cmux-tui/target/deps-audit"
cargo bloat --release --crates -n 60 -p cmux-tui --bin cmux-tui > "$out/bloat-full.txt" 2>"$out/bloat-full.err"
tail -n 5 "$out/bloat-full.err"; cat "$out/bloat-full.txt"
cargo bloat --release --crates -n 0 -p cmux-tui --bin cmux-tui --message-format json > "$out/bloat-full.json" 2>/dev/null
bin="$CARGO_TARGET_DIR/release/cmux-tui"
cp "$bin" "$out/full.unstripped.bin"; cp "$bin" "$out/full.bin"; strip --strip-unneeded "$out/full.bin"

echo "==> cargo bloat (slim, --no-default-features = no tui)"
cargo bloat --release --crates -n 60 -p cmux-tui --bin cmux-tui --no-default-features > "$out/bloat-slim.txt" 2>"$out/bloat-slim.err"
tail -n 5 "$out/bloat-slim.err"; cat "$out/bloat-slim.txt"
cargo bloat --release --crates -n 0 -p cmux-tui --bin cmux-tui --no-default-features --message-format json > "$out/bloat-slim.json" 2>/dev/null
cp "$bin" "$out/slim.unstripped.bin"; cp "$bin" "$out/slim.bin"; strip --strip-unneeded "$out/slim.bin"

for f in full slim; do
  for v in "$f.unstripped.bin" "$f.bin"; do
    printf '%s %s\n' "$v" "$(stat -c %s "$out/$v")"
  done
  printf '%s.bin.xz %s\n' "$f" "$(xz -9e -T0 -c "$out/$f.bin" | wc -c)"
  printf '%s.bin.zst %s\n' "$f" "$(zstd -19 --long=27 -T0 -c "$out/$f.bin" | wc -c)"
  printf '%s.bin.gz %s\n' "$f" "$(gzip -9 -c "$out/$f.bin" | wc -c)"
done | tee "$out/sizes.txt"
# The binaries themselves stay out of the artifact (sizes are recorded above).
rm -f "$out"/*.bin
echo done
