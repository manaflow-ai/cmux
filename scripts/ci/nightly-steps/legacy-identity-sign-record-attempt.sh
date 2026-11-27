#!/usr/bin/env bash
# nightly.yml sign-nightly-identity-legacy: "Record the attempt". Moved out of the workflow to keep
# nightly.yml under GitHub's workflow file size limit; the step's env: still sets every input.
#
# The step's notes, moved from nightly.yml:
# What publish-nightly-identity-legacy needs to resolve the attempt:
# Apple's answer (a notary log or a stapled ticket), a requirement
# refusal, and whether every step here passed.
set -euo pipefail
apple=unknown
if grep -Eq '"status" *: *"(Invalid|Rejected)"' "$RUNNER_TEMP/legacy.notarization.log" 2>/dev/null; then
  apple=refused
elif grep -Eq '"status" *: *"Accepted"' "$RUNNER_TEMP/legacy.notarization.log" 2>/dev/null \
   || { [ -d "legacy-app/cmux NIGHTLY.app" ] && ! grep -Fxq stapled_app=true "$RUNNER_TEMP/legacy.notarization.state" 2>/dev/null \
        && xcrun stapler validate "legacy-app/cmux NIGHTLY.app" >/dev/null 2>&1; }; then
  apple=accepted
fi
refused=false
if [ -e "$RUNNER_TEMP/legacy-requirement-refused" ]; then refused=true; fi
signed_ok=false
if [ "$JOB_STATUS" = success ]; then signed_ok=true; fi
{
  echo "notarize=${NOTARIZE:-skipped}"
  echo "apple=$apple"
  echo "requirement_refused=$refused"
  echo "signed_ok=$signed_ok"
} >> "$GITHUB_OUTPUT"
echo "attempt: notarize=${NOTARIZE:-skipped} apple=$apple requirement_refused=$refused signed_ok=$signed_ok"
if [ "$LEGACY_ACTION" = continue ] && [ -f pending/pending.json ]; then
  mkdir -p attempt-meta
  cp pending/pending.json attempt-meta/pending.json
fi
