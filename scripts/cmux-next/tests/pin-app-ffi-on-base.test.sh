#!/usr/bin/env bash
# scripts/cmux-next/pin-app-ffi-on-base.sh and app_ffi_additive.py against a
# scratch repository and a local bare remote (no network: curl is a fake that
# serves the release's SOURCE_SHA and SHA256SUMS):
#  - a release whose FFI sources are the tip's is pinned on the branch, also
#    when unrelated commits sit on top (the pin is content-addressed), and the
#    pin check passes on the pushed tip;
#  - a tip whose FFI sources moved past the release is left alone (newer), and
#    the pin check still fails there: a stale pin is never accepted;
#  - headers that drop or change a declaration, a declaration moved under a
#    new `#if`, a new directive, and a packaging change (a module map edit in
#    build-app-ffi.sh) go to the pull request (pr);
#  - an already pinned tip, a dry run and a push the remote refuses once.
set -euo pipefail
# shellcheck source=scripts/cmux-next/tests/lib/git-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-fixture.sh"  # turns off git's background maintenance in temp repos

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
fail() { echo "FAIL: $*" >&2; exit 1; }
checksum="$(printf 'c%.0s' {1..64})"

# curl -o FILE URL: SOURCE_SHA names the sha in the tag, SHA256SUMS the checksum.
mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<EOF
#!/usr/bin/env bash
out="" url=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in -o) out="\$2"; shift ;; http*) url="\$1" ;; esac
  shift
done
tag="\${url%/*}"; tag="\${tag##*/}"
case "\$url" in
  */SOURCE_SHA) echo "\${tag#cmux-app-ffi-}" > "\$out" ;;
  */SHA256SUMS) echo "$checksum  CCmuxAppFFI.xcframework.zip" > "\$out" ;;
  *) exit 22 ;;
esac
EOF
chmod +x "$tmp/bin/curl"
export PATH="$tmp/bin:$PATH"

seed="$tmp/seed"
mkdir -p "$seed/scripts/cmux-next" "$seed/scripts/ci" "$seed/Packages/macOS/CmuxNext" \
  "$seed/cmux-tui/crates/cmux-app-ffi/src" "$seed/cmux-tui/crates/cmux-app-ffi/include" "$seed/cmux-tui/crates/cmux-unrelated"
for f in scripts/cmux-next/check-app-ffi-pin.sh scripts/cmux-next/pin-app-ffi-on-base.sh \
  scripts/cmux-next/repin-app-ffi.sh scripts/cmux-next/app_ffi_additive.py scripts/ci/app_ffi_pin.py; do
  cp "$here/$f" "$seed/$f"
done
printf '[package]\nname = "x"\n' > "$seed/cmux-tui/crates/cmux-app-ffi/Cargo.toml"
printf '[package]\nname = "y"\n' > "$seed/cmux-tui/crates/cmux-unrelated/Cargo.toml"
# The packaging script, an FFI input whose module maps the Swift imports depend on.
cat > "$seed/scripts/cmux-next/build-app-ffi.sh" <<'EOF'
#!/bin/sh
printf 'module CCmuxX {\n    header "cmux_x.h"\n}\n' > module.modulemap
EOF
header="cmux-tui/crates/cmux-app-ffi/include/cmux_x.h"
cat > "$seed/$header" <<'EOF'
#pragma once
/* the first ABI, wrapped the way cbindgen wraps a header */
#ifdef __cplusplus
extern "C" {
#endif
typedef struct CmuxPoint { int x; int y; } CmuxPoint;
int cmux_one(int a);
#ifdef __cplusplus
}
#endif
EOF
echo v1 > "$seed/cmux-tui/crates/cmux-app-ffi/src/lib.rs"
pin_manifest() { # pin_manifest SHA
  cat > "$seed/Packages/macOS/CmuxNext/Package.swift" <<EOF
let appFFI: Target = .binaryTarget(
    name: "CCmuxAppFFI",
    url: "https://github.com/manaflow-ai/cmux/releases/download/cmux-app-ffi-$1/CCmuxAppFFI.xcframework.zip",
    checksum: "$checksum"
)
EOF
}
git -C "$seed" init -q -b feat-cmux-next
git -C "$seed" add -A
git -C "$seed" commit -qm sources
first="$(git -C "$seed" rev-parse HEAD)"
pin_manifest "$first"
git -C "$seed" add -A
git -C "$seed" commit -qm pin
git_fixture_clone --bare "$seed" "$tmp/remote.git"
export PIN_BASE_REMOTE="$tmp/remote.git"

work="$tmp/work"
git clone -q "$tmp/remote.git" "$work"
commit() { # commit MESSAGE: commits the work tree and pushes it to the remote
  git -C "$work" add -A
  git -C "$work" commit -qm "$1"
  git -C "$work" push -q origin HEAD:refs/heads/feat-cmux-next
  git -C "$work" rev-parse HEAD
}
remote_tip() { git -C "$tmp/remote.git" rev-parse refs/heads/feat-cmux-next; }
run_pin() { # run_pin SHA: prints the result
  local output="$tmp/out"
  : > "$output"
  (cd "$work" && GITHUB_OUTPUT="$output" bash scripts/cmux-next/pin-app-ffi-on-base.sh "$1" "$checksum") > "$tmp/log" 2>&1 \
    || { cat "$tmp/log" >&2; fail "pin-app-ffi-on-base.sh $1 failed"; }
  sed -n 's/^result=//p' "$output"
}
pinned_at() { git -C "$tmp/remote.git" show "refs/heads/feat-cmux-next:Packages/macOS/CmuxNext/Package.swift" | grep -oE 'cmux-app-ffi-[0-9a-f]{40}' | head -n 1; }

# An additive FFI change (a new function), then an unrelated commit on top.
sed -i.bak 's/^int cmux_one(int a);$/int cmux_one(int a);\nint cmux_two(void);/' "$work/$header" && rm -f "$work/$header.bak"
grep -q '^int cmux_two(void);$' "$work/$header" || fail "the additive edit did not apply"
echo v2 > "$work/cmux-tui/crates/cmux-app-ffi/src/lib.rs"
release="$(commit "ffi: add cmux_two")"
echo z > "$work/cmux-tui/crates/cmux-unrelated/lib.rs"
commit "unrelated" >/dev/null

# Dry run: nothing is pushed.
before="$(remote_tip)"
[[ "$(run_pin "$release")" == dry-run ]] || fail "no dry run: $(cat "$tmp/log")"
[[ "$(remote_tip)" == "$before" ]] || fail "a dry run pushed"

# The remote refuses the first push (the tip moved); the second attempt lands.
cat > "$tmp/remote.git/hooks/pre-receive" <<EOF
#!/bin/sh
[ -f "$tmp/refused" ] && exit 0
touch "$tmp/refused"
exit 1
EOF
chmod +x "$tmp/remote.git/hooks/pre-receive"
export ENABLED=true
[[ "$(run_pin "$release")" == pinned ]] || fail "not pinned: $(cat "$tmp/log")"
[[ -f "$tmp/refused" ]] || fail "the refused push never happened"
grep -q "moved (attempt 1)" "$tmp/log" || fail "no retry after the refused push: $(cat "$tmp/log")"
[[ "$(pinned_at)" == "cmux-app-ffi-$release" ]] || fail "the remote pins $(pinned_at), not $release"
[[ "$(git -C "$tmp/remote.git" log -1 --format=%s feat-cmux-next)" == "chore(next): pin CCmuxAppFFI to cmux-app-ffi-$release" ]] \
  || fail "unexpected pin commit: $(git -C "$tmp/remote.git" log -1 --format=%s feat-cmux-next)"
[[ "$(git -C "$tmp/remote.git" diff --name-only feat-cmux-next~1 feat-cmux-next)" == Packages/macOS/CmuxNext/Package.swift ]] \
  || fail "the pin commit changes more than Package.swift"
git -C "$work" pull -q --ff-only origin feat-cmux-next
out="$(cd "$work" && bash scripts/cmux-next/check-app-ffi-pin.sh --verify-release 2>&1)" || fail "the pin check fails on the pinned tip: $out"

# Again: already pinned, nothing pushed.
before="$(remote_tip)"
[[ "$(run_pin "$release")" == already ]] || fail "not already: $(cat "$tmp/log")"
[[ "$(remote_tip)" == "$before" ]] || fail "already pinned, but pushed"

# An unrelated commit keeps the pin valid: the check passes with no re-pin.
echo zz > "$work/cmux-tui/crates/cmux-unrelated/lib.rs"
commit "unrelated 2" >/dev/null
out="$(cd "$work" && bash scripts/cmux-next/check-app-ffi-pin.sh 2>&1)" || fail "an unrelated commit made the pin stale: $out"

# Two newer FFI changes, the tip ahead of both releases. The release the tip already pins is not pinned again,
# and the pin check fails (no --stale-grace here).
echo v3 > "$work/cmux-tui/crates/cmux-app-ffi/src/lib.rs"
middle="$(commit "ffi: v3")"
echo v4 > "$work/cmux-tui/crates/cmux-app-ffi/src/lib.rs"
newer="$(commit "ffi: v4")"
before="$(remote_tip)"
[[ "$(run_pin "$release")" == already ]] || fail "the pinned release was not read as already pinned: $(cat "$tmp/log")"
[[ "$(remote_tip)" == "$before" ]] || fail "an already pinned release was pushed"
if out="$(cd "$work" && bash scripts/cmux-next/check-app-ffi-pin.sh 2>&1)"; then fail "a stale pin passed: $out"; fi
[[ "$out" == *"error: the app FFI sources changed since the pinned source $release"* ]] || fail "no stale error: $out"
# The release in the middle: the tip moved past its sources, and it is on the tip's history and newer than the
# pin, so it is pinned. Before, it was refused as "newer", and with FFI commits landing faster than a release
# builds no release was ever pinned (2026-11-10 23:42 to 03:37 UTC).
[[ "$(run_pin "$middle")" == pinned ]] || fail "a release the tip moved past was not pinned: $(cat "$tmp/log")"
[[ "$(pinned_at)" == "cmux-app-ffi-$middle" ]] || fail "the remote pins $(pinned_at), not $middle"
git -C "$tmp/remote.git" log -1 --format=%b feat-cmux-next | grep -q "The tip's FFI sources moved on" \
  || fail "the pin commit does not say the tip is ahead: $(git -C "$tmp/remote.git" log -1 --format=%b feat-cmux-next)"
git -C "$work" pull -q --ff-only origin feat-cmux-next
# The pin never goes backwards: the older release is refused now that a newer one is pinned.
before="$(remote_tip)"
[[ "$(run_pin "$release")" == newer ]] || fail "an older release was not refused: $(cat "$tmp/log")"
[[ "$(remote_tip)" == "$before" ]] || fail "an older release was pushed"
[[ "$(pinned_at)" == "cmux-app-ffi-$middle" ]] || fail "the pin went backwards to $(pinned_at)"
# A release that is not on the tip's history is refused too.
git -C "$work" checkout -q --detach "$release"
echo side > "$work/cmux-tui/crates/cmux-app-ffi/src/lib.rs"
git -C "$work" commit -qam "ffi: a side branch"
side="$(git -C "$work" rev-parse HEAD)"
git -C "$work" push -q origin "HEAD:refs/heads/side"
git -C "$work" checkout -q feat-cmux-next
[[ "$(run_pin "$side")" == newer ]] || fail "a release off the tip's history was not refused: $(cat "$tmp/log")"
[[ "$(remote_tip)" == "$before" ]] || fail "a release off the tip's history was pushed"
# The tip's own release is pinned.
[[ "$(run_pin "$newer")" == pinned ]] || fail "the newer release was not pinned: $(cat "$tmp/log")"
[[ "$(pinned_at)" == "cmux-app-ffi-$newer" ]] || fail "the remote pins $(pinned_at), not $newer"
git -C "$work" pull -q --ff-only origin feat-cmux-next

# A changed declaration (a field added to a struct, a parameter changed) goes to the pull request.
# A moved declaration (wrapped in a new #if), a new #pragma before a struct, and a module map edit in the packaging
# script keep every declaration's text, and still go to the pull request.
for edit in 's/int x; int y;/int x; int y; int z;/:cmux_x.h' 's/int cmux_one(int a);/int cmux_one(long a);/:cmux_x.h' \
  's/^int cmux_one(int a);$/#if defined(CMUX_ONE)\nint cmux_one(int a);\n#endif/:cmux_x.h' \
  's/^typedef struct CmuxPoint/#pragma pack(1)\ntypedef struct CmuxPoint/:cmux_x.h' \
  's/module CCmuxX/module CCmuxRenamed/:build-app-ffi.sh'; do
  target="$header"
  [[ "${edit##*:}" == build-app-ffi.sh ]] && target=scripts/cmux-next/build-app-ffi.sh
  edit="${edit%:*}"
  before_edit="$(git -C "$work" hash-object "$work/$target")"
  sed -i.bak "$edit" "$work/$target" && rm -f "$work/$target.bak"
  [[ "$(git -C "$work" hash-object "$work/$target")" != "$before_edit" ]] || fail "$edit did not apply to $target"
  changed="$(commit "ffi: $edit")"
  before="$(remote_tip)"
  [[ "$(run_pin "$changed")" == pr ]] || fail "$edit was pinned on the base: $(cat "$tmp/log")"
  grep -q "drops or changes 1 thing" "$tmp/log" || fail "$edit: no difference named: $(cat "$tmp/log")"
  [[ "$(remote_tip)" == "$before" ]] || fail "$edit was pushed"
  git -C "$work" checkout -q --force feat-cmux-next
  git -C "$work" reset -q --hard "$changed"
  git -C "$work" revert --no-edit HEAD >/dev/null
  git -C "$work" push -q origin HEAD:refs/heads/feat-cmux-next
done

# app_ffi_additive.py alone: comments and whitespace are not declarations; a removed header is not additive.
cd "$work"
cp "$header" "$tmp/h"
{ echo '// a comment'; sed 's/int cmux_one(int a);/int   cmux_one( int a);  \/* note *\//' "$tmp/h"; } > "$header"
git commit -qam "ffi: comments"
python3 -I scripts/cmux-next/app_ffi_additive.py HEAD~1 HEAD -- cmux-tui/crates/cmux-app-ffi >/dev/null \
  && fail "whitespace inside a declaration was read as unchanged"
git reset -q --hard HEAD~1
{ echo '// a comment'; echo; cat "$tmp/h"; } > "$header"
git commit -qam "ffi: comment only"
python3 -I scripts/cmux-next/app_ffi_additive.py HEAD~1 HEAD -- cmux-tui/crates/cmux-app-ffi >/dev/null \
  || fail "a comment was read as a changed declaration"
git rm -q "$header"
git commit -qm "ffi: drop the header"
if python3 -I scripts/cmux-next/app_ffi_additive.py HEAD~1 HEAD -- cmux-tui/crates/cmux-app-ffi > "$tmp/additive"; then
  fail "a removed header read as additive"
fi
grep -q "the header is gone" "$tmp/additive" || fail "no removed-header line: $(cat "$tmp/additive")"

echo "pin-app-ffi-on-base: ok"
