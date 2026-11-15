#!/usr/bin/env bash
# nightly.yml nightly-next-one: whether the Mac's kept Zig package cache (~/.cache/zig) already holds every package
# "Cache Zig packages" would restore, so the job skips that restore (647 MB, 70-86 s in runs 43390156751 and
# 43395323737) on a warm Mac.
#
#   zig-cache-kept.sh check   kept=true in $GITHUB_OUTPUT when the cache's marker names KEY, else kept=false
#   zig-cache-kept.sh mark    write KEY as the marker; run only after "Build the cmux-next source archive"
#                             succeeded, whose `zig build --fetch=all` of Ghostty and ghostty-next (ZIG_GLOBAL_CACHE_DIR
#                             = ~/.cache/zig) leaves every package of that key in the cache
#
# KEY is the restore's own key (zig-packages-<hashFiles of ghostty's build.zig.zon files>). Skipping the restore never
# removes a package: it only adds none. A package that went missing since the marker was written is seeded from our
# mirror by the source archive's zig-fetch-all.sh, as on any runner whose cache missed.
set -euo pipefail
cache="${CMUX_KEPT_ZIG_CACHE:-$HOME/.cache/zig}"
marker="$cache/.cmux-complete-key"
valid_key() { [[ "${KEY:-}" =~ ^zig-packages-[0-9a-f]{64}$ ]]; }
case "${1:-}" in
  check)
    kept=false
    if valid_key && [[ -d "$cache/p" && -f "$marker" && "$(cat "$marker")" == "$KEY" ]]; then
      kept=true
      echo "the kept Zig package cache $cache already holds every package of $KEY: no restore"
    else
      echo "the kept Zig package cache $cache is not known complete for ${KEY:-<no key>}: restoring it"
    fi
    echo "kept=$kept" >> "$GITHUB_OUTPUT"
    ;;
  mark)
    if ! valid_key; then echo "::warning title=Zig package cache::no valid key (${KEY:-}); marking nothing"; exit 0; fi
    mkdir -p "$cache"
    printf '%s\n' "$KEY" > "$marker.$$"
    mv -f "$marker.$$" "$marker"
    echo "marked $cache complete for $KEY"
    ;;
  *) echo "usage: zig-cache-kept.sh check|mark" >&2; exit 2 ;;
esac
