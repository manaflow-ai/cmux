#!/usr/bin/env bash
set -euo pipefail

# Interactive Kitty Graphics Protocol gallery for cmux/Ghostty verification.
# Downloads cat photos over HTTPS, converts them to PNG, then renders them.

cache_dir="${TMPDIR:-/tmp}/cmux-kitty-image-demo"
curl_user_agent="cmux-kitty-image-demo/1.0 (https://github.com/manaflow-ai/cmux)"

names=(
  "White Cat"
  "Black Barn Cat"
  "Tabby Cat"
)

files=(
  "white-cat.jpg"
  "black-barn-cat.jpg"
  "tabby-cat.jpg"
)

urls=(
  "https://upload.wikimedia.org/wikipedia/commons/c/c3/White_Cat.jpg"
  "https://upload.wikimedia.org/wikipedia/commons/thumb/a/a1/Black_barn_cat_-_Public_Domain.jpg/960px-Black_barn_cat_-_Public_Domain.jpg"
  "https://upload.wikimedia.org/wikipedia/commons/thumb/a/a5/Cat_public_domain_dedication_image_0002.jpg/960px-Cat_public_domain_dedication_image_0002.jpg"
)

sources=(
  "https://commons.wikimedia.org/wiki/File:White_Cat.jpg"
  "https://commons.wikimedia.org/wiki/File:Black_barn_cat_-_Public_Domain.jpg"
  "https://commons.wikimedia.org/wiki/File:Cat_public_domain_dedication_image_0002.jpg"
)

fallback_pngs=(
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg=="
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgoB8AAABaAAGAMoP7AAAAAElFTkSuQmCC"
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGOQY2D4DwABBAEAghoZbQAAAABJRU5ErkJggg=="
)

download_only=0

usage() {
  printf 'Usage: %s [--download-only]\n' "$0"
}

case "${1:-}" in
  "")
    ;;
  --download-only)
    download_only=1
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

clear_screen() {
  printf '\033[2J\033[H'
}

enter_alternate_screen() {
  printf '\033[?1049h'
}

leave_alternate_screen() {
  printf '\033[?1049l'
}

delete_images() {
  printf '\033_Ga=d;\033\\'
}

decode_base64() {
  if base64 --help 2>&1 | grep -q -- '--decode'; then
    base64 --decode
  else
    base64 -D
  fi
}

supports_kitty_graphics() {
  case "${TERM_PROGRAM:-}" in
    ghostty|WezTerm)
      return 0
      ;;
  esac

  case "${TERM:-}" in
    xterm-kitty)
      return 0
      ;;
  esac

  [[ -n "${KITTY_WINDOW_ID:-}" ]]
}

download_images() {
  mkdir -p "$cache_dir"

  for i in "${!urls[@]}"; do
    local file="$cache_dir/${files[$i]}"
    local png="$cache_dir/${files[$i]%.*}.png"
    local tmp="$file.tmp"

    printf 'Downloading %s\n' "${urls[$i]}"
    if curl -LfsS --retry 2 --connect-timeout 10 -A "$curl_user_agent" "${urls[$i]}" -o "$tmp"; then
      mv "$tmp" "$file"
    else
      rm -f "$tmp"
      if [[ ! -s "$file" ]]; then
        printf 'Download failed for %s; using embedded fallback image.\n' "${names[$i]}" >&2
        printf '%s' "${fallback_pngs[$i]}" | decode_base64 > "$png"
        continue
      fi
      printf 'Using cached copy for %s\n' "${names[$i]}"
    fi

    if command -v sips >/dev/null 2>&1; then
      sips -s format png "$file" --out "$png" >/dev/null
    else
      printf 'sips is required to convert %s to PNG\n' "$file" >&2
      return 1
    fi
  done
}

image_data() {
  base64 < "$1" | tr -d '\n'
}

copy_text() {
  if command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$1" | pbcopy
    printf 'Copied to clipboard: %s\n' "$1"
  else
    printf 'pbcopy is not available. Value: %s\n' "$1" >&2
  fi
}

open_image() {
  local file="$1"

  if command -v open >/dev/null 2>&1; then
    open "$file"
  else
    printf 'open is not available. File: %s\n' "$file" >&2
  fi
}

reveal_image() {
  local file="$1"

  if command -v open >/dev/null 2>&1; then
    open -R "$file"
  else
    printf 'open is not available. File: %s\n' "$file" >&2
  fi
}

current_png() {
  local i="$1"
  printf '%s/%s.png' "$cache_dir" "${files[$i]%.*}"
}

print_controls() {
  printf 'n next  p previous  a all  o open  f finder  c copy path  u copy URL  r refetch  q quit\n'
}

render_image() {
  local i="$1"
  local file
  local data
  file="$(current_png "$i")"
  data="$(image_data "$file")"

  clear_screen
  delete_images
  printf 'cmux Kitty graphics protocol gallery\n'
  printf 'TERM=%s TERM_PROGRAM=%s\n\n' "${TERM:-}" "${TERM_PROGRAM:-}"
  printf 'Image %d/%d: %s\n' "$((i + 1))" "${#names[@]}" "${names[$i]}"
  printf 'Downloaded from: %s\n' "${urls[$i]}"
  printf 'Source page: %s\n' "${sources[$i]}"
  printf 'Cached at: %s\n\n' "$file"
  printf '\033_Ga=T,f=100,i=%d,c=48,r=16,q=1;%s\033\\' "$((i + 1))" "$data"
  printf '\n\n'
  print_controls
}

render_all() {
  clear_screen
  delete_images
  printf 'cmux Kitty graphics protocol gallery\n'
  printf 'TERM=%s TERM_PROGRAM=%s\n\n' "${TERM:-}" "${TERM_PROGRAM:-}"
  printf 'Expected: three downloaded cat photos rendered below.\n\n'

  for i in "${!names[@]}"; do
    local file
    local data
    file="$(current_png "$i")"
    data="$(image_data "$file")"

    printf '%d. %s\n' "$((i + 1))" "${names[$i]}"
    printf '   %s\n' "${sources[$i]}"
    printf '\033_Ga=T,f=100,i=%d,c=38,r=11,q=1;%s\033\\' "$((i + 1))" "$data"
    printf '\n\n'
  done

  print_controls
}

if (( download_only )); then
  download_images
  printf 'Downloaded and converted %d images into %s\n' "${#names[@]}" "$cache_dir"
  exit 0
fi

if [[ ! -t 1 ]]; then
  printf 'kitty-image-demo: stdout is not a TTY; use --download-only to test downloads.\n' >&2
  exit 0
fi

if ! supports_kitty_graphics; then
  printf 'kitty-image-demo: this terminal does not advertise Kitty graphics support.\n' >&2
  printf 'Run inside cmux/Ghostty, WezTerm, or kitty.\n' >&2
  exit 1
fi

enter_alternate_screen
trap 'delete_images; leave_alternate_screen' EXIT

clear_screen
printf 'cmux Kitty graphics protocol gallery\n'
printf 'Downloading cat photos into %s\n\n' "$cache_dir"
download_images
render_all

if [[ ! -t 0 ]]; then
  exit 0
fi

index=0
while IFS= read -rsn1 key; do
  case "$key" in
    n|" ")
      index=$(((index + 1) % ${#names[@]}))
      render_image "$index"
      ;;
    p)
      index=$(((index + ${#names[@]} - 1) % ${#names[@]}))
      render_image "$index"
      ;;
    a)
      render_all
      ;;
    o)
      open_image "$(current_png "$index")"
      ;;
    f)
      reveal_image "$(current_png "$index")"
      ;;
    c)
      copy_text "$(current_png "$index")"
      ;;
    u)
      copy_text "${sources[$index]}"
      ;;
    r)
      clear_screen
      printf 'Refetching internet PNGs into %s\n\n' "$cache_dir"
      download_images
      render_all
      ;;
    q)
      printf '\n'
      exit 0
      ;;
  esac
done
