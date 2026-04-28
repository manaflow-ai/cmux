#!/usr/bin/env bash
set -euo pipefail

# Interactive Kitty Graphics Protocol gallery for cmux/Ghostty verification.
# Downloads cat photos over HTTPS, converts them to PNG, then renders them.

cache_dir="${TMPDIR:-/tmp}/cmux-kitty-image-demo"

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
  "https://commons.wikimedia.org/wiki/Special:Redirect/file/White%20Cat.jpg?width=640"
  "https://commons.wikimedia.org/wiki/Special:Redirect/file/Black_barn_cat_-_Public_Domain.jpg?width=960"
  "https://commons.wikimedia.org/wiki/Special:Redirect/file/Cat_public_domain_dedication_image_0002.jpg?width=960"
)

sources=(
  "https://commons.wikimedia.org/wiki/File:White_Cat.jpg"
  "https://commons.wikimedia.org/wiki/File:Black_barn_cat_-_Public_Domain.jpg"
  "https://commons.wikimedia.org/wiki/File:Cat_public_domain_dedication_image_0002.jpg"
)

clear_screen() {
  printf '\033[2J\033[H'
}

delete_images() {
  printf '\033_Ga=d;\033\\'
}

download_images() {
  mkdir -p "$cache_dir"

  for i in "${!urls[@]}"; do
    local file="$cache_dir/${files[$i]}"
    local png="$cache_dir/${files[$i]%.*}.png"
    local tmp="$file.tmp"

    printf 'Downloading %s\n' "${urls[$i]}"
    if curl -LfsS --retry 2 --connect-timeout 10 "${urls[$i]}" -o "$tmp"; then
      mv "$tmp" "$file"
    else
      rm -f "$tmp"
      if [[ ! -s "$file" ]]; then
        printf 'Failed to download %s\n' "${urls[$i]}" >&2
        return 1
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

render_image() {
  local i="$1"
  local file="$cache_dir/${files[$i]%.*}.png"
  local data
  data="$(image_data "$file")"

  clear_screen
  delete_images
  printf 'cmux Kitty graphics protocol gallery\n'
  printf 'TERM=%s TERM_PROGRAM=%s\n\n' "${TERM:-}" "${TERM_PROGRAM:-}"
  printf 'Image %d/%d: %s\n' "$((i + 1))" "${#names[@]}" "${names[$i]}"
  printf 'Downloaded from: %s\n' "${urls[$i]}"
  printf 'Source page: %s\n' "${sources[$i]}"
  printf 'Cached at: %s\n\n' "$file"
  printf '\033_Ga=T,f=100,i=%d,c=48,r=16,q=2;%s\033\\' "$((i + 1))" "$data"
  printf '\n\nn next  p previous  a all  r refetch  q quit\n'
}

render_all() {
  clear_screen
  delete_images
  printf 'cmux Kitty graphics protocol gallery\n'
  printf 'TERM=%s TERM_PROGRAM=%s\n\n' "${TERM:-}" "${TERM_PROGRAM:-}"
  printf 'Expected: three downloaded cat photos rendered below.\n\n'

  for i in "${!names[@]}"; do
    local file="$cache_dir/${files[$i]%.*}.png"
    local data
    data="$(image_data "$file")"

    printf '%d. %s\n' "$((i + 1))" "${names[$i]}"
    printf '   %s\n' "${sources[$i]}"
    printf '\033_Ga=T,f=100,i=%d,c=38,r=11,q=2;%s\033\\' "$((i + 1))" "$data"
    printf '\n\n'
  done

  printf 'n next  p previous  a all  r refetch  q quit\n'
}

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
