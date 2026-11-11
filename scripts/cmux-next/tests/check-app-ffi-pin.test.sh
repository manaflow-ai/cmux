#!/usr/bin/env bash
# scripts/cmux-next/check-app-ffi-pin.sh against a scratch repository:
#  - every crate cmux-app-ffi reaches through Cargo path dependencies is an
#    FFI input (cmux-rd-ffi pulls cmux-remote-browser; a change there left the
#    pin "current" on 2026-10-07, cf25b525a03b), and an unrelated crate is not;
#  - a checkout without an `origin` remote (a fleet ci-step worktree, step
#    6e04059b590e) still fetches the pinned source sha;
#  - a module a change adds beside the pin reader (scripts/ci/json.py) or at
#    the repository root (json.py) does not change the verdict: every python3
#    the check runs is isolated (-I), so neither the script's directory nor the
#    working directory is on its import path. base_red_excuse.py trusts the
#    verdict of a PR that leaves the check's files alone, and a new file is not
#    one of them.
set -euo pipefail
# shellcheck source=scripts/cmux-next/tests/lib/git-fixture.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-fixture.sh"  # turns off git's background maintenance in temp repos

script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/check-app-ffi-pin.sh"
# The script reads the pin only through scripts/ci/app_ffi_pin.py, so the scratch tree carries it too.
pin_reader="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../ci" && pwd)/app_ffi_pin.py"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
fail() { echo "FAIL: $*" >&2; exit 1; }

repo="$tmp/repo"
mkdir -p "$repo/scripts/cmux-next" "$repo/scripts/ci" "$repo/Packages/macOS/CmuxNext"
cp "$script" "$repo/scripts/cmux-next/check-app-ffi-pin.sh"
cp "$pin_reader" "$repo/scripts/ci/app_ffi_pin.py"
crate() { # crate NAME [DEP...]
  local dir="$repo/cmux-tui/crates/$1"; shift
  mkdir -p "$dir/src"
  {
    printf '[package]\nname = "x"\n\n[lib]\npath = "src/lib.rs"\n\n[dependencies]\n'
    for dep in "$@"; do printf '%s = { path = "../%s" }\n' "$dep" "$dep"; done
  } > "$dir/Cargo.toml"
  echo "// $dir" > "$dir/src/lib.rs"
}
crate cmux-app-ffi cmux-rd-ffi cmux-layout-reducer-ffi
crate cmux-rd-ffi cmux-rd-core cmux-remote-browser
crate cmux-rd-core
crate cmux-layout-reducer-ffi
crate cmux-remote-browser
crate cmux-unrelated
git -C "$repo" init -q
git -C "$repo" add -A
git -C "$repo" commit -qm sources
pinned="$(git -C "$repo" rev-parse HEAD)"
cat > "$repo/Packages/macOS/CmuxNext/Package.swift" <<EOF
let appFFI: Target = .binaryTarget(
    name: "CCmuxAppFFI",
    url: "https://github.com/manaflow-ai/cmux/releases/download/cmux-app-ffi-$pinned/CCmuxAppFFI.xcframework.zip",
    checksum: "$(printf '0%.0s' {1..64})"
)
EOF
git -C "$repo" add -A
git -C "$repo" commit -qm pin

out="$(cd "$repo" && bash scripts/cmux-next/check-app-ffi-pin.sh 2>&1)" || fail "a current pin failed: $out"
[[ "$out" == *"sources match $pinned"* ]] || fail "no match line: $out"

# An unrelated crate does not make the pin stale.
echo "// changed" >> "$repo/cmux-tui/crates/cmux-unrelated/src/lib.rs"
git -C "$repo" commit -qam unrelated
out="$(cd "$repo" && bash scripts/cmux-next/check-app-ffi-pin.sh 2>&1)" || fail "an unrelated crate made the pin stale: $out"

# --verify-release reads the release-assets API's answer with python3 -c from
# the repository root. A json.py there does not change that verdict. curl is a
# fake: the release download fails, so the API is asked, and it names a release
# whose SOURCE_SHA is not the pinned sha.
zeros="$(printf '0%.0s' {1..64})"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/curl" <<CURL
#!/usr/bin/env bash
out="" url=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out="\$2"; shift ;;
    -H|--connect-timeout|--max-time|--retry|--retry-delay) shift ;;
    http*) url="\$1" ;;
  esac
  shift
done
case "\$url" in
  https://github.com/*/releases/download/*) exit 22 ;;
  https://api.github.com/repos/*/releases/tags/*)
    body='{"assets": [{"name": "SOURCE_SHA", "url": "https://assets.invalid/served/SOURCE_SHA"}, {"name": "SHA256SUMS", "url": "https://assets.invalid/served/SHA256SUMS"}]}' ;;
  https://assets.invalid/served/SOURCE_SHA) body="$(printf 'f%.0s' {1..40})" ;;
  https://assets.invalid/planted/SOURCE_SHA) body="$pinned" ;;
  https://assets.invalid/*/SHA256SUMS) body="$zeros  CCmuxAppFFI.xcframework.zip" ;;
  *) exit 6 ;;
esac
if [[ -n "\$out" ]]; then echo "\$body" > "\$out"; else echo "\$body"; fi
CURL
chmod +x "$tmp/bin/curl"
verify() { (cd "$repo" && PATH="$tmp/bin:$PATH" bash scripts/cmux-next/check-app-ffi-pin.sh --verify-release "$@" 2>&1); }
if out="$(verify)"; then
  fail "a release whose SOURCE_SHA is not the pin passed --verify-release: $out"
fi
[[ "$out" == *"is not the pinned sha $pinned"* ]] || fail "the release-assets API path did not report the SOURCE_SHA: $out"
cat > "$repo/json.py" <<'PY'
import sys
def load(stream):
    stream.read()
    return {"assets": [{"name": sys.argv[1], "url": "https://assets.invalid/planted/" + sys.argv[1]}]}
PY
if out="$(verify)"; then
  fail "a json.py at the repository root changed the --verify-release verdict: $out"
fi
[[ "$out" == *"is not the pinned sha $pinned"* ]] || fail "a root json.py changed the --verify-release report: $out"
rm -f "$repo/json.py"

# A no-origin checkout (shallow, as a fleet step) fetches the pinned sha from
# CMUX_APP_FFI_PIN_REMOTE.
fleet="$tmp/fleet"
git init -q "$fleet"
git -C "$fleet" fetch -q --depth=1 "file://$repo" "$(git -C "$repo" rev-parse HEAD)"
git -C "$fleet" checkout -q --detach FETCH_HEAD
git -C "$fleet" cat-file -e "$pinned^{commit}" 2>/dev/null && fail "the fleet checkout already has the pinned sha"
out="$(cd "$fleet" && CMUX_APP_FFI_PIN_REMOTE="file://$repo" bash scripts/cmux-next/check-app-ffi-pin.sh 2>&1)" \
  || fail "a checkout without origin could not check the pin: $out"

# A crate reached only through cmux-rd-ffi's path dependencies is an input.
echo "// rb client" >> "$repo/cmux-tui/crates/cmux-remote-browser/src/lib.rs"
git -C "$repo" commit -qam rb
rb="$(git -C "$repo" rev-parse HEAD)"
if out="$(cd "$repo" && bash scripts/cmux-next/check-app-ffi-pin.sh 2>&1)"; then
  fail "a cmux-remote-browser change kept the pin current: $out"
fi
[[ "$out" == *"cmux-remote-browser"* ]] || fail "the stale report does not name cmux-remote-browser: $out"
# The stale report tells a pull request author what to do (lead decision, 2026-11-10): a release is published only
# from a feat-cmux-next push, so a PR cannot pin its own FFI sources; it splits into a Rust-only step A and a Swift
# step B after the re-pin, and docs/ci/app-ffi-release.md says how.
[[ "$out" == *"this PR changes FFI inputs: split it into a Rust-only step A and a Swift step B after the re-pin"* ]] \
  || fail "the stale report does not give the step A / step B rule: $out"
[[ "$out" == *"docs/ci/app-ffi-release.md"* ]] || fail "the stale report does not point to the doc: $out"

# A pin outside the canonical block fails closed, naming the reader's reason.
git -C "$repo" checkout -q HEAD~1
sed -i.bak 's/^let appFFI: Target = //' "$repo/Packages/macOS/CmuxNext/Package.swift"
if out="$(cd "$repo" && bash scripts/cmux-next/check-app-ffi-pin.sh 2>&1)"; then
  fail "a non-canonical pin passed: $out"
fi
[[ "$out" == *"no canonical cmux-app-ffi pin"* ]] || fail "the non-canonical report does not say so: $out"

# A json.py beside the pin reader does not change the verdict. Without -I it
# is imported first: this one prints a pin naming HEAD, so the stale sources
# would read as current.
git -C "$repo" checkout -q -f "$rb"
rm -f "$repo/Packages/macOS/CmuxNext/Package.swift.bak"
shadow() { # shadow SHA: scripts/ci/json.py makes the pin reader print SHA as the pin
  printf 'import sys\nsys.stdout.write("%s %s\\n")\nsys.exit(0)\n' "$1" "$zeros" > "$repo/scripts/ci/json.py"
}
shadow "$rb"
if out="$(cd "$repo" && bash scripts/cmux-next/check-app-ffi-pin.sh 2>&1)"; then
  fail "a scripts/ci/json.py made a stale pin read as current: $out"
fi
[[ "$out" == *"cmux-remote-browser"* ]] || fail "a scripts/ci/json.py changed the stale report: $out"
rm -f "$repo/scripts/ci/json.py"

# The --base read (the base's Package.swift through the pin reader) is isolated
# too. The base pins the current sources ($rb) and the change moves the pin
# back to the stale $pinned: its own red. A json.py that reads every pin as
# $pinned would make it base drift, which passes.
pin_to() { # pin_to SHA MESSAGE
  sed -i.bak -E "s/cmux-app-ffi-[0-9a-f]{40}/cmux-app-ffi-$1/" "$repo/Packages/macOS/CmuxNext/Package.swift"
  rm -f "$repo/Packages/macOS/CmuxNext/Package.swift.bak"
  git -C "$repo" commit -qam "$2"
}
pin_to "$rb" base
pin_to "$pinned" "pin back"
if out="$(cd "$repo" && bash scripts/cmux-next/check-app-ffi-pin.sh --base HEAD~1 2>&1)"; then
  fail "moving the pin back to a stale release passed against its base: $out"
fi
[[ "$out" == *"changed since the pinned source $pinned"* ]] || fail "no stale report for the moved pin: $out"
shadow "$pinned"
if out="$(cd "$repo" && bash scripts/cmux-next/check-app-ffi-pin.sh --base HEAD~1 2>&1)"; then
  fail "a scripts/ci/json.py made the change's own stale pin base drift: $out"
fi
[[ "$out" == *"changed since the pinned source $pinned"* ]] || fail "a scripts/ci/json.py changed the --base report: $out"
rm -f "$repo/scripts/ci/json.py"

# --tree DIR: a copy of the check outside the repository judges the tree at DIR
# (its Package.swift, its FFI inputs, its history) and reads the pin only with
# its own reader, never the tree's. cmux-next.yml runs the base's copy so on a
# pull request's tree.
code="$tmp/code"
mkdir -p "$code/scripts/cmux-next" "$code/scripts/ci"
cp "$script" "$code/scripts/cmux-next/check-app-ffi-pin.sh"
cp "$pin_reader" "$code/scripts/ci/app_ffi_pin.py"
check_tree() { (cd "$tmp" && bash "$code/scripts/cmux-next/check-app-ffi-pin.sh" --tree "$repo" "$@" 2>&1); }
git -C "$repo" checkout -q -f "$rb~1"
out="$(check_tree)" || fail "--tree failed on a current pin: $out"
[[ "$out" == *"sources match $pinned"* ]] || fail "--tree did not read the tree's pin: $out"
out="$(check_tree --list-inputs)" || fail "--tree --list-inputs failed: $out"
[[ "$out" == *"cmux-tui/crates/cmux-remote-browser"* ]] || fail "--tree --list-inputs did not read the tree's crates: $out"
git -C "$repo" checkout -q -f "$rb"
if out="$(check_tree)"; then
  fail "--tree passed a stale pin: $out"
fi
[[ "$out" == *"cmux-remote-browser"* ]] || fail "--tree did not report the tree's stale crate: $out"
# The tree's own reader, changed to read the pin as HEAD, is not the one that runs.
printf 'print("%s %s")\n' "$rb" "$zeros" > "$repo/scripts/ci/app_ffi_pin.py"
if out="$(check_tree)"; then
  fail "--tree ran the tree's pin reader: $out"
fi
[[ "$out" == *"cmux-remote-browser"* ]] || fail "the tree's pin reader changed the --tree report: $out"
git -C "$repo" checkout -q -f "$rb"

# The JSON pin (cmux#37645): app-ffi-pin.json beside a Package.swift that holds
# only its loader block, read through app_ffi_pin.py's read_pin_file and
# check_loader. The base's copy of the check judges a pull request that moves
# the pin to that form, so the check reads both forms, at HEAD and at --base.
json_pin() { # json_pin MESSAGE: rewrite the tree's pin into the JSON form for $pinned, and commit
  python3 -I - "$pin_reader" "$pinned" "$zeros" "$repo/Packages/macOS/CmuxNext" <<'PY'
import importlib.util
import sys
from pathlib import Path
spec = importlib.util.spec_from_file_location("app_ffi_pin", sys.argv[1])
pin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pin)
folder = Path(sys.argv[4])
(folder / "app-ffi-pin.json").write_text(pin.render_pin_file(sys.argv[2], sys.argv[3]))
(folder / "Package.swift").write_text("import Foundation\n\n" + pin.loader(sys.argv[3]) + "\nlet package = 0\n")
PY
  git -C "$repo" add -A
  git -C "$repo" commit -qm "$1"
}
git -C "$repo" checkout -q -f "$rb~1"
json_pin "json pin, current"
out="$(check_tree)" || fail "a current JSON pin failed: $out"
[[ "$out" == *"sources match $pinned"* ]] || fail "the JSON pin was not read: $out"
# A stale JSON pin whose base pins the same release in the same form: base
# drift, which passes only when the base's JSON pin is read too.
git -C "$repo" checkout -q -f "$rb"
json_pin "json pin, stale base"
echo "not an FFI input" > "$repo/NOTES.txt"
git -C "$repo" add -A
git -C "$repo" commit -qm "unrelated"
if ! out="$(check_tree --base HEAD~1)"; then
  fail "a change that leaves a stale JSON base pin alone failed: $out"
fi
[[ "$out" == *"note: base drift"* ]] || fail "the base's JSON pin was not read: $out"
if out="$(check_tree)"; then
  fail "a stale JSON pin passed: $out"
fi
[[ "$out" == *"changed since the pinned source $pinned"* ]] || fail "no stale report for the JSON pin: $out"

# --stale-grace (the push run of feat-cmux-next): a pin behind the sources passes with a note while the first
# commit that left it behind is younger than the grace, and fails once it is older. Before, every FFI commit left
# the tip red until its release was pinned (cmux-next runs 42952459700, 42958342526, 42960857925, 42973010316).
check_at() { # check_at NOW [check option...]: the check in $repo with the clock at NOW
  local now="$1"; shift
  (cd "$repo" && CMUX_APP_FFI_PIN_NOW="$now" bash scripts/cmux-next/check-app-ffi-pin.sh "$@" 2>&1)
}
behind_at="$(git -C "$repo" show -s --format=%ct "$rb")"
out="$(check_at "$((behind_at + 600))" --stale-grace 3600)" || fail "a pin behind for 10 minutes failed inside its grace: $out"
[[ "$out" == *"note: the pin is behind: the app FFI sources changed 10 min ago"* ]] || fail "no behind note: $out"
[[ "$out" == *"cmux-remote-browser"* ]] || fail "the behind note does not name what changed: $out"
if out="$(check_at "$((behind_at + 7200))" --stale-grace 3600)"; then
  fail "a pin behind for two hours passed a one hour grace: $out"
fi
[[ "$out" == *"error: the pin has been behind for 120 min"* ]] || fail "no overdue line: $out"
[[ "$out" == *"changed since the pinned source $pinned"* ]] || fail "the overdue report lost the stale report: $out"
# Without the flag (a pull request, the pre-push gate) the same tree still fails.
if out="$(check_at "$((behind_at + 600))")"; then fail "a stale pin passed without --stale-grace: $out"; fi
# The grace counts from the first commit that left the pin behind: a later FFI commit does not start it again.
echo "// later" >> "$repo/cmux-tui/crates/cmux-rd-core/src/lib.rs"
GIT_COMMITTER_DATE="@$((behind_at + 3000)) +0000" git -C "$repo" commit -qam "rd-core, later"
if out="$(check_at "$((behind_at + 4000))" --stale-grace 3600)"; then
  fail "a later FFI commit started the grace again: $out"
fi
[[ "$out" == *"error: the pin has been behind for 66 min"* ]] || fail "the age is not counted from the first commit: $out"
# A shallow checkout (actions/checkout) holds no commit between the pin and HEAD: the check deepens it to date
# the first one. Without that, HEAD's own commit read as the first, and a pin never grew overdue.
shallow="$tmp/shallow"
git clone -q --depth=1 "file://$repo" "$shallow"
[[ "$(git -C "$shallow" rev-list --count HEAD)" == 1 ]] || fail "the clone is not shallow"
out="$(cd "$shallow" && CMUX_APP_FFI_PIN_NOW="$((behind_at + 600))" bash scripts/cmux-next/check-app-ffi-pin.sh --stale-grace 3600 2>&1)" \
  || fail "a shallow checkout failed inside the grace: $out"
[[ "$out" == *"note: the pin is behind: the app FFI sources changed 10 min ago"* ]] || fail "a shallow checkout dated the pin wrong: $out"
if out="$(cd "$shallow" && CMUX_APP_FFI_PIN_NOW="$((behind_at + 4000))" bash scripts/cmux-next/check-app-ffi-pin.sh --stale-grace 3600 2>&1)"; then
  fail "a shallow checkout passed an overdue pin: $out"
fi
[[ "$out" == *"error: the pin has been behind for 66 min"* ]] || fail "a shallow checkout lost the first commit: $out"

echo "check-app-ffi-pin.test.sh: ok"
