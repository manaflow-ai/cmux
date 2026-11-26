# shellcheck shell=bash
# Sourced by the Swift package lanes (package-test-lane.sh,
# run-swift-testing-suites.sh) and by the kept-DerivedData app scheme compile
# (scripts/cmux-next/check-cmux-scheme-compile.sh). Keeps a reused SwiftPM
# .build or Xcode DerivedData correct when a binary target's C headers change.
#
# Why: a fleet step-warm slot (hq build-fleet cmd/worker/step_warm.go), a
# GitHub runner's kept checkout or an nx-remote tree builds many commits in one
# .build. A binary target (CCmuxAppFFI, GhosttyNextKit, iroh-ffi) gives its headers to the build at a fixed path
# (.build/out/Products/<config>/include/... under Xcode 27). Its explicit
# precompiled module (.pcm) is keyed by the compile arguments, which do not
# change when a pin moves, so the build reuses the old .pcm against the new
# header: "ghostty.h has been modified since the module file ... was built",
# or, when the size happens to match, Swift sees the old declarations
# ("cannot find type CmuxFocusReply"). A fresh .build never fails this way.
#
# swiftpm_binary_module_guard PKGDIR [SCRATCH]
#   Resolves PKGDIR (so the binary artifacts in SCRATCH are the commit's; a network
#   fetch failure is tried again, swiftpm_resolve_package, and when every try fails
#   it returns 75, "fetch failed, no test ran": the caller decides), then
#   hashes every header, module map and API notes file the build can read from
#   a binary target: SCRATCH/artifacts and each *.xcframework of the checkout
#   that the package's or a local dependency's manifest names.
#   The digest (with the toolchain's version) is stored in
#   SCRATCH/.cmux-binary-module-inputs. When it differs, or a kept SCRATCH has
#   no digest yet, it removes every build output in SCRATCH before the build
#   (swiftpm_purge_build_outputs), so the package builds cold once per header
#   change. Dependency checkouts, downloaded artifacts and the resolution state
#   stay. Removing only the module caches is not enough: swiftbuild's build
#   database still lists the deleted dependency scans as done, and the next
#   build fails with "Failed to query serialized dependencies at
#   .../ExplicitPrecompiledModules/*.scan" (2026-10-18, aws-m4pro-2 slot-1,
#   step ec537be95de8581e393962bd).
#
# xcode_binary_module_guard DIR DERIVED_DATA XCODEBUILD_ARGS...
#   The same guard for an xcodebuild run in DIR (XCODEBUILD_ARGS name the
#   project or package scheme) into a kept DERIVED_DATA: resolves the packages
#   into DERIVED_DATA/SourcePackages, digests the same inputs (DIR's
#   Package.swift and its local dependencies; an Xcode project root without a
#   manifest counts every Packages/**/Package.swift) and, on a change, removes
#   every build output in DERIVED_DATA but SourcePackages
#   (clear-stale-scheme-build-state.sh). It resolves from the kept packages
#   first, without fetching (-skipPackageUpdates), and sets
#   xcode_binary_module_guard_offline=1 when that sufficed. The glaeda scheme job reused a .pcm of
#   the old CCmuxAppFFI header after the pin moved, and Swift saw the old
#   declarations: "cannot find type 'CmuxFocusReply'" on every push from
#   2026-10-18T06:50Z (cmux17, cmux18, cmux24, cmux-austin-mini-1), which the
#   stale-module retry does not match.
#
# swiftpm_purge_build_outputs SCRATCH
#   Removes every build output in SCRATCH (keeps checkouts, repositories,
#   artifacts and the resolution state). Also the backstop of the suite build.
#   It keeps app-ffi-linux too: CmuxNext's Linux libcmux_app_ffi.a and its
#   cargo state (scripts/ci/app_ffi_linux.py), which cargo keeps current and
#   the lane builds before any purge here.
#
# swiftpm_stale_module_failure LOG
#   Exit 0 when LOG has a stale explicit-module failure
#   (scripts/cmux-next/stale-pcm-retry-needed.sh).

swiftpm_binary_module_inputs_file=.cmux-binary-module-inputs

swiftpm__sha256() {
  if command -v shasum >/dev/null 2>&1; then shasum -a 256; else sha256sum; fi
}

# The manifests of PKGDIR and of its local (path) dependencies, one per line.
swiftpm__local_manifests() {
  local pkgdir="$1" scratch="$2"
  if [ -f "$pkgdir/Package.swift" ]; then
    echo "$pkgdir/Package.swift"
  elif [ -d "$pkgdir/Packages" ]; then
    # An Xcode project root (no manifest of its own): every package it can link.
    find "$pkgdir/Packages" \( -name .build -o -name '.build-*' \) -prune -o -name Package.swift -type f -print 2>/dev/null
  fi
  [ -f "$scratch/workspace-state.json" ] || return 0
  python3 -I -c '
import json, os, sys
try:
    state = json.load(open(sys.argv[1]))
except (OSError, ValueError):
    sys.exit(0)
for dep in state.get("object", {}).get("dependencies", []):
    ref = dep.get("packageRef", {})
    if ref.get("kind") == "fileSystem" and ref.get("location"):
        print(os.path.join(ref["location"], "Package.swift"))
' "$scratch/workspace-state.json" 2>/dev/null || true
}

# The digest of the binary-target headers PKGDIR's build reads (stdout): the
# downloaded artifacts in SCRATCH, and each xcframework of the checkout that
# PKGDIR's manifest or a local dependency's manifest names. An xcframework no
# manifest names stays out, so a lane that downloads GhosttyKit.xcframework for
# another package does not change this package's digest.
swiftpm_binary_module_digest() {
  local pkgdir="$1" scratch="$2" root roots=() dir manifests=() manifest
  root="$(git -C "$pkgdir" rev-parse --show-toplevel 2>/dev/null || pwd)"
  [ ! -d "$scratch/artifacts" ] || roots+=("$scratch/artifacts")
  while IFS= read -r manifest; do
    [ ! -f "$manifest" ] || manifests+=("$manifest")
  done < <(swiftpm__local_manifests "$pkgdir" "$scratch")
  while IFS= read -r -d '' dir; do
    if [ "${#manifests[@]}" -gt 0 ] && grep -Fqs -- "${dir##*/}" "${manifests[@]}"; then
      roots+=("$dir")
    fi
  done < <(find "$root" -maxdepth 1 -name '*.xcframework' -type d -print0 2>/dev/null;
    [ ! -d "$root/Packages" ] || find "$root/Packages" \( -name .build -o -name '.build-*' \) -prune -o \
      -name '*.xcframework' -type d -print0 2>/dev/null)
  {
    swift --version 2>&1 || true
    if [ "${#roots[@]}" -gt 0 ]; then
      find "${roots[@]}" -type f \( -name '*.h' -o -name '*.hpp' -o -name '*.modulemap' -o -name '*.apinotes' \) \
        -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 shasum -a 256 2>/dev/null \
        | sed "s#  $root/#  #" || true
    fi
  } | swiftpm__sha256 | cut -d' ' -f1
}

# A resolve's output (FILE) shows a network fetch failure: git, curl or a release download lost the connection
# or got a server error (5xx), not the commit's own manifest, pins, a 404 or a checksum mismatch (those are the
# commit's defects and stay a red). Step 9bc9eadb (cmux14, 2026-10-28): "RPC failed; curl 18 Transferred a
# partial file". GitHub's 403 and 429 are its refusal of the worker's address (a rate limit or block), not of the
# commit: step 0787f5e4 (ultra2, 2026-11-26) got 403 on every github.com fetch, public swift-crypto and release
# zips alike, and its kit suite went red (exit 1) with no test run; it is a fetch failure (75, rerun elsewhere).
swiftpm__network_fetch_failure() {
  grep -qE 'curl [0-9]+|RPC failed|Transferred a partial file|expected flush after|Could not resolve host|Failed to connect to|Couldn.{1,3}t connect to server|Connection (reset|refused|timed out)|Operation timed out|SSL_ERROR|gnutls_handshake|unexpected disconnect|early EOF|remote end hung up unexpectedly|Empty reply from server|The requested URL returned error: (5[0-9][0-9]|403|429)|badResponseStatusCode[(](5[0-9][0-9]|403|429)|The network connection was lost|The request timed out' "$1"
}

# `swift package resolve` of PKGDIR (ARGS go after --package-path), its output in the step log. A failure on
# a network fetch is tried again after each delay of CMUX_SWIFTPM_RESOLVE_RETRY_DELAYS (seconds, default
# "5 20": three tries). Returns 0 when it resolved, 75 when every try failed on the network (no test can run),
# 1 when it failed for another reason (the build reports why).
# Seed SwiftPM's shared artifact cache for PKGDIR with curl, each artifact checked against its manifest
# checksum (scripts/ci/swiftpm_prefetch_binary_artifacts.py), so the resolve after it downloads nothing.
# On the fleet workers SwiftPM's own NSURLSession download of a binary artifact traps (exit 133): macOS's
# single sign-on check (AppSSO) calls xpc_connection_set_target_uid, an API misuse in the worker's process
# context (2026-11-20, cmux-austin-mini-0; every CmuxNext swift test on a new FFI pin until the worker had it
# cached). Runs on macOS, and on Linux when CMUX_SWIFTPM_ARTIFACT_STORE names a store. Never fails the step:
# what it does not seed, SwiftPM fetches as before. CMUX_SWIFTPM_ARTIFACT_CACHE overrides the cache (tests).
swiftpm_seed_binary_artifacts() {
  local pkgdir="$1" seeder args=()
  shift
  seeder="$(dirname "${BASH_SOURCE[0]}")/swiftpm_prefetch_binary_artifacts.py"
  [ -f "$seeder" ] || return 0
  [ "${CMUX_SWIFTPM_SEED_ARTIFACTS:-1}" != 0 ] || return 0
  if [ -n "${CMUX_SWIFTPM_ARTIFACT_STORE:-}" ]; then
    args+=(--store "$CMUX_SWIFTPM_ARTIFACT_STORE")
  elif [ "$(uname -s)" != Darwin ]; then
    return 0
  fi
  if [ -n "${CMUX_SWIFTPM_ARTIFACT_CACHE:-}" ]; then
    args+=(--cache "$CMUX_SWIFTPM_ARTIFACT_CACHE")
  else
    # A resolve with its own --cache-path reads that cache.
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --cache-path) [ "$#" -lt 2 ] || args+=(--cache "$2/artifacts"); shift ;;
        --cache-path=*) args+=(--cache "${1#--cache-path=}/artifacts") ;;
      esac
      shift
    done
  fi
  python3 -I "$seeder" --package-path "$pkgdir" ${args[@]+"${args[@]}"} < /dev/null || true
}

# GitHub refused the fetch (403 or 429): its limit on anonymous git requests
# per address, which every fleet Mac behind the office's one address shares.
swiftpm__github_refused() {
  grep -qE 'The requested URL returned error: (403|429)|badResponseStatusCode[(](403|429)' "$1"
}

# github_git_auth_env: when CMUX_GITHUB_GIT_TOKEN holds a token (the job's
# github.token), give every git request to https://github.com/ in this shell
# and its children (xcodebuild's package fetches, swift package resolve) that
# token, through GIT_CONFIG_COUNT in the environment, never in a config file.
# Why: anonymous fetches count against GitHub's per-address limit, and all
# office Macs share one address; on 2026-11-26 00:00-08:00Z GitHub refused them
# with 403 (sentry-cocoa, Sparkle, swift-atomics) and about 430 Release compiles
# failed, while AWS and Blacksmith Macs (their own addresses) passed. A token's
# requests count against its own limit. The token is masked, the variable that
# held it unset; a config the caller already passed through GIT_CONFIG_COUNT
# is kept (the header is added after it).
github_git_auth_env() {
  local token="${CMUX_GITHUB_GIT_TOKEN:-}" auth n
  [ -n "$token" ] || return 0
  unset CMUX_GITHUB_GIT_TOKEN
  auth="$(printf 'x-access-token:%s' "$token" | base64 | tr -d '\n')"
  [ "${GITHUB_ACTIONS:-}" != true ] || echo "::add-mask::$auth"
  n="${GIT_CONFIG_COUNT:-0}"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  export "GIT_CONFIG_KEY_$n=http.https://github.com/.extraheader"
  export "GIT_CONFIG_VALUE_$n=AUTHORIZATION: basic $auth"
  export GIT_CONFIG_COUNT=$((n + 1))
}

# shellcheck source=scripts/ci/github-egress-direct.sh
source "$(dirname "${BASH_SOURCE[0]}")/github-egress-direct.sh"
# shellcheck source-path=SCRIPTDIR source=lib/swiftpm-stale-artifact.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/swiftpm-stale-artifact.sh"

swiftpm_resolve_package() {
  local pkgdir="$1" log delays tries try=1 delay code
  shift
  github_git_auth_env
  github_egress_probe
  swiftpm_seed_binary_artifacts "$pkgdir" "$@"
  read -r -a delays <<< "${CMUX_SWIFTPM_RESOLVE_RETRY_DELAYS-5 20}"
  tries=$((${#delays[@]} + 1))
  log="$(mktemp)"
  while :; do
    code=0
    swift package resolve --package-path "$pkgdir" "$@" < /dev/null >"$log" 2>&1 || code=$?
    if [ "$code" -eq 0 ]; then
      rm -f "$log"
      return 0
    fi
    echo "ci-phase swift package resolve failed in $pkgdir (try $try of $tries, exit $code); its last lines:"
    tail -n 20 "$log" | sed 's/^/  | /' || true
    # A dead or half-dead github.com proxy: once more at once, direct (github-egress-direct.sh).
    if github_egress_retry_direct "$log"; then
      continue
    fi
    if ! swiftpm__network_fetch_failure "$log" && ! swiftpm__github_refused "$log"; then
      rm -f "$log"
      return 1
    fi
    if [ "$try" -ge "$tries" ]; then
      rm -f "$log"
      return 75
    fi
    delay="${delays[$((try - 1))]}"
    echo "ci-phase the resolve failed on a network fetch; trying again in ${delay}s"
    sleep "$delay"
    try=$((try + 1))
  done
}

swiftpm_binary_module_guard() {
  local pkgdir="$1" scratch="${2:-$1/.build}" stamp digest previous="" resolve_args=() resolved=0
  [ "$scratch" = "$pkgdir/.build" ] || resolve_args=(--scratch-path "$scratch")
  stamp="$scratch/$swiftpm_binary_module_inputs_file"
  # Resolution fetches and unpacks the commit's binary artifacts. When it fails
  # (the build reports why), the artifacts may still be the old commit's, so the
  # digest proves nothing: drop the caches and the stamp, and the next step
  # starts from a digest of its own. A network fetch failure is tried again; when
  # every try fails, no test can run for PKGDIR: the guard keeps the outputs and
  # the stamp (nothing builds on them now) and returns 75 (no verdict)
  # and the caller decides (a lane of several packages records it for this one
  # package and goes on; a step of one package ends with 75, never 1).
  swiftpm_resolve_package "$pkgdir" ${resolve_args[@]+"${resolve_args[@]}"} || resolved=$?
  if [ "$resolved" -eq 75 ]; then
    # No test runs on unresolved packages, so the outputs and the digest stay:
    # the next resolve that succeeds purges only when the headers changed
    # (xcode_binary_module_guard keeps them the same way).
    echo "ci-phase fetch failed, no test ran: swift package resolve in $pkgdir failed on a network fetch on every try; kept the build outputs in $scratch (infrastructure, no verdict: 75; rerun the step)"
    return 75
  fi
  if [ "$resolved" -ne 0 ]; then
    digest=""
  else
    digest="$(swiftpm_binary_module_digest "$pkgdir" "$scratch")"
  fi
  [ ! -f "$stamp" ] || previous="$(cat "$stamp")"
  if [ -n "$digest" ] && [ "$digest" = "$previous" ]; then
    return 0
  fi
  # Written only after the outputs are gone: a step stopped in between purges again.
  local had_outputs=0 entry
  for entry in "$scratch"/out "$scratch"/*-apple-* "$scratch"/debug "$scratch"/release; do
    [ ! -e "$entry" ] || had_outputs=1
  done
  swiftpm_purge_build_outputs "$scratch"
  mkdir -p "$scratch"
  if [ -z "$digest" ]; then
    rm -f "$stamp"
    echo "ci-phase swift package resolve failed in $pkgdir: removed the build outputs in $scratch"
    return 0
  fi
  printf '%s\n' "$digest" > "$stamp"
  if [ -n "$previous" ]; then
    echo "ci-phase binary-target headers changed in $pkgdir since its last build: removed the build outputs in $scratch (a cold build of this package)"
  elif [ "$had_outputs" -eq 1 ]; then
    echo "ci-phase $scratch had build outputs but no binary-target header digest: removed them (a cold build of this package)"
  fi
}

xcode_binary_module_guard() {
  local root="$1" derived="$2" scratch="$2/SourcePackages" stamp digest previous="" resolve_log entry had_outputs=0
  local resolved=0 delays tries try=1 cleared=0
  shift 2
  stamp="$derived/$swiftpm_binary_module_inputs_file"
  resolve_log="$(mktemp)"
  xcode_binary_module_guard_offline=0
  github_git_auth_env
  github_egress_probe
  # Kept packages first, with no fetch: a plain resolve asks github.com for
  # updates of every cached package repository, anonymously, from the fleet's
  # shared address. On 2026-11-26 00:00-08:00Z GitHub answered those with 403
  # and about 430 Release compiles failed in 1-2 min, each one also emptying
  # its kept DerivedData below (the next build on that host cold, past the
  # job's 60 min). -skipPackageUpdates resolves the pins from the kept
  # SourcePackages when they hold them (compile-app-host-test-product.sh
  # resolves its kept packages the same way); a pin they lack, or no kept
  # packages, fails it and the resolve below fetches as before. The caller
  # passes -skipPackageUpdates to its build too when this succeeds
  # (xcode_binary_module_guard_offline=1), so the build fetches nothing either.
  if [ "${CMUX_XCODE_RESOLVE_OFFLINE_FIRST:-1}" != 0 ] && [ -d "$scratch/repositories" ] \
      && (cd "$root" && xcodebuild "$@" -derivedDataPath "$derived" -skipPackageUpdates \
        -resolvePackageDependencies < /dev/null >"$resolve_log" 2>&1); then
    xcode_binary_module_guard_offline=1
    echo "ci-phase resolved the packages from the kept SourcePackages (no fetch)"
  else
    # A fetch that failed on the network or that GitHub refused (403/429) is
    # tried again after each delay of CMUX_SWIFTPM_RESOLVE_RETRY_DELAYS, as
    # swiftpm_resolve_package does.
    read -r -a delays <<< "${CMUX_SWIFTPM_RESOLVE_RETRY_DELAYS-5 20}"
    tries=$((${#delays[@]} + 1))
    while :; do
      resolved=0
      (cd "$root" && xcodebuild "$@" -derivedDataPath "$derived" \
        -resolvePackageDependencies < /dev/null >"$resolve_log" 2>&1) || resolved=1
      [ "$resolved" -ne 0 ] || break
      if github_egress_retry_direct "$resolve_log"; then
        continue
      fi
      # A half-written entry in the shared SwiftPM artifact cache ("already exists in file system")
      # fails every resolve on this host until it is removed: remove the ones named, once.
      if [ "$cleared" -eq 0 ] && swiftpm_clear_stale_artifacts "$resolve_log"; then
        cleared=1
        continue
      fi
      if ! swiftpm__network_fetch_failure "$resolve_log" && ! swiftpm__github_refused "$resolve_log"; then
        break
      fi
      if [ "$try" -ge "$tries" ]; then
        resolved=75
        break
      fi
      echo "ci-phase xcodebuild -resolvePackageDependencies failed on a fetch (try $try of $tries); trying again in ${delays[$((try - 1))]}s"
      sleep "${delays[$((try - 1))]}"
      try=$((try + 1))
    done
  fi
  if [ "$resolved" -eq 75 ]; then
    # Every try failed on a fetch: the commit's packages are not here, so no
    # build can run. Keep the build outputs and the header digest as they are:
    # the next resolve that succeeds compares its digest with this stamp and
    # purges only when the headers changed. Emptying them here made every
    # Release compile after the 2026-11-26 403s on that host build cold (and
    # time out at 60 min), and the fetch failed anyway.
    echo "ci-phase xcodebuild -resolvePackageDependencies failed on a fetch on every try; its last lines:"
    tail -n 20 "$resolve_log" | sed 's/^/  | /' || true
    echo "ci-phase fetch failed, no build ran: kept the build outputs and header digest in $derived (infrastructure, no verdict: 75; rerun the step)"
    rm -f "$resolve_log"
    return 75
  fi
  if [ "$resolved" -ne 0 ]; then
    # As above: when resolution fails the artifacts may be the old commit's, so
    # the digest proves nothing; build cold and let the build report why.
    digest=""
    echo "ci-phase xcodebuild -resolvePackageDependencies failed; its last lines:"
    tail -n 20 "$resolve_log" || true
  else
    digest="$(swiftpm_binary_module_digest "$root" "$scratch")"
  fi
  rm -f "$resolve_log"
  [ ! -f "$stamp" ] || previous="$(cat "$stamp")"
  if [ -n "$digest" ] && [ "$digest" = "$previous" ]; then
    return 0
  fi
  # Only build outputs need removing: a new DerivedData (a runner's temp dir)
  # holds at most the packages the resolve just fetched.
  for entry in "$derived"/* "$derived"/.[!.]*; do
    [ -e "$entry" ] || continue
    case "${entry##*/}" in
      # Not build outputs: what the resolve itself writes in a new DerivedData,
      # and the build log a caller copies in (check-release-compile.sh).
      SourcePackages|"$swiftpm_binary_module_inputs_file"|Logs|info.plist|cmux-next-build.log) ;;
      *) had_outputs=1 ;;
    esac
  done
  # Written only after the outputs are gone: a step stopped in between purges again.
  rm -f "$stamp"
  if [ "$had_outputs" -eq 1 ]; then
    bash "$(dirname "${BASH_SOURCE[0]}")/../cmux-next/clear-stale-scheme-build-state.sh" "$derived"
  fi
  if [ -z "$digest" ]; then
    [ "$had_outputs" -eq 0 ] || echo "ci-phase removed the build outputs in $derived (a cold build)"
    return 0
  fi
  mkdir -p "$derived"
  printf '%s\n' "$digest" > "$stamp"
  if [ "$had_outputs" -eq 0 ]; then
    return 0
  elif [ -n "$previous" ]; then
    echo "ci-phase binary-target headers changed since the last build in $derived: removed its build outputs (a cold build)"
  else
    echo "ci-phase $derived had build outputs but no binary-target header digest: removed them (a cold build)"
  fi
}

swiftpm_purge_build_outputs() {
  local scratch="$1" entry
  [ -d "$scratch" ] || return 0
  for entry in "$scratch"/* "$scratch"/.[!.]*; do
    [ -e "$entry" ] || continue
    case "${entry##*/}" in
      artifacts|checkouts|repositories|workspace-state.json|Package.resolved|app-ffi-linux) ;;
      *) rm -rf -- "$entry" ;;
    esac
  done
}

# swiftpm_unverified_build SCRATCH: the fleet worker kept this .build after a
# step whose build never finished (stopped at its max-run, cancelled, or failed)
# and marked it unverified (hq build-fleet cmd/worker step_warm.go,
# warmUnverifiedFile). SwiftPM resumes such a build where it stopped: the
# 2026-11-21 CmuxNext suite steps on lent minis were stopped at 180 min with 27
# of 13,437-15,760 targets left, and the worker used to drop the .build, so the
# next step compiled all of them again. When a build on an unverified .build
# fails, the caller builds once more from clean outputs, so a bad leftover (the
# 2026-10-10 undefined-symbols link) never reports red. A complete build
# removes the marker (record_built_ref, run-swift-testing-suites.sh). The worker
# keeps an unfinished .build only for a step whose script calls this function.
swiftpm_unverified_build() {
  [ -f "$1/.cmux-ci-unverified" ]
}

swiftpm_stale_module_failure() {
  bash "$(dirname "${BASH_SOURCE[0]}")/../cmux-next/stale-pcm-retry-needed.sh" "$1"
}
