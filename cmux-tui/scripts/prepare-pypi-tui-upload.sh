#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'prepare-pypi-tui-upload: %s\n' "$*" >&2
  exit 1
}

if [[ $# -ne 3 ]]; then
  die "usage: $0 WHEELS_DIR UPLOAD_DIR VERSION"
fi

wheels_dir="$1"
upload_dir="$2"
version="$3"
: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"

[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] ||
  die "version must match X.Y.Z"
[[ -d "$wheels_dir" ]] || die "missing wheel directory: $wheels_dir"
mkdir -p "$upload_dir"
if [[ -n "$(find "$upload_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  die "upload directory must start empty: $upload_dir"
fi

shopt -s nullglob
wheels=("$wheels_dir"/*.whl)
[[ "${#wheels[@]}" == 6 ]] ||
  die "expected six wheels, found ${#wheels[@]}"

allowed_args=()
for wheel in "${wheels[@]}"; do
  allowed_args+=(--allowed-artifact "$wheel")
done

temp_root="${RUNNER_TEMP:-${TMPDIR:-/tmp}}"
mkdir -p "$temp_root"
status_root="$(mktemp -d "$temp_root/cmux-tui-pypi-status.XXXXXX")"
trap 'rm -rf "$status_root"' EXIT

has_new=false
for wheel in "${wheels[@]}"; do
  status_file="$status_root/$(basename "$wheel").output"
  : > "$status_file"
  if ! GITHUB_OUTPUT="$status_file" python3 cmux-tui/bindings/reconcile_registry_artifact.py check \
    --registry pypi \
    --package cmux \
    --version "$version" \
    --artifact "$wheel" \
    "${allowed_args[@]}" \
    --wait-seconds 120 \
    --write-github-output \
    --github-output-name status; then
    die "could not prove the PyPI state for $(basename "$wheel"); refusing to publish"
  fi

  status="$(awk -F= '$1 == "status" { value = $2 } END { print value }' "$status_file")"
  case "$status" in
    match)
      printf 'already published exact PyPI wheel: %s\n' "$(basename "$wheel")"
      ;;
    missing)
      cp -- "$wheel" "$upload_dir/"
      has_new=true
      printf 'staging new PyPI wheel: %s\n' "$(basename "$wheel")"
      ;;
    *)
      die "reconciler returned invalid status '$status' for $(basename "$wheel")"
      ;;
  esac
done

printf 'has_new=%s\n' "$has_new" >> "$GITHUB_OUTPUT"
