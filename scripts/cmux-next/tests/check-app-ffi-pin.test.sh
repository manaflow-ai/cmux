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
#  - a file in an input crate that no library source, build script or
#    Cargo.toml names (a test, a script, the README, a descriptor only the
#    tests read) is not an input: on 2026-11-09 #39027 changed
#    cmux-tui/bindings/rust/.cmux-resource-api.json, which only
#    tests/catalog_manifest.rs reads, and staled the pin. A file such a source
#    names (include_str!, a build script's read) still is.
set -euo pipefail

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
# Reached only through a [workspace.dependencies] path entry, once a crate inherits it (below).
crate cmux-ws-only
# cmux-app-ffi is its own workspace root, as in the repository, so cargo builds it with its own [patch], [profile] and
# Cargo.lock; the cmux-tui workspace's apply only when it is not (the guard test below).
printf '\n[workspace]\n' >> "$repo/cmux-tui/crates/cmux-app-ffi/Cargo.toml"
echo "lock" > "$repo/cmux-tui/Cargo.lock"
# cmux-rd-core's files beside src/: what a library source, build script or Cargo.toml names is an input; the rest is not.
core="$repo/cmux-tui/crates/cmux-rd-core"
mkdir -p "$core/tests/vectors" "$core/scripts" "$core/benches" "$core/examples"
printf 'pub const DATA: &str = include_str!("../data.json");\n' >> "$core/src/lib.rs"
# rustfmt's form of a long include (the path on its own line, a trailing comma), and the other delimiters.
printf 'pub const ML: &str = include_str!(\n    "../ml.json",\n);\npub const BR: &[u8] = include_bytes!["../br.json"];\n' \
  >> "$core/src/lib.rs"
printf '/// A doc comment may spell out include_str!(PATH) with no literal.\n' >> "$core/src/lib.rs"
printf 'fn main() { println!("cargo:rerun-if-changed=build-data.txt"); std::fs::read_to_string("build-data.txt").unwrap(); }\n' > "$core/build.rs"
printf 'const V: &str = include_str!("../../cmux-rd-core/tests/vectors/lines.json");\n' > "$repo/cmux-tui/crates/cmux-rd-ffi/src/vectors.rs"
printf 'const D: &str = include_str!("../.descriptor.json");\n' > "$core/tests/api.rs"
for f in data.json ml.json br.json build-data.txt .descriptor.json README.md LICENSE tests/vectors/lines.json \
  scripts/sync.py benches/b.rs examples/e.rs; do
  echo "$f" > "$core/$f"
done
# The cmux-tui workspace manifest: cmux-rd-core inherits two [workspace.package] keys and two [workspace.dependencies]
# entries (one in a target table) for its library, and one entry only for its tests.
cat > "$repo/cmux-tui/Cargo.toml" <<'EOF'
[workspace]
members = ["crates/cmux-unrelated"]

[workspace.package]
edition = "2021"
license = "MIT"
rust-version = "1.80"
homepage = "https://a.example"

[workspace.lints.rust]
unsafe_code = "warn"

[workspace.dependencies]
serde = { version = "1", features = ["derive"] }
libc = "0.2"
criterion = "0.5"
tokio = "1"
rusqlite = { version = "0.32", default-features = false }
itoa = "1"
cmux-ws-only = { path = "crates/cmux-ws-only" }

[patch.crates-io]
tokio = { path = "vendor/tokio" }

[profile.release]
opt-level = 3
EOF
cat > "$core/Cargo.toml" <<'EOF'
[package]
name = "x"
edition.workspace = true
license = { workspace = true }

[lib]
path = "src/lib.rs"

[dependencies]
serde = { workspace = true, features = ["std"] }
rusqlite.workspace = true

[target.'cfg(unix)'.dependencies]
libc.workspace = true

[dev-dependencies]
criterion = { workspace = true }
EOF
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

# A file in an input crate that nothing the library build reads names is not an input: a test, a script, a bench, an
# example, the README, the LICENSE, and a descriptor only a test reads (.cmux-resource-api.json, #39027).
for f in tests/api.rs scripts/sync.py benches/b.rs examples/e.rs README.md LICENSE .descriptor.json; do
  echo "changed" >> "$core/$f"
done
git -C "$repo" commit -qam "test-only files"
out="$(cd "$repo" && bash scripts/cmux-next/check-app-ffi-pin.sh 2>&1)" || fail "a test-only file made the pin stale: $out"
[[ "$out" == *"sources match $pinned"* ]] || fail "no match line after a test-only change: $out"
# What the library build reads stays an input: a file a library source includes (include_str!), one its build script
# reads, and a tests/ file that a library source of another input crate includes.
for f in data.json ml.json br.json build-data.txt tests/vectors/lines.json; do
  echo "changed" >> "$core/$f"
  git -C "$repo" commit -qam "input $f"
  if out="$(cd "$repo" && bash scripts/cmux-next/check-app-ffi-pin.sh 2>&1)"; then
    fail "a change to $f, which the library build reads, kept the pin current: $out"
  fi
  [[ "$out" == *"cmux-tui/crates/cmux-rd-core/$f"* ]] || fail "the stale report does not name $f: $out"
  git -C "$repo" reset -q --hard HEAD~1
done
# What cargo and rustup read above the crate files: the crate's own and its parents' cargo config and toolchain
# (review of #40095).
for f in cmux-tui/crates/cmux-app-ffi/.cargo/config.toml cmux-tui/crates/cmux-app-ffi/rust-toolchain.toml \
  cmux-tui/crates/.cargo/config.toml cmux-tui/.cargo/config.toml .cargo/config.toml; do
  mkdir -p "$(dirname "$repo/$f")"
  echo "changed" > "$repo/$f"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "input $f"
  if out="$(cd "$repo" && bash scripts/cmux-next/check-app-ffi-pin.sh 2>&1)"; then
    fail "a change to $f, which cargo or rustup reads, kept the pin current: $out"
  fi
  [[ "$out" == *"$f"* ]] || fail "the stale report does not name $f: $out"
  git -C "$repo" reset -q --hard HEAD~1
done
# Of the cmux-tui workspace manifest, only what the FFI crates inherit for their library is an input: it changed 55
# times on feat-cmux-next in the 14 days to 2026-11-10. cmux-app-ffi is its own workspace root, so the manifest's
# members, lints, [patch] and [profile] do not reach the FFI build, nor do entries the crates do not inherit or
# inherit only for tests.
ws="$repo/cmux-tui/Cargo.toml"
edit_ws() { # edit_ws FROM TO MESSAGE: replace FROM with TO in the workspace manifest and commit
  python3 - "$ws" "$1" "$2" <<'EOF'
import sys
from pathlib import Path
path, old, new = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = path.read_text()
assert text.count(old) == 1, old
path.write_text(text.replace(old, new))
EOF
  git -C "$repo" commit -qam "$3"
}
edit_ws 'members = ["crates/cmux-unrelated"]' 'members = ["crates/cmux-unrelated", "crates/cmux-new"]' "ws members"
edit_ws 'unsafe_code = "warn"' 'unsafe_code = "deny"' "ws lints"
edit_ws 'criterion = "0.5"' 'criterion = "0.6"' "ws dev-only dependency"
edit_ws 'tokio = "1"' 'tokio = "1.40"' "ws dependency no FFI crate inherits"
edit_ws 'path = "vendor/tokio"' 'path = "vendor/tokio2"' "ws patch"
edit_ws 'opt-level = 3' 'opt-level = 2' "ws profile"
edit_ws 'rust-version = "1.80"' 'rust-version = "1.81"' "ws package key no FFI crate inherits"
edit_ws 'homepage = "https://a.example"' 'homepage = "https://b.example"' "ws package key no FFI crate inherits yet"
edit_ws 'itoa = "1"' 'itoa = "1.0.15"' "ws dependency no FFI crate inherits yet"
echo "changed" >> "$repo/cmux-tui/crates/cmux-ws-only/src/lib.rs"
echo "changed" >> "$repo/cmux-tui/Cargo.lock"
git -C "$repo" commit -qam "a crate no FFI crate reaches yet, and the cmux-tui lock file"
printf '\n[workspace.metadata.x]\ny = 1\n' >> "$ws"
git -C "$repo" commit -qam "ws metadata"
out="$(cd "$repo" && bash scripts/cmux-next/check-app-ffi-pin.sh 2>&1)" \
  || fail "a workspace manifest change no FFI crate inherits made the pin stale: $out"
[[ "$out" == *"sources match $pinned"* ]] || fail "no match line after workspace manifest changes: $out"
# What an FFI crate inherits for its library is an input: a [workspace.package] key in either form, and a
# [workspace.dependencies] entry from [dependencies] or a target table.
for change in 'edition = "2021"|edition = "2024"' 'license = "MIT"|license = "MIT OR Apache-2.0"' \
  'features = ["derive"]|features = ["derive", "rc"]' 'features = ["derive"]|features = ["derive"], optional = true' \
  'default-features = false|default-features = true' 'libc = "0.2"|libc = "0.2.170"'; do
  edit_ws "${change%%|*}" "${change#*|}" "inherited ${change%%|*}"
  if out="$(cd "$repo" && bash scripts/cmux-next/check-app-ffi-pin.sh 2>&1)"; then
    fail "a change to the inherited ${change%%|*} kept the pin current: $out"
  fi
  [[ "$out" == *"cmux-tui/Cargo.toml"* ]] || fail "the stale report does not name cmux-tui/Cargo.toml: $out"
  git -C "$repo" reset -q --hard HEAD~1
done
# A crate that starts to inherit an entry is a changed input (its own Cargo.toml).
printf 'tokio = { workspace = true }\n' >> "$core/Cargo.toml"
git -C "$repo" commit -qam "inherit tokio"
if out="$(cd "$repo" && bash scripts/cmux-next/check-app-ffi-pin.sh 2>&1)"; then
  fail "a crate that starts to inherit an entry kept the pin current: $out"
fi
git -C "$repo" reset -q --hard HEAD~1
before_ws="$(git -C "$repo" rev-parse HEAD)"
repin() { # repin MESSAGE: pin the current HEAD (the tests below start from a pin of what they set up)
  local head
  head="$(git -C "$repo" rev-parse HEAD)"
  perl -pi -e "s/cmux-app-ffi-[0-9a-f]{40}/cmux-app-ffi-$head/" "$repo/Packages/macOS/CmuxNext/Package.swift"
  git -C "$repo" commit -qam "$1"
  out="$(cd "$repo" && bash scripts/cmux-next/check-app-ffi-pin.sh 2>&1)" || fail "$1: a current pin failed: $out"
  [[ "$out" == *"sources match $head"* ]] || fail "$1: no match line: $out"
}
stale_after() { # stale_after WHY NAMED: the check fails, naming NAMED; then drop the last commit
  if out="$(cd "$repo" && bash scripts/cmux-next/check-app-ffi-pin.sh 2>&1)"; then
    fail "$1 kept the pin current: $out"
  fi
  [[ "$out" == *"$2"* ]] || fail "the stale report for $1 does not name $2: $out"
  git -C "$repo" reset -q --hard HEAD~1
}
# What is inherited is read from the FFI crates' manifests on every run, never from a fixed list: once cmux-rd-core
# inherits a package key, a library, build and dev dependency and the lints that no crate inherited before, each is
# an input, and a crate reached only through an inherited [workspace.dependencies] path entry is an input crate.
cat > "$core/Cargo.toml" <<'EOF'
[package]
name = "x"
edition.workspace = true
license = { workspace = true }
homepage.workspace = true

[lib]
path = "src/lib.rs"

[dependencies]
serde = { workspace = true, features = ["std"] }
rusqlite.workspace = true
cmux-ws-only = { workspace = true }

[build-dependencies]
itoa = { workspace = true }

[target.'cfg(unix)'.dependencies]
libc.workspace = true

[dev-dependencies]
criterion = { workspace = true }

[lints]
workspace = true
EOF
git -C "$repo" commit -qam "cmux-rd-core inherits more"
repin "pin the new inheritance"
edit_ws 'homepage = "https://b.example"' 'homepage = "https://c.example"' "newly inherited package key"
stale_after "a change to a newly inherited package key" cmux-tui/Cargo.toml
edit_ws 'itoa = "1.0.15"' 'itoa = "1.0.16"' "newly inherited build dependency"
stale_after "a change to a newly inherited build dependency" cmux-tui/Cargo.toml
edit_ws 'unsafe_code = "deny"' 'unsafe_code = "forbid"' "newly inherited lints"
stale_after "a change to newly inherited lints" cmux-tui/Cargo.toml
echo "changed again" >> "$repo/cmux-tui/crates/cmux-ws-only/src/lib.rs"
git -C "$repo" commit -qam "a crate reached through an inherited path entry"
stale_after "a change to a crate reached through an inherited path entry" cmux-tui/crates/cmux-ws-only/src/lib.rs
# Still not an input: a dev-dependency entry (only tests build it).
edit_ws 'criterion = "0.6"' 'criterion = "0.7"' "inherited dev-dependency"
out="$(cd "$repo" && bash scripts/cmux-next/check-app-ffi-pin.sh 2>&1)" \
  || fail "a change to an entry inherited only as a dev-dependency made the pin stale: $out"
git -C "$repo" reset -q --hard "$before_ws"
# The narrowing holds only because cmux-app-ffi is its own workspace root (its [workspace] table; cargo then reads its
# [patch], [profile] and Cargo.lock, never those of cmux-tui). Without that table it would build in the cmux-tui
# workspace, so the whole cmux-tui manifest and the cmux-tui Cargo.lock are inputs again.
python3 - "$repo/cmux-tui/crates/cmux-app-ffi/Cargo.toml" <<'EOF'
import sys
from pathlib import Path
path = Path(sys.argv[1])
path.write_text(path.read_text().replace("\n[workspace]\n", "\n"))
EOF
git -C "$repo" commit -qam "cmux-app-ffi in the cmux-tui workspace"
repin "pin cmux-app-ffi in the cmux-tui workspace"
edit_ws 'opt-level = 2' 'opt-level = 1' "ws profile, cmux-app-ffi in the cmux-tui workspace"
stale_after "a cmux-tui profile change when cmux-app-ffi builds in the cmux-tui workspace" cmux-tui/Cargo.toml
echo "changed again" >> "$repo/cmux-tui/Cargo.lock"
git -C "$repo" commit -qam "cmux-tui lock, cmux-app-ffi in the cmux-tui workspace"
stale_after "a cmux-tui Cargo.lock change when cmux-app-ffi builds in the cmux-tui workspace" cmux-tui/Cargo.lock
git -C "$repo" reset -q --hard "$before_ws"
# Without tomllib (Python before 3.11, /usr/bin/python3 on macOS) the view is the whole manifest, and an inherited path
# entry is read line by line; an entry that line reading cannot find refuses.
python3 -I - "$repo/scripts/ci" "$ws" "$core/Cargo.toml" <<'EOF' || fail "the reader without tomllib is wrong"
import sys
sys.path.insert(0, sys.argv[1])
import app_ffi_pin as m
workspace, crate = open(sys.argv[2]).read(), open(sys.argv[3]).read()
assert m.own_root("[package]\nname = \"x\"\n\n[workspace]\n", loads=None)
assert not m.own_root("[package]\nname = \"x\"\n# [workspace]\n", loads=None)
assert m.workspace_view(workspace, [crate], loads=None) != m.workspace_view(
    workspace + "\n# a comment\n", [crate], loads=None)
inheriting = '[dependencies]\ncmux-ws-only = { workspace = true }\nserde.workspace = true\n' \
    '[target."cfg(unix)".build-dependencies.itoa]\nworkspace = true\n'
assert m.workspace_paths(workspace, inheriting, loads=None) == ["crates/cmux-ws-only"], \
    m.workspace_paths(workspace, inheriting, loads=None)
try:
    m.workspace_paths(workspace, "[dependencies]\nnot-in-the-workspace.workspace = true\n", loads=None)
except m.Unresolved:
    pass
else:
    raise AssertionError("an inherited entry the workspace does not have was not refused")
EOF

# A name the scan cannot read refuses, never leaves the file out: a build script that reads by a computed path, an
# include whose argument is not one string literal, and a #[path] module outside src/ (its own modules would go
# unread).
refuse() { # refuse FILE TEXT WHY
  printf '%s\n' "$2" >> "$repo/$1"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "refuse $1"
  if out="$(cd "$repo" && bash scripts/cmux-next/check-app-ffi-pin.sh 2>&1)"; then
    fail "$3 passed: $out"
  fi
  [[ "$out" == *"the app FFI inputs cannot be listed"* ]] || fail "$3 did not refuse: $out"
  git -C "$repo" reset -q --hard HEAD~1
}
refuse cmux-tui/crates/cmux-rd-core/build.rs \
  'fn more() { let p = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("x.txt"); std::fs::read_to_string(&p).unwrap(); }' \
  "a build script that reads by a computed path"
refuse cmux-tui/crates/cmux-rd-core/src/lib.rs 'pub const Q: &str = include_str!(concat!("../", "q.json"));' \
  "an include by a computed path"
refuse cmux-tui/crates/cmux-rd-core/src/lib.rs '#[path = "../shared/foo.rs"] mod foo;' \
  "a #[path] module outside src/"
refuse cmux-tui/Cargo.toml '[[[' "a workspace manifest that is not TOML"

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

echo "check-app-ffi-pin.test.sh: ok"
