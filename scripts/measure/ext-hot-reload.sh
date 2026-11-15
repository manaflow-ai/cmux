#!/usr/bin/env bash
# Extension hot reload on a fleet Mac: builds a tagged cmux-next app at this checkout (bench config: Release
# optimization with the debug.* control commands kept; `--config=release` builds the configuration a nightly
# ships), then runs scripts/cmux-next/ext-hot-reload.py against it: an installed customize-folder extension,
# saved with each editor write pattern, read back from the running app (`apps.views`) after every save.
# Runs alone on the worker because it launches an app:
#   cmux-ci run --class exclusive --label measure --script scripts/measure/ext-hot-reload.sh --ref <sha>
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
tag="exthotreload"
out="$(mktemp -d)"
reload_config=(--config bench) test_args=()
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    *) test_args+=("$arg") ;;
  esac
done
set -- ${test_args[@]+"${test_args[@]}"}
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" "${reload_config[@]}" 2>&1 | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "ext-hot-reload: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
exec python3 scripts/cmux-next/ext-hot-reload.py --app "$app" --out "$out" --json "$PWD/ext-hot-reload.json" "$@"
