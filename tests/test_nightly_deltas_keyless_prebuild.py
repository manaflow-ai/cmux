#!/usr/bin/env python3
"""The nightly deltas are built without the Sparkle key, off the whole-Mac hold.

generate-nightly-deltas holds the Sparkle key, so glaeda gives it the whole nightly mini. On run
42149108998 it held cmux15 15 min (04:06:31-04:21:42Z), 494 s of them in BinaryDelta, which needs no
key, and 18 s in the keyed generate_appcast. build-nightly-deltas now builds the delta files on a
light nightly-only runner with no secret; generate-nightly-deltas puts them where generate_appcast
reuses them (SPARKLE_PREBUILT_DELTAS_DIR) and signs. A delta it lacks it still builds itself.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
TEXT = (ROOT / ".github" / "workflows" / "nightly.yml").read_text()
JOBS = yaml.safe_load(TEXT)["jobs"]
GENERATE = (ROOT / "scripts" / "ci" / "generate-nightly-deltas.sh").read_text()
APPCAST = (ROOT / "scripts" / "sparkle_generate_appcast.sh").read_text()
failures: list[str] = []


def job_text(name: str) -> str:
    start = TEXT.index(f"\n  {name}:\n") + 1
    match = re.search(r"^  [A-Za-z0-9_-]+:\n", TEXT[start + 4:], re.MULTILINE)
    return TEXT[start:] if match is None else TEXT[start:start + 4 + match.start()]


def steps(name: str) -> list[dict]:
    return JOBS.get(name, {}).get("steps") or []


build = JOBS.get("build-nightly-deltas")
if build is None:
    failures.append("no build-nightly-deltas job builds the deltas without the key")
else:
    body = job_text("build-nightly-deltas")
    if "secrets." in body:
        failures.append("build-nightly-deltas must hold no secret")
    if "glaeda-trusted-next-signing" in str(build.get("runs-on")) or "hold-the-whole-mac" in body \
            or "claim-publication-mac" in body:
        failures.append("build-nightly-deltas must run on a light nightly-only runner, not the whole-Mac signer")
    if "CI_NIGHTLY_ONLY_RUNNER" not in str(build.get("runs-on")):
        failures.append("build-nightly-deltas must stay on the nightly mini's nightly-only runners")
    if "NIGHTLY_DELTAS_PREBUILD_ONLY: 1" not in body and "NIGHTLY_DELTAS_PREBUILD_ONLY: '1'" not in body:
        failures.append("build-nightly-deltas must run generate-nightly-deltas.sh in its keyless mode")
    if "cmux-nightly-prebuilt-deltas-${{ matrix.variant }}" not in body:
        failures.append("build-nightly-deltas must upload cmux-nightly-prebuilt-deltas-<variant>")
    if build.get("continue-on-error") is not True:
        failures.append("a failed keyless build must leave the deltas to the keyed job, not fail the run")

generate = JOBS.get("generate-nightly-deltas", {})
needs = generate.get("needs") or []
if "build-nightly-deltas" not in needs:
    failures.append("generate-nightly-deltas must wait for the keyless deltas")
prebuilt = next((s for s in steps("generate-nightly-deltas") if "prebuilt deltas" in str(s.get("name", ""))), None)
if prebuilt is None or prebuilt.get("continue-on-error") is not True \
        or "cmux-nightly-prebuilt-deltas-${{ matrix.variant }}" not in str(prebuilt.get("with", {}).get("name", "")):
    failures.append("generate-nightly-deltas must download the prebuilt deltas, best effort")
if "SPARKLE_PREBUILT_DELTAS_DIR" not in job_text("generate-nightly-deltas"):
    failures.append("generate-nightly-deltas must hand the prebuilt deltas to generate_appcast")

# The keyless mode never reads the key and stops before generate_appcast signs anything.
mode = GENERATE.find('if [[ "${NIGHTLY_DELTAS_PREBUILD_ONLY:-}" == 1 ]]')
if not 0 <= mode < GENERATE.find('"$scripts_dir/ci/nightly-sparkle-key.sh"'):
    failures.append("generate-nightly-deltas.sh must leave before reading the key in its keyless mode")
if 'if [[ -z "$PREBUILD_ONLY_DIR" && -z "${SPARKLE_PRIVATE_KEY:-}" ]]' not in APPCAST:
    failures.append("sparkle_generate_appcast.sh must not require the key in its prebuild-only mode")
exit_at = APPCAST.find("prebuild-only: ")
if not 0 <= exit_at < APPCAST.find('key_file="$work_dir/sparkle_ed_key"'):
    failures.append("sparkle_generate_appcast.sh must exit its prebuild-only mode before it writes the key file")
if "SPARKLE_PREBUILT_DELTAS_DIR" not in APPCAST:
    failures.append("sparkle_generate_appcast.sh must reuse SPARKLE_PREBUILT_DELTAS_DIR's deltas")

if failures:
    print("FAIL: keyless nightly deltas\n  " + "\n  ".join(failures))
    sys.exit(1)
print("PASS: keyless nightly deltas")
