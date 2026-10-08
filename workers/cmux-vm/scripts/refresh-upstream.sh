#!/usr/bin/env bash
# Refreshes the pinned upstream surface in upstream/ from public sources only
# (no key): the unauthenticated OpenAPI document and the latest SDK/CLI npm
# package's type declarations. Rewrites upstream/PINNED.json only when a file
# changed, so a run with no upstream change leaves the tree clean.
#
#   bash scripts/refresh-upstream.sh      # exit 0; prints "changed" or "unchanged"
#
# Needs curl, jq, tar and sha256sum (Linux CI).
set -euo pipefail
cd "$(dirname "$0")/.."

pinned=upstream/PINNED.json
openapi_url="$(jq -r .openapi.url "$pinned")"
package="$(jq -r .sdk.package "$pinned")"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl -fsSL --retry 3 --max-time 60 -o "$work/openapi.json" "$openapi_url"
jq -e '.openapi and .paths' "$work/openapi.json" >/dev/null

curl -fsSL --retry 3 --max-time 60 -o "$work/meta.json" "https://registry.npmjs.org/${package}/latest"
version="$(jq -r .version "$work/meta.json")"
# The version names the PR branch; accept plain semver only.
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
  echo "unexpected ${package} version: ${version}" >&2
  exit 1
fi
tarball="$(jq -r .dist.tarball "$work/meta.json")"
integrity="$(jq -r .dist.integrity "$work/meta.json")"
license="$(jq -r .license "$work/meta.json")"
curl -fsSL --retry 3 --max-time 120 -o "$work/package.tgz" "$tarball"

# Verify the registry's integrity (sha512, base64) before extracting anything.
expected="${integrity#sha512-}"
actual="$(openssl dgst -sha512 -binary "$work/package.tgz" | base64 -w0)"
if [ "$expected" != "$actual" ]; then
  echo "tarball integrity mismatch for ${package}@${version}" >&2
  exit 1
fi

# Only regular files and directories: a symlink or hard link in the archive
# could point the copy below at files outside it (for example .git/config).
if tar -tvzf "$work/package.tgz" | grep -qv '^[-d]'; then
  echo "${package}@${version} tarball contains links or special files; refusing it" >&2
  exit 1
fi
mkdir -p "$work/extract" "$work/sdk"
tar -xzf "$work/package.tgz" -C "$work/extract" --no-same-owner --no-same-permissions
# Type declarations under dist/ and package.json, byte for byte; nothing executable.
(cd "$work/extract/package/dist" && find . -name '*.d.ts' -type f ! -type l -print0 | while IFS= read -r -d '' file; do
  mkdir -p "$work/sdk/$(dirname "$file")"
  cp "$file" "$work/sdk/$file"
done)
cp "$work/extract/package/package.json" "$work/sdk/package.json"

changed=0
if ! cmp -s "$work/openapi.json" upstream/openapi.json; then changed=1; fi
if ! diff -r -q "$work/sdk" upstream/sdk >/dev/null; then changed=1; fi

if [ "$changed" -eq 0 ]; then
  echo "unchanged"
  exit 0
fi

cp "$work/openapi.json" upstream/openapi.json
rm -rf upstream/sdk
cp -R "$work/sdk" upstream/sdk

operations="$(jq '[.paths[] | to_entries[] | select(.key | test("^(get|put|post|delete|patch|head|options|trace)$"))] | length' upstream/openapi.json)"
jq --arg fetchedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
   --arg sha "$(sha256sum upstream/openapi.json | cut -d' ' -f1)" \
   --arg openapiVersion "$(jq -r .openapi upstream/openapi.json)" \
   --arg infoVersion "$(jq -r .info.version upstream/openapi.json)" \
   --argjson operations "$operations" \
   --arg version "$version" --arg license "$license" --arg tarball "$tarball" \
   --arg tarballSha "$(sha256sum "$work/package.tgz" | cut -d' ' -f1)" --arg integrity "$integrity" \
   '.fetchedAt = $fetchedAt
    | .openapi.sha256 = $sha | .openapi.openapiVersion = $openapiVersion | .openapi.infoVersion = $infoVersion
    | .openapi.operations = $operations
    | .sdk.version = $version | .sdk.license = $license | .sdk.tarball = $tarball
    | .sdk.tarballSha256 = $tarballSha | .sdk.integrity = $integrity' \
   "$pinned" > "$work/pinned.json"
cp "$work/pinned.json" "$pinned"
echo "changed"
