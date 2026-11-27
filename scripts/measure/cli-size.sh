#!/usr/bin/env bash
# CMUX-570: compare CLI compiler optimization on one source tree and toolchain.
# Fleet only. Results are binary payloads until a complete app is packaged.
#
#   cli-size.sh                   cmux-tui's own opt-level 3, s and z on this tree.
#   cli-size.sh toolchain BASE [HEAD|.] [PATCH]
#       Four builds in one job: BASE and HEAD (commits, each built with its own
#       rust-toolchain.toml; HEAD `.` or omitted is this checkout), and HEAD with
#       acpmux and cmux-tui-core at opt-level "s" and at "z". Stripped and
#       unstripped bytes, then interleaved CLI and daemon p50 (cli-size-speed.py).
#       Commits come from this clone's history, else from origin. A job checkout
#       with no history or remote passes HEAD `.` and PATCH, the diff from this
#       tree to BASE.
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
  base_ref="${2:?usage: cli-size.sh toolchain BASE [HEAD|.] [PATCH]}"
  head_ref="${3:-.}"
  patch="${4:-}"
  scratch="$(mktemp -d "${TMPDIR:-/tmp}/cli-size.XXXXXX")"
  trees=()
  # The BASE and HEAD worktrees and the scratch folder go on every exit (a failed build, a TERM), not only after
  # a run that succeeded: a leaked one holds two whole source trees. Never changes the status of the run.
  # shellcheck disable=SC2329 # run by the trap below
  cli_size_cleanup() {
    local t
    for t in ${trees[@]+"${trees[@]}"}; do git -C "$root" worktree remove --force "$t" 2>/dev/null || true; done
    rm -rf -- "$scratch"
    git -C "$root" worktree prune 2>/dev/null || true
  }
  trap cli_size_cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  source "$root/scripts/measure/fetch-commit.sh"
  have() { measure_fetch_commit "$root" "$1" 2>/dev/null; }
  tree_at() {  # tree_at REF DIR: a worktree of REF, its ghostty-next shared with this checkout when the pins match
    local ref=$1 dir=$2
    git -C "$root" worktree add -q --detach "$dir" "$ref"
    trees+=("$dir")
    if [[ -f "$root/ghostty-next/build.zig" &&
      "$(git -C "$root" rev-parse HEAD:ghostty-next)" == "$(git -C "$root" rev-parse "$ref:ghostty-next")" ]]; then
      rm -rf "$dir/ghostty-next"
      ln -s "$root/ghostty-next" "$dir/ghostty-next"
    else
      git -C "$dir" submodule update -q --init ghostty-next
    fi
  }
  if [[ "$head_ref" == . ]]; then
    head="$root"
  else
    have "$head_ref" || { echo "cli-size: HEAD $head_ref is not in this clone and origin cannot give it" >&2; exit 2; }
    head="$scratch/head"
    tree_at "$head_ref" "$head"
  fi
  if have "$base_ref"; then
    base="$scratch/base"
    tree_at "$base_ref" "$base"
  elif [[ -n "$patch" && "$head_ref" == . ]]; then
    # A job checkout with no history: BASE is this tree with the reverse patch (the diff from it to BASE).
    base="$scratch/base"
    tree_at HEAD "$base"
    git -C "$base" apply --whitespace=nowarn "$patch"
  else
    echo "cli-size: BASE $base_ref is not in this clone and origin cannot give it; pass HEAD . and the reverse patch" >&2
    exit 2
  fi
  build() {  # build TREE TARGET_DIR NAME [cargo --config ...]
    local tree=$1 target=$2 name=$3
    shift 3
    (cd "$tree/cmux-tui" && rustc --version >"$scratch/rustc-$name.txt" &&
      CARGO_TARGET_DIR="$target" cargo build -q --locked --release -p cmux-tui --bin cmux-tui "$@")
    strip_copy "$target/release/cmux-tui" "$out/$name"
    mv "$scratch/rustc-$name.txt" "$out/$name/rustc.txt"
  }
  target="${CARGO_TARGET_DIR:-$root/cmux-tui/target/cli-size}"
  build "$base" "$target-base" base
  build "$head" "$target" head
  for level in s z; do
    build "$head" "$target" "head-$level" \
      --config "profile.release.package.acpmux.opt-level=\"$level\"" \
      --config "profile.release.package.cmux-tui-core.opt-level=\"$level\""
  done
  python3 "$root/scripts/measure/cli-size-speed.py" "$out" base head head-s head-z
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
