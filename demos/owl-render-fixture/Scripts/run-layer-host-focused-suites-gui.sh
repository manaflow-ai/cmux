#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

OUT_ROOT="${OWL_LAYER_HOST_FOCUSED_OUT:-$ROOT_DIR/artifacts/layer-host-focused-gui-latest}"
RUN_SCRIPT="$SCRIPT_DIR/run-layer-host-verifier-gui.sh"

if [ "$#" -eq 0 ]; then
  suites=(render input resize lifecycle scale recovery file-picker scroll-text)
else
  suites=("$@")
fi

expanded_suites=()
for suite in "${suites[@]}"; do
  if [ "$suite" = "all" ]; then
    expanded_suites+=(render input resize lifecycle scale recovery file-picker scroll-text widgets google devtools)
  else
    expanded_suites+=("$suite")
  fi
done
suites=("${expanded_suites[@]}")

rm -rf "$OUT_ROOT"
mkdir -p "$OUT_ROOT"

if [ "${OWL_CHROMIUM_PATCH_CHECK:-1}" != "0" ]; then
  echo "== OWL Chromium source check =="
  "$SCRIPT_DIR/check-chromium-patch.sh" --mode applied | tee "$OUT_ROOT/chromium-patch-check.txt"
fi

run_suite() {
  local suite="$1"
  local out_dir="$OUT_ROOT/$suite"

  echo "== OWL focused suite: $suite =="
  case "$suite" in
    render)
      OWL_LAYER_HOST_RENDER_OUT="$out_dir" \
        "$RUN_SCRIPT"
      ;;
    input)
      OWL_LAYER_HOST_RENDER_OUT="$out_dir" \
      OWL_LAYER_HOST_INPUT_CHECK=1 \
      OWL_LAYER_HOST_INPUT_DIAGNOSTIC_CAPTURE=1 \
      OWL_LAYER_HOST_ONLY_TARGETS="input-fixture,form-fixture,modifier-fixture" \
        "$RUN_SCRIPT"
      ;;
    resize)
      OWL_LAYER_HOST_RENDER_OUT="$out_dir" \
      OWL_LAYER_HOST_INPUT_CHECK=1 \
      OWL_LAYER_HOST_INPUT_DIAGNOSTIC_CAPTURE=1 \
      OWL_LAYER_HOST_RESIZE_CHECK=1 \
      OWL_LAYER_HOST_ONLY_TARGETS="resize-small-fixture,resize-roundtrip-fixture" \
        "$RUN_SCRIPT"
      ;;
    lifecycle)
      OWL_LAYER_HOST_RENDER_OUT="$out_dir" \
      OWL_LAYER_HOST_INPUT_CHECK=1 \
      OWL_LAYER_HOST_INPUT_DIAGNOSTIC_CAPTURE=1 \
      OWL_LAYER_HOST_LIFECYCLE_CHECK=1 \
      OWL_LAYER_HOST_ONLY_TARGETS="lifecycle-fixture" \
        "$RUN_SCRIPT"
      ;;
    scale)
      OWL_LAYER_HOST_RENDER_OUT="$out_dir" \
      OWL_LAYER_HOST_INPUT_CHECK=1 \
      OWL_LAYER_HOST_INPUT_DIAGNOSTIC_CAPTURE=1 \
      OWL_LAYER_HOST_SCALE_CHECK=1 \
      OWL_LAYER_HOST_ONLY_TARGETS="scale-fixture" \
        "$RUN_SCRIPT"
      ;;
    recovery)
      OWL_LAYER_HOST_RENDER_OUT="$out_dir" \
      OWL_LAYER_HOST_RECOVERY_CHECK=1 \
      OWL_LAYER_HOST_ONLY_TARGETS="crash-recovery-fixture" \
        "$RUN_SCRIPT"
      ;;
    file-picker)
      OWL_LAYER_HOST_RENDER_OUT="$out_dir" \
      OWL_LAYER_HOST_INPUT_CHECK=1 \
      OWL_LAYER_HOST_INPUT_DIAGNOSTIC_CAPTURE=1 \
      OWL_LAYER_HOST_FILE_PICKER_CHECK=1 \
      OWL_LAYER_HOST_ONLY_TARGETS="file-picker-fixture" \
        "$RUN_SCRIPT"
      ;;
    devtools)
      OWL_LAYER_HOST_RENDER_OUT="$out_dir" \
      OWL_FRESH_ENABLE_DEVTOOLS=1 \
      OWL_LAYER_HOST_INPUT_CHECK=1 \
      OWL_LAYER_HOST_INPUT_DIAGNOSTIC_CAPTURE=1 \
      OWL_LAYER_HOST_DEVTOOLS_CHECK=1 \
      OWL_LAYER_HOST_ONLY_TARGETS="devtools-bottom-fixture,devtools-right-fixture,devtools-left-fixture,devtools-window-fixture" \
        "$RUN_SCRIPT"
      ;;
    scroll-text)
      OWL_LAYER_HOST_RENDER_OUT="$out_dir" \
      OWL_LAYER_HOST_INPUT_CHECK=1 \
      OWL_LAYER_HOST_INPUT_DIAGNOSTIC_CAPTURE=1 \
      OWL_LAYER_HOST_ONLY_TARGETS="scroll-fixture,text-edit-fixture" \
        "$RUN_SCRIPT"
      ;;
    widgets)
      OWL_LAYER_HOST_RENDER_OUT="$out_dir" \
      OWL_LAYER_HOST_INPUT_CHECK=1 \
      OWL_LAYER_HOST_INPUT_DIAGNOSTIC_CAPTURE=1 \
      OWL_LAYER_HOST_WIDGET_CHECK=1 \
      OWL_LAYER_HOST_ONLY_TARGETS="widget-fixture,plain-native-select-fixture,native-popup-fixture" \
        "$RUN_SCRIPT"
      ;;
    google)
      OWL_LAYER_HOST_RENDER_OUT="$out_dir" \
      OWL_LAYER_HOST_INPUT_CHECK=1 \
      OWL_LAYER_HOST_INPUT_DIAGNOSTIC_CAPTURE=1 \
      OWL_LAYER_HOST_GOOGLE_CHECK=1 \
      OWL_LAYER_HOST_ONLY_TARGETS="google-search" \
        "$RUN_SCRIPT"
      ;;
    *)
      echo "unknown focused suite: $suite" >&2
      echo "usage: $0 [all|render|input|resize|lifecycle|scale|recovery|file-picker|scroll-text|widgets|google|devtools ...]" >&2
      exit 2
      ;;
  esac

  if [ ! -f "$out_dir/summary.json" ]; then
    echo "missing summary after focused suite: $suite" >&2
    exit 1
  fi
}

for suite in "${suites[@]}"; do
  run_suite "$suite"
done

report="$OUT_ROOT/focused-suites.txt"
{
  echo "Focused OWL LayerHost suites"
  echo "Artifacts root: $OUT_ROOT"
  echo
  for suite in "${suites[@]}"; do
    suite_dir="$OUT_ROOT/$suite"
    echo "[$suite]"
    echo "summary: $suite_dir/summary.json"
    find "$suite_dir" -maxdepth 1 -type f -name "*.png" -print | sort | sed 's/^/png: /'
    find "$suite_dir" -maxdepth 1 -type f -name "*-mojo-dom-state.json" -print | sort | sed 's/^/dom: /'
    find "$suite_dir" -maxdepth 1 -type f -name "crash-recovery.json" -print | sort | sed 's/^/recovery: /'
    echo
  done
} > "$report"

cat "$report"
