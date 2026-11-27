#!/usr/bin/env bash
# nightly.yml: this job's steps call gh. A gh already on PATH is kept. Otherwise the job takes the pinned
# gh release from github.com/cli/cli, checked against its sha256 and unpacked into $RUNNER_TEMP: no
# Homebrew, apt or sudo, so a runner that lost gh does not wait on a package manager or drift to whatever
# version it serves. Only when that fails does the old route run: Homebrew on a Mac (/opt/homebrew/bin), the
# distro or cli.github.com's apt repo on Linux (a job that still waits for glaeda's exclusive class on hosted
# Ubuntu). Fail loudly if none works.
set -uo pipefail
command -v gh >/dev/null && exit 0

# The pin: gh v2.103.3 (2026-10-26), sha256 from its gh_2.103.3_checksums.txt.
GH_PIN_VERSION=2.103.3
file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
pinned_gh() {
  local asset sum
  case "$(uname -s)/$(uname -m)" in
    Darwin/arm64) asset="gh_${GH_PIN_VERSION}_macOS_arm64.zip" sum=d700207eae9ae98fe2b89535c2c087c07823d4628c56364695a5a07ef311c062 ;;
    Darwin/x86_64) asset="gh_${GH_PIN_VERSION}_macOS_amd64.zip" sum=a2f86418f4350ae6e9ec60d5000bdf7665728436946a97fc27fe50e6ae752682 ;;
    Linux/x86_64) asset="gh_${GH_PIN_VERSION}_linux_amd64.tar.gz" sum=4c806978ffce1cec70853302a56d70ac6da4f19bae7adca4e1a8ab00633dd91d ;;
    Linux/aarch64 | Linux/arm64) asset="gh_${GH_PIN_VERSION}_linux_arm64.tar.gz" sum=ee32df2323c8847f5fac6cb6b4b69ca75828e9329a8f22f677021f7b3306ce63 ;;
    *) return 1 ;;
  esac
  command -v curl >/dev/null 2>&1 || return 1
  # GH_PIN_URL and GH_PIN_SHA256 exist for the tests (tests/test_nightly_owned_minis_only.py).
  local url="${GH_PIN_URL:-https://github.com/cli/cli/releases/download/v${GH_PIN_VERSION}/$asset}"
  sum="${GH_PIN_SHA256:-$sum}"
  local dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/pinned-gh-$GH_PIN_VERSION"
  rm -rf "$dir" && mkdir -p "$dir/unpacked" "$dir/bin" || return 1
  curl -fsSL --connect-timeout 10 --max-time 120 --retry 3 --retry-all-errors -o "$dir/$asset" "$url" || {
    echo "::warning title=Pinned gh::could not download $url"; return 1; }
  local actual
  actual="$(file_sha256 "$dir/$asset")"
  if [ "$actual" != "$sum" ]; then
    echo "::warning title=Pinned gh::$asset has sha256 $actual, not the pinned $sum; not using it"
    rm -rf "$dir"
    return 1
  fi
  case "$asset" in
    *.zip) unzip -q "$dir/$asset" -d "$dir/unpacked" ;;
    *) tar -xzf "$dir/$asset" -C "$dir/unpacked" ;;
  esac || return 1
  local name="${asset%.zip}"
  mv "$dir/unpacked/${name%.tar.gz}/bin/gh" "$dir/bin/gh" && "$dir/bin/gh" --version >/dev/null 2>&1 || return 1
  [ -n "${GITHUB_PATH:-}" ] && echo "$dir/bin" >> "$GITHUB_PATH"
  echo "gh $GH_PIN_VERSION from the pinned, sha256-checked release ($asset) in $dir/bin"
}
pinned_gh && exit 0

if [ "$(uname -s)" = Darwin ]; then
  brew=$(command -v brew || echo /opt/homebrew/bin/brew)
  HOMEBREW_NO_AUTO_UPDATE=1 "$brew" install gh
  if ! command -v gh >/dev/null && [ -x /opt/homebrew/bin/gh ] && [ -n "${GITHUB_PATH:-}" ]; then
    echo /opt/homebrew/bin >> "$GITHUB_PATH"
    exit 0
  fi
else
  { sudo apt-get update -q && sudo apt-get install -y -q gh; } || {
    keyring=/etc/apt/keyrings/githubcli-archive-keyring.gpg
    sudo mkdir -p -m 755 /etc/apt/keyrings &&
      curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee "$keyring" >/dev/null &&
      sudo chmod go+r "$keyring" &&
      echo "deb [arch=$(dpkg --print-architecture) signed-by=$keyring] https://cli.github.com/packages stable main" |
      sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null &&
      sudo apt-get update -q && sudo apt-get install -y -q gh
  }
fi
command -v gh >/dev/null && exit 0
echo "::error title=No GitHub CLI::gh is not on this runner and could not be installed; this job's gh calls would fail"
exit 1
