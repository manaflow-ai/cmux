#!/usr/bin/env bash
# CMUX-570: compare CLI compiler optimization on one source tree and toolchain.
# Fleet only. Results are binary payloads until a complete app is packaged.
#
#   cli-size.sh                   cmux-tui's own opt-level 3, s and z on this tree.
#   cli-size.sh toolchain BASE    four builds in one job: BASE (a commit, built with
#                                 its own rust-toolchain.toml), this tree, and this
#                                 tree with acpmux and cmux-tui-core at opt-level
#                                 "s" and at "z". Stripped and unstripped bytes, then
#                                 interleaved CLI and daemon p50 (cli-size-speed.py).
#                                 BASE comes from this clone's history, else from
#                                 origin; a shallow job checkout with no remote can
#                                 pass a reverse patch instead: toolchain BASE PATCH
#                                 (the diff from this tree to BASE).
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/scripts/cmux-next/lib/fleet-only.sh"
cmux_next_require_fleet cli-size.sh 'cargo build' 'CMUX-570 CLI optimization comparison'
out="${FAST_CHECKS_OUT:-$root/artifacts/cli-size}"
mkdir -p "$out"

strip_copy() {  # strip_copy BUILT DIR: DIR/cmux.unstripped and the stripped DIR/cmux
  mkdir -p "$2"
  cp "$1" "$2/cmux.unstripped"
  cp "$1" "$2/cmux"
  case "$(uname -s)" in
    Darwin) strip -x "$2/cmux" ;;
    Linux) strip --strip-unneeded "$2/cmux" ;;
    *) echo 'CLI size comparison requires a Linux or macOS fleet worker' >&2; exit 2 ;;
  esac
  echo "SIZE $(basename "$2") unstripped=$(wc -c <"$2/cmux.unstripped" | tr -d ' ') stripped=$(wc -c <"$2/cmux" | tr -d ' ')"
}

if [[ "${1:-}" == toolchain ]]; then
  base_sha="${2:?usage: cli-size.sh toolchain BASE [PATCH]}"
  patch="${3:-}"
  base="$(mktemp -d "${TMPDIR:-/tmp}/cli-size-base.XXXXXX")/tree"
  if git -C "$root" cat-file -e "$base_sha^{commit}" 2>/dev/null \
    || git -C "$root" fetch -q origin "$base_sha" 2>/dev/null; then
    git -C "$root" worktree add -q --detach "$base" "$base_sha"
  elif [[ -n "$patch" ]]; then
    git -C "$root" worktree add -q --detach "$base" HEAD
    git -C "$base" apply --whitespace=nowarn "$patch"
  else
    echo "cli-size: $base_sha is not in this clone and origin cannot give it; pass the reverse patch" >&2
    exit 2
  fi
  # libghostty-vt builds from the ghostty-next submodule: share this tree's copy when BASE pins the same commit.
  if [[ "$(git -C "$root" rev-parse HEAD:ghostty-next)" == "$(git -C "$root" rev-parse "$base_sha:ghostty-next" 2>/dev/null || git -C "$root" rev-parse HEAD:ghostty-next)" ]]; then
    rm -rf "$base/ghostty-next"
    ln -s "$root/ghostty-next" "$base/ghostty-next"
  else
    git -C "$base" submodule update -q --init ghostty-next
  fi
  build() {  # build TREE TARGET_DIR NAME [cargo --config ...]
    local tree=$1 target=$2 name=$3
    shift 3
    (cd "$tree/cmux-tui" && rustc --version >"$out/rustc-$name.txt" &&
      CARGO_TARGET_DIR="$target" cargo build -q --locked --release -p cmux-tui --bin cmux-tui "$@")
    strip_copy "$target/release/cmux-tui" "$out/$name"
    mv "$out/rustc-$name.txt" "$out/$name/rustc.txt"
  }
  target="${CARGO_TARGET_DIR:-$root/cmux-tui/target/cli-size}"
  build "$base" "$target-base" base
  build "$root" "$target" head
  for level in s z; do
    build "$root" "$target" "head-$level" \
      --config "profile.release.package.acpmux.opt-level=\"$level\"" \
      --config "profile.release.package.cmux-tui-core.opt-level=\"$level\""
  done
  python3 "$root/scripts/measure/cli-size-speed.py" "$out" base head head-s head-z
  git -C "$root" worktree remove --force "$base" || true
  exit 0
fi

export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$root/cmux-tui/target/cli-size}"
cd "$root/cmux-tui"
for level in 3 s z; do
  # Override only the CLI crate. Dependencies and the rendering/daemon core
  # retain their shipping optimization, LTO and codegen-unit settings.
  setting="$level"
  [[ "$level" == 3 ]] || setting="\"$level\""
  cargo build --locked --release -p cmux-tui --bin cmux-tui \
    --config "profile.release.package.cmux-tui.opt-level=$setting" \
    2>&1 | tee "$out/build-$level.log"
  mkdir -p "$out/$level"
  cp "$CARGO_TARGET_DIR/release/cmux-tui" "$out/$level/cmux"
  case "$(uname -s)" in
    Darwin) strip -x "$out/$level/cmux" ;;
    Linux) strip --strip-unneeded "$out/$level/cmux" ;;
    *) echo 'CLI size comparison requires a Linux or macOS fleet worker' >&2; exit 2 ;;
  esac
done
# Interleave samples so the comparison does not assign a cold filesystem to
# one compiler mode. Each invocation has a deadline and must succeed.
python3 - "$out" <<'PY'
import hashlib, json, pathlib, statistics, subprocess, sys, time
out = pathlib.Path(sys.argv[1])
levels = ('3', 's', 'z')
samples = {level: {'help': [], 'version': []} for level in levels}
expected = {}
for round in range(21):
    for level in levels[round % 3:] + levels[:round % 3]:
        for command in ('help', 'version'):
            start = time.perf_counter()
            result = subprocess.run([str(out / level / 'cmux'), '--' + command],
                                    capture_output=True, check=True, timeout=30)
            elapsed = (time.perf_counter() - start) * 1000
            # These flags must retain exactly the same grammar and version.
            answer = (result.stdout, result.stderr)
            expected.setdefault(command, answer)
            if answer != expected[command]:
                raise SystemExit(f'{level}: --{command} output changed')
            if round:
                samples[level][command].append(elapsed)
report = {'kind': 'CLI-payload-only', 'source_sha': subprocess.check_output(
    ['git', 'rev-parse', 'HEAD'], text=True).strip(), 'variants': {}}
for level in levels:
    binary = out / level / 'cmux'
    report['variants'][level] = {'bytes': binary.stat().st_size,
        'sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
        'commands': {key: {'median_ms': statistics.median(values),
                          'p95_ms': sorted(values)[18], 'samples_ms': values}
                     for key, values in samples[level].items()}}
(out / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
PY
