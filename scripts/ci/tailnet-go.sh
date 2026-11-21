#!/usr/bin/env bash
# Job-private Go for libtailscale: the host's go
# with GOTOOLCHAIN=auto (Go 1.21 or later) when it has one, else the pinned
# release, checksummed, in the step's own .build. Go's module and build caches
# also stay in .build, and toolchain downloads go only through the default
# proxy with the checksum database on: nothing is installed on the host.
ensure_tailnet_go() {
  local root=${1:?checkout root}
  # GOFLAGS drops any host flags; -modcacherw keeps the modules Go fetches removable. Go writes
  # its module cache read-only, and the warm nightly builder's `git clean -ffdxq` then failed on
  # it ("failed to remove .build/go-path/pkg/mod/...: Permission denied", run 42940891027). Same
  # as cmux-tui-rust-check.sh's go_caches. A GOTOOLCHAIN=auto switch (host Go older than
  # libtailscale's) reads GOFLAGS too late and still writes golang.org/toolchain read-only, so
  # workflows that clean a kept clone run `chmod -R u+w .build/go-path` before `git clean`.
  export GOTOOLCHAIN=auto GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org GOFLAGS=-modcacherw
  export GOPATH="$root/.build/go-path" GOMODCACHE="$root/.build/go-path/pkg/mod" GOCACHE="$root/.build/go-cache"
  local os arch sum dir="$root/.build/go-1.27.1" tmp
  local installed=""
  if command -v go >/dev/null 2>&1; then installed="$(go version 2>/dev/null || true)"; fi
  if [[ ! "$installed" =~ go1\.(2[1-9]|[3-9][0-9])([.[:space:]]|$) ]]; then
    # Linux fleet builders cross-build the macOS acpmux (build-acpmux.sh) with no Go on the image.
    case "$(uname -s)-$(uname -m)" in
      Darwin-arm64) os=darwin arch=arm64; sum=ee215d57e0ec269c60cc9ceca68e6bda321ba9ee5afe24f4b0988703c2d87d12 ;;
      Darwin-x86_64) os=darwin arch=amd64; sum=8f8f52c6649542cf027bbc9b9c68d1ec042f9f34808a40413f0b8b3f66f3caa4 ;;
      Linux-x86_64) os=linux arch=amd64; sum=63d339f0da5ab53635a56f2490a7984dfe12dfcff22ad749f63edaf590168445 ;;
      Linux-aarch64|Linux-arm64) os=linux arch=arm64; sum=3450b45a3f9ee8568792736a5c5e70a1f2e9b36c35a8f74958c03e51d7d92bec ;;
      *) echo "error: no pinned Go for $(uname -s) $(uname -m); install Go 1.21 or later in the build job" >&2; return 3 ;;
    esac
    if [[ ! -x "$dir/go/bin/go" ]]; then
      # Extract beside the target and rename, so a cut-off extract never looks complete.
      tmp="$dir.partial"
      rm -rf "$dir" "$tmp" && mkdir -p "$tmp" || return 3
      curl -fsSL -o "$tmp/go.tgz" "https://go.dev/dl/go1.27.1.$os-$arch.tar.gz" || return 3
      if command -v shasum >/dev/null 2>&1; then
        echo "$sum  $tmp/go.tgz" | shasum -a 256 -c - || return 3
      else
        echo "$sum  $tmp/go.tgz" | sha256sum -c - || return 3
      fi
      tar -xzf "$tmp/go.tgz" -C "$tmp" && rm -f "$tmp/go.tgz" && mv "$tmp" "$dir" || return 3
    fi
    export PATH="$dir/go/bin:$PATH"
  fi
  # libtailscale's go.mod selects Go 1.27.1; GOTOOLCHAIN=auto switches to it inside that folder.
  go version || return 3
}
