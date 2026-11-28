#!/usr/bin/env bash
# Puts a gh that has `gh attestation` first on PATH, for a step that verifies an attestation.
#
# The cmux-fleet-linux pool VMs install gh from Ubuntu 24.04's apt (cmuxterm-hq
# build-fleet/swift-linux-builder/gha-runners/runner-startup.sh): gh 2.45, older than `gh attestation`
# (gh 2.49). On one of them, cmux-tui-artifacts' "Verify the publishing commit's attested manifest" failed
# 'unknown command "attestation" for "gh"' after the commit's manifest was prepared (run 44833264148
# attempt 3, job 136690901390, runner cmux-runner-pool-hy4c-0010), so cmux-tui/<sha>/manifest.json was never
# written and the nightly could not bundle that commit's client.
#
# Source it (`source scripts/ci/ensure-gh-attestation.sh`): a gh that already has the command is kept;
# otherwise the pinned release below is downloaded, checked against its SHA-256, unpacked under RUNNER_TEMP
# and put first on PATH for this step and, through GITHUB_PATH, for the job's later steps.

ensure_gh_attestation() {
  local version=2.105.0 arch sha dir tarball
  if gh attestation verify --help >/dev/null 2>&1; then
    return 0
  fi
  case "$(uname -m)" in
    x86_64 | amd64) arch=amd64 sha=79e7ab5db738c48777b696e374f8b428f0647debfb424f44d2f426370407fe2f ;;
    aarch64 | arm64) arch=arm64 sha=b1278c75107423d818f1937fd92cafc9e5e9b606631568f68d7fb816f5885a02 ;;
    *) echo "::error::gh has no attestation command and no pinned gh is listed for $(uname -s) $(uname -m)" >&2; return 1 ;;
  esac
  if [[ "$(uname -s)" != Linux ]]; then
    echo "::error::gh has no attestation command and no pinned gh is listed for $(uname -s) $(uname -m)" >&2
    return 1
  fi
  dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/gh-$version-$arch"
  if [[ ! -x "$dir/bin/gh" ]]; then
    tarball="$dir.tar.gz"
    curl -fsSL --retry 3 --connect-timeout 10 --max-time 120 -o "$tarball" \
      "https://github.com/cli/cli/releases/download/v$version/gh_${version}_linux_$arch.tar.gz" || return 1
    if ! echo "$sha  $tarball" | sha256sum -c --quiet -; then
      echo "::error::gh $version ($arch) did not match its pinned SHA-256" >&2
      rm -f "$tarball"
      return 1
    fi
    mkdir -p "$dir"
    tar -xzf "$tarball" -C "$dir" --strip-components=1 || return 1
    rm -f "$tarball"
  fi
  export PATH="$dir/bin:$PATH"
  if [[ -n "${GITHUB_PATH:-}" ]]; then
    echo "$dir/bin" >> "$GITHUB_PATH"
  fi
  echo "gh $(gh --version | head -1 | awk '{print $3}') from $dir: the runner's gh has no attestation command" >&2
  gh attestation verify --help >/dev/null 2>&1
}

ensure_gh_attestation
