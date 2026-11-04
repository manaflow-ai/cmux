# shellcheck shell=bash
# Sourced by the Swift package lanes (package-test-lane.sh,
# run-swift-testing-suites.sh) and by the kept-DerivedData app scheme compile
# (scripts/cmux-next/check-cmux-scheme-compile.sh). Keeps a reused SwiftPM
# .build or Xcode DerivedData correct when a binary target's C headers change.
#
# Why: a fleet step-warm slot (hq build-fleet cmd/worker/step_warm.go), a
# GitHub runner's kept checkout or an nx-remote tree builds many commits in one
# .build. A binary target (CCmuxAppFFI, GhosttyNextKit, CmuxTerminalClientFFI,
# iroh-ffi) gives its headers to the build at a fixed path
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
#   (clear-stale-scheme-build-state.sh). The glaeda scheme job reused a .pcm of
#   the old CCmuxAppFFI header after the pin moved, and Swift saw the old
#   declarations: "cannot find type 'CmuxFocusReply'" on every push from
#   2026-10-18T06:50Z (cmux17, cmux18, cmux24, cmux-austin-mini-1), which the
#   stale-module retry does not match.
#
# swiftpm_purge_build_outputs SCRATCH
#   Removes every build output in SCRATCH (keeps checkouts, repositories,
#   artifacts and the resolution state). Also the backstop of the suite build.
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
# partial file".
swiftpm__network_fetch_failure() {
  grep -qE 'curl [0-9]+|RPC failed|Transferred a partial file|expected flush after|Could not resolve host|Failed to connect to|Couldn.{1,3}t connect to server|Connection (reset|refused|timed out)|Operation timed out|SSL_ERROR|gnutls_handshake|unexpected disconnect|early EOF|remote end hung up unexpectedly|Empty reply from server|The requested URL returned error: 5[0-9][0-9]|badResponseStatusCode[(]5[0-9][0-9]|The network connection was lost|The request timed out' "$1"
}

# `swift package resolve` of PKGDIR (ARGS go after --package-path), its output in the step log. A failure on
# a network fetch is tried again after each delay of CMUX_SWIFTPM_RESOLVE_RETRY_DELAYS (seconds, default
# "5 20": three tries). Returns 0 when it resolved, 75 when every try failed on the network (no test can run),
# 1 when it failed for another reason (the build reports why).
swiftpm_resolve_package() {
  local pkgdir="$1" log delays tries try=1 delay code
  shift
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
    if ! swiftpm__network_fetch_failure "$log"; then
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
  # every try fails, no test can run for PKGDIR: the guard returns 75 (no verdict)
  # and the caller decides (a lane of several packages records it for this one
  # package and goes on; a step of one package ends with 75, never 1).
  swiftpm_resolve_package "$pkgdir" ${resolve_args[@]+"${resolve_args[@]}"} || resolved=$?
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
    if [ "$resolved" -eq 75 ]; then
      echo "ci-phase fetch failed, no test ran: swift package resolve in $pkgdir failed on a network fetch on every try (infrastructure, no verdict: 75; rerun the step)"
      return 75
    fi
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
  shift 2
  stamp="$derived/$swiftpm_binary_module_inputs_file"
  resolve_log="$(mktemp)"
  # As above: when resolution fails the artifacts may be the old commit's, so
  # the digest proves nothing; build cold and let the build report why.
  if ! (cd "$root" && xcodebuild "$@" -derivedDataPath "$derived" \
      -resolvePackageDependencies < /dev/null >"$resolve_log" 2>&1); then
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
      SourcePackages|"$swiftpm_binary_module_inputs_file") ;;
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
      artifacts|checkouts|repositories|workspace-state.json|Package.resolved) ;;
      *) rm -rf -- "$entry" ;;
    esac
  done
}

swiftpm_stale_module_failure() {
  bash "$(dirname "${BASH_SOURCE[0]}")/../cmux-next/stale-pcm-retry-needed.sh" "$1"
}
