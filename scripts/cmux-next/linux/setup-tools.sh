#!/usr/bin/env bash
# Installs the oracle's extra tools on the Linux VM: OpenJDK (for
# plans/cmux-next/formal/tlc.sh), the stable and a dated nightly Rust,
# cargo-nextest, cargo-mutants, cargo-fuzz, zig for ghostty-next, and a
# shasum shim when shasum is missing. It also checks the ghostty-next submodule.
#
# Every version comes from a repo file (see tool-versions.toml for the list).
# Each step checks first and changes nothing when the tool is already right,
# so a second run prints "no change".
#
# Usage: scripts/cmux-next/linux/setup-tools.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(git -C "$here" rev-parse --show-toplevel)"
pins="$here/tool-versions.toml"
cargo_bin="${CARGO_HOME:-$HOME/.cargo}/bin"
local_bin="$HOME/.local/bin"
changes=0

note() { printf 'setup-tools: %s\n' "$*"; }
fail() { printf 'setup-tools: error: %s\n' "$*" >&2; exit 1; }
changed() { changes=$((changes + 1)); note "$*"; }

# toml_get FILE DOTTED.KEY prints a scalar, or a list one item per line.
toml_get() {
  python3 -I - "$1" "$2" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    value = tomllib.load(f)
for part in sys.argv[2].split("."):
    value = value[part]
print("\n".join(map(str, value)) if isinstance(value, list) else value)
PY
}

as_root() {
  if [[ "$(id -u)" == 0 ]]; then "$@"; return; fi
  sudo -n true 2>/dev/null || fail "'$*' needs root and sudo asks for a password; run it once by hand"
  sudo -n "$@"
}

# sha256_of FILE prints the hex digest.
sha256_of() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi
}

workdir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-setup-tools.XXXXXX")"
trap 'rm -rf "$workdir"' EXIT

[[ "$(uname -s)" == Linux ]] || fail "this script sets up the Linux VM only"
case "$(uname -m)" in
  x86_64) arch=x86_64 ;;
  aarch64 | arm64) arch=aarch64 ;;
  *) fail "no tool pins for $(uname -m)" ;;
esac
[[ -f "$pins" ]] || fail "missing $pins"

# shasum: tlc.sh checks its jar with `shasum -a 256`.
setup_shasum() {
  if command -v shasum >/dev/null; then return; fi
  command -v sha256sum >/dev/null || fail "neither shasum nor sha256sum is installed"
  mkdir -p "$local_bin"
  cat >"$local_bin/shasum" <<'SH'
#!/usr/bin/env bash
# shasum shim from scripts/cmux-next/linux/setup-tools.sh: maps -a N to shaNsum.
algo=1
if [[ "${1:-}" == -a ]]; then algo="$2"; shift 2; fi
exec "sha${algo}sum" "$@"
SH
  chmod 755 "$local_bin/shasum"
  changed "installed the shasum shim in $local_bin"
  command -v shasum >/dev/null || note "add $local_bin to PATH to use the shasum shim"
}

java_major() {
  command -v java >/dev/null || return 0
  java -version 2>&1 | sed -nE '1s/.*version "(1\.)?([0-9]+).*/\2/p'
}

setup_java() {
  local want min pkg have
  want="$(toml_get "$pins" java.openjdk)"
  min="$(sed -nE 's/.*Needs Java ([0-9]+) or later.*/\1/p' "$root/plans/cmux-next/formal/tlc.sh" | head -n 1)"
  [[ -n "$min" ]] || fail "tlc.sh no longer says which Java it needs ('Needs Java N or later')"
  ((want >= min)) || fail "tool-versions.toml pins OpenJDK $want, but tlc.sh needs Java $min or later"
  pkg="openjdk-$want-jre-headless"
  if [[ "$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || true)" != "install ok installed" ]]; then
    as_root apt-get update -qq
    as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$pkg"
    changed "installed $pkg"
  fi
  have="$(java_major)"
  [[ -n "$have" ]] || fail "$pkg is installed but java is not on PATH"
  ((have >= min)) || fail "java on PATH is $have; tlc.sh needs $min or later (check update-alternatives --config java)"
}

# ensure_toolchain CHANNEL PROFILE COMPONENT... installs what is missing.
# `rustup component list --installed` names a component with its target
# triple (clippy-x86_64-unknown-linux-gnu) or without (rust-src), and drops
# a -preview suffix (llvm-tools-preview lists as llvm-tools-<triple>).
ensure_toolchain() {
  local channel="$1" profile="$2" component toolchains installed missing=() flags=()
  shift 2
  # Captured, not piped: grep -q's early exit would fail rustup under pipefail.
  toolchains="$(rustup toolchain list)"
  if [[ $'\n'"$toolchains" != *$'\n'"$channel-"* ]]; then
    for component in "$@"; do flags+=(--component "$component"); done
    rustup toolchain install "$channel" --profile "$profile" --no-self-update "${flags[@]}"
    changed "installed Rust $channel"
    return
  fi
  installed="$(rustup component list --toolchain "$channel" --installed)"
  for component in "$@"; do
    grep -Eq "^${component%-preview}(-preview)?(-$arch-unknown-linux-gnu)?\$" <<<"$installed" || missing+=("$component")
  done
  if ((${#missing[@]})); then
    rustup component add --toolchain "$channel" "${missing[@]}"
    changed "added ${missing[*]} to Rust $channel"
  fi
}

stable=""
setup_rust() {
  local toolchain="$root/cmux-tui/rust-toolchain.toml" nightly
  command -v rustup >/dev/null || fail "rustup is not installed (https://rustup.rs)"
  stable="$(toml_get "$toolchain" toolchain.channel)"
  # shellcheck disable=SC2046 # one component per line
  ensure_toolchain "$stable" "$(toml_get "$toolchain" toolchain.profile)" $(toml_get "$toolchain" toolchain.components)
  nightly="$(toml_get "$pins" nightly.channel)"
  [[ "$nightly" =~ ^nightly-[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || fail "nightly.channel must be a dated nightly, not '$nightly'"
  # shellcheck disable=SC2046
  ensure_toolchain "$nightly" "$(toml_get "$pins" nightly.profile)" $(toml_get "$pins" nightly.components)
}

# cargo-nextest: the pinned release binary that the Rust CI gate uses.
setup_nextest() {
  local gate="$root/scripts/ci/cmux-tui-rust-check.sh" version asset sha have archive
  version="$(sed -nE 's/^nextest_version=([0-9.]+)$/\1/p' "$gate")"
  read -r asset sha < <(sed -nE "s/^ *Linux-$arch\) asset=([^ ]+) sha=([0-9a-f]{64}) ;;.*/\1 \2/p" "$gate") || true
  [[ -n "$version" ]] || fail "no nextest_version= line in $gate"
  [[ -n "${sha:-}" ]] || fail "$gate pins no cargo-nextest for Linux-$arch"
  have="$(cargo nextest --version 2>/dev/null | head -n 1 || true)"
  [[ "$have" == "cargo-nextest $version "* ]] && return
  archive="$workdir/cargo-nextest.tar.gz"
  curl --fail --silent --show-error --location --retry 3 --connect-timeout 10 --max-time 300 --output "$archive" \
    "https://github.com/nextest-rs/nextest/releases/download/cargo-nextest-$version/cargo-nextest-$version-$asset.tar.gz"
  [[ "$(sha256_of "$archive")" == "$sha" ]] || fail "cargo-nextest $version archive sha256 is not the pinned $sha"
  tar -xzf "$archive" -C "$workdir" cargo-nextest
  mkdir -p "$cargo_bin"
  install -m 755 "$workdir/cargo-nextest" "$cargo_bin/cargo-nextest"
  changed "installed cargo-nextest $version (was: ${have:-none})"
}

# cargo-mutants, cargo-fuzz: cargo install --locked at the pinned version.
setup_cargo_installs() {
  local name version have
  while IFS='=' read -r name version; do
    have="$(cargo "${name#cargo-}" --version 2>/dev/null | head -n 1 || true)"
    [[ "$have" == "$name $version" || "$have" == "$name $version "* ]] && continue
    # From $HOME, so no repo rust-toolchain.toml picks the compiler.
    (cd "$HOME" && nice -n 10 cargo "+$stable" install --quiet --locked --force "$name@$version")
    changed "installed $name $version (was: ${have:-none})"
  done < <(python3 -I - "$pins" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    for name, version in tomllib.load(f)["cargo-install"].items():
        print(f"{name}={version}")
PY
)
}

# ghostty-next: initialize it when missing; its recorded commit pins zig.
zig_want=""
check_ghostty_next() {
  local status gitlink
  status="$(git -C "$root" submodule status ghostty-next)"
  gitlink="$(git -C "$root" ls-files --stage ghostty-next | awk '{print $2}')"
  [[ -n "$gitlink" ]] || fail "ghostty-next is not a submodule in this checkout"
  case "${status:0:1}" in
    -)
      git -C "$root" submodule update --init ghostty-next
      changed "initialized ghostty-next at ${gitlink:0:12}"
      ;;
    U) fail "ghostty-next has a merge conflict: $status" ;;
    +) note "warning: ghostty-next is checked out at another commit than ${gitlink:0:12}: $status" ;;
  esac
  if ! git -C "$root/ghostty-next" cat-file -e "$gitlink^{commit}" 2>/dev/null; then
    git -C "$root/ghostty-next" fetch -q origin "$gitlink" \
      || fail "ghostty-next does not have ${gitlink:0:12}; run git submodule update ghostty-next"
  fi
  zig_want="$(git -C "$root/ghostty-next" show "$gitlink:build.zig.zon" \
    | sed -nE 's/^ *\.minimum_zig_version *= *"([^"]+)".*/\1/p')"
  [[ -n "$zig_want" ]] || fail "ghostty-next build.zig.zon at ${gitlink:0:12} has no minimum_zig_version"
}

# zig_pin VERSION TARGET prints the tarball sha256 that tool-versions.toml pins.
zig_pin() {
  python3 -I - "$pins" "$1" "$2" <<'PY'
import sys, tomllib
with open(sys.argv[1], "rb") as f:
    print(tomllib.load(f).get("zig", {}).get(sys.argv[2], {}).get(sys.argv[3], ""))
PY
}

setup_zig() {
  local have name dest sum
  have="$(zig version 2>/dev/null || true)"
  [[ "$have" == "$zig_want" ]] && return
  name="zig-$arch-linux-$zig_want"
  dest="/opt/$name"
  if [[ "$("$dest/zig" version 2>/dev/null || true)" != "$zig_want" ]]; then
    sum="$(zig_pin "$zig_want" "$arch-linux")"
    [[ "$sum" =~ ^[0-9a-f]{64}$ ]] \
      || fail "tool-versions.toml pins no sha256 for zig $zig_want $arch-linux (add it under [zig.\"$zig_want\"])"
    curl --fail --silent --show-error --location --retry 3 --max-time 600 --output "$workdir/zig.tar.xz" \
      "https://ziglang.org/download/$zig_want/$name.tar.xz"
    [[ "$(sha256_of "$workdir/zig.tar.xz")" == "$sum" ]] || fail "zig $zig_want tarball sha256 is not the pinned $sum"
    tar -xJf "$workdir/zig.tar.xz" -C "$workdir"
    as_root rm -rf "$dest"
    as_root mv "$workdir/$name" "$dest"
  fi
  as_root ln -sfn "$dest/zig" /usr/local/bin/zig
  hash -r
  [[ "$(zig version)" == "$zig_want" ]] || fail "zig on PATH is $(zig version), not $zig_want (/usr/local/bin is not first?)"
  changed "installed zig $zig_want (was: ${have:-none})"
}

setup_shasum
setup_java
setup_rust
setup_nextest
setup_cargo_installs
check_ghostty_next
setup_zig

note "java $(java_major), rust $stable + $(toml_get "$pins" nightly.channel), $(cargo nextest --version | head -n 1),"
note "$(cargo mutants --version), $(cargo fuzz --version), zig $(zig version)"
if ((changes)); then note "$changes change(s)"; else note "no change"; fi
