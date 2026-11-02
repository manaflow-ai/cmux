#!/usr/bin/env bash
# nightly.yml build-nightly-app: "Bound Xcode compilation cache size". Moved out of the workflow to keep nightly.yml under
# its size budget (tests/test_workflow_file_size.py); the step's env: still sets every input.
set -euo pipefail
cache_path="build-universal/CompilationCache.noindex"
# A trusted NEXT worker links it to the cache it keeps on disk
# (nightly_build_state.py); measure and bound the cache itself.
if [ -L "$cache_path" ]; then cache_path="$(readlink "$cache_path")"; fi
max_cache_kib=$((5 * 1024 * 1024))
if [ -d "$cache_path" ]; then
  # Xcode's CAS chains v1.N generations: the newest is the primary,
  # the one before it is the upstream it faults objects in from, and
  # anything older is dead until the CAS's next garbage collection.
  # The CAS rotates a new primary whenever the current one ends a
  # build above half of COMPILATION_CACHE_LIMIT_SIZE (1.5 GiB here,
  # below one build's 3.3 GB working set), so every warm build leaves
  # a dead generation behind, the directory measures two full builds
  # (6.6 GB on main), and this bound used to drop every warm cache.
  # Prune the dead generations first, exactly as the CAS would.
  python3 scripts/ci/prune-xcode-compilation-cache.py "$cache_path" \
    || echo "::warning::Xcode compilation cache pruning failed; measuring it unpruned"
  cache_kib=$(du -sk "$cache_path" | awk '{print $1}')
else
  cache_kib=0
fi
echo "Xcode compilation cache size: ${cache_kib} KiB (limit: ${max_cache_kib} KiB)"
save=false
if [ "$cache_kib" -gt "$max_cache_kib" ]; then
  # Nothing is saved, so the next build restores the same older entry
  # and lands here again: the cache freezes at its last saved entry
  # until the bound (and COMPILATION_CACHE_LIMIT_SIZE) is raised.
  echo "::warning::Xcode compilation cache exceeds 5 GiB; skipping cache save"
  rm -rf "$cache_path"
elif [ "$cache_kib" -gt 0 ]; then
  save=true
else
  echo "Xcode compilation cache is empty; skipping cache save"
fi
echo "save=${save}" >> "$GITHUB_OUTPUT"
