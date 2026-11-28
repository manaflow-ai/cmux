#!/usr/bin/env bash
# crash_ratchet.py counts only TRACKED files. Git-ignored build or sync output
# (an nx-remote per-job tree on cmux-lawrence-2, job nxsa-gate10-e8fce6ad)
# made the ratchet red while every tracked file equalled the tip (2026-10-07).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
g() { git -C "$tmp" -c user.name=t -c user.email=t@t -c commit.gpgsign=false "$@"; }
mkdir -p "$tmp/scripts/cmux-next" "$tmp/cmux-tui/crates/x/src" "$tmp/Packages/macOS/CmuxNext/Sources/M"
cp "$here/crash_ratchet.py" "$tmp/scripts/cmux-next/"
printf 'pub fn f() {}\n' > "$tmp/cmux-tui/crates/x/src/lib.rs"
printf 'let a = 1\n' > "$tmp/Packages/macOS/CmuxNext/Sources/M/A.swift"
printf 'cmux-tui/crates/x/src/gen/\nPackages/macOS/CmuxNext/Sources/M/Gen/\n' > "$tmp/.gitignore"
g init -q && g add . && g commit -qm fixture
python3 "$tmp/scripts/cmux-next/crash_ratchet.py" --update-baseline >/dev/null
g add . && g commit -qm baseline

# Ignored output with crash-class hits does not count.
mkdir -p "$tmp/cmux-tui/crates/x/src/gen" "$tmp/Packages/macOS/CmuxNext/Sources/M/Gen"
printf 'fn g() { panic!("generated"); }\n' > "$tmp/cmux-tui/crates/x/src/gen/out.rs"
printf 'let b = c!\n' > "$tmp/Packages/macOS/CmuxNext/Sources/M/Gen/Out.swift"
[[ -z "$(g status --porcelain)" ]] || fail "the fixture outputs are not ignored"
out="$(python3 "$tmp/scripts/cmux-next/crash_ratchet.py" 2>&1)" || fail "ignored files made the ratchet red: $out"

# A tracked file that gains a panic! still fails.
printf 'pub fn f() { panic!("tracked"); }\n' > "$tmp/cmux-tui/crates/x/src/lib.rs"
if out="$(python3 "$tmp/scripts/cmux-next/crash_ratchet.py" 2>&1)"; then fail "a tracked panic! passed: $out"; fi
[[ "$out" == *"rust x: panic_macro 0 -> 1"* ]] || fail "the tracked panic! is not reported: $out"


# Outside a git checkout (a Testbox or tarball tree) the ratchet refuses with exit 2 instead
# of walking every file: walking counted build output and vendored crates and made a false red
# on 2026-10-09. An exported tree of tracked files (git archive) passes with --exported-tree.
plain="$(mktemp -d)"
trap 'rm -rf "$tmp" "$plain"' EXIT
cp -R "$tmp/scripts" "$tmp/cmux-tui" "$tmp/Packages" "$plain/"
status=0; out="$(python3 "$plain/scripts/cmux-next/crash_ratchet.py" --repo "$plain" 2>&1)" || status=$?
[[ "$status" == 2 ]] || fail "a tree outside git did not exit 2 (exit $status): $out"
[[ "$out" == *"not a git checkout"* ]] || fail "the refusal does not say why: $out"
out="$(python3 "$plain/scripts/cmux-next/crash_ratchet.py" --repo "$plain" --exported-tree 2>&1)" \
  || [[ "$out" == *"gained a crash-class hit"* ]] || fail "--exported-tree did not scan the tree: $out"

# A checkout whose index lists none of the sources (a sync without a usable index) refuses too.
rm -f "$tmp/.git/index"
status=0; out="$(python3 "$tmp/scripts/cmux-next/crash_ratchet.py" --repo "$tmp" 2>&1)" || status=$?
[[ "$status" == 2 ]] || fail "an empty index did not exit 2 (exit $status): $out"

echo "crash-ratchet-tracked.test.sh: ok"
