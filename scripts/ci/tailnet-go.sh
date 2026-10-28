#!/usr/bin/env bash
# Job-private Go for libtailscale: the host's go
# with GOTOOLCHAIN=auto (Go 1.21 or later) when it has one, else the pinned
# release, checksummed, in the step's own .build. Go's module and build caches
# also stay in .build, and toolchain downloads go only through the default
# proxy with the checksum database on: nothing is installed on the host.
ensure_tailnet_go() {
  local root=${1:?checkout root}
  export GOTOOLCHAIN=auto GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org GOFLAGS=
  export GOPATH="$root/.build/go-path" GOMODCACHE="$root/.build/go-path/pkg/mod" GOCACHE="$root/.build/go-cache"
  local arch sum dir="$root/.build/go-1.27.1" tmp
  local installed=""
  if command -v go >/dev/null 2>&1; then installed="$(go version 2>/dev/null || true)"; fi
  if [[ ! "$installed" =~ go1\.(2[1-9]|[3-9][0-9])([.[:space:]]|$) ]]; then
    if [[ "$(uname -s)" != Darwin ]]; then
      echo "error: install Go 1.21 or later in the build job before building libtailscale" >&2
      return 3
    fi
    case "$(uname -m)" in
      arm64) arch=arm64; sum=ee215d57e0ec269c60cc9ceca68e6bda321ba9ee5afe24f4b0988703c2d87d12 ;;
      x86_64) arch=amd64; sum=8f8f52c6649542cf027bbc9b9c68d1ec042f9f34808a40413f0b8b3f66f3caa4 ;;
      *) echo "error: no pinned Go for $(uname -m)" >&2; return 3 ;;
    esac
    if [[ ! -x "$dir/go/bin/go" ]]; then
      # Extract beside the target and rename, so a cut-off extract never looks complete.
      tmp="$dir.partial"
      rm -rf "$dir" "$tmp" && mkdir -p "$tmp" || return 3
      curl -fsSL -o "$tmp/go.tgz" "https://go.dev/dl/go1.27.1.darwin-$arch.tar.gz" || return 3
      echo "$sum  $tmp/go.tgz" | shasum -a 256 -c - || return 3
      tar -xzf "$tmp/go.tgz" -C "$tmp" && rm -f "$tmp/go.tgz" && mv "$tmp" "$dir" || return 3
    fi
    export PATH="$dir/go/bin:$PATH"
  fi
  # libtailscale's go.mod selects Go 1.27.1; GOTOOLCHAIN=auto switches to it inside that folder.
  go version || return 3
}
