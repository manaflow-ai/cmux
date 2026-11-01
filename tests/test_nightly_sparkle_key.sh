#!/usr/bin/env bash
# Regression coverage for scripts/ci/nightly-sparkle-key.sh: which Sparkle key
# a nightly build embeds and signs with.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PICK="$ROOT_DIR/scripts/ci/nightly-sparkle-key.sh"
WORKFLOW="$ROOT_DIR/.github/workflows/nightly.yml"

expect() {
  # expect <want> <selector> <channel> [nightly-key]
  local want="$1" got
  got="$(NIGHTLY_SPARKLE_KEY="$2" CHANNEL="$3" SHARED_SPARKLE_PRIVATE_KEY=shared \
    NIGHTLY_SPARKLE_PRIVATE_KEY="${4-nightly}" "$PICK" 2>/dev/null)" || got="<error>"
  if [ "$got" != "$want" ]; then
    echo "FAIL: selector='$2' channel=$3 picked '$got', want '$want'"
    exit 1
  fi
}

expect shared    ""      nightly
expect nightly   nightly nightly
# The rc channel never moves.
expect shared    nightly rc
# Selecting the nightly key without the secret fails instead of falling back.
expect "<error>" nightly nightly ""
expect "<error>" typo    nightly

# The cmux-next track signs only with its own key and never falls back.
got="$(TRACK=nightly-next CHANNEL=nightly NIGHTLY_SPARKLE_KEY=nightly SHARED_SPARKLE_PRIVATE_KEY=shared \
  NIGHTLY_SPARKLE_PRIVATE_KEY=nightly NEXT_SPARKLE_PRIVATE_KEY=next "$PICK")"
[ "$got" = next ] || { echo "FAIL: nightly-next picked '$got', want 'next'"; exit 1; }
if TRACK=nightly-next CHANNEL=nightly NIGHTLY_SPARKLE_KEY=nightly SHARED_SPARKLE_PRIVATE_KEY=shared \
  NIGHTLY_SPARKLE_PRIVATE_KEY=nightly "$PICK" >/dev/null 2>&1; then
  echo "FAIL: nightly-next without its own key must fail, not fall back"
  exit 1
fi

if SHARED_SPARKLE_PRIVATE_KEY="" CHANNEL=nightly "$PICK" >/dev/null 2>&1; then
  echo "FAIL: a missing shared key must fail"
  exit 1
fi

# The embedded public key and the appcast signature must come from the same
# helper, so they can never disagree.
if grep -Eq '^ +SPARKLE_PRIVATE_KEY: \$\{\{ secrets\.' "$WORKFLOW"; then
  echo "FAIL: nightly.yml passes SPARKLE_PRIVATE_KEY directly; use scripts/ci/nightly-sparkle-key.sh"
  exit 1
fi
# Run blocks moved into scripts/ci/nightly-steps (#25879, #26196) still count:
# only the scripts nightly.yml actually runs, and each one that signs must use it.
step_scripts=()
while IFS= read -r name; do
  step_scripts+=("$ROOT_DIR/scripts/ci/nightly-steps/$name")
done < <(grep -oE 'scripts/ci/nightly-steps/[A-Za-z0-9_.-]+\.sh' "$WORKFLOW" | sed 's#.*/##' | sort -u)
for script in "${step_scripts[@]}"; do
  # A step script that signs (it reads SPARKLE_PRIVATE_KEY) must take it from the helper.
  case "$(grep -c 'SPARKLE_PRIVATE_KEY' "$script")" in
    0) ;;
    *)
      grep -Eq 'SPARKLE_PRIVATE_KEY="\$\((bash "\$TOOLS/|\./)scripts/ci/nightly-sparkle-key\.sh"?\)"' "$script" || {
        echo "FAIL: $(basename "$script") reads SPARKLE_PRIVATE_KEY without scripts/ci/nightly-sparkle-key.sh"
        exit 1
      } ;;
  esac
done
helper_calls="$(cat "$WORKFLOW" "${step_scripts[@]}" \
  | grep -cE 'SPARKLE_PRIVATE_KEY="\$\((bash "\$TOOLS/|\./)scripts/ci/nightly-sparkle-key\.sh"?\)"')"
if [ "$helper_calls" -lt 3 ]; then
  echo "FAIL: nightly.yml must derive the embedded key and sign every appcast through the helper"
  exit 1
fi

DELTAS="$ROOT_DIR/scripts/ci/generate-nightly-deltas.sh"
if ! grep -Fq 'scripts/ci/generate-nightly-deltas.sh' "$WORKFLOW" || ! grep -Fq 'drop-previous-nightlies-with-other-sparkle-key.sh" "$previous" "$SPARKLE_PUBLIC_KEY"' "$DELTAS"; then
  echo "FAIL: the post-publication delta step must drop previous nightlies signed for another key before building deltas"
  exit 1
fi

echo "PASS: nightly Sparkle key selection"
