#!/usr/bin/env bash
# bin/cmux with compact unwind for Rust functions (.cargo/config.toml, CMUX-570), BASE vs HEAD on a Mac:
#
#   cmux-ci run --class exclusive --script scripts/measure/bin-cmux-compact-unwind.sh --ref HEAD_SHA --arg=BASE_SHA
#
# Builds `cmux-tui --bin cmux-tui` (the shipped bin/cmux) release at both commits, strips each as the
# release does, and prints:
#   SIZE side file=N text=N eh_frame=N unwind_info=N build_seconds=N
#   UNWIND side flag=on|off ok=1   a panic through frames with Drop guards, caught by catch_unwind,
#                                  nested panics in drop, and a symbolized backtrace, in a test
#                                  binary built with and without the flag
#   BENCH side what p50_ms=N n=60  interleaved runs while every core spins (duress)
set -euo pipefail
root="$(git rev-parse --show-toplevel)"; base="${1:?BASE}"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/compact-unwind.XXXXXX")"
busy=()
cleanup() { ((${#busy[@]})) && kill "${busy[@]}" 2>/dev/null; git -C "$root" worktree remove --force "$scratch/base" 2>/dev/null || true; rm -rf "$scratch"; }
trap cleanup EXIT
fetch_url="$(git -C "$root" remote get-url origin 2>/dev/null || echo https://github.com/manaflow-ai/cmux.git)"
depth=(); [[ "$(git -C "$root" rev-parse --is-shallow-repository)" == true ]] && depth=(--depth 1)
git -C "$root" cat-file -e "$base^{commit}" 2>/dev/null || git -C "$root" fetch -q ${depth[@]+"${depth[@]}"} "$fetch_url" "$base"
git -C "$root" worktree add -q --detach "$scratch/base" "$base"
# Both sides build ghostty from HEAD's ghostty-next (the base worktree has no submodules).
export CMUX_GHOSTTY_SRC="${CMUX_GHOSTTY_SRC:-$root/ghostty-next}"
unset RUSTFLAGS CARGO_ENCODED_RUSTFLAGS
sect() { size -m "$1" | awk -v s="Section $2:" 'index($0,s){print $3; exit}'; }
for side in base head; do
  tree="$root"; [[ $side == base ]] && tree="$scratch/base"
  start=$SECONDS
  (cd "$tree/cmux-tui" && CARGO_TARGET_DIR="$scratch/t-$side" cargo build -q --locked --release -p cmux-tui --bin cmux-tui >&2)
  cp "$scratch/t-$side/release/cmux-tui" "$scratch/$side"; strip "$scratch/$side"
  echo "SIZE $side file=$(stat -f %z "$scratch/$side") text=$(sect "$scratch/$side" __text) eh_frame=$(sect "$scratch/$side" __eh_frame || echo 0) unwind_info=$(sect "$scratch/$side" __unwind_info) build_seconds=$((SECONDS-start))"
done
# Runtime: unwinding through Rust frames built with and without the flag, opt z like the release.
mkdir -p "$scratch/uw/src"
cat > "$scratch/uw/Cargo.toml" <<'TOML'
[package]
name = "uw"
version = "0.0.0"
edition = "2021"
[profile.release]
opt-level = "z"
lto = "thin"
codegen-units = 1
TOML
cat > "$scratch/uw/src/main.rs" <<'RS'
use std::sync::atomic::{AtomicUsize, Ordering::SeqCst};
static DROPS: AtomicUsize = AtomicUsize::new(0);
struct Guard(Vec<u8>);
impl Drop for Guard { fn drop(&mut self) { DROPS.fetch_add(1, SeqCst); std::hint::black_box(&self.0); } }
#[inline(never)] fn leaf(n: usize) -> usize { let _g = Guard(vec![1; n]); if std::hint::black_box(n) > 2 { panic!("leaf {n}") } n }
#[inline(never)] fn mid(n: usize) -> usize { let _g = Guard(vec![2; n]); leaf(n + 1) * 2 }
#[inline(never)] fn top(n: usize) -> usize { let _g = Guard(vec![3; n]); mid(n + 1) + 1 }
struct PanicInDrop;
impl Drop for PanicInDrop { fn drop(&mut self) { let r = std::panic::catch_unwind(|| top(1)); assert!(r.is_err()); } }
fn main() {
    std::panic::set_hook(Box::new(|_| {}));
    for i in 0..1000 { let r = std::panic::catch_unwind(|| top(1)); assert!(r.is_err(), "round {i}"); }
    assert_eq!(DROPS.load(SeqCst), 3000, "every Guard dropped while unwinding");
    let r = std::panic::catch_unwind(|| { let _p = PanicInDrop; top(1) });
    assert!(r.is_err());
    let bt = std::backtrace::Backtrace::force_capture().to_string();
    assert!(bt.contains("uw::main"), "symbolized backtrace: {bt}");
    // A panic that escapes a thread is reported through join, the thread's frames unwound.
    assert!(std::thread::spawn(|| top(1)).join().is_err());
    println!("ok");
}
RS
for flag in off on; do
  rf=""; [[ $flag == on ]] && rf="-C llvm-args=--emit-compact-unwind-non-canonical"
  (cd "$scratch/uw" && RUSTFLAGS="$rf" CARGO_TARGET_DIR="$scratch/uw-$flag" cargo build -q --release >&2)
  out="$("$scratch/uw-$flag/release/uw")"
  echo "UNWIND flag=$flag ok=$([[ $out == ok ]] && echo 1 || echo 0) eh_frame=$(sect "$scratch/uw-$flag/release/uw" __eh_frame || echo 0)"
  [[ $out == ok ]]
done
# HEAD's own binary: a CLI panic path is not reachable from argv, so check the binary runs and exits 0.
"$scratch/head" --version >/dev/null
for _ in $(seq "$(sysctl -n hw.ncpu)"); do (while :; do :; done) & busy+=($!); done
python3 - "$scratch" <<'PY'
import os,statistics,subprocess,sys,time
d=sys.argv[1]; r={}
env=dict(os.environ,HOME=d+"/home",XDG_STATE_HOME=d+"/home/state",XDG_CONFIG_HOME=d+"/home/config")
cases={"customize-recipes":["customize","recipes"],"version":["--version"]}
for _ in range(60):
    for side in ("base","head"):
        for what,args in cases.items():
            t=time.perf_counter(); subprocess.run([d+"/"+side]+args,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,env=env)
            r.setdefault((side,what),[]).append((time.perf_counter()-t)*1000)
for (side,what),v in sorted(r.items()): print(f"BENCH {side} {what} p50_ms={statistics.median(v):.2f} n={len(v)}")
PY
