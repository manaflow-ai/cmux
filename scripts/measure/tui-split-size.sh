#!/usr/bin/env bash
# CMUX-570: the bundled `cmux` with and without the terminal UI (the `tui`
# feature of cmux-tui), against the base, from one source tree and toolchain.
#
#   tui-split-size.sh BASE_SHA|none
#
# Builds, with the shipping release profile (cmux-tui/Cargo.toml):
#   base   BASE_SHA's cmux-tui (a worktree of it beside this checkout)
#   full   this checkout, default features (what every downloadable cmux-tui is)
#   slim   this checkout, --no-default-features (the app's bundled bin/cmux)
# strips each the way cli-size.sh does, checks the slim binary still answers
# --version and hands bare `cmux` off (no terminal UI installed: exit 2 and the
# install hint), and writes report.json to $FAST_CHECKS_OUT. Fleet only.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$root/scripts/cmux-next/lib/fleet-only.sh"
cmux_next_require_fleet tui-split-size.sh 'cargo build' 'CMUX-570 TUI split size'
base_sha="${1:?usage: tui-split-size.sh BASE_SHA}"
out="${FAST_CHECKS_OUT:-$root/artifacts/tui-split-size}"
mkdir -p "$out"
target_root="${CARGO_TARGET_DIR:-$root/cmux-tui/target}/tui-split-size"

strip_copy() {
  cp "$1" "$2"
  case "$(uname -s)" in
    Darwin) strip -x "$2" ;;
    Linux) strip --strip-unneeded "$2" ;;
    *) echo 'needs a Linux or macOS fleet worker' >&2; exit 2 ;;
  esac
}

build() { # name source-root extra-cargo-args...
  local name=$1 src=$2; shift 2
  echo "==> build $name ($src $*)"
  (cd "$src/cmux-tui" && CARGO_TARGET_DIR="$target_root/$(basename "$src")" \
    cargo build --locked --release -p cmux-tui --bin cmux-tui "$@" 2>&1 | tail -n 3)
  cp "$target_root/$(basename "$src")/release/cmux-tui" "$out/$name.unstripped"
  strip_copy "$target_root/$(basename "$src")/release/cmux-tui" "$out/$name"
}

[[ -e "$root/ghostty-next/build.zig" ]] || git -C "$root" submodule update --init --depth 1 ghostty-next

# The base tree (BASE_SHA `none` skips it: full is then the reference, since the
# default build compiles the same program as the base plus tui_handoff.rs).
variants=(full slim)
if [[ "$base_sha" != none ]]; then
  variants=(base full slim)
  base_dir="$root/.tui-split-base"
  if [[ ! -d "$base_dir" ]]; then
    git -C "$root" cat-file -e "$base_sha^{commit}" 2>/dev/null \
      || git -C "$root" fetch --quiet --depth=1 origin "$base_sha"
    git -C "$root" worktree add --quiet --detach "$base_dir" "$base_sha"
  fi
  trap 'git -C "$root" worktree remove --force "$base_dir" >/dev/null 2>&1 || true' EXIT
  if [[ "$(git -C "$root" rev-parse "HEAD:ghostty-next")" == "$(git -C "$root" rev-parse "$base_sha:ghostty-next")" ]]; then
    rmdir "$base_dir/ghostty-next" 2>/dev/null || true
    [[ -e "$base_dir/ghostty-next" ]] || ln -s "$root/ghostty-next" "$base_dir/ghostty-next"
  else
    git -C "$base_dir" submodule update --init --depth 1 ghostty-next
  fi
  build base "$base_dir"
fi
build full "$root"
build slim "$root" --no-default-features

python3 - "$out" "$base_sha" "${variants[@]}" <<'PY'
import hashlib, json, pathlib, subprocess, sys
out, base_sha, names = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3:]
mb = lambda n: round(n / 1e6, 2)
variants = {}
for name in names:
    data = (out / name).read_bytes()
    variants[name] = {"stripped_bytes": len(data), "stripped_mb": mb(len(data)),
                      "unstripped_bytes": (out / f"{name}.unstripped").stat().st_size,
                      "sha256": hashlib.sha256(data).hexdigest()}
ref = "base" if "base" in variants else "full"
report = {"kind": "cmux-tui-binary-stripped", "host": subprocess.check_output(["uname", "-sm"], text=True).strip(),
          "head_sha": subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip(),
          "base_sha": base_sha, "reference": ref, "variants": variants,
          "slim_minus_reference_mb": mb(variants["slim"]["stripped_bytes"] - variants[ref]["stripped_bytes"]),
          "full_minus_reference_mb": mb(variants["full"]["stripped_bytes"] - variants[ref]["stripped_bytes"])}
(out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
print(json.dumps(report, indent=2))
PY

# The slim binary still serves the CLI, and hands an interactive start off.
"$out/slim" --version > "$out/slim-version.txt"
set +e
HOME="$(mktemp -d)" CMUX_TUI_BIN='' "$out/slim" --session tui-split-probe </dev/null > "$out/slim-bare.txt" 2>&1
bare_exit=$?
set -e
echo "slim bare exit: $bare_exit"; cat "$out/slim-bare.txt"
if [[ "$bare_exit" != 2 ]] || ! grep -q 'cmux tui install' "$out/slim-bare.txt"; then
  echo "slim bare cmux did not hand off (exit $bare_exit)" >&2
  exit 1
fi

# The hand-off end to end on Linux: the slim binary runs a headless owner,
# `cmux tui install` downloads the published terminal UI (sha256-checked), and
# `cmux attach` from the slim binary runs it in a pty against that owner. The
# owner's client list must then hold a `tui` client, or the terminal UI must
# have refused a version skew with its message (also recorded).
if [[ "$(uname -s)" == Linux ]]; then
  probe="$(mktemp -d)"
  sock="$probe/s.sock"
  export CMUX_TUI_HOME="$probe/home"
  HOME="$probe" "$out/slim" --session tui-split-probe --socket "$sock" --headless \
    > "$probe/owner.log" 2>&1 &
  owner=$!
  for _ in $(seq 1 100); do [[ -S "$sock" ]] && break; sleep 0.2; done
  [[ -S "$sock" ]] || { cat "$probe/owner.log"; echo "owner socket never appeared" >&2; kill "$owner"; exit 1; }
  HOME="$probe" "$out/slim" tui install 2>&1 | tee "$out/tui-install.txt"
  HOME="$probe" "$out/slim" tui path | tee -a "$out/tui-install.txt"
  HOME="$probe" TERM=xterm-256color script -qfec \
    "timeout 15 '$out/slim' attach --socket '$sock'" /dev/null > "$out/tui-attach.raw" 2>&1 &
  viewer=$!
  sleep 8
  python3 - "$sock" > "$out/tui-clients.json" <<'PY'
import json, socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.settimeout(5)
s.sendall(b'{"id":1,"cmd":"list-clients"}\n')
buf = b""
while not buf.endswith(b"\n"):
    buf += s.recv(65536)
print(buf.decode())
PY
  kill "$viewer" 2>/dev/null || true; wait "$viewer" 2>/dev/null || true
  kill "$owner" 2>/dev/null || true; wait "$owner" 2>/dev/null || true
  cat "$out/tui-clients.json"
  if grep -q '"tui"' "$out/tui-clients.json"; then
    echo "handoff: the downloaded terminal UI attached to the slim owner"
  elif grep -a -q -E 'older than this cmux|too old for the cmux-tui server' "$out/tui-attach.raw"; then
    echo "handoff: the downloaded terminal UI refused a version skew:"
    grep -a -o -E '[^\r\n]*(older than this cmux|too old for the cmux-tui server)[^\r\n]*' "$out/tui-attach.raw" | head -n 2
  else
    echo "handoff: no tui client and no skew message" >&2
    tail -c 2000 "$out/tui-attach.raw" >&2
    exit 1
  fi
fi

