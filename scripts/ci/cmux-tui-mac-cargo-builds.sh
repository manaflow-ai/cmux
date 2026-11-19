#!/usr/bin/env bash
# The cargo builds of a cmux-tui tree's macOS leg built on a Mac ("Build cmux-tui (native)",
# "Build cmux-tui (macOS cross)" in .github/workflows/cmux-tui-build-package.yml). Run from
# cmux-tui/ with the step's environment.
#
# usage: scripts/ci/cmux-tui-mac-cargo-builds.sh TRIPLE
#
# Six cargo builds, one per package (building them in one cargo would unify their features).
# With CONCURRENT_MIN_BYTES of memory or more (hw.memsize, read here at run time) they run at
# once through scripts/ci/cargo-groups.sh, each in its own target directory; with less, one
# after another as before. Measured on an aarch64-apple-darwin leg from an empty target dir:
# on a 16 GB mini, one after another took 33.8 min (cmux-tui 18.2, acpmux-standalone 14.5, the
# other four under a minute, largest process 10.9 GB) and at once ran out of memory (11 GB of
# swap, critical pressure at 14 min). The two heavy builds cannot share a target directory to
# share their dependencies: cargo locks the directory, so they would run one after the other.
# tests/test_ci_cmux_tui_mac_legs_cargo_groups.py.
set -euo pipefail

t=${1:?usage: $0 TRIPLE}
CONCURRENT_MIN_BYTES=$((40 * 1024 * 1024 * 1024))
mem=$(sysctl -n hw.memsize 2>/dev/null || true)
[[ "$mem" =~ ^[0-9]+$ ]] || mem=0

# The script prints one `--features=...` argument or nothing.
acpmux_features="$(../scripts/ci/acpmux-build-features.sh crates/acpmux/Cargo.toml "$t" acpmux)"

if ((mem >= CONCURRENT_MIN_BYTES)); then
  echo "cmux-tui mac builds: $((mem / 1024 / 1024 / 1024)) GiB of memory, the cargo builds run at once"
  cb() { echo "cargo build --timings --release --locked --target $t"; }
  # The terminal holder (std and libc only) is its own invocation so its features do not unify
  # with the daemon's; the daemon starts every holder from a copy found beside its executable.
  # The app host runs each app's JS next to the daemon (cmux-tui-core::apps). Unix only.
  ../scripts/ci/cargo-groups.sh "$PWD/target" "$t" \
    "cmux-tui cmux-tui-hook cmux-tui-host" "$(cb) -p cmux-tui --bin cmux-tui --bin cmux-tui-hook --bin cmux-tui-host" \
    "cmux-holder" "$(cb) -p cmux-holder --bin cmux-holder" \
    "cmux-app-host" "$(cb) -p cmux-app-host --bin cmux-app-host" \
    "cmux-relay" "$(cb) -p cmux-relay --bin cmux-relay" \
    "chatmux-relay" "$(cb) -p chatmux-relay --bin chatmux-relay" \
    "acpmux-standalone" "$(cb) -p acpmux-standalone --bin acpmux-standalone $acpmux_features"
  # cargo-groups.sh gathers the binaries only; the dSYM upload reads every .dSYM from
  # target/<triple>/release, so bring each group's beside its binary.
  for dsym in target/groups/*/"$t"/release/*.dSYM; do
    [[ -d "$dsym" ]] || continue
    rm -rf "target/$t/release/${dsym##*/}"
    cp -Rp "$dsym" "target/$t/release/"
  done
else
  echo "cmux-tui mac builds: $((mem / 1024 / 1024 / 1024)) GiB of memory (under $((CONCURRENT_MIN_BYTES / 1024 / 1024 / 1024))), the cargo builds run one after another"
  cargo build -p cmux-tui --bin cmux-tui --bin cmux-tui-hook --bin cmux-tui-host --release --locked --target "$t"
  # The terminal holder (std and libc only), its own invocation so its
  # features do not unify with the daemon's. The daemon starts every
  # holder from a copy of it found beside its own executable.
  cargo build -p cmux-holder --bin cmux-holder --release --locked --target "$t"
  # The app host runs each app's JS next to the daemon, which finds it
  # beside its own executable (cmux-tui-core::apps). Unix only.
  cargo build -p cmux-app-host --bin cmux-app-host --release --locked --target "$t"
  cargo build -p cmux-relay --bin cmux-relay --release --locked --target "$t"
  cargo build -p chatmux-relay --bin chatmux-relay --release --locked --target "$t"
  cargo build -p acpmux-standalone --bin acpmux-standalone --release --locked --target "$t" \
    ${acpmux_features:+"$acpmux_features"}
fi
# As the Linux legs: the build id only in this binary, staged as acpmux.
cp "target/$t/release/acpmux-standalone" "target/$t/release/acpmux"
