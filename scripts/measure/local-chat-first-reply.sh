#!/usr/bin/env bash
# Local chat select to first reply on a fresh build of a commit (goal local-instant-start): the timed chat of
# cmuxterm-hq's synthetic probe `local-chat` (tools/fleet-reconcilers/local_chat_probe.py), which only times the
# published NIGHTLY on one owner-only runner, here on a fleet Mac at any commit, so a pull request's number is known
# before it ships. Driver: scripts/measure/local_chat_first_reply.py (its module text says the flow).
#   cmux-ci run --class exclusive --measurement --label measure --display \
#     --script scripts/measure/local-chat-first-reply.sh --ref <feat-cmux-next sha> \
#     --arg=base_url=http://100.120.48.119:4016 [--arg=build=SHA] [--arg=rounds=5] [--arg=model=claude-haiku-5-5] \
#     [--arg=claude=2.1.325] --artifact artifacts/local-chat-first-reply.json --timeout 5400
# base_url= is a Claude route that needs no credential (a router that signs requests itself, SR2): Claude Code gets
# only that base URL and a placeholder key, so no credential reaches the worker (as chief-latency.sh).
# build=SHA builds the app at SHA (a pull request's head) with that commit's own reload.sh (app-at-commit.sh); without
# it, this checkout's. The bench configuration: Release optimization with the debug.* control methods kept.
# Output: LOCAL-CHAT-FIRST-REPLY {json} (p50 of select_to_first_text_ms, stage and turn-mark p50s) and
# artifacts/local-chat-first-reply.json (every round).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
. scripts/measure/app-at-commit.sh
base_url="" build="" rounds=5 model="claude-haiku-5-5" claude_version="2.1.325"
for arg in "$@"; do
  case "$arg" in
    base_url=*) base_url="${arg#base_url=}" ;;
    build=*) build="${arg#build=}" ;;
    rounds=*) rounds="${arg#rounds=}" ;;
    model=*) model="${arg#model=}" ;;
    claude=*) claude_version="${arg#claude=}" ;;
    *) echo "local-chat-first-reply.sh: unknown argument $arg" >&2; exit 2 ;;
  esac
done
[[ "$base_url" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]] || { echo "local-chat-first-reply.sh: base_url=http://HOST[:PORT] is required" >&2; exit 2; }
[[ -z "$build" || "$build" =~ ^[0-9a-f]{7,40}$ ]] || { echo "local-chat-first-reply.sh: build=SHA" >&2; exit 2; }
[[ "$rounds" =~ ^([1-9]|1[0-9]|20)$ ]] || { echo "local-chat-first-reply.sh: rounds=1..20" >&2; exit 2; }
[[ "$model" =~ ^[A-Za-z0-9._/-]{1,80}$ ]] || { echo "local-chat-first-reply.sh: model=NAME" >&2; exit 2; }
[[ "$claude_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "local-chat-first-reply.sh: claude=X.Y.Z" >&2; exit 2; }
[[ "$(uname -s)" == Darwin ]] || { echo "local-chat-first-reply.sh: runs on a Mac" >&2; exit 2; }
out="$(mktemp -d)"
trap 'measure_remove_scratch "$out"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
echo "LOCAL-CHAT-MACHINE host=$(scutil --get ComputerName 2>/dev/null || hostname) cores=$(sysctl -n hw.ncpu) macos=$(sw_vers -productVersion) harness_rev=$(git rev-parse HEAD) build=${build:-harness} model=$model rounds=$rounds"
curl -fsS -m 10 -o /dev/null "$base_url/_subrouter/ready" || { echo "local-chat-first-reply: the route $base_url is not reachable from this worker" >&2; exit 1; }
# Ready says nothing about Claude: one tiny real request, else stop before the build.
python3 -I Native/OptChat/optchat-chief/measure/first_turn_cost.py probe --url "$base_url" \
  || { echo "local-chat-first-reply: the route $base_url does not answer Claude requests" >&2; exit 1; }

# Claude Code at the pinned version (the native build, checked against the release manifest).
dl="https://downloads.claude.ai/claude-code-releases/$claude_version"
curl -fsSL --proto '=https' -m 60 "$dl/manifest.json" -o "$out/claude-manifest.json"
want="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["platforms"]["darwin-arm64"]["checksum"])' "$out/claude-manifest.json")"
curl -fsSL --proto '=https' -m 600 "$dl/darwin-arm64/claude" -o "$out/claude"
[[ "$(shasum -a 256 "$out/claude" | awk '{print $1}')" == "$want" ]] || { echo "local-chat-first-reply: claude $claude_version sha256 mismatch" >&2; exit 1; }
chmod 755 "$out/claude"

tag="lcfirst"
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
if [[ -n "$build" ]]; then
  app="$(measure_app_at_commit "$build" "$tag" "$out/at" --config bench)"
  ref="$build"
else
  CMUX_DEV_BACKEND_MODE=local ./scripts/reload.sh --tag "$tag" --config bench 2>&1 | tee "$out/reload.log"
  app="$(sed -n '/^App path:/{n;s/^ *//;p;}' "$out/reload.log" | tail -n 1)"
  ref="$(git rev-parse HEAD)"
fi
[[ -n "$app" && -d "$app" ]] || { echo "local-chat-first-reply: the build printed no app path" >&2; exit 1; }
echo "LOCAL-CHAT-BUILD ref=$ref app=$app"
mkdir -p artifacts
CMUX_BENCH_LAUNCH=direct python3 scripts/measure/local_chat_first_reply.py --app "$app" --base-url "$base_url" \
  --claude "$out/claude" --model "$model" --rounds "$rounds" --ref "$ref" --json artifacts/local-chat-first-reply.json
