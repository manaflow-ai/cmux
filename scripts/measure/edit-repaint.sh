#!/usr/bin/env bash
# Edit to repaint on a fleet Mac: builds a tagged cmux-next app (bench config: Release optimization with the
# debug.* control commands kept) at this checkout, then runs scripts/cmux-next/edit-repaint.py against it:
# a cmux-next.json theme edit, a cmux-next.json sidebar edit and a customize-folder extension save, each timed
# from the file write to the first window snapshot that shows the change (method in that script's docstring).
# Runs alone on the worker because it launches an app:
#   cmux-ci run --class exclusive --label measure --script scripts/measure/edit-repaint.sh --ref <sha> [--arg=--rounds=10]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
tag="editrepaint"
out="$(mktemp -d)"
reload_config=(--config bench) bench_args=()
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    *) bench_args+=("$arg") ;;
  esac
done
set -- ${bench_args[@]+"${bench_args[@]}"}
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" "${reload_config[@]}" 2>&1 | tee "$out/reload.log"
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
if [[ -z "$app" || ! -d "$app" ]]; then
  echo "edit-repaint: the tagged reload printed no app path" >&2
  grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 60 >&2 || true
  exit 1
fi
exec python3 scripts/cmux-next/edit-repaint.py --app "$app" --out "$out" --json "$PWD/edit-repaint.json" "$@"
