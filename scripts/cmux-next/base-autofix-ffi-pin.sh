#!/usr/bin/env bash
# Whether FROM..TO moved the CCmuxAppFFI pin, for scripts/cmux-next/autofix-areas.sh: prints the
# pseudo path "Packages/macOS/CmuxNext/Package.swift#CCmuxAppFFI" when the binary target's url or
# checksum differ, nothing when they are the same.
#
# The action exports (plans/cmux-next/action-surfaces.json, actions.md, links.json) are written from
# the Rust catalog in the pinned CCmuxAppFFI (CmuxNextActions reads cmux-action-catalog through
# RustActionCatalog), so a re-pin alone changes them. d0745a8d (2026-11-11) pinned 4 Rust actions in
# and touched only Package.swift; no base autofix run made the exports again, and action-surfaces.json
# kept 1447 of the catalog's 1451 rows (swift_parity action_list_export_matches red on the base).
# Package.swift as a whole is not an input: it changes about 13 times a day, 23 of 40 of them in the
# 3 days to 2026-11-11 a pin and the rest a target, and each Mac regeneration takes about 40 minutes.
#
# Run in a git repository that has both commits' trees. A blob it lacks (base-autofix-changed.sh's
# scratch repository fetches trees only) is fetched by id from FETCH_URL. When either pin can't be
# read it prints the pseudo path: an unread pin never proves the exports current.
#
# Usage: scripts/cmux-next/base-autofix-ffi-pin.sh FROM TO [FETCH_URL]
set -euo pipefail
from="${1:?usage: $0 FROM TO [FETCH_URL]}"
to="${2:?usage: $0 FROM TO [FETCH_URL]}"
url="${3:-}"
manifest=Packages/macOS/CmuxNext/Package.swift
marker="$manifest#CCmuxAppFFI"

pin() { # <commit>: the CCmuxAppFFI binary target's url and checksum lines ("none" without a manifest)
  local blob
  if ! git cat-file -e "$1:$manifest" 2>/dev/null; then
    git rev-parse --verify --quiet "$1^{tree}" >/dev/null || return 1
    git ls-tree --name-only "$1" -- "$manifest" | grep -q . || { echo none; return 0; }
    blob="$(git rev-parse --verify --quiet "$1:$manifest")" || return 1
    [[ -n "$url" ]] || return 1
    # core.alternateRefsCommand=true: as base-autofix-changed.sh, offer no commits this repository
    # has none of the history of.
    git -c core.alternateRefsCommand=true fetch --quiet --no-tags --no-write-fetch-head "$url" "$blob" \
      2>/dev/null || return 1
  fi
  git cat-file blob "$1:$manifest" | sed -n '/name: "CCmuxAppFFI"/,/)/{/url:/p;/checksum:/p;/path:/p;}'
}

if a="$(pin "$from")" && b="$(pin "$to")"; then
  [[ "$a" == "$b" ]] || echo "$marker"
else
  echo "base-autofix-ffi-pin: cannot read the CCmuxAppFFI pin at ${from:0:12} or ${to:0:12}; counting it as moved" >&2
  echo "$marker"
fi
