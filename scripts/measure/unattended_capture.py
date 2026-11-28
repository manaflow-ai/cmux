"""May this run take a ScreenCaptureKit capture without leaving an alert on a screen nobody watches?

`cmux computer-use screenshot` (and `record`) captures through the NIGHTLY's screen-sharing helper, which uses
ScreenCaptureKit with no system picker. macOS then shows its periodic acknowledgement from UserNotificationCenter,
'"cmux" is requesting to bypass the system private window picker and directly access your screen', whose only
buttons are Allow and Open System Settings. On a fleet Mac nobody is there to answer it, so it stays over every later
capture and walk on that Mac (cmux-ci step abeec0d3 on a shared mini, 2026-11-28: ext-rows-nightly's web-pane row
captured its side copy's window at 20:03:52Z, and the next walk there was host-red skipped with the alert still up).

The one thing that ends the alert without a person is the MDM restriction `forceBypassScreenCaptureAlert`
(cmuxterm-hq build-fleet/mdm). So an unattended run captures only on a Mac that carries it, and otherwise says why it
did not; a run a person watches captures as before.

    capture_refusal()   None when a capture may run here, else the reason it may not
"""
from __future__ import annotations

import os
import plistlib
from pathlib import Path

MANAGED = Path("/Library/Managed Preferences/com.apple.applicationaccess.plist")
BYPASS_KEY = "forceBypassScreenCaptureAlert"
ATTENDED_ENV = "CMUX_CAPTURE_ATTENDED"
# Set in every fleet step (cmux-ci worker) or CI job: nobody is at that screen.
UNATTENDED_ENVS = ("CMUX_CI_JOB_ID", "GITHUB_ACTIONS", "CI")


def unattended(environ=None) -> bool:
    env = os.environ if environ is None else environ
    if (env.get(ATTENDED_ENV) or "").strip() == "1":
        return False
    return any((env.get(name) or "").strip() not in ("", "0", "false") for name in UNATTENDED_ENVS)


def alert_bypassed(managed: Path = MANAGED) -> bool:
    try:
        with Path(managed).open("rb") as stream:
            return plistlib.load(stream).get(BYPASS_KEY) is True
    except (OSError, ValueError, plistlib.InvalidFileException, AttributeError):
        return False


def capture_refusal(environ=None, managed: Path = MANAGED) -> str | None:
    if not unattended(environ) or alert_bypassed(managed):
        return None
    return (f"unattended Mac without the MDM {BYPASS_KEY} restriction: a ScreenCaptureKit capture would leave "
            f"macOS's screen-capture acknowledgement up with nobody to answer it (set {ATTENDED_ENV}=1 when a person "
            "watches this screen)")
