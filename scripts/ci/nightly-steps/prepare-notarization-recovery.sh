#!/usr/bin/env bash
# nightly.yml build-sign-notarize-nightly: "Prepare pending notarization recovery artifact". Moved out of the
# workflow to keep nightly.yml under its size budget (tests/test_workflow_file_size.py); the step's env: sets every
# input the run block read from ${{ }} expressions.
set -euo pipefail
for required in \
  "$NIGHTLY_DMG_RELEASE" \
  "$NIGHTLY_DMG_RELEASE.notarization.state" \
  "$NIGHTLY_DMG_RELEASE.notarization.log" \
  "$CHANNEL_APP_PATH"; do
  if [ ! -e "$required" ]; then
    echo "Missing notarization recovery input: $required" >&2
    exit 1
  fi
done
# A handed-off stapled-app DMG travels with the accepted first DMG
# (the 6 h fallback of notarize-nightly-dmg.sh).
if grep -Fxq stapled_app=true "$NIGHTLY_DMG_RELEASE.notarization.state" && [ ! -f "${NIGHTLY_DMG_RELEASE%.dmg}.first.dmg" ]; then
  echo "Missing notarization recovery input: ${NIGHTLY_DMG_RELEASE%.dmg}.first.dmg" >&2
  exit 1
fi
recovery_app_archive="cmux-nightly-notarization-recovery-app.tar.gz"
./scripts/ci/archive-recovery-app.sh "$CHANNEL_APP_PATH" "$recovery_app_archive"
dmg_sha256="$(shasum -a 256 "$NIGHTLY_DMG_RELEASE" | awk '{print $1}')"
[[ "$dmg_sha256" =~ ^[[:xdigit:]]{64}$ ]] || {
  echo "Could not record a SHA-256 for $NIGHTLY_DMG_RELEASE" >&2
  exit 1
}
python3 - \
  "$NIGHTLY_DMG_RELEASE.notarization.state" \
  "$dmg_sha256" \
  "$NIGHTLY_DMG_RELEASE" \
  "$CHANNEL_APP_PATH" \
  "$CHANNEL" \
  "$NIGHTLY_VARIANT" \
  "$CHANNEL_RELEASE_TAG" \
  "$NIGHTLY_BUILD" \
  "$BUILD_SHA" \
  "$BUILD_SHORT_SHA" \
  "$TIP_SHA" \
  "$BEHIND" \
  "$BEHIND_HOURS" \
  "$SIGN_CHANNEL" <<'PY'
import json
import os
import pathlib
import sys

state_path, actual_sha, dmg_path, app_path, channel, variant, release_tag, build, head_sha, short_sha, tip_sha, behind, behind_hours, sign_channel = sys.argv[1:]
state = {}
for line in pathlib.Path(state_path).read_text(encoding="utf-8").splitlines():
    if not line:
        continue
    key, sep, value = line.partition("=")
    if not sep or key in state:
        raise SystemExit(f"invalid notarization state line: {line!r}")
    state[key] = value
if state.get("dmg_sha256") != actual_sha:
    raise SystemExit("notarization state SHA-256 does not match the signed DMG")
# A bounded wait that ran out exits nonzero after a successful upload.
if state.get("submit_exit", "0") != "0" and state.get("wait_timed_out") != "true":
    raise SystemExit("notarization submit exited nonzero; refusing automatic continuation")
submission_id = state.get("submission_id", "")
if not submission_id or not all(character.isalnum() or character in "._-" for character in submission_id):
    raise SystemExit("notarization state has no valid Apple submission id")
for key in ("immutable_path", "release_tag", "dmg_prefix", "variant", "channel"):
    if not state.get(key):
        raise SystemExit(f"notarization state is missing {key}")
# The manifest keeps the release channel for check-manifest.
if state["channel"] != sign_channel or state["variant"] != variant or state["release_tag"] != release_tag:
    raise SystemExit("notarization state metadata does not match the build")
if state.get("dmg_path", "").split("/")[-1] != pathlib.Path(dmg_path).name:
    raise SystemExit("notarization state points at a different DMG")
pathlib.Path("cmux-nightly-notarization-recovery.json").write_text(
    json.dumps({
        "schema": 1,
        "source_run_id": os.environ["GITHUB_RUN_ID"],
        "source_run_attempt": os.environ["GITHUB_RUN_ATTEMPT"],
        "should_publish": True,
        "channel": channel,
        "track": "nightly-next",
        "variant": variant,
        "release_tag": release_tag,
        "build": build,
        "head_sha": head_sha,
        "short_sha": short_sha,
        # The resolved build commit and its distance from the tip,
        # which publication records (find-nightly-next-recovery.py).
        "build_sha": head_sha,
        "build_short_sha": short_sha,
        "tip_sha": tip_sha,
        "behind": behind,
        "behind_hours": behind_hours,
        "dmg_path": pathlib.Path(dmg_path).name,
        "app_path": f"cmux-nightly-notarization-recovery-app/{pathlib.Path(app_path).name}",
        "app_archive_path": "cmux-nightly-notarization-recovery-app.tar.gz",
        "state_path": pathlib.Path(state_path).name,
        "log_path": f"{pathlib.Path(dmg_path).name}.notarization.log",
        "immutable_path": state["immutable_path"],
        "dmg_prefix": state["dmg_prefix"],
        "dmg_sha256": actual_sha,
        "submission_id": submission_id,
    }, indent=2) + "\n",
    encoding="utf-8",
)
PY
