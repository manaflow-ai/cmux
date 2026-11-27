#!/usr/bin/env bash
# The cargo builds of a cmux-tui tree's macOS leg built on a Mac ("Build cmux-tui (native)",
# "Build cmux-tui (macOS cross)" in .github/workflows/cmux-tui-build-package.yml). Run from
# cmux-tui/ with the step's environment.
#
# usage: scripts/ci/cmux-tui-mac-cargo-builds.sh TRIPLE
#
# Six cargo builds plus the optional login prereader, one per package (building them in one cargo would unify their features).
# With CONCURRENT_MIN_BYTES of memory or more (hw.memsize) and CONCURRENT_MIN_CPUS of CPU budget
# or more (CMUX_CI_CPU_BUDGET, which the runner hook sets to the cores it admitted the job with,
# else hw.ncpu), both read here at run time, they run at once through scripts/ci/cargo-groups.sh,
# each in its own target directory; else one after another in one target directory, where the
# two heavy builds (cmux-tui, acpmux-standalone) share every dependency they build alike.
# Measured on an aarch64-apple-darwin leg from an empty target dir: on a 16 GB mini, one after
# another took 33.8 min (cmux-tui 18.2, acpmux-standalone 14.5, the other four under a minute,
# largest process 10.9 GB) and at once ran out of memory (11 GB of swap, critical pressure at
# 14 min). On a 48 GB mini admitted with 3 cores (CMUX_CI_CPU_BUDGET=3, CARGO_BUILD_JOBS=3), at
# once took 2h01m (run 44947539922): six groups of 3 jobs time-sliced 3 cores, and cmux-tui-core
# (6398 s) and acpmux (5633 s, 5725 s) compiled twice, once in each heavy group's directory.
# The two heavy builds cannot share a target directory and still run at once: cargo locks the
# directory, so they would run one after the other.
# tests/test_ci_cmux_tui_mac_legs_cargo_groups.py.
set -euo pipefail

t=${1:?usage: $0 TRIPLE}
CONCURRENT_MIN_BYTES=$((40 * 1024 * 1024 * 1024))
mem=$(sysctl -n hw.memsize 2>/dev/null || true)
[[ "$mem" =~ ^[0-9]+$ ]] || mem=0
# At once runs six cargo builds of CARGO_BUILD_JOBS jobs each, the two heavy ones ending in
# long one-codegen-unit crates and fat links; on fewer cores they time-slice each other.
CONCURRENT_MIN_CPUS=8
if [[ "${CMUX_CI_CPU_BUDGET:-}" =~ ^[1-9][0-9]*$ ]]; then
  cpus=$CMUX_CI_CPU_BUDGET cpus_from=CMUX_CI_CPU_BUDGET
else
  cpus=$(sysctl -n hw.ncpu 2>/dev/null || true) cpus_from=hw.ncpu
  [[ "$cpus" =~ ^[0-9]+$ ]] || cpus=0
fi

# The script prints one `--features=...` argument or nothing.
acpmux_features="$(../scripts/ci/acpmux-build-features.sh crates/acpmux/Cargo.toml "$t" acpmux)"

gib=$((mem / 1024 / 1024 / 1024))
if ((mem >= CONCURRENT_MIN_BYTES && cpus >= CONCURRENT_MIN_CPUS)); then
  echo "cmux-tui mac builds: $gib GiB of memory, $cpus cores ($cpus_from), the cargo builds run at once"
  cb() { echo "cargo build --timings --release --locked --target $t"; }
  preread_group=()
  if [[ -f crates/cmux-launch-preread/Cargo.toml ]]; then
    preread_group=("cmux-launch-preread" "$(cb) -p cmux-launch-preread --bin cmux-launch-preread")
  fi
  # The terminal holder (std and libc only) is its own invocation so its features do not unify
  # with the daemon's; the daemon starts every holder from a copy found beside its executable.
  # The app host runs each app's JS next to the daemon (cmux-tui-core::apps). Unix only.
  ../scripts/ci/cargo-groups.sh "$PWD/target" "$t" \
    ${preread_group[@]+"${preread_group[@]}"} \
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
  echo "cmux-tui mac builds: $gib GiB of memory (at once needs $((CONCURRENT_MIN_BYTES / 1024 / 1024 / 1024))), $cpus cores ($cpus_from; at once needs $CONCURRENT_MIN_CPUS), the cargo builds run one after another in one target dir"
  cargo build -p cmux-tui --bin cmux-tui --bin cmux-tui-hook --bin cmux-tui-host --release --locked --target "$t"
  # The terminal holder (std and libc only), its own invocation so its
  # features do not unify with the daemon's. The daemon starts every
  # holder from a copy of it found beside its own executable.
  cargo build -p cmux-holder --bin cmux-holder --release --locked --target "$t"
  if [[ -f crates/cmux-launch-preread/Cargo.toml ]]; then
    cargo build -p cmux-launch-preread --bin cmux-launch-preread --release --locked --target "$t"
  fi
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
