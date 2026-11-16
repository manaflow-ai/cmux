#!/usr/bin/env bash
# The chat-open bench's seed with the acpmux that the app's bundle has, on a Mac. No app and no display.
#   cmux-ci run --class light --script scripts/ci/chat-open-seed-proof.sh --ref SHA --os macos
# Builds acpmux as the app's bundle has it (scripts/cmux-next/build-acpmux.sh: a release build with the
# shipping features of scripts/ci/acpmux-build-features.sh) and runs
# scripts/cmux-next/chat_open_seed_proof.py with that binary: the bench's subagent chat alone, after the
# bench's small chat, and with its 2 later turns after the chat's first checkpoint. For each case the proof
# prints the binary's path, its --version line and the python3 version, then what the daemon stored.
# A proof run on a branch that never merges: the printed lines are the result.
# Output: SEED-PROOF lines; files under .build/chat-open-seed-proof.
# Exit: the proof script's (0 each subagent is stored in each case; 1 not; 2 a chat was not made);
# 3 when acpmux did not build.
set -euo pipefail
[[ $# -eq 0 ]] || { echo "chat-open-seed-proof.sh: takes no argument" >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
cd "$root"
work="$root/.build/chat-open-seed-proof"
rm -rf "$work"
mkdir -p "$work/bin"
echo "SEED-PROOF-MACHINE macos=$(sw_vers -productVersion 2>/dev/null || uname -sr) arch=$(uname -m) rev=$(git rev-parse HEAD) python3=$(command -v python3 || echo none) ($(python3 --version 2>&1 || true))"

# The build scripts run Cargo only on a build host; this step is one. The step's checkout has empty
# submodules; cmux-tui crates build libghostty-vt from ghostty-next.
export CI=1
git submodule update --init --depth 1 ghostty-next
scripts/cmux-next/build-acpmux.sh --output "$work/bin/acpmux" || { echo "SEED-PROOF acpmux did not build (exit $?)" >&2; exit 3; }
if [[ -f "$work/bin/acpmux.ref" ]]; then
  echo "SEED-PROOF-BIN $work/bin/acpmux: $(tr '\n' ' ' <"$work/bin/acpmux.ref")"
else
  echo "SEED-PROOF-BIN $work/bin/acpmux: no .ref file beside it"
fi
status=0
python3 scripts/cmux-next/chat_open_seed_proof.py --acpmux "$work/bin/acpmux" || status=$?
echo "SEED-PROOF-STEP exit $status"
exit "$status"
