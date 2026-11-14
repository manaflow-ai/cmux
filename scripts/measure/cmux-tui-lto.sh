#!/usr/bin/env bash
# Release-profile A/B/C for the shipped cmux binary (bin/cmux = the cmux-tui crate's cmux-tui
# binary; bin/cmux-tui and bin/acpmux are symlinks to it). One fleet Mac, one commit, one harness:
#   A  cmux-tui/Cargo.toml as is (lto=fat, codegen-units=1, cmux-tui opt-level=z)
#   B  lto=thin, codegen-units=1 (CARGO_PROFILE_RELEASE_LTO=thin)
#   C  lto=fat, codegen-units=16 (release and the cmux-tui, cmux-tui-core, acpmux overrides)
#
#   cmux-ci run --class exclusive --measurement --os macos --script scripts/measure/cmux-tui-lto.sh \
#     --ref SHA [--arg rounds=30] [--arg bench_rounds=5] \
#     --artifact .build/lto-measure/report.tar.gz --timeout 7200
#
# Each variant builds what macos-cross.sh's cmux-tui group builds (cmux-tui, cmux-tui-hook,
# cmux-tui-host, --release --locked --target aarch64-apple-darwin, MACOSX_DEPLOYMENT_TARGET=11.0)
# in its own target dir. The three warm-up builds run at once (untimed); then, one variant at a
# time on the idle host, every workspace crate in cmux-tui's graph is cleaned (`cargo clean -p`;
# not ghostty-vt-sys or cmux-tailnet, whose build scripts run zig and go builds the profile does not
# change) and rebuilt with --timings: the timed build. The linker (cc) is wrapped to time each link.
# Then sizes (as built, strip -S -x as strip-release-bundle.sh ships bin/cmux, zip and DMG of the
# binary alone), cold and warm startup (`cmux --version`, and a headless daemon start on an empty
# state to lifecycle_ready, `sudo purge` before each cold sample, variants interleaved), and
# cmux-tui/scripts/bench-terminal-perf.py (throughput and busy) per variant, interleaved.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/scripts/cmux-next/lib/fleet-only.sh"
cmux_next_require_fleet cmux-tui-lto.sh 'cargo build --release' 'cmux-tui LTO measure'
[[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || { echo "needs an arm64 fleet Mac" >&2; exit 2; }
rounds=30 bench_rounds=5 variants="A B C"
for kv in "$@"; do
  case "$kv" in
    rounds=*) rounds="${kv#*=}" ;;
    bench_rounds=*) bench_rounds="${kv#*=}" ;;
    variants=*) variants="${kv#*=}"; variants="${variants//,/ }" ;;
    *) echo "unknown argument: $kv" >&2; exit 2 ;;
  esac
done
out="$root/.build/lto-measure"
rm -rf "$out"; mkdir -p "$out"
t=aarch64-apple-darwin
sha="$(git -C "$root" rev-parse HEAD)"
echo "LTO host $(hostname -s) $(sysctl -n machdep.cpu.brand_string) cpus $(sysctl -n hw.ncpu) mem $(( $(sysctl -n hw.memsize) / 1073741824 )) GB macOS $(sw_vers -productVersion) sha $sha"
if [[ ! -f "$root/ghostty-next/build.zig" ]]; then
  git -C "$root" submodule update --init --depth 1 ghostty-next
fi
cd "$root/cmux-tui"
echo "LTO toolchain $(rustc -V) | $(cargo -V) | zig $(zig version 2>/dev/null || echo none) | go $(go version 2>/dev/null || echo none) | ld $(ld -v 2>&1 | head -1)"
export GOFLAGS=-modcacherw GOPATH="$root/.build/go-path" GOMODCACHE="$root/.build/go-path/pkg/mod" GOCACHE="$root/.build/go-cache"
export MACOSX_DEPLOYMENT_TARGET=11.0
export CMUX_TUI_BUILD_COMMIT="$sha" CMUX_TUI_GHOSTTY_COMMIT="$(git -C "$root" rev-parse HEAD:ghostty-next)" CMUX_TUI_DISTRIBUTION_VERSION=0.0.0-lto-measure
# The linker wrapper: one line per link (output name, seconds), then cc.
cat > "$out/cc-timed" <<'EOF'
#!/usr/bin/env bash
o=""; prev=""
for a in "$@"; do [[ "$prev" == -o ]] && o="$a"; prev="$a"; done
s=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
cc "$@"; rc=$?
e=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
printf '%s %s %s\n' "$(basename "$o")" "$(echo "$e - $s" | bc)" "$rc" >> "${CMUX_LTO_LINK_LOG:-/dev/null}"
exit $rc
EOF
chmod +x "$out/cc-timed"
export CARGO_TARGET_AARCH64_APPLE_DARWIN_LINKER="$out/cc-timed"

flags() { # <variant>: the cargo arguments of the variant
  case "$1" in
    A) ;;
    B) ;; # CARGO_PROFILE_RELEASE_LTO=thin, in build()
    C) echo "--config profile.release.codegen-units=16 --config profile.release.package.cmux-tui.codegen-units=16 --config profile.release.package.cmux-tui-core.codegen-units=16 --config profile.release.package.acpmux.codegen-units=16" ;;
  esac
}
build() { # <variant> <log> [extra cargo args]
  local v=$1 log=$2; shift 2
  # shellcheck disable=SC2046
  local lto=fat; [[ "$v" != B ]] || lto=thin
  CARGO_PROFILE_RELEASE_LTO=$lto CARGO_TARGET_DIR="$out/target-$v" CMUX_LTO_LINK_LOG="$out/links-$v.txt" \
    cargo build --release --locked --target "$t" $(flags "$v") "$@" \
    -p cmux-tui --bin cmux-tui --bin cmux-tui-hook --bin cmux-tui-host >"$log" 2>&1
}

# 1. warm-up: every variant's dependencies, at once, untimed for the comparison.
start=$(date +%s)
pids=()
for v in $variants; do build "$v" "$out/warm-$v.log" & pids+=($!); done
status=0
for p in "${pids[@]}"; do wait "$p" || status=1; done
echo "LTO warm-up (all variants at once) $(( $(date +%s) - start )) s"
if (( status )); then for v in $variants; do tail -30 "$out/warm-$v.log"; done; exit 1; fi

# 2. timed: clean the workspace crates, rebuild, one variant at a time.
members=()
while IFS= read -r m; do members+=("$m"); done < <(cd "$root/cmux-tui" && python3 -I "$root/scripts/measure/cmux-tui-lto.py" members)
(( ${#members[@]} > 5 )) || { echo "no workspace crates found to clean" >&2; exit 1; }
echo "LTO cleaned crates (${#members[@]}): ${members[*]}"
clean_args=(); for m in "${members[@]}"; do clean_args+=(-p "$m"); done
for v in $variants; do
  CARGO_TARGET_DIR="$out/target-$v" cargo clean --release --target "$t" "${clean_args[@]}" >"$out/clean-$v.log" 2>&1
  : > "$out/links-$v.txt"
  s=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  build "$v" "$out/timed-$v.log" --timings
  e=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
  cp "$(ls -t "$out/target-$v/cargo-timings/"cargo-timing-*.html | head -1)" "$out/timings-$v.html"
  echo "LTO timed $v wall_s $(echo "$e - $s" | bc) links: $(tr '\n' ';' < "$out/links-$v.txt")"
  r="$out/target-$v/$t/release"
  mkdir -p "$out/$v/bin"
  cp "$r/cmux-tui" "$out/$v/bin/cmux.unstripped"
  cp "$r/cmux-tui" "$out/$v/bin/cmux"
  cp "$r/cmux-tui-host" "$out/$v/bin/cmux-tui-host"
  strip -S -x "$out/$v/bin/cmux" "$out/$v/bin/cmux-tui-host"
  ln -s cmux "$out/$v/bin/cmux-tui"; ln -s cmux "$out/$v/bin/acpmux"
  mkdir -p "$out/$v/pkg/payload"; cp "$out/$v/bin/cmux" "$out/$v/pkg/payload/cmux"
  (cd "$out/$v/pkg" && ditto -c -k --keepParent payload cmux.zip)
  hdiutil create -quiet -format ULFO -srcfolder "$out/$v/pkg/payload" "$out/$v/pkg/cmux-ulfo.dmg"
  hdiutil create -quiet -format UDZO -srcfolder "$out/$v/pkg/payload" "$out/$v/pkg/cmux-udzo.dmg"
  "$out/$v/bin/acpmux" --version >"$out/$v/acpmux-version.txt" 2>&1 || true
done

# 3. sizes, timings, startup, bench.
python3 -I "$root/scripts/measure/cmux-tui-lto.py" measure --out "$out" --variants "$variants" \
  --rounds "$rounds" --bench-rounds "$bench_rounds" --bench "$root/cmux-tui/scripts/bench-terminal-perf.py"
tar -czf "$out/report.tar.gz" -C "$out" report.json $(cd "$out" && ls timings-*.html links-*.txt timed-*.log bench-*.json 2>/dev/null)
echo "LTO done"
