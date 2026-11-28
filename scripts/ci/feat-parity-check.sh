#!/usr/bin/env bash
# feat-cmux-next checks that had no fleet mode, as a cmux-ci step, so a merge train or an agent
# can run them on a pushed commit (the perf/chrome-parity train-parity table, 2026-10-29):
#   cmux-ci run --class light --script scripts/ci/feat-parity-check.sh --ref SHA --key KEY \
#     --arg MODE [--arg ROOT]
# Each mode runs the workflow's own commands, from the checkout root:
#   rust-workspace ROOT  rust-workspaces.yml's job for ROOT, a `run = true` root of
#                        .github/rust-workspaces.toml: its own toolchain pin (a root with no
#                        rust-toolchain.toml gets cmux-tui's, as setup-cmux-tui-rust makes it the
#                        job's default) and clippy, the
#                        ghostty-next checkout when the root uses ghostty-vt-sys, then
#                        `rust-workspaces.py run ROOT` (clippy --all-targets -D warnings and
#                        cargo test). `rust-workspaces.py plan --base BASE` names the roots a
#                        change reaches. Needs python 3.11 or later (tomllib).
#   sdk-rust             cmux-tui-sdks.yml `packages` (rust): fmt --check, tests, doc tests and
#                        clippy -D warnings of cmux-sdk and cmux-sidebar, cmux-sdk without default
#                        features, rustdoc -D warnings, and the two `cargo package` checks.
#   sdk-msrv             cmux-tui-sdks.yml `rust-msrv`: the public Rust SDK crates and examples
#                        on Rust 1.88 (installed with rustup into the step's RUSTUP_HOME).
#   cef-shim-cpp         cmux-next-shim-cpp.yml: every scripts/cmux-next/test-*-cpp.sh, then the
#                        Chromium Host's C++ tests where the commit has them
#                        (scripts/cmux-next/tests/chromium-host-dispatch.test.sh and
#                        remote-shim-abi.test.sh, on perf/chrome-parity).
#   swift-portable PKG   swift-linux-packages.yml for one package its matrix lists:
#                        `swift build --build-tests`, then `swift test --skip-build --parallel`
#                        when it has Tests, with CMUX_SWIFTPM_TARGET_LINUX=1. Linux only (the
#                        job runs in swift:6.2-noble, with libsqlite3-dev): elsewhere it exits 78.
#   web                  ci-web.yml's web/ checks: bun install --frozen-lockfile, the managed
#                        relay catalog check, typecheck, lint:complexity and the unit tests
#                        (all four shards in one run), with the bun ci-web.yml pins.
#   clippy-changed BASE  cmux-tui-spec.yml `clippy (changed cmux-tui packages)`, required on
#                        feat-cmux-next: changed-package clippy, Cloud host identity tests and the
#                        panic ratchet against BASE (a 40-hex commit).
#   head-check BASE      cmux-next-head-compile.yml's Linux leg (scripts/ci/head_compile.py): every
#                        tracked Cargo.lock matches its manifests (cargo-locks.py check --strict,
#                        BASE for which workspaces a timeout may fail), then `cargo check
#                        --workspace --all-targets --locked --keep-going` of cmux-tui (its tests). It
#                        shares clippy-changed's warm target. Exit 1 for a compile or lock red, 3
#                        when the tools could not be set up (no verdict).
#   react-doctor BASE    cmux-next-react-doctor.yml `React Doctor (changed React projects)`, required
#                        on feat-cmux-next: the gate on the projects BASE..HEAD touches.
#   notices              cmux-next-guards.yml rust-notices-tree's "Generate the Rust notices from
#                        this tree (as the nightly does)": generate-third-party-notices.sh
#                        --tui-source tree --write-cargo-trees with CMUX_NOTICES_ALLOW_CARGO=1 (cargo
#                        writes the exact cargo trees). cmux-tui's pinned cargo runs every
#                        `cargo tree --locked` (a Linux fleet runner's rustup has no default
#                        toolchain for a tree with no pin). Its crate cache and trees are in the
#                        step's .build. The caller decides whether the change reaches a notice input
#                        (the job's "Changed notice inputs" step).
# Every step of a mode runs, even after a red one; the summary lists each, and the step exits
# with the first red step's code. Nothing is committed or pushed. Cargo runs only as a fleet
# step: outside one (CMUX_CI_STEP_KEY) the script refuses.
set -euo pipefail
usage() {
  echo "usage: feat-parity-check.sh rust-workspace ROOT | swift-portable PKG | clippy-changed BASE | head-check BASE | react-doctor BASE | sdk-rust | sdk-msrv | cef-shim-cpp | web | notices" >&2
  exit 2
}
if [[ -z "${CMUX_CI_STEP_KEY:-}" ]]; then
  cat >&2 <<'MSG'
feat-parity-check.sh runs cargo, compilers and tests and runs only as a fleet step:
  cmux-ci run --class light --script scripts/ci/feat-parity-check.sh --ref SHA --key KEY --arg MODE
MSG
  exit 2
fi
mode="${1:-}"
workspace="${2:-}"
case "$mode" in
  rust-workspace | swift-portable | clippy-changed | head-check | react-doctor)
    [[ $# -eq 2 && "$workspace" =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ && "/$workspace/" != *"/../"* && "/$workspace/" != *"/./"* ]] || usage
    ;;
  sdk-rust | sdk-msrv | cef-shim-cpp | web | notices) [[ $# -eq 1 ]] || usage ;;
  *) usage ;;
esac
case "$mode" in
  clippy-changed | head-check | react-doctor) [[ "$workspace" =~ ^[0-9a-f]{40}$ ]] || usage ;;
  *) ;;
esac
umask 022
root="$(pwd -P)"
msrv=1.88.0

first_rc=0
last_rc=0
step_rows=()
step() { # NAME CMD...: runs CMD, records pass or fail and seconds
  local name="$1" t0 rc=0
  shift
  echo "=== step $name: $*"
  t0=$SECONDS
  "$@" || rc=$?
  last_rc=$rc
  if [[ "$rc" -eq 0 ]]; then
    step_rows+=("$name"$'\t'"pass"$'\t'"$((SECONDS - t0))")
  else
    step_rows+=("$name"$'\t'"FAIL (exit $rc)"$'\t'"$((SECONDS - t0))")
    [[ "$first_rc" -ne 0 ]] || first_rc=$rc
  fi
  return 0
}
finish() {
  local row a b c
  echo
  echo "=== feat-parity-check summary (mode $mode${workspace:+, root $workspace})"
  printf '%-36s %-16s %s\n' step result seconds
  for row in ${step_rows[@]+"${step_rows[@]}"}; do
    IFS=$'\t' read -r a b c <<<"$row"
    printf '%-36s %-16s %s\n' "$a" "$b" "$c"
  done
  if [[ "$first_rc" -ne 0 ]]; then
    echo "feat-parity-check: RED (first red step exit $first_rc)"
  else
    echo "feat-parity-check: green"
  fi
  exit "$first_rc"
}
# The pinned toolchain's own cargo first on PATH (as cmux-tui-rust-check.sh does), from DIR.
use_pinned_cargo() { # DIR
  local cargo_bin
  (cd "$1" && rustup component add clippy rustfmt) || { echo "error: rustup component add clippy rustfmt failed in $1" >&2; return 3; }
  cargo_bin="$(cd "$1" && rustup which cargo)" || { echo "error: rustup which cargo failed in $1" >&2; return 3; }
  PATH="$(dirname "$cargo_bin"):$PATH"
  export PATH
  echo "cargo: $cargo_bin"
}
# Puts the cargo rustup selects in ROOT first on PATH, for the rest of the step.
use_root_cargo() { # ROOT
  local cargo_bin
  cargo_bin="$(cd "$root/$1" && rustup which cargo)" || { echo "error: rustup which cargo failed in $1" >&2; return 3; }
  PATH="$(dirname "$cargo_bin"):$PATH"
  export PATH
  echo "cargo: $cargo_bin"
}
# As cmux-tui-rust-check.sh: a synced copy without the gitlink uses the files present;
# otherwise the commit's gitlink, with init-submodule.sh's retries.
ghostty_next() {
  if [[ -z "$(git -C "$root" submodule status ghostty-next 2>/dev/null || true)" && -f "$root/ghostty-next/build.zig" ]]; then
    echo "ghostty-next: no gitlink in this tree (a synced copy); using the files present"
    return 0
  fi
  (cd "$root" && bash scripts/ci/init-submodule.sh ghostty-next)
}
# The root's toolchain: nothing when a rust-toolchain(.toml) applies from ROOT up, else
# cmux-tui's channel (setup-cmux-tui-rust makes it the job's default).
root_toolchain() { # ROOT
  local dir="$root/$1"
  while :; do
    if [[ -f "$dir/rust-toolchain.toml" || -f "$dir/rust-toolchain" ]]; then
      return 0
    fi
    [[ "$dir" != "$root" ]] || break
    dir="$(dirname "$dir")"
  done
  python3 -I -c 'import sys, tomllib; print(tomllib.load(open(sys.argv[1], "rb"))["toolchain"]["channel"])' "$root/cmux-tui/rust-toolchain.toml"
}

if [[ "$mode" == rust-workspace ]]; then
  python3 -c 'import sys, tomllib' 2>/dev/null || { echo "error: rust-workspace needs python 3.11 or later (tomllib) as python3" >&2; exit 3; }
  # Every `run = true` root, with what its job needs (no --base plans every one).
  plan="$(python3 .github/scripts/rust-workspaces.py plan)" || { echo "error: rust-workspaces.py plan failed" >&2; exit 3; }
  needs="$(python3 -I -c '
import json, sys
jobs = {j["root"]: j for j in json.loads(sys.argv[1])}
j = jobs.get(sys.argv[2])
if j is None:
    raise SystemExit(1)
print(("1" if j.get("ghostty") else "0") + "\t" + (j.get("apt") or ""))
' "$plan" "$workspace")" || { echo "error: $workspace is not a run = true root of .github/rust-workspaces.toml" >&2; exit 2; }
  IFS=$'\t' read -r uses_ghostty apt <<<"$needs"
  # Its own target dir per root, inside the checkout: a warm slot keeps .build between steps.
  CARGO_TARGET_DIR="$root/.build/rust-workspace-target/${workspace//\//__}"
  export CARGO_TARGET_DIR
  if [[ -n "$apt" ]]; then
    if [[ "$(uname -s)" == Linux ]] && command -v apt-get >/dev/null && sudo -n true 2>/dev/null; then
      # shellcheck disable=SC2086 # the entry's apt list is space-separated package names
      step "apt $apt" sh -c 'sudo -n apt-get update && sudo -n apt-get install -y "$@"' _ $apt
    else
      step "apt $apt" sh -c 'echo "error: this host cannot install the apt packages $1" >&2; exit 3' _ "$apt"
    fi
  fi
  if [[ "$uses_ghostty" == 1 ]]; then
    export GHOSTTY_ZIG_SOURCE=ghostty-next CMUX_GHOSTTY_SRC=""
    step "ghostty-next" ghostty_next
  fi
  fallback="$(root_toolchain "$workspace")" || { echo "error: cannot read cmux-tui/rust-toolchain.toml" >&2; exit 3; }
  if [[ -n "$fallback" ]]; then
    echo "toolchain: $workspace has no rust-toolchain.toml; using cmux-tui's $fallback"
    export RUSTUP_TOOLCHAIN="$fallback"
    step "toolchain" bash -c 'rustup toolchain install "$2" --profile minimal --component clippy --component rustfmt && cd "$1" && cargo --version' _ "$workspace" "$fallback"
  else
    step "toolchain" bash -c 'cd "$1" && rustup toolchain install && rustup component add clippy && cargo --version' _ "$workspace"
  fi
  # The toolchain's own cargo first on PATH (its bin dir holds cargo-clippy and cargo-fmt): the
  # cargo on a fleet step's PATH is not always the rustup proxy, and then `cargo clippy` finds no
  # cargo-clippy (2026-10-29, step dbb2c454 on cmux8s). rustup picks the root's pin, or
  # RUSTUP_TOOLCHAIN for an unpinned root, from the root's folder.
  step "toolchain cargo" use_root_cargo "$workspace"
  step "clippy and tests" python3 .github/scripts/rust-workspaces.py run "$workspace"
  finish
fi

if [[ "$mode" == sdk-rust ]]; then
  export CARGO_TARGET_DIR="$root/.build/cmux-tui-rust-target"
  step "pinned cargo" use_pinned_cargo "$root/cmux-tui"
  cd "$root/cmux-tui"
  step "fmt" cargo fmt -p cmux-sdk -p cmux-sidebar -- --check
  step "test" cargo test -p cmux-sdk -p cmux-sidebar --all-targets --locked
  step "doc tests" cargo test -p cmux-sdk -p cmux-sidebar --doc --locked
  step "clippy" cargo clippy -p cmux-sdk -p cmux-sidebar --all-targets --locked -- -D warnings
  # Embedders such as Chromium build without sha2 (socket-path-hash).
  step "test no-default-features" cargo test -p cmux-sdk --all-targets --locked --no-default-features
  step "clippy no-default-features" cargo clippy -p cmux-sdk --all-targets --locked --no-default-features -- -D warnings
  step "rustdoc" env RUSTDOCFLAGS="-D warnings" cargo doc -p cmux-sdk -p cmux-sidebar --locked --no-deps
  step "package cmux-sdk" cargo package -p cmux-sdk --locked
  step "package cmux-sidebar (list)" cargo package -p cmux-sidebar --locked --list
  finish
fi

if [[ "$mode" == sdk-msrv ]]; then
  export CARGO_TARGET_DIR="$root/.build/sdk-msrv-target"
  step "rust $msrv" rustup toolchain install "$msrv" --profile minimal --component clippy --component rustfmt
  b="$root/cmux-tui/bindings"
  step "fmt rust" rustup run "$msrv" cargo fmt --manifest-path "$b/rust/Cargo.toml" -- --check
  step "test rust" rustup run "$msrv" cargo test --manifest-path "$b/rust/Cargo.toml" --locked
  step "test rust-sidebar" rustup run "$msrv" cargo test --manifest-path "$b/rust-sidebar/Cargo.toml" --locked
  step "test rust-agent-screen-detection" rustup run "$msrv" cargo test --manifest-path "$b/examples/rust-agent-screen-detection/Cargo.toml" --locked
  step "clippy rust-agent-dashboard" rustup run "$msrv" cargo clippy --manifest-path "$b/examples/rust-agent-dashboard/Cargo.toml" --locked --all-targets -- -D warnings
  step "clippy rust-sidebar-monitor" rustup run "$msrv" cargo clippy --manifest-path "$b/examples/rust-sidebar-monitor/Cargo.toml" --locked --all-targets -- -D warnings
  finish
fi

if [[ "$mode" == cef-shim-cpp ]]; then
  shopt -s nullglob
  tests=("$root"/scripts/cmux-next/test-*-cpp.sh)
  shopt -u nullglob
  [[ "${#tests[@]}" -gt 0 ]] || { echo "error: no scripts/cmux-next/test-*-cpp.sh at this commit" >&2; exit 2; }
  for t in "${tests[@]}"; do
    step "$(basename "$t" .sh)" "$t"
  done
  # The Chromium Host's dispatcher and remote shim ABI (C++ and the generated wire cases, no
  # AppKit), where this commit has them.
  for t in chromium-host-dispatch remote-shim-abi; do
    f="$root/scripts/cmux-next/tests/$t.test.sh"
    if [[ -f "$f" ]]; then
      step "$t.test" bash "$f"
    else
      echo "cef-shim-cpp: no scripts/cmux-next/tests/$t.test.sh at this commit"
    fi
  done
  finish
fi

if [[ "$mode" == notices ]]; then
  # The crate cache stays in .build (a warm slot keeps it between steps); the trees are written fresh.
  notices_dir="$root/.build/notices"
  rm -rf "$notices_dir/cargo-trees"
  mkdir -p "$notices_dir"
  step "pinned cargo" use_pinned_cargo "$root/cmux-tui"
  step "notices from the tree" env CMUX_NOTICES_ALLOW_CARGO=1 CMUX_NOTICES_CACHE="$notices_dir/cache" \
    ./scripts/cmux-next/generate-third-party-notices.sh --tui-source tree \
    --cargo-trees "$notices_dir/cargo-trees" --write-cargo-trees
  finish
fi

if [[ "$mode" == swift-portable ]]; then
  pkg="$workspace"
  # The packages of swift-linux-packages.yml's portable matrix groups (`packages:` lines and `>-` blocks).
  python3 -I - "$root/.github/workflows/swift-linux-packages.yml" "$pkg" <<'PY' || { echo "error: $pkg is not a package of swift-linux-packages.yml's matrix" >&2; exit 2; }
import re, sys
# A repo-relative package path: Packages/... or vendor/..., never absolute or with a .. part.
PATH = r"(?!/)(?!.*(?:^|/)\.\.(?:/|$))[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)+"
listed, block = set(), None
for line in open(sys.argv[1], encoding="utf-8"):
    indent = len(line) - len(line.lstrip())
    if re.match(r"\s*packages:\s*>-\s*$", line):
        block = indent
        continue
    one = re.fullmatch(r"\s*packages:\s*(" + PATH + r")\s*", line)
    if one:
        listed.add(one.group(1))
        continue
    if block is not None:
        if line.strip() and indent > block and re.fullmatch(PATH, line.strip()):
            listed.add(line.strip())
            continue
        block = None
raise SystemExit(0 if sys.argv[2] in listed else 1)
PY
  if [[ "$(uname -s)" != Linux ]]; then
    echo "error: swift-portable checks Linux portability and runs only on Linux, not $(uname -s)" >&2
    exit 78
  fi
  export CMUX_SWIFTPM_TARGET_LINUX=1
  step "swift build $pkg" swift build --package-path "$pkg" --build-tests
  if [[ "$first_rc" -eq 0 && -d "$pkg/Tests" ]]; then
    step "swift test $pkg" swift test --package-path "$pkg" --skip-build --parallel
  fi
  finish
fi

# The two checks feat-cmux-next's ruleset requires, as fleet steps on our own Linux pool (Leo,
# 2026-11-19: "200 minutes to queue for fucking what? Nobody fucking normal waits 200 fucking
# minutes median." and "Stop making stupid fucking labels"). Each takes BASE, the commit the
# change is compared with (the pull request's base tip; its merge base with HEAD when the
# checkout can reach it), and runs its workflow job's own commands.
required_base() { # BASE: fetch it when the checkout lacks it, then print the merge base (or BASE)
  local base="$1" depth=() shallow=false remote
  [[ "$(git -C "$root" rev-parse --is-shallow-repository)" == true ]] && { depth=(--depth=200); shallow=true; }
  # A pool worker's checkout is `git init` plus a depth-1 fetch of the head, so it has no origin remote. Use the
  # worker's configured Git base when present, otherwise the public repository. A normal checkout keeps its origin.
  remote="$(git -C "$root" remote get-url origin 2>/dev/null || true)"
  if [[ -z "$remote" ]]; then
    remote="${CMUX_CI_STEP_GIT_BASE:-https://github.com}"
    [[ "$remote" == */cmux || "$remote" == */cmux.git ]] || remote="${remote%/}/manaflow-ai/cmux.git"
  fi
  have_base() { git -C "$root" cat-file -e "$base^{commit}" 2>/dev/null; }
  # The exact commit first. A remote that refuses a fetch by SHA, or history too shallow to reach the base, gets
  # the base branch's tip and then the whole history (2026-11-20: cmux#46751 and #45681 failed with "base: cannot
  # fetch" and `fatal: bad object`, exit 128, after the single fetch of the SHA).
  have_base || git -C "$root" fetch --quiet --no-tags ${depth[@]+"${depth[@]}"} "$remote" "$base" || true
  have_base || git -C "$root" fetch --quiet --no-tags --depth=1000 "$remote" "refs/heads/$requiredChecksBranch" || true
  if ! have_base && [[ "$shallow" == true ]]; then
    git -C "$root" fetch --quiet --no-tags --unshallow "$remote" || true
  fi
  if ! have_base; then
    # No verdict (exit 3, setup): the pool poster requeues a setup fault on the same head, where exit 1 is the
    # change's red. The callers' `base="$(required_base ...)"` ends the step with this code (set -e).
    echo "base: cannot fetch $base (tried the commit, $requiredChecksBranch and the full history)" >&2
    return 3
  fi
  # The merge base, never BASE itself when HEAD is not on it: a pool checkout holds HEAD at depth 1, so `merge-base`
  # found nothing and BASE (the base tip) stood in. Every file the base changed since the branch was cut then read as
  # the branch's own (2026-11-24: cmux#53262's panic ratchet counted its old cli/hub.rs, 890 indexing_slicing hits,
  # against a base where #51720 had rewritten it; the merge base was 20 commits back). Deepen HEAD until they meet.
  local head merged
  head="$(git -C "$root" rev-parse HEAD)"
  merged="$(git -C "$root" merge-base "$base" HEAD 2>/dev/null)" && { echo "$merged"; return 0; }
  if [[ "$(git -C "$root" rev-parse --is-shallow-repository)" == true ]]; then
    git -C "$root" fetch --quiet --no-tags --deepen=200 "$remote" "$head" || true
    merged="$(git -C "$root" merge-base "$base" HEAD 2>/dev/null)" && { echo "$merged"; return 0; }
    git -C "$root" fetch --quiet --no-tags --unshallow "$remote" "$head" || true
    merged="$(git -C "$root" merge-base "$base" HEAD 2>/dev/null)" && { echo "$merged"; return 0; }
  fi
  echo "base: HEAD and $base share no history here; comparing with $base itself" >&2
  echo "$base"
}
requiredChecksBranch=feat-cmux-next
# Go at cmux-tailnet's pin (crates/cmux-tailnet/go-version) first on PATH: its build.rs builds libtailscale with
# it (CI: actions/setup-go). A pool worker without that Go gets the release tarball in .build/tools, checked
# against the sha256 go.dev publishes for it (2026-11-20: cmux#46751 clippy failed with "go was not found").
use_pinned_go() { # ROOT
  local want have dir tmp file sum got goarch
  want="$(tr -d '[:space:]' <"$1/cmux-tui/crates/cmux-tailnet/go-version")" || return 3
  have="$(go version 2>/dev/null | awk '{print $3}')" || true
  if [[ "$have" == "go$want" ]]; then echo "go: $(command -v go) ($have)"; return 0; fi
  case "$(uname -m)" in x86_64) goarch=amd64 ;; aarch64 | arm64) goarch=arm64 ;; *) echo "error: no Go for $(uname -m)" >&2; return 3 ;; esac
  file="go$want.linux-$goarch.tar.gz"
  dir="$1/.build/tools/go-$want"
  if [[ ! -x "$dir/go/bin/go" ]]; then
    tmp="$(mktemp -d)"
    sum="$(curl -fsSL --retry 5 'https://go.dev/dl/?mode=json&include=all' | python3 -c '
import json, sys
for rel in json.load(sys.stdin):
    for f in rel["files"]:
        if f["filename"] == sys.argv[1]:
            print(f["sha256"])
            sys.exit(0)
sys.exit(1)' "$file")" || { echo "error: go.dev lists no $file" >&2; return 3; }
    curl -fsSL --retry 5 -o "$tmp/go.tgz" "https://go.dev/dl/$file" || { echo "error: download of $file failed" >&2; return 3; }
    got="$(sha256sum "$tmp/go.tgz" | cut -d' ' -f1)"
    [[ "$got" == "$sum" ]] || { echo "error: $file sha256 $got is not the published $sum" >&2; return 3; }
    rm -rf "$dir.part" && mkdir -p "$dir.part" && tar -xzf "$tmp/go.tgz" -C "$dir.part" && rm -rf "$dir" && mv "$dir.part" "$dir" || return 3
    rm -rf "$tmp"
  fi
  export PATH="$dir/go/bin:$PATH" GOROOT="$dir/go"
  echo "go: $(command -v go) ($(go version | awk '{print $3}'))"
}
if [[ "$mode" == clippy-changed ]]; then
  # cmux-tui-spec.yml `clippy (changed cmux-tui packages)`.
  base="$(required_base "$workspace")"
  echo "base: $base"
  # A change that reaches none of this check's inputs passes before any setup. cmux-tui-clippy-changed.py reads only
  # paths under cmux-tui/ and its ratchet inputs (WHOLE_WORKSPACE), so for such a change it lints nothing and its
  # ratchet judges nothing; the host identity tests read only cmux-tui/crates/cmux-host. Before, every such head
  # still initialized ghostty-next, zig, the pinned cargo with clippy and the pinned Go first: on 2026-11-24, 1,816
  # of 5,411 clippy-changed steps touched no input and took 8,066 fleet min (2.5 min median cold, 5.2 on Blacksmith
  # overflow). The check's own scripts are inputs too, so a change to them still runs everything.
  clippy_inputs=(cmux-tui scripts/cmux-next/rust_panic_ratchet.py scripts/cmux-next/rust-panic-baseline.json
    plans/cmux-next/rust-panic-free.md .github/scripts/cmux-tui-clippy-changed.py
    .github/scripts/cmux-tui-fmt-changed.py .github/scripts/test_cmux_tui_clippy_changed.py
    scripts/ci/cargo_test_verdict.py scripts/ci/feat-parity-check.sh)
  if changed_inputs="$(git -C "$root" diff --no-renames --name-only "$base" HEAD -- "${clippy_inputs[@]}")" \
      && [[ -z "$changed_inputs" ]]; then
    echo "No clippy-changed input changed since $base (${clippy_inputs[*]}); nothing to lint."
    step_rows+=("clippy-changed inputs"$'\t'"pass (none changed)"$'\t'"0")
    finish
  fi
  export GHOSTTY_ZIG_SOURCE=ghostty-next CMUX_GHOSTTY_SRC="" CMUX_GHOSTTY_VT_ZIG_CPU=baseline
  # No incremental compile, as cmux-tui-rust-check.sh's channel roll (#56014). sccache 0.17 refuses every
  # incremental unit, so each workspace crate was checked from nothing in both clippy runs: on 2026-11-26 the step
  # logged "680 hits, 2 misses, 916 not cacheable (incremental workspace crates, ...)", and of 38 sampled pool steps
  # 25 began with a just-created slot (2.1 GiB kept: a fresh worker has no warm target to be incremental against),
  # 5.3 min mean in clippy and 3.1 in the ratchet of a 15 min step. Without it a workspace crate this change does not
  # reach comes from the shared cache, as the registry crates already do; the lint flags, targets and verdict are the
  # same. head-check sets it too: the two share this target, and a different setting would recheck it all.
  export CARGO_INCREMENTAL=0
  step "clippy-changed self-test" python3 .github/scripts/test_cmux_tui_clippy_changed.py
  tools="$(mktemp -d)"
  cp .github/scripts/cmux-tui-clippy-changed.py .github/scripts/cmux-tui-fmt-changed.py "$tools/"
  step "ghostty-next" ghostty_next
  if ! command -v zig >/dev/null 2>&1; then
    step "zig" ./scripts/install-zig-ci.sh
  fi
  step "pinned cargo" use_pinned_cargo "$root/cmux-tui"
  step "pinned go" use_pinned_go "$root"
  # The target lives in the checkout's .build, which a fleet worker's warm cargo slot keeps between steps at one
  # path (HQ build-fleet step_warm.go; the worker measures the slot, counts it against its disk floor and wipes it
  # over its cap), so the next step rechecks only what changed. Before, it was cmux-tui/target in a fresh checkout:
  # every step checked about 1,067 crates from nothing, three times when the panic ratchet linted the base too.
  # A cold step (no free slot) builds it in its own checkout as before, and the worker removes it with the checkout.
  [[ -n "${CARGO_TARGET_DIR:-}" ]] || export CARGO_TARGET_DIR="$root/.build/cmux-tui-clippy-target"
  echo "cargo target: $CARGO_TARGET_DIR"
  # A cold target (a just-created slot or a per-job checkout) starts from the base's build, written only by
  # cmux-tui-clippy-seed.yml on feat-cmux-next; a reused slot is left alone, a miss builds cold as before.
  step "clippy base seed" bash scripts/ci/clippy-base-seed.sh restore "$CARGO_TARGET_DIR"
  # The clippy step writes this when every error it found is in a file the change does not touch (a base red).
  export CMUX_CLIPPY_BASE_RED_FILE="$tools/clippy-base-red"
  step "cargo clippy --all-targets on changed cmux-tui packages" python3 "$tools/cmux-tui-clippy-changed.py" --repo "$root" --base "$base"
  clippy_rc=$last_rc
  unset CMUX_CLIPPY_BASE_RED_FILE
  host_identity() {
    local changed log rc=0
    if changed="$(git diff --no-renames --name-only "$base" HEAD)" \
        && ! python3 scripts/ci/cargo_test_verdict.py touches cmux-tui/crates/cmux-host <<<"$changed"; then
      echo "No Cloud host test input changed; skipping identity tests."
      return 0
    fi
    log="$(mktemp)"
    (cd cmux-tui && cargo test --locked -p cmux-host --lib identity) 2>&1 | tee "$log" || rc=${PIPESTATUS[0]}
    [[ "$rc" -eq 0 ]] || return "$rc"
    grep -qE 'test result: ok\. [1-9][0-9]* passed' "$log" || { echo "error: identity selected no test" >&2; return 1; }
  }
  step "Cloud host identity tests" host_identity
  # A red clippy step is a compile or manifest red (lints never fail it), so the check is already red. The ratchet
  # would lint HEAD and then the base again (a red HEAD lints both) for no verdict: 2026-11-24, in 38 sampled red
  # clippy-changed steps the ratchet after a red clippy step took 12,393 of 28,504 s (43%), and 17 of them ended
  # "the clippy run did not finish successfully" anyway (goal ci-runner-min-per-day-250k). It runs once the
  # change compiles. A red whose every error is in a file the change does not touch (the base's) still runs it: the
  # ratchet still checks production lib and bin targets: a base red in test code must not let a change's
  # own panic sites land unjudged
  # (2026-11-26: 18 counts over the baseline came in that way while a cmux-tui-core lib test failed to compile on the
  # base; #55916, #57780, #54990, #59113 and #44357 merged with this step skipped).
  if [[ "$clippy_rc" -ne 0 && ! -s "$tools/clippy-base-red" ]]; then
    echo "=== step Rust panic ratchet on changed cmux-tui packages: not run (the clippy step is red, exit $clippy_rc: fix its errors first)"
    step_rows+=("Rust panic ratchet on changed cmux-tui packages"$'\t'"skip (clippy red)"$'\t'"0")
  else
    step "Rust panic ratchet on changed cmux-tui packages" python3 "$tools/cmux-tui-clippy-changed.py" --repo "$root" --base "$base" --panic-ratchet "$root/.build/panic-clippy.jsonl" --compare-base
  fi
  finish
fi
if [[ "$mode" == head-check ]]; then
  # The head compiles on Linux (2026-11-22: a second Supervisor::signal_due from two merges, and a stale
  # cmux-app-ffi Cargo.lock, each green on its own base). Setup failures are no verdict (3), never a red head.
  base="$(required_base "$workspace")" || exit 3
  echo "base: $base"
  # Not incremental, as clippy-changed (whose warm target this shares): sccache serves the unchanged crates.
  export GHOSTTY_ZIG_SOURCE=ghostty-next CMUX_GHOSTTY_SRC="" CMUX_GHOSTTY_VT_ZIG_CPU=baseline CARGO_INCREMENTAL=0
  ghostty_next || exit 3
  if ! command -v zig >/dev/null 2>&1; then ./scripts/install-zig-ci.sh || exit 3; fi
  use_pinned_cargo "$root/cmux-tui" || exit 3
  use_pinned_go "$root" || exit 3
  # clippy-changed's warm target: the dependencies are the same check metadata, so a warm slot rechecks only what
  # changed (HQ build-fleet step_warm.go keeps the checkout's .build between steps).
  [[ -n "${CARGO_TARGET_DIR:-}" ]] || export CARGO_TARGET_DIR="$root/.build/cmux-tui-clippy-target"
  echo "cargo target: $CARGO_TARGET_DIR"
  step "every Cargo.lock matches its manifests" python3 scripts/cmux-next/cargo-locks.py check --strict --base "$base"
  # cmux-tui.yml's Linux clippy set (cmux-holder-v3 is a frozen fixture); --keep-going: one round finds every red crate.
  step "cargo check --workspace --all-targets --locked (cmux-tui)" \
    bash -c 'cd cmux-tui && cargo check --workspace --exclude cmux-holder-v3 --all-targets --locked --keep-going --message-format=short'
  if [[ "$first_rc" -ne 0 ]]; then
    first_rc=1  # a compile or lock red, whatever code cargo gave
  fi
  finish
fi
if [[ "$mode" == react-doctor ]]; then
  # cmux-next-react-doctor.yml `React Doctor (changed React projects)`, its pull request leg.
  base="$(required_base "$workspace")"
  echo "base: $base"
  export REACT_DOCTOR_NO_TELEMETRY=1 PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1
  step "gate tests" python3 tests/test_react_doctor_gate.py
  projects="$(git diff --name-only "$base" HEAD | python3 -c 'import sys; sys.path.insert(0, "scripts/ci"); import react_doctor_gate as g; print(" ".join(g.select_projects(sys.stdin.read().split())))')"
  echo "projects: ${projects:-none}"
  if [[ -n "$projects" ]]; then
    rd_bun=1.4.4 rd_node=24.22.1
    rd_tools() { # the workflow's Setup Bun and Setup Node pins, in the step's .build when the host has others
      local bdir="$root/.build/tools/bun-$rd_bun" ndir="$root/.build/tools/node-$rd_node" arch
      if [[ "$(bun --version 2>/dev/null || true)" != "$rd_bun" ]]; then
        [[ -x "$bdir/bin/bun" ]] || { mkdir -p "$bdir"; curl -fsSL https://bun.sh/install | BUN_INSTALL="$bdir" bash -s "bun-v$rd_bun" >/dev/null || return 3; }
        PATH="$bdir/bin:$PATH"
      fi
      if [[ "$(node --version 2>/dev/null || true)" != "v$rd_node" ]]; then
        case "$(uname -m)" in x86_64) arch=x64 ;; aarch64 | arm64) arch=arm64 ;; *) echo "error: no node for $(uname -m)" >&2; return 3 ;; esac
        if [[ ! -x "$ndir/bin/node" ]]; then
          mkdir -p "$ndir"
          curl -fsSL "https://nodejs.org/dist/v$rd_node/node-v$rd_node-linux-$arch.tar.xz" | tar -xJ -C "$ndir" --strip-components=1 || return 3
        fi
        PATH="$ndir/bin:$PATH"
      fi
      export PATH
      echo "bun $(bun --version), node $(node --version)"
    }
    step "bun $rd_bun and node $rd_node" rd_tools
    step "React Doctor gate" python3 scripts/ci/react_doctor_gate.py --changed-from "$base" --out-dir "$root/.build/react-doctor"
  fi
  finish
fi

# web: the bun webviews/package.json pins (the web job's bun, ci-web.yml `Setup Bun`), read
# by the one shared reader beside this script's folder; installed into the step's own
# .build when the host has another. No pin the reader accepts stops the step.
web_bun_pin="$(python3 -I "$(dirname "${BASH_SOURCE[0]}")/../webviews_bun_version.py" "$root/webviews/package.json")" || exit 3
ensure_web_bun() {
  local dir="$root/.build/tools/bun-$web_bun_pin"
  if [[ "$(bun --version 2>/dev/null || true)" != "$web_bun_pin" ]]; then
    if [[ ! -x "$dir/bin/bun" ]]; then
      echo "installing bun $web_bun_pin into $dir"
      mkdir -p "$dir"
      curl -fsSL https://bun.sh/install | BUN_INSTALL="$dir" bash -s "bun-v$web_bun_pin" >/dev/null || return 3
    fi
    PATH="$dir/bin:$PATH"
    export PATH
  fi
  [[ "$(bun --version)" == "$web_bun_pin" ]] || { echo "error: bun is $(bun --version), not $web_bun_pin" >&2; return 3; }
  echo "bun: $(command -v bun) ($(bun --version))"
}
step "bun $web_bun_pin" ensure_web_bun
cd "$root/web"
step "bun install" bun install --frozen-lockfile
step "relay catalog" bun tools/generate-managed-iroh-relay-catalog.ts --check
# ci-web.yml retries the native TypeScript compiler once when it aborts; real type errors stay red.
web_typecheck() {
  local log rc=0
  log="$(mktemp)"
  bun run typecheck 2>&1 | tee "$log" || rc=${PIPESTATUS[0]}
  if [[ "$rc" -ne 0 ]] && grep -Fq 'Aborted (core dumped)' "$log"; then
    echo "native tsgo aborted during web typecheck; retrying once"
    rc=0
    bun run typecheck || rc=$?
  fi
  rm -f "$log"
  return "$rc"
}
step "typecheck" web_typecheck
step "lint:complexity" bun run lint:complexity
step "unit tests" ./scripts/run-tests.sh
finish
