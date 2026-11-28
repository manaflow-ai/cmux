#!/usr/bin/env bash
# nightly.yml: the build commit's source, obtained once per run, so no later job fetches it from github.com.
#
#   nightly-source.sh pack SHA OUTDIR     (resolve-nightly-cmux-tui-client, from its mirror-served checkout)
#   unpack.sh unpack SHA DIR              (every job that checks out the build ref, before actions/checkout)
#
# Why: Leo, "are nightlies not publishin? where the priority?" and "can you help us on the nightlies :o".
# Run 46101546346 (NIGHTLY 4610154634601) made about 8 github.com git fetches, three of them for the
# build ref itself: prepare-nightly-variant (the fleet shim waited 90 s for its mirror to bring the
# commit, then fetched it from github.com anyway), build-sign-notarize-nightly and the signed-nightly
# verify (hosted Macs, plain actions/checkout). Each one is a request in the class that answers 429.
#
# pack writes one git pack holding the commit, every tree and every blob the lean checkout reads
# (.github/checkout-lean.json: cmux-next-ios/verify/ media left out; submodule gitlinks are not
# objects here) plus this script as unpack.sh. unpack turns the job's workspace into a sparse,
# shallow checkout of SHA from that pack: no network. It prints
#   github.com git fetches this job: 0 (build source from this run's pack)
# and sets the step output ok=true; on any failure it leaves ok unset and the job's actions/checkout
# runs as before, so a missing artifact costs one fetch, never the build.
set -euo pipefail

mode="${1:-}"
sha="${2:-}"
dir="${3:-}"
[[ "$mode" =~ ^(pack|unpack)$ && "$sha" =~ ^[0-9a-f]{40}$ && -n "$dir" ]] || {
  echo "usage: $0 pack|unpack SHA DIR" >&2
  exit 2
}

say() { echo "nightly-source: $*"; }

lean_patterns() {
  # The checkout-lean table's patterns, one per line; the built-in copy when the table is absent.
  local table="${GITHUB_WORKSPACE:-.}/.github/checkout-lean.json"
  if [[ -f "$table" ]] && python3 -I -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["sparse_checkout"]))' "$table" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' '/*' '!/cmux-next-ios/verify/'
}

pack() {
  local out="$dir" started=$SECONDS
  cd "${GITHUB_WORKSPACE:-$PWD}"
  # Never ask a promisor remote for a missing object: a pack that would need the network is not made.
  export GIT_NO_LAZY_FETCH=1
  git cat-file -e "$sha^{commit}" || { say "$sha is not in this checkout; no pack"; return 1; }
  mkdir -p "$out"
  lean_patterns >"$out/sparse-checkout"
  # Objects: the commit, its root tree, every tree below it, and the blobs outside the "!/..." patterns.
  git ls-tree -r -t -z --full-tree "$sha" | python3 -I -c '
import sys
sha, root, patterns = sys.argv[1], sys.argv[2], open(sys.argv[3]).read().split()
drop = tuple(p[2:] for p in patterns if p.startswith("!/"))
out = sys.stdout
out.write(f"{sha}\n{root}\n")
for entry in sys.stdin.buffer.read().split(b"\0"):
    if not entry:
        continue
    meta, path = entry.split(b"\t", 1)
    _mode, kind, oid = meta.split()
    name = path.decode("utf-8", "surrogateescape")
    if kind == b"commit" or (kind == b"blob" and name.startswith(drop)):
        continue
    out.write(f"{oid.decode()} {name}\n")
' "$sha" "$(git rev-parse "$sha^{tree}")" "$out/sparse-checkout" >"$out/objects"
  # --window=0: stored deltas whose base is in the pack are reused; no new delta search on the
  # critical path. The artifact uploads with compression 0, since a pack is already compressed.
  git pack-objects --window=0 --threads=0 --stdout -q <"$out/objects" >"$out/source.pack"
  rm -f "$out/objects"
  echo "$sha" >"$out/sha"
  cp "${BASH_SOURCE[0]}" "$out/unpack.sh"
  say "packed $sha: $(du -k "$out/source.pack" | cut -f1) KiB in $((SECONDS - started)) s"
}

unpack() {
  local src="$dir" ws="${GITHUB_WORKSPACE:-$PWD}" started=$SECONDS
  export GIT_NO_LAZY_FETCH=1  # the unpack itself never reaches the network; a gap fails over to actions/checkout
  [[ -f "$src/source.pack" && "$(cat "$src/sha" 2>/dev/null)" == "$sha" ]] || {
    say "no pack for $sha in $src; actions/checkout fetches it"
    return 1
  }
  mkdir -p "$ws"
  cd "$ws"
  git init -q .
  local url="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-manaflow-ai/cmux}"
  git remote get-url origin >/dev/null 2>&1 && git remote set-url origin "$url" || git remote add origin "$url"
  rm -f .git/index.lock .git/shallow.lock
  # On failure, leave no sparse setting behind for the actions/checkout that runs next.
  trap 'git config --unset core.sparseCheckout; git config --unset core.sparseCheckoutCone; true' ERR
  # A promisor pack in a partial clone: the verify/ blobs the sparse checkout never reads may be
  # absent without git calling the index broken; reading one would fetch it from origin.
  git config core.repositoryformatversion 1
  git config extensions.partialClone origin
  git config remote.origin.promisor true
  git config remote.origin.partialclonefilter blob:none
  git index-pack --stdin --promisor="nightly-source $sha" <"$src/source.pack" >/dev/null
  git cat-file -e "$sha^{commit}"
  # Shallow only when a parent is absent: a reused workspace that holds the history stays complete.
  local parent
  for parent in $(git cat-file commit "$sha" | sed -n '/^$/q; s/^parent //p'); do
    if ! git cat-file -e "$parent^{commit}" 2>/dev/null; then
      grep -qx "$sha" .git/shallow 2>/dev/null || echo "$sha" >>.git/shallow
      break
    fi
  done
  git config core.sparseCheckout true
  git config core.sparseCheckoutCone false
  mkdir -p .git/info
  # The checkout applies the new patterns itself: it re-marks skip-worktree on every entry it moves.
  cp "$src/sparse-checkout" .git/info/sparse-checkout
  git -c advice.detachedHead=false checkout -q --force --detach "$sha"
  git clean -ffdxq
  [[ "$(git rev-parse HEAD)" == "$sha" ]]
  trap - ERR
  rm -rf "$src"
  say "checked out $sha from this run's pack in $((SECONDS - started)) s"
  echo "github.com git fetches this job: 0 (build source from this run's pack)"
  [[ -z "${GITHUB_OUTPUT:-}" ]] || echo "ok=true" >>"$GITHUB_OUTPUT"
}

"$mode"
