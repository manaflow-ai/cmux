# shellcheck shell=bash
# Sourced by the Swift package lanes (package-test-lane.sh,
# run-swift-testing-suites.sh). Keeps a reused SwiftPM .build correct when a
# binary target's C headers change.
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
#   Resolves PKGDIR (so the binary artifacts in SCRATCH are the commit's), then
#   hashes every header, module map and API notes file the build can read from
#   a binary target: SCRATCH/artifacts and each *.xcframework of the checkout
#   that the package's or a local dependency's manifest names.
#   The digest (with the toolchain's version) is stored in
#   SCRATCH/.cmux-binary-module-inputs. When it differs, or a kept SCRATCH has
#   no digest yet, it removes the precompiled module caches in SCRATCH before the
#   build; the build then compiles them again from the current headers, and
#   the Swift modules that import them after it. Sources, dependency checkouts
#   and downloaded artifacts stay.
#
# swiftpm_purge_build_outputs SCRATCH
#   The backstop: removes every build output in SCRATCH (keeps checkouts,
#   repositories, artifacts and the resolution state).
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
  echo "$pkgdir/Package.swift"
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

swiftpm_binary_module_guard() {
  local pkgdir="$1" scratch="${2:-$1/.build}" stamp digest previous="" resolve_args=()
  [ "$scratch" = "$pkgdir/.build" ] || resolve_args=(--scratch-path "$scratch")
  stamp="$scratch/$swiftpm_binary_module_inputs_file"
  # Resolution fetches and unpacks the commit's binary artifacts. When it fails
  # (the build reports why), the artifacts may still be the old commit's, so the
  # digest proves nothing: drop the caches and the stamp, and the next step
  # starts from a digest of its own.
  if ! swift package resolve --package-path "$pkgdir" ${resolve_args[@]+"${resolve_args[@]}"} < /dev/null >/dev/null 2>&1; then
    digest=""
  else
    digest="$(swiftpm_binary_module_digest "$pkgdir" "$scratch")"
  fi
  [ ! -f "$stamp" ] || previous="$(cat "$stamp")"
  if [ -n "$digest" ] && [ "$digest" = "$previous" ]; then
    return 0
  fi
  local removed=0 dir
  while IFS= read -r -d '' dir; do
    rm -rf -- "$dir"
    removed=$((removed + 1))
  done < <(find "$scratch" \( -path "$scratch/artifacts" -o -path "$scratch/checkouts" -o -path "$scratch/repositories" \) -prune -o \
    -type d \( -name '*ExplicitPrecompiledModules' -o -name 'ModuleCache' -o -name 'ModuleCache.noindex' -o -name 'PrecompiledHeaders' \) \
    -prune -print0 2>/dev/null)
  # Written only after the caches are gone: a step stopped in between purges again.
  mkdir -p "$scratch"
  if [ -n "$digest" ]; then
    printf '%s\n' "$digest" > "$stamp"
  else
    rm -f "$stamp"
    echo "ci-phase swift package resolve failed in $pkgdir: removed $removed precompiled module cache folder(s) in $scratch"
    return 0
  fi
  if [ -n "$previous" ]; then
    echo "ci-phase binary-target headers changed in $pkgdir since its last build: removed $removed precompiled module cache folder(s) in $scratch"
  elif [ "$removed" -gt 0 ]; then
    echo "ci-phase $scratch had no binary-target header digest: removed $removed precompiled module cache folder(s)"
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
