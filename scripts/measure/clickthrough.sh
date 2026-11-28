#!/usr/bin/env bash
# Fleet entry for the click-through check (scripts/cmux-next/clickthrough-live.py, #21729): builds a tagged
# cmux-next app at this checkout, then clicks through it the way a person does. It fails when a model, reasoning
# level or access mode does not stick (pass 1), or when a chat switch is slow, blank or shifts its layout (pass 2).
# Leo (ask-184fd85d1e): "when you pick a model and then you start a chat, like the model doesn't fucking switch.
# The reasoning doesn't fucking switch." A lane VM cannot reach a GUI Mac, so this is how one runs the check:
#   cmux-ci run --class exclusive --label measure --display --script scripts/measure/clickthrough.sh --ref <sha> \
#     --artifact .build/clickthrough/report.tgz --timeout 3600 [--arg=--passes=1] [--arg=--chats=12]
# Every argument goes to clickthrough-live.py, except --config=<debug|bench> (reload.sh's build configuration;
# release compiles out the debug.* commands the check drives). Exit: the check's own (0 every scenario passed),
# 3 when the build printed no app. results.md, results.json, switches.json and live.log go in report.tgz.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
tag="clickthru"
out=".build/clickthrough"
mkdir -p "$out"
rm -rf -- "$out/run" "$out/report.tgz"
# The report is written on every exit (a failed build, a failed scenario, a TERM), so a red run still shows why.
trap 'tar -czf "$out/report.tgz" -C "$out" --exclude report.tgz . 2>/dev/null || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
reload_config=() check_args=()
for arg in "$@"; do
  case "$arg" in
    --config=*) reload_config=(--config "${arg#--config=}") ;;
    *) check_args+=("$arg") ;;
  esac
done
CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" ${reload_config[@]+"${reload_config[@]}"} \
  > "$out/reload.log" 2>&1 || { echo "clickthrough: the tagged build failed"; grep -E "error:|BUILD FAILED" "$out/reload.log" | head -n 40; exit 3; }
app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
[[ -n "$app" && -d "$app" ]] || { echo "clickthrough: the tagged build printed no app path"; exit 3; }
echo "clickthrough: app $app"
set +e
python3 scripts/cmux-next/clickthrough-live.py --tag "$tag" --app "$app" --out "$out/run" \
  ${check_args[@]+"${check_args[@]}"} 2>&1 | tee "$out/run.log"
rc=${PIPESTATUS[0]}
set -e
[[ -f "$out/run/results.md" ]] && cat "$out/run/results.md"
exit "$rc"
