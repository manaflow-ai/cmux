#!/usr/bin/env bash
# Select bounded, worker-local Release build state after Select Xcode. One runner
# executes one job at a time; separate lanes/workspaces never prune each other.
# --host selects the lane's one per-host state instead, for a caller that holds
# the host's build lock (compile-dev-release.sh, host_build_lock.py).
set -euo pipefail

lane="${1:?Release cache lane required (release-compile or dev-daily-release)}"
configuration="${2:?Release configuration required}"
scope="${3:-}"
case "$lane:$configuration" in
  release-compile:Release|dev-daily-release:Release) ;;
  *) echo "unsupported Release cache lane/configuration: $lane:$configuration" >&2; exit 2 ;;
esac
case "$scope" in
  ""|--host) ;;
  *) echo "unsupported Release cache scope: $scope (want --host or nothing)" >&2; exit 2 ;;
esac

if [[ "${CMUX_NEXT_RUNNER:-}" != glaeda-* ]]; then
  printf '%s\n' "${RUNNER_TEMP:?}/cmux-next-$lane"
  exit 0
fi

# RUNNER_NAME isolates concurrent root/side workers on the same host. Xcode's
# build database also contains absolute source paths, so a workspace move is a
# new cache. Never share a fallback worker name or an unknown workspace. The
# host scope is shared by design: its caller's host lock keeps it to one build.
if [[ "$scope" == --host ]]; then
  worker_key=host
else
  worker_key="$(printf '%s\n' "${RUNNER_NAME:?}" "${GITHUB_WORKSPACE:?}" | shasum -a 256 | cut -c1-16)"
fi
xcode_version="$(xcodebuild -version)"
sdk_build="$(xcrun --sdk macosx --show-sdk-build-version)"
toolchain_key="$(printf '%s\n' "${DEVELOPER_DIR:?}" "$xcode_version" "$sdk_build" | shasum -a 256 | cut -c1-16)"
worker_root="${HOME:?}/Library/Caches/cmux-next-ci/$lane/$worker_key/$configuration"
derived_data="$worker_root/xcode-$toolchain_key"
mkdir -p "$worker_root"

# Keep just the selected toolchain for this worker/workspace/lane/configuration.
# The selected lane cannot be active in another job on this runner.
for previous in "$worker_root"/xcode-*; do
  [[ "$previous" != "$derived_data" && -d "$previous" && ! -L "$previous" ]] || continue
  echo "removing obsolete Release toolchain state: $previous" >&2
  rm -rf -- "$previous"
done

# Match the Debug scheme cache's 12 GiB bound; only this lane's output is reset.
if [[ -d "$derived_data" ]]; then
  size_kib="$(du -sk "$derived_data" | cut -f1)"
  if (( size_kib > 12 * 1024 * 1024 )); then
    echo "kept Release DerivedData over 12 GiB; building cold: $derived_data" >&2
    rm -rf -- "$derived_data"
  fi
fi
printf '%s\n' "$derived_data"
