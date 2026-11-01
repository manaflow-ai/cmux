#!/usr/bin/env bash
# The cmux dev tree (web/scripts/cmux-vm-image/dev-tree.ts): the public checkout, its Rust and
# Zig toolchains and warm caches. Runs as root; the work user's files are written as that user.
# Nothing here writes a credential, a token or a git identity.
#   dev-tree.sh clone REPO BRANCH REF DIR SUBMODULE...  blobless clone of BRANCH, checked out at REF
#                                                        (empty: the branch head), then the submodules
#   dev-tree.sh rust DIR URL SHA256 SIZE                 rustup-init (checked), the checkout's toolchain
#   dev-tree.sh zig DIR                                  the checkout's Zig and ghostty-next's Zig packages
#   dev-tree.sh build DIR COMMAND...                     the first build, in DIR/cmux-tui
#   dev-tree.sh update DIR REF SUBMODULE...              fetch, fast-forward to REF (empty: the branch head),
#                                                        then the submodules
#   dev-tree.sh sizes DIR                                bytes per part, then the root file system's used bytes
# The work user's scripts are single-quoted on purpose: as_user passes their arguments.
# shellcheck disable=SC2016
set -euo pipefail
U=cmux
H=/home/cmux

# The work user's shell with a clean environment: no root variable or credential reaches it.
as_user() {
  local script="$1"
  shift
  runuser -u "$U" -- env -i HOME="$H" USER="$U" LOGNAME="$U" LANG=C.UTF-8 GIT_TERMINAL_PROMPT=0 \
    PATH="$H/.cargo/bin:/usr/local/bin:/usr/bin:/bin" bash -euo pipefail -c "$script" dev-tree "$@"
}

cmd="$1"
shift
case "$cmd" in
  clone)
    as_user '
      git clone -q --filter=blob:none --single-branch --branch "$2" --no-checkout "$1" "$4"
      cd "$4"
      git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
      git checkout -q -B "$2" "${3:-origin/$2}"
      git branch -q --set-upstream-to="origin/$2"
      for m in "${@:5}"; do git submodule update -q --init --filter=blob:none -- "$m"; done
      git log -1 --format=%H' "$@"
    ;;
  rust)
    tmp="$(mktemp -d)"
    curl -fsSL --retry 3 -o "$tmp/rustup-init" "$2"
    printf '%s  %s\n' "$3" "$tmp/rustup-init" | sha256sum -c --quiet -
    test "$(stat -c %s "$tmp/rustup-init")" = "$4"
    chmod 0755 "$tmp/rustup-init" && chown -R "$U:$U" "$tmp"
    # rustup-init adds ~/.cargo/bin to the user's shell profiles. `rustup toolchain install` reads
    # cmux-tui/rust-toolchain.toml (channel, profile, components); the default makes cargo work elsewhere.
    as_user '
      "$1" -y -q --profile minimal --default-toolchain none
      cd "$2/cmux-tui"
      rustup toolchain install
      rustup default "$(rustup show active-toolchain | cut -d" " -f1)"
      cargo --version' "$tmp/rustup-init" "$1"
    rm -rf "$tmp"
    ;;
  zig)
    # install-zig-ci.sh installs the Zig version ghostty-next names, checked against the pinned
    # sha256, under /usr/local; the package fetch fills the work user's Zig cache.
    work="$(mktemp -d)"
    GHOSTTY_ZIG_SOURCE=ghostty-next RUNNER_TEMP="$work" "$1/scripts/install-zig-ci.sh" >/dev/null
    rm -rf "$work"
    as_user 'cd "$1" && scripts/ci/fetch-ghostty-zig-packages.sh ghostty-next >/dev/null && zig version' "$1"
    ;;
  build)
    as_user 'cd "$1/cmux-tui" && "${@:2}"' "$@"
    ;;
  update)
    as_user '
      cd "$1"
      git fetch -q origin
      target="$2"
      test -n "$target" || target="@{upstream}"
      git merge -q --ff-only "$target"
      for m in "${@:3}"; do git submodule update -q --init --filter=blob:none -- "$m"; done
      git log -1 --format=%H' "$@"
    ;;
  sizes)
    zig_root="$(dirname "$(readlink -f /usr/local/bin/zig 2>/dev/null || echo /nonexistent/zig)")"
    for p in "$1/.git" "$1" "$1/cmux-tui/target" "$H/.cargo" "$H/.rustup" "$H/.cache/zig" "$zig_root" /usr/lib/llvm-18; do
      printf '%s\t%s\n' "$p" "$(du -sb "$p" 2>/dev/null | cut -f1)"
    done
    printf 'root-used\t%s\n' "$(df -B1 --output=used / | tail -1 | tr -d ' ')"
    ;;
  *)
    echo "dev-tree.sh: unknown command $cmd" >&2
    exit 2
    ;;
esac
