#!/usr/bin/env bash
# The cmux NEXT Nightly app's whole-product reuse, for nightly.yml's build-nightly-app
# (scripts/ci/nightly_release_product_reuse.py has the why and the trust rules).
#
#   nightly-release-product.sh lookup   key this checkout, look up a record, unpack a hit into
#                                       build-universal/Build/Products/Release; prints key=, hit=,
#                                       reason= (and the hit's source_run_id=, source_sha=, ...) and
#                                       record=true|false (whether this job may write a record:
#                                       reuse switched on, a key, and a fresh VM that starts with
#                                       empty DerivedData) for $GITHUB_OUTPUT
#   nightly-release-product.sh record   pack the finished products and write their record; prints
#                                       archive= and manifest= (both empty when nothing is recorded)
#
# Environment: NIGHTLY_PRODUCT_<FLAG> for every job_input_fingerprint.NIGHTLY_PRODUCT_FLAGS entry
# (decide's outputs, '' allowed), CMUX_TUI_TREE_KEY (the bundled cmux-tui tree), SKIP_REASON
# (lookup), KEY, BUILD_SHA and the REUSED_FROM_* values (record). Never fails the job for a reuse
# problem: a lookup error is a miss, and a record error records nothing.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
products="${NIGHTLY_PRODUCTS_DIR:-build-universal/Build/Products/Release}"
derived="${NIGHTLY_DERIVED_DATA_DIR:-build-universal}"
work="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cmux-nightly-next-product"

# The key names nightly.yml as the build commit has it, but the steps run as the workflow commit
# (GITHUB_WORKFLOW_SHA) has it; build-nightly-app can build an older commit than the one it runs
# (resolve-nightly-cmux-tui-client's build_sha), from a depth-1 checkout that does not hold the
# workflow commit. Reuse only when the two files are the same blob: from git when the checkout has
# the workflow commit, else from the contents API (its `sha` is the blob id). A missing SHA, an
# unreadable blob or an API error is a mismatch.
workflow_blob() {
  local sha=$1 path=.github/workflows/nightly.yml blob
  if blob="$(git -C "$repo_root" rev-parse -q --verify "$sha:$path" 2>/dev/null)"; then
    printf '%s\n' "$blob"
    return 0
  fi
  [[ -n "${GH_TOKEN:-}" && -n "${GITHUB_REPOSITORY:-}" ]] || return 1
  curl -fsS --retry 2 --connect-timeout 10 --max-time 30 -H @- \
    -H 'Accept: application/vnd.github+json' \
    "${GITHUB_API_URL:-https://api.github.com}/repos/$GITHUB_REPOSITORY/contents/$path?ref=$sha" \
    <<<"Authorization: Bearer $GH_TOKEN" 2>/dev/null \
    | python3 -I -c 'import json, re, sys; blob = str(json.load(sys.stdin).get("sha", "")); sys.exit(1) if not re.fullmatch("[0-9a-f]{40}", blob) else print(blob)'
}

workflow_matches() {
  local workflow_sha="${GITHUB_WORKFLOW_SHA:-}" head ours theirs
  [[ "$workflow_sha" =~ ^[0-9a-f]{40}$ ]] || return 1
  head="$(git -C "$repo_root" rev-parse HEAD 2>/dev/null)" || return 1
  ours="$(workflow_blob "$head")" || return 1
  [[ "$head" == "$workflow_sha" ]] && return 0
  theirs="$(workflow_blob "$workflow_sha")" || return 1
  [[ "$ours" == "$theirs" ]]
}

lookup_once() {
  local recipe flags=() name var key
  if ! workflow_matches; then
    echo "key="
    echo "hit=false"
    echo "reason=the running nightly.yml (${GITHUB_WORKFLOW_SHA:-unset}) is not the build commit's, or cannot be read"
    return 0
  fi
  recipe="$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import nightly_release_product_reuse as r; print(r.RECIPE)' "$repo_root/scripts/ci")"
  while IFS= read -r name; do
    var="NIGHTLY_PRODUCT_$(tr '[:lower:]' '[:upper:]' <<<"$name")"
    flags+=(--extra "$name=${!var-}")
  done < <(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import job_input_fingerprint as f; print("\n".join(f.NIGHTLY_PRODUCT_FLAGS))' "$repo_root/scripts/ci")
  key="$(python3 -I "$repo_root/scripts/ci/job_input_fingerprint.py" nightly-release-product --root "$repo_root" \
    --extra "xcode=$(xcodebuild -version | tr '\n' ' ')" \
    --extra "sdk=$(xcrun --sdk macosx --show-sdk-version) $(xcrun --sdk macosx --show-sdk-build-version)" \
    --extra "arch=$(uname -m)" \
    --extra "macos=$(sw_vers -productVersion)" --extra "macos_build=$(sw_vers -buildVersion)" \
    --extra "recipe=$recipe" \
    --extra "tui_tree=${CMUX_TUI_TREE_KEY:-}" \
    "${flags[@]}" | sed -n 's/^fingerprint=//p')" || key=""
  echo "key=$key"
  python3 -I "$repo_root/scripts/ci/nightly_release_product_reuse.py" lookup --key "${key:-none}" \
    --skip "${SKIP_REASON:-}" --out "$work/lookup" --products "$products" --timeout 240
}

# Every way out but a hit removes the products directory: xcodebuild would merge into whatever a
# miss left there.
lookup() {
  local result status=0 facts
  # Measured first: a hit unpacks into $derived.
  facts="$(python3 -I "$repo_root/scripts/ci/nightly_release_product_reuse.py" builder \
    --derived-data "$derived" --out "$work/builder.json")" || facts="recordable=false"
  result="$(lookup_once)" || status=$?
  if (( status != 0 )) || ! grep -qx 'hit=true' <<<"$result"; then
    rm -rf -- "$products"
    grep -q '^hit=' <<<"$result" || result+=$'\nhit=false\nreason=the lookup failed (exit '"$status"')'
  fi
  printf '%s\n' "$result"
  if [[ -z "${SKIP_REASON:-}" ]] && grep -qx 'recordable=true' <<<"$facts" && grep -q '^key=.' <<<"$result"; then
    echo "record=true"
  else
    echo "record=false"
  fi
}

record() {
  local archive="$work/cmux-nightly-next-release-${BUILD_SHA:?}.tar.gz" packed manifest="$work/record/manifest.json"
  [[ "${KEY:-}" =~ ^[0-9a-f]{64}$ ]] || { echo "archive="; echo "manifest="; echo "no product key; nothing recorded" >&2; return 0; }
  # Only a fresh VM that started from empty DerivedData records (the lookup measured it).
  if ! python3 -I -c 'import json, sys; sys.path.insert(0, sys.argv[1]); import dev_release_product_reuse as r; why = r.clean_builder(json.load(open(sys.argv[2]))); print(why or "fresh VM, clean start", file=sys.stderr); sys.exit(1 if why else 0)' \
      "$repo_root/scripts/ci" "$work/builder.json"; then
    echo "archive="; echo "manifest="; echo "nothing recorded" >&2; return 0
  fi
  packed="$(python3 -I "$repo_root/scripts/ci/nightly_release_product_reuse.py" pack --products "$products" --out "$archive")"
  printf '%s\n' "$packed" >&2
  if ! grep -q '^archive=.' <<<"$packed"; then
    echo "archive="; echo "manifest="; return 0
  fi
  if ! python3 -I "$repo_root/scripts/ci/nightly_release_product_reuse.py" record --key "$KEY" --sha "$BUILD_SHA" \
      --archive "$archive" --out "$manifest" --reused-from-run "${REUSED_FROM_RUN:-}" \
      --reused-from-sha "${REUSED_FROM_SHA:-}" --compiled-run "${COMPILED_RUN:-}" \
      --builder "$work/builder.json" >&2; then
    echo "archive="; echo "manifest="; return 0
  fi
  echo "archive=$archive"
  echo "manifest=$manifest"
}

case "${1:-}" in
  lookup) lookup ;;
  record) record ;;
  *) echo "usage: nightly-release-product.sh lookup|record" >&2; exit 2 ;;
esac
