#!/usr/bin/env bash
# acpmux-libtest-mem.sh: peak RSS and wall time of the one rustc that builds acpmux's lib test target
# (`cargo test -p acpmux --lib --no-run`, the build the IR and acpmux-tests jobs start with), for each
# profile variant named on the command line. Dependencies are built once; each variant rebuilds only acpmux.
# The 19:25Z 2026-11-28 base IR job (141090861146) was SIGKILLed in this rustc at CARGO_BUILD_JOBS=2;
# measured alone at -j1 on a loaded lane VM it peaked at 14.2 GiB.
#
# usage: scripts/measure/acpmux-libtest-mem.sh [VARIANT ...]
#   base | nodebug | cgu16 | cgu1024 | opt1 | nodebug-opt1   (default: all)
# CI:    cmux-ci test --setup rust --timeout 120 -- scripts/measure/acpmux-libtest-mem.sh
set -uo pipefail
[[ $# -gt 0 ]] || set -- base nodebug cgu16 cgu1024 opt1 nodebug-opt1
cd "$(git rev-parse --show-toplevel)/cmux-tui" || exit 1
export CARGO_INCREMENTAL=0 CARGO_BUILD_JOBS=${J:-1}
echo "host: nproc=$(nproc) mem=$(awk '/MemTotal/{printf "%.1f GiB", $2/1048576}' /proc/meminfo) $(rustc -V) -j$CARGO_BUILD_JOBS"

flags() {
  case $1 in
    base) ;;
    nodebug) echo "--config profile.dev.package.acpmux.debug=false" ;;
    cgu16) echo "--config profile.dev.package.acpmux.codegen-units=16" ;;
    cgu1024) echo "--config profile.dev.package.acpmux.codegen-units=1024" ;;
    opt1) echo "--config profile.dev.package.acpmux.opt-level=1" ;;
    nodebug-opt1) echo "--config profile.dev.package.acpmux.debug=false --config profile.dev.package.acpmux.opt-level=1" ;;
    *) echo "unknown variant $1" >&2; return 1 ;;
  esac
}

# Dependencies once, at full width; acpmux itself is rebuilt per variant below.
CARGO_BUILD_JOBS=$(nproc) cargo test --locked -p acpmux --lib --no-run >/dev/null 2>&1 || {
  echo "warm build failed"; cargo test --locked -p acpmux --lib --no-run 2>&1 | tail -20; exit 1; }

printf '%-14s %10s %8s %s\n' variant peak_GiB wall_s result
for v in "$@"; do
  f=$(flags "$v") || continue
  cargo clean --locked -p acpmux >/dev/null 2>&1
  t=$(mktemp)
  # shellcheck disable=SC2086
  /usr/bin/time -v -o "$t" cargo test --locked -p acpmux --lib --no-run $f >"$t.log" 2>&1
  rc=$?
  rss=$(awk -F: '/Maximum resident/{printf "%.2f", $2/1048576}' "$t")
  wall=$(awk '/Elapsed \(wall/{n=split($NF,a,":"); s=0; for(i=1;i<=n;i++) s=s*60+a[i]; printf "%.0f", s}' "$t")
  printf '%-14s %10s %8s %s\n' "$v" "$rss" "$wall" "$([[ $rc == 0 ]] && echo ok || echo "fail rc=$rc")"
  [[ $rc == 0 ]] || tail -5 "$t.log"
  rm -f "$t" "$t.log"
done
