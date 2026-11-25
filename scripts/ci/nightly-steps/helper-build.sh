#!/usr/bin/env bash
# nightly.yml build-nightly-ghostty-cli-helper: "Build Ghostty CLI helper". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
echo "Ghostty CLI helper cache: ${HELPER_CACHE_HIT:-false}" | tee -a "$GITHUB_STEP_SUMMARY"
mkdir -p nightly-helper
# A helper build that misses every cache has Zig fetch Ghostty's packages itself, and Zig's own HTTPS client
# failed on the macOS 27 nightly Mac ("unable to connect to server: TlsInitializationFailed" for glslang,
# nightly-next run 45594076083, 2026-11-25) when its Zig package cache had missed too. Seed the cache from our
# mirror with curl first (scripts/ci/seed-zig-package-archives.sh, as zig-fetch-all.sh does for the source
# archive): Zig then unpacks each package from p/<hash>.tar.gz with no network, and checks its hash. Best effort:
# a package the seed cannot place is left for Zig, as before.
if [[ "${HELPER_CACHE_HIT:-false}" != true && "${CMUX_ZIG_SEED:-1}" != 0 ]]; then
  zig_cache="${ZIG_GLOBAL_CACHE_DIR:-}"
  if [[ -z "$zig_cache" ]]; then
    zig_cache="$("${CMUX_ZIG:-zig}" env 2>/dev/null | sed -n 's/.*global_cache_dir"\{0,1\} *[:=] *"\([^"]*\)".*/\1/p' | head -1)" || zig_cache=""
  fi
  if [[ -n "$zig_cache" ]]; then
    mkdir -p "$zig_cache/p" "$zig_cache/tmp"
    bash scripts/ci/seed-zig-package-archives.sh "$zig_cache" ghostty || echo "::warning title=Ghostty CLI helper::seeding Zig's package cache from the mirror failed; Zig fetches what is missing"
  fi
fi
# A package the seed could not place is fetched by Zig itself, once, with no retry: one TLS or connection failure
# ended the whole nightly (run 45594076083). Retry the build, bounded with backoff, only when its output names a
# network failure in Zig's fetch; Zig keeps every package it already unpacked, so a retry fetches only the rest.
# A compile error, or anything else, fails at once as before.
helper_attempts="${CMUX_HELPER_FETCH_ATTEMPTS:-3}"
helper_delay="${CMUX_HELPER_FETCH_RETRY_DELAY:-15}"
helper_net_re='TlsInitializationFailed|unable to connect to server|ConnectionRefused|ConnectionResetByPeer|ConnectionTimedOut|NetworkUnreachable|TemporaryNameServerFailure|NameServerFailure|UnknownHostName|HttpConnectionClosing|EndOfStream|unable to (download|fetch)|bad HTTP response code'
if [[ "$NIGHTLY_COMPILE_ARCHS" == "arm64" ]]; then
  helper_args=(--target aarch64-macos --output nightly-helper/ghostty)
  helper_archs=(arm64)
else
  helper_args=(--universal --output nightly-helper/ghostty)
  helper_archs=(arm64 x86_64)
fi
helper_log="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/helper-build.XXXXXX")"
attempt=1
while :; do
  status=0
  ./scripts/build-ghostty-cli-helper.sh "${helper_args[@]}" 2>&1 | tee "$helper_log" || status=$?
  (( status == 0 )) && break
  if (( attempt >= helper_attempts )) || ! grep -Eq "$helper_net_re" "$helper_log"; then
    exit "$status"
  fi
  wait_s=$((helper_delay * attempt * attempt))
  echo "::warning title=Ghostty CLI helper::attempt $attempt of $helper_attempts failed fetching a Zig package ($(grep -Eo "$helper_net_re" "$helper_log" | head -1)); retrying in ${wait_s}s"
  sleep "$wait_s"
  attempt=$((attempt + 1))
done
rm -f "$helper_log"
lipo nightly-helper/ghostty -verify_arch "${helper_archs[@]}"
# The provenance line resolve-nightly-ghostty-cli-helper reads later.
echo "ghostty-cli-helper-build=$(git rev-parse HEAD)"
