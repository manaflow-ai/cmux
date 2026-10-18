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
#   a binary target: SCRATCH/artifacts and each *.xcframework of the checkout.
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

# The digest of the binary-target headers PKGDIR's build reads (stdout).
swiftpm_binary_module_digest() {
  local pkgdir="$1" scratch="$2" root roots=() dir
  root="$(git -C "$pkgdir" rev-parse --show-toplevel 2>/dev/null || pwd)"
  [ ! -d "$scratch/artifacts" ] || roots+=("$scratch/artifacts")
  while IFS= read -r -d '' dir; do
    roots+=("$dir")
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
  # Resolution fetches and unpacks the commit's binary artifacts; a failure here
  # is reported again by the build itself.
  swift package resolve --package-path "$pkgdir" ${resolve_args[@]+"${resolve_args[@]}"} < /dev/null >/dev/null 2>&1 || true
  stamp="$scratch/$swiftpm_binary_module_inputs_file"
  digest="$(swiftpm_binary_module_digest "$pkgdir" "$scratch")"
  [ ! -f "$stamp" ] || previous="$(cat "$stamp")"
  if [ "$digest" = "$previous" ]; then
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
  printf '%s\n' "$digest" > "$stamp"
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
