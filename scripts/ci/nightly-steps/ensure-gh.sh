#!/usr/bin/env bash
# nightly.yml: this job's steps call gh. Nightlies run on our own Mac minis, which have it from Homebrew
# (/opt/homebrew/bin); a mini that lost it gets it back from Homebrew. A Linux runner (a job that still
# waits for glaeda's exclusive class on hosted Ubuntu) installs it from the distro, else from
# cli.github.com's apt repo. Fail loudly if none works.
set -uo pipefail
command -v gh >/dev/null && exit 0
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
