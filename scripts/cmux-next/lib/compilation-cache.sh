# shellcheck shell=bash
# Sourced by check-cmux-scheme-compile.sh. The DEV Release compile's warm
# state is Xcode's content-addressed compilation cache, never kept build
# products.
#
# A kept DerivedData builds incrementally from objects an earlier build left,
# and an incremental Xcode build can keep stale autolink and force-load data
# in objects it did not recompile after an import set changed; nightly
# stopped shipping from one for that reason (manaflow-ai/cmux#21761). With
# CMUX_NEXT_COMPILATION_CACHE=1 and a kept DerivedData path, each build starts
# from an empty tree that keeps only:
#   CompilationCache.noindex  Xcode's CAS. A compile job is replayed only when
#                             its key (the job's full inputs, the toolchain
#                             and its explicit module dependencies) matches,
#                             so nothing stale can come back.
#   SourcePackages            SwiftPM checkouts pinned by Package.resolved.
# The CAS lives on the runner that wrote it (no remote store, no other
# writer), at the same real path every build, since the path is part of the
# keys.
#
# Self-healing: a CAS that will not open or reads corrupt is removed and the
# build runs once more without it; a CAS over the bound is pruned, then
# dropped. Neither fails the build by itself.

# The compilation cache's own limit (nightly and ci-macos use the same) and
# the size past which the directory is dropped after pruning.
CMUX_NEXT_CAS_LIMIT_BYTES=3221225472
CMUX_NEXT_CAS_MAX_KIB=$((6 * 1024 * 1024))

# Empty a kept DerivedData except the CAS and the package checkouts. Fails
# closed: returns 1 when anything else is still there afterwards (the caller
# must not build on it).
# Usage: cmux_next_cas_fresh_tree <derived data>
cmux_next_cas_fresh_tree() {
  local dd=$1 entry name left=0
  [[ -d "$dd" ]] || return 0
  for entry in "$dd"/* "$dd"/.[!.]*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    name=${entry##*/}
    case "$name" in
      CompilationCache.noindex|SourcePackages) ;;
      *) rm -rf -- "$entry" 2>/dev/null || true ;;
    esac
  done
  for entry in "$dd"/* "$dd"/.[!.]*; do
    [[ -e "$entry" || -L "$entry" ]] || continue
    case "${entry##*/}" in
      CompilationCache.noindex|SourcePackages) ;;
      *) echo "error: could not remove $entry before the build" >&2; left=1 ;;
    esac
  done
  return "$left"
}

# The xcodebuild settings that turn the cache on.
cmux_next_cas_settings() {
  printf '%s\n' COMPILATION_CACHE_ENABLE_CACHING=YES "COMPILATION_CACHE_LIMIT_SIZE=$CMUX_NEXT_CAS_LIMIT_BYTES"
}

# Whether a failed build's log shows the cache itself failing (not the code).
# Usage: cmux_next_cas_failed <log>
cmux_next_cas_failed() {
  [[ -f "$1" ]] || return 1
  # Swift's and clang's caching diagnostics name the CAS ("CAS error
  # encountered during", "cannot create CAS filesystem", "failed to load
  # input ... from CAS") or the cache ("failed to replay cached diagnostics",
  # "cannot create cache key for compilation"). Any compiler error that says
  # either counts: a code error that happens to say "cache" costs one more
  # build without the cache, never a wrong verdict. Only compiler diagnostic
  # lines ("error: ..." or "<file>:<l>:<c>: error: ..."), never the
  # diagnostic wrapper's process and host dumps.
  # run-xcodebuild-with-diagnostics.sh ends xcodebuild's own output with
  # "xcodebuild exit status:"; what follows (host, process and argv dumps) is
  # never read.
  local diag='^([^[:space:]]+: )?(fatal )?error: ' errors
  errors="$(awk '/^xcodebuild exit status:/ { exit } { print }' "$1" | grep -E "$diag" || true)"
  grep -Eq '\bCAS\b' <<<"$errors" && return 0
  grep -Eqi 'cach(e|ed|ing)|OnDiskCAS' <<<"$errors"
}

# Drop the CAS (after a cache failure, or when it is over the bound). A CAS
# that will not go away is never read again in this run: the retry builds
# with the cache off, and the next run's cache failure drops it again.
# Usage: cmux_next_cas_drop <derived data>
cmux_next_cas_drop() {
  rm -rf -- "$1/CompilationCache.noindex" || echo "warning: could not remove $1/CompilationCache.noindex" >&2
  return 0
}

# Prune dead CAS generations and drop the CAS past the bound. Advisory.
# Usage: cmux_next_cas_bound <repo root> <derived data>
cmux_next_cas_bound() {
  local root=$1 cas="$2/CompilationCache.noindex" kib
  [[ -d "$cas" ]] || return 0
  python3 "$root/scripts/ci/prune-xcode-compilation-cache.py" "$cas" \
    || echo "warning: pruning the compilation cache failed; measuring it unpruned" >&2
  kib="$(du -sk "$cas" 2>/dev/null | cut -f1 || true)"
  echo "check-cmux-scheme-compile: compilation cache ${kib:-?} KiB (bound $CMUX_NEXT_CAS_MAX_KIB KiB): $cas"
  if [[ "$kib" =~ ^[0-9]+$ ]] && (( kib > CMUX_NEXT_CAS_MAX_KIB )); then
    echo "::warning::compilation cache over its bound; dropped (the next build fills it again)"
    cmux_next_cas_drop "$2"
  fi
  return 0
}
