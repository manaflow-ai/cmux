#!/usr/bin/env bash
# Pack and unpack the compiled app-host test products that CI passes between
# jobs. The archive is an Apple Archive compressed with LZFSE: /usr/bin/aa
# ships with macOS and compresses on every core, where `tar -z` uses one.
#
# Symbolic links are preserved. A link is portable when its target is relative
# and has no `..` component, because such a link can only resolve below its own
# directory and therefore inside Build/Products. `pack` replaces every other
# resolvable link (absolute, or climbing with `..`) with a copy of its target,
# in place, so the archive never depends on files outside the archived tree.
# Dangling unportable links are dropped because they cannot be useful to the
# restored product and could resolve against paths on the consuming runner.
set -euo pipefail

ARCHIVE_SUBDIR="Build/Products"

usage() {
  cat >&2 <<'EOF'
usage: app-host-products-archive.sh pack DERIVED_DATA ARCHIVE
       app-host-products-archive.sh list ARCHIVE
       app-host-products-archive.sh unpack ARCHIVE DESTINATION

pack    archives DERIVED_DATA/Build/Products into ARCHIVE
list    prints the archive entries as JSON without extracting anything
unpack  extracts Build/Products below DESTINATION
EOF
  exit 64
}

die() {
  echo "app-host-products-archive: $*" >&2
  exit 1
}

require_aa() {
  command -v aa >/dev/null 2>&1 || die "aa (Apple Archive) is required and ships only with macOS"
}

is_portable_link_target() {
  case "$1" in
    ""|/*|..|../*|*/..|*/../*) return 1 ;;
  esac
  return 0
}

materialize_unportable_links() {
  local root="$1" links link target copy
  links="$(mktemp "${TMPDIR:-/tmp}/app-host-products-links.XXXXXX")"
  find "$root" -type l -print0 > "$links"
  while IFS= read -r -d '' link; do
    # An earlier copy may already have replaced a parent of this link.
    [ -L "$link" ] || continue
    target="$(readlink "$link")"
    if is_portable_link_target "$target"; then
      continue
    fi
    if [ ! -e "$link" ]; then
      echo "app-host-products-archive: dropping dangling unportable link $link -> $target" >&2
      rm "$link"
      continue
    fi
    echo "app-host-products-archive: copying link target into the products: $link -> $target" >&2
    copy="$link.materialize.$$"
    rm -rf "$copy"
    cp -RL "$link" "$copy"
    rm "$link"
    mv "$copy" "$link"
  done < "$links"
  rm -f "$links"
}

pack() {
  local derived="$1" archive="$2" root
  root="$derived/$ARCHIVE_SUBDIR"
  [ -d "$root" ] || die "missing products directory: $root"
  [ ! -L "$root" ] || die "products directory must not be a symbolic link: $root"
  require_aa
  materialize_unportable_links "$root"
  rm -f "$archive"
  # Owner ids are omitted so extraction never needs to chown on another runner.
  aa archive -d "$derived" -subdir "$ARCHIVE_SUBDIR" -o "$archive" -a lzfse -exclude-field uid,gid \
    || die "aa archive failed for $root"
  [ -s "$archive" ] || die "aa archive produced an empty archive: $archive"
}

list() {
  local archive="$1"
  [ -f "$archive" ] || die "missing archive: $archive"
  require_aa
  aa list -i "$archive" -list-format json || die "aa list failed for $archive"
}

unpack() {
  local archive="$1" destination="$2"
  [ -f "$archive" ] || die "missing archive: $archive"
  require_aa
  mkdir -p "$destination"
  [ ! -e "$destination/$ARCHIVE_SUBDIR" ] || die "destination already has products: $destination/$ARCHIVE_SUBDIR"
  aa extract -d "$destination" -i "$archive" || die "aa extract failed for $archive"
  [ -d "$destination/$ARCHIVE_SUBDIR" ] || die "archive did not contain $ARCHIVE_SUBDIR"
}

[ "$#" -ge 1 ] || usage
command_name="$1"
shift
case "$command_name" in
  pack) [ "$#" -eq 2 ] || usage; pack "$1" "$2" ;;
  list) [ "$#" -eq 1 ] || usage; list "$1" ;;
  unpack) [ "$#" -eq 2 ] || usage; unpack "$1" "$2" ;;
  *) usage ;;
esac
