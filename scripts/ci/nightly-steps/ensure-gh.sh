#!/usr/bin/env bash
# nightly.yml: a fleet Linux runner (a GCP JIT VM made before HQ#5804's startup
# script) may lack the GitHub CLI, and this job's steps call gh. Install it from
# the distro, else from cli.github.com's apt repo; fail loudly if neither works.
set -uo pipefail
command -v gh >/dev/null && exit 0
{ sudo apt-get update -q && sudo apt-get install -y -q gh; } || {
  keyring=/etc/apt/keyrings/githubcli-archive-keyring.gpg
  sudo mkdir -p -m 755 /etc/apt/keyrings &&
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo tee "$keyring" >/dev/null &&
    sudo chmod go+r "$keyring" &&
    echo "deb [arch=$(dpkg --print-architecture) signed-by=$keyring] https://cli.github.com/packages stable main" |
    sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null &&
    sudo apt-get update -q && sudo apt-get install -y -q gh
}
command -v gh >/dev/null && exit 0
echo "::error title=No GitHub CLI::gh is not on this runner and could not be installed; this job's gh calls would fail"
exit 1
