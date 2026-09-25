#!/usr/bin/env bash
set -euo pipefail

base_url="${1:-${CMUX_SOCIAL_IMAGE_BASE_URL:-}}"
if [[ -z "$base_url" ]]; then
  echo "Usage: $0 <base-url>" >&2
  exit 2
fi
base_url="${base_url%/}"

scratch_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-social-images.XXXXXX")"
cleanup() {
  rm -rf -- "$scratch_dir"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

url_on_test_origin() {
  local advertised_url="$1"
  local path_and_query

  advertised_url="${advertised_url//&amp;/&}"
  case "$advertised_url" in
    http://*|https://*)
      path_and_query="${advertised_url#*://}"
      path_and_query="/${path_and_query#*/}"
      ;;
    /*)
      path_and_query="$advertised_url"
      ;;
    *)
      fail "social image URL is neither absolute nor root-relative: $advertised_url"
      ;;
  esac

  printf '%s%s\n' "$base_url" "$path_and_query"
}

advertised_image_url() {
  local html_file="$1"
  local metadata_key="$2"
  local meta_tag
  local image_url

  meta_tag="$(
    grep -oE '<meta[^>]+>' "$html_file" |
      grep -E "(property|name)=\"${metadata_key}\"" |
      head -n 1 || true
  )"
  [[ -n "$meta_tag" ]] ||
    fail "served HTML does not advertise ${metadata_key}"

  image_url="$(printf '%s\n' "$meta_tag" | sed -nE 's/.*content="([^"]+)".*/\1/p')"
  [[ -n "$image_url" ]] ||
    fail "${metadata_key} metadata has no content URL: $meta_tag"

  printf '%s\n' "$image_url"
}

assert_direct_png() {
  local label="$1"
  local image_url="$2"
  local headers_file="$scratch_dir/headers-${RANDOM}.txt"
  local status
  local content_type

  if ! curl --silent --show-error --head --max-redirs 0 \
    --dump-header "$headers_file" --output /dev/null "$image_url"; then
    fail "${label} could not be fetched: $image_url"
  fi

  status="$(
    awk '/^HTTP\// { value = $2 } END { print value }' "$headers_file"
  )"
  content_type="$(
    awk '
      tolower($1) == "content-type:" {
        value = tolower($2)
        sub(/\r$/, "", value)
      }
      END { print value }
    ' "$headers_file"
  )"

  if [[ "$status" != "200" ]]; then
    cat "$headers_file" >&2
    fail "${label} returned HTTP ${status:-unknown}, expected 200: $image_url"
  fi
  if [[ "$content_type" != "image/png" ]]; then
    cat "$headers_file" >&2
    fail "${label} returned ${content_type:-no content-type}, expected image/png: $image_url"
  fi
  if grep -Eiq '^location:' "$headers_file"; then
    cat "$headers_file" >&2
    fail "${label} returned a Location header: $image_url"
  fi

  echo "PASS: ${label} -> HTTP 200 image/png with no redirect"
}

for page_path in "/" "/ja"; do
  html_file="$scratch_dir/page-${page_path//\//_}.html"
  page_url="${base_url}${page_path}"
  curl --silent --show-error --fail --max-redirs 0 \
    --output "$html_file" "$page_url" ||
    fail "could not fetch served HTML: $page_url"

  for metadata_key in "og:image" "twitter:image"; do
    advertised_url="$(advertised_image_url "$html_file" "$metadata_key")"
    image_url="$(url_on_test_origin "$advertised_url")"
    assert_direct_png "${page_path} ${metadata_key}" "$image_url"
  done
done

# Link-preview services can cache metadata independently from the page HTML.
# Keep the exact URL reported in #7865 working while those caches expire.
assert_direct_png \
  "legacy advertised og:image" \
  "${base_url}/en/opengraph-image-e6it15?f656b4354be9c5cd"
