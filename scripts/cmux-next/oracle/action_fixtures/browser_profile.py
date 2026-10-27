"""Gap fixtures: browserProfile (p15-oracle-084). Spec: plans/cmux-next/chrome-parity/p15-oracle.md, tasks 082-087.

Every gap of this family was "needs a browser-profile argument": the sweep's base fills no `browser-profile` target.
The fixture is a scratch second profile, made once per launch through the same action a person uses
(`browserProfile.new`) and named by its name (BrowserProfileHandlers.explicitBrowserProfile resolves an id or a
name). A socket caller can never delete a profile (browserProfile.delete is person-only), so the profile is made only
when the launch does not already hold it, and it stays in the tagged app's data.

What the actions leave behind:
  newTab, openLink, newWorkspace, newWindow, manageExtensions, duplicateTab  a new tab, workspace or window: an extra
      the restore's close_new closes.
  moveTab, duplicateTab  act on the focused browser tab: PREPARE opens one (an extra), so the base's tabs keep their
      profile.
  setWorkspaceDefault, setSpaceDefault  a default no restore sees: UNDO clears it.

Chrome reference (chromium/src): chrome/browser/profiles/profile_test_util.h (profiles::testing::CreateProfileSync)
and chrome/test/base/in_process_browser_test.h tests make a second profile in the test's own user data dir and open
a browser in it, rather than reuse the person's profiles.
"""

from __future__ import annotations

from typing import Any, Mapping, Optional, Tuple

FAMILY = "browserProfile"

NAME = "Oracle Scratch"  # no colon: `browser-profile:<name>` parses as one target id
TARGET = f"browser-profile:{NAME}"
PAGE = "about:blank"  # a URL with a scheme (openLink refuses one without) that loads nothing from the network
APPEAR_S = 10.0  # the daemon's create-browser-profile reply reaches the app's records well inside this


def _error(reply: Any) -> Optional[str]:
    """The error of a socket reply (the sweep's rpc gives {"error": ...} for a failure), else None."""
    if isinstance(reply, dict) and reply.get("error"):
        return str(reply["error"])[:200]
    return None


def _held(driver: Any) -> bool:
    """True when the launch holds the scratch profile. The socket lists no browser profiles, so the check renames the
    target profile to its own name: rename takes the profile only as its target and `name` as its one argument, keeps
    every field, and refuses a target no profile's name matches."""
    return _error(driver.run("browserProfile.rename", {"name": NAME}, target=TARGET)) is None


class ScratchProfile:
    """The scratch profile of one launch, made on the first row that names it."""

    def __init__(self) -> None:
        self.held = False

    def value(self, driver: Any, base: Mapping[str, Any]) -> Tuple[Optional[str], Optional[str]]:
        if not self.held:
            if not _held(driver):
                error = _error(driver.run("browserProfile.new", {"name": NAME}))
                if error:
                    return None, f"browserProfile.new did not make the scratch profile: {error}"
                if not driver.wait(lambda: _held(driver), APPEAR_S):
                    return None, f"the scratch profile {NAME!r} did not appear within {APPEAR_S:g} s"
            self.held = True
        return TARGET, None


class BlankPage:
    """A page to open: the same value in every launch."""

    def value(self, driver: Any, base: Mapping[str, Any]) -> Tuple[str, None]:
        return PAGE, None


CLOSES = (
    "browserProfile.duplicateTab",
    "browserProfile.manageExtensions",
    "browserProfile.moveTab",
    "browserProfile.newTab",
    "browserProfile.newWindow",
    "browserProfile.newWorkspace",
    "browserProfile.openLink",
    "browserProfile.setSpaceDefault",
    "browserProfile.setWorkspaceDefault",
)
ARGUMENTS = {
    **{(ident, "browserProfile"): ScratchProfile for ident in CLOSES},
    ("browserProfile.openLink", "url"): BlankPage,
}
PREPARE = {
    "browserProfile.moveTab": [("openBrowser.chromium", {"url": PAGE})],
    "browserProfile.duplicateTab": [("openBrowser.chromium", {"url": PAGE})],
}
UNDO = {
    "browserProfile.setWorkspaceDefault": ("browserProfile.clearWorkspaceDefault", {}),
    "browserProfile.setSpaceDefault": ("browserProfile.clearSpaceDefault", {}),
}
