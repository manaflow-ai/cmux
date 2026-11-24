#!/usr/bin/env bash
# The Ubuntu 24.04 packages `playwright install --with-deps` installs, for the apt cache in R2
# (.github/actions/playwright-apt-cache restores it, cmux-next-fast-tier-seed.yml seeds it).
#
#   playwright-apt-deps.sh packages ENGINES        the package list, one per line
#   playwright-apt-deps.sh missing ENGINES         the ones dpkg does not have installed
#   playwright-apt-deps.sh seed ENGINES OUT_DIR    download every .deb a bare ubuntu:24.04 needs for them into OUT_DIR
#
# ENGINES is the action's `engines` input: engine names joined by `-` (`chromium`, `chromium-webkit`).
#
# The lists are Playwright 1.62.1's (playwright-core lib/coreBundle.js, "ubuntu24.04-x64": tools, chromium,
# webkit), with the system Chrome's own Depends added to chromium: scripts/ci/ensure-system-chrome.sh installs
# Chrome stable through `playwright install --with-deps chrome` in the jobs that restore this cache. A list that
# drifts from Playwright's costs speed, never correctness: the job's own apt-get still installs whatever is
# missing, from the mirror when the cache does not hold it.
set -euo pipefail

tools=(xvfb fonts-noto-color-emoji fonts-unifont libfontconfig1 libfreetype6 xfonts-cyrillic xfonts-scalable
  fonts-liberation fonts-ipafont-gothic fonts-wqy-zenhei fonts-tlwg-loma-otf fonts-freefont-ttf)
chromium=(libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 libcairo2 libcups2t64 libdbus-1-3
  libdrm2 libgbm1 libglib2.0-0t64 libnspr4 libnss3 libpango-1.0-0 libx11-6 libxcb1 libxcomposite1 libxdamage1
  libxext6 libxfixes3 libxkbcommon0 libxrandr2
  libcurl4t64 libgtk-3-0t64 libvulkan1 wget xdg-utils)
webkit=(gstreamer1.0-libav gstreamer1.0-plugins-bad gstreamer1.0-plugins-base gstreamer1.0-plugins-good libicu74
  libatomic1 libatk-bridge2.0-0t64 libatk1.0-0t64 libcairo-gobject2 libcairo2 libdbus-1-3 libdrm2 libenchant-2-2
  libepoxy0 libevent-2.1-7t64 libflite1 libfontconfig1 libfreetype6 libgbm1 libgdk-pixbuf-2.0-0 libgles2
  libglib2.0-0t64 libgstreamer-gl1.0-0 libgstreamer-plugins-bad1.0-0 libgstreamer-plugins-base1.0-0
  libgstreamer1.0-0 libgtk-4-1 libharfbuzz-icu0 libharfbuzz0b libhyphen0 libjpeg-turbo8 liblcms2-2
  libmanette-0.2-0 libopus0 libpango-1.0-0 libpangocairo-1.0-0 libpng16-16t64 libsecret-1-0 libvpx9
  libwayland-client0 libwayland-egl1 libwayland-server0 libwebp7 libwebpdemux2 libwoff1 libx11-6 libxkbcommon0
  libxml2 libxslt1.1 libx264-164 libavif16)

usage() { echo "usage: playwright-apt-deps.sh packages|missing ENGINES | seed ENGINES OUT_DIR" >&2; exit 2; }

packages() { # ENGINES
  local engine list=("${tools[@]}")
  [[ "$1" =~ ^[a-z]+(-[a-z]+)*$ ]] || { echo "playwright-apt-deps: bad engines: $1" >&2; exit 2; }
  for engine in ${1//-/ }; do
    case "$engine" in
      chromium) list+=("${chromium[@]}") ;;
      webkit) list+=("${webkit[@]}") ;;
      *) echo "playwright-apt-deps: no package list for engine $engine" >&2; exit 2 ;;
    esac
  done
  printf '%s\n' "${list[@]}" | sort -u
}

missing() { # ENGINES: every package whose dpkg state is not "installed" (absent, half-installed, removed)
  local pkg status
  while IFS= read -r pkg; do
    status="$(dpkg-query -W -f='${db:Status-Status}' "$pkg" 2>/dev/null || true)"
    [[ "$status" == installed ]] || echo "$pkg"
  done < <(packages "$1")
}

seed() { # ENGINES OUT_DIR: the closure over a bare ubuntu:24.04, a superset of what any runner image lacks
  local engines="$1" out="$2" pkgs
  command -v docker >/dev/null 2>&1 || { echo "::warning::playwright-apt-deps: no docker on this runner; nothing seeded"; return 1; }
  pkgs="$(packages "$engines" | tr '\n' ' ')"
  mkdir -p "$out"
  docker run --rm -e PKGS="$pkgs" -e OWNER="$(id -u):$(id -g)" -v "$out:/out" ubuntu:24.04 bash -euo pipefail -c '
    export DEBIAN_FRONTEND=noninteractive
    rm -f /etc/apt/apt.conf.d/docker-clean
    apt-get update -qq
    # shellcheck disable=SC2086
    apt-get install -y -qq --download-only --no-install-recommends $PKGS >/dev/null
    cp /var/cache/apt/archives/*.deb /out/
    chown -R "$OWNER" /out'
  echo "playwright-apt-deps: $(find "$out" -maxdepth 1 -name '*.deb' | wc -l) packages, $(du -sm "$out" | cut -f1) MB for $engines"
}

case "${1:-}" in
  packages) [[ $# == 2 ]] || usage; packages "$2" ;;
  missing) [[ $# == 2 ]] || usage; missing "$2" ;;
  seed) [[ $# == 3 ]] || usage; seed "$2" "$3" ;;
  *) usage ;;
esac
