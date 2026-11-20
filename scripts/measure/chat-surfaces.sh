#!/usr/bin/env bash
# Fleet entry for the chat surfaces before/after shots (scripts/cmux-next/chat-surfaces-shots.py, design/chat-surfaces.md):
# builds a tagged bench app at --before=SHA and at this checkout through app-at-commit.sh, and shoots one chat with every
# content surface (the edited-files card, the turn error card, a plan, a shell call, code, a table) in each window
# style, dark and light, in the console user's GUI session (scripts/ci/frame-pacing/console-session.sh):
#   cmux-ci run --class exclusive --measurement --label measure --target-worker aws-m4pro-7 --pin-strict \
#     --script scripts/measure/chat-surfaces.sh --ref <a feat-cmux-next sha with this script> \
#     --arg=--before=<base sha> --artifact artifacts/chat-surfaces/chat-surfaces.tar.gz
# The shot harness's test agent and the harness itself are this checkout's in both arms; only the app differs.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
. scripts/measure/app-at-commit.sh
out="$(pwd)/artifacts/chat-surfaces"
shots="$out/shots"
mkdir -p "$shots"
before="" args=()
for arg in "$@"; do
  case "$arg" in
    --before=*) before="${arg#--before=}" ;;
    *) args+=("$arg") ;;
  esac
done
[[ -n "$before" ]] || { echo "chat-surfaces: --before=SHA is required" >&2; exit 2; }
export CMUX_TUI_CLIENT_TARGET_DIR="${CI_SHARED_CACHE_DIR:-$(pwd)/cmux-tui/target}/chat-surfaces-cmux-tui-target"
scratch="$(mktemp -d)"
trap 'measure_remove_scratch "$scratch"' EXIT
after_app="$(measure_app_at_commit "$(git rev-parse HEAD)" chatsurfa "$scratch/after" --config bench)" \
  || { echo "chat-surfaces: the after app did not build" >&2; exit 1; }
before_app="$(measure_app_at_commit "$before" chatsurfb "$scratch/before" --config bench)" \
  || { echo "chat-surfaces: the before app did not build" >&2; exit 1; }
echo "chat-surfaces: before $before_app after $after_app"
status=0
GITHUB_WORKSPACE="$PWD" CMUX_BENCH_LAUNCH=direct scripts/ci/frame-pacing/console-session.sh \
  python3 -I "$PWD/scripts/cmux-next/chat-surfaces-shots.py" --app "before=$before_app" --app "after=$after_app" \
  --out "$shots" ${args[@]+"${args[@]}"} || status=$?
for app in "$before_app" "$after_app"; do python3 scripts/cmux-next/tag_teardown.py "$app" >/dev/null 2>&1 || true; done
rm -rf "$shots/.scratch"
tar -czf "$out/chat-surfaces.tar.gz" -C "$out" shots
echo "SHOTS=$([[ $status == 0 ]] && echo pass || echo fail) (chat-surfaces-shots exit $status)"
