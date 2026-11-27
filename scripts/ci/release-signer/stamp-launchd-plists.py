#!/usr/bin/env python3
"""Stamp the launchd plists sealed into a signed cmux app bundle.

The server helper and server agent are development/nightly-only.  The optional
login-time pre-read is carried by stable bundles too when its binary is present.
"""

import os
import plistlib
import re
import sys


def stamp(contents: str, bundle_id: str, kind: str, name: str, program: str,
          present: bool, label: str, args: list[str], extra: dict,
          drop_when_stable: bool) -> None:
    plist = os.path.join(contents, "Library", kind, name)
    drop = drop_when_stable and bundle_id == "com.cmuxterm.app"
    if drop or not present:
        if kind == "LaunchDaemons" and os.path.lexists(os.path.join(contents, program[9:])):
            os.remove(os.path.join(contents, program[9:]))
        if os.path.exists(plist):
            os.remove(plist)
        try:
            os.rmdir(os.path.dirname(plist))
        except OSError:
            pass
        return
    os.makedirs(os.path.dirname(plist), exist_ok=True)
    job = {"Label": label, "BundleProgram": program, "AssociatedBundleIdentifiers": [bundle_id],
           "ProgramArguments": args, **extra}
    with open(plist, "wb") as handle:
        plistlib.dump(job, handle)
    print(f"==> stamped {kind}/{name}: {label}")


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {sys.argv[0]} <app-path>", file=sys.stderr)
        return 2
    contents = os.path.join(sys.argv[1], "Contents")
    with open(os.path.join(contents, "Info.plist"), "rb") as handle:
        bundle_id = plistlib.load(handle)["CFBundleIdentifier"]
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]", bundle_id, re.ASCII):
        raise SystemExit(f"error: bundle id {bundle_id!r} is not a plain reverse-DNS name")

    helper = "Contents/Resources/libexec/cmux-server-helper"
    stamp(contents, bundle_id, "LaunchDaemons", "com.cmux.server.helper.plist", helper,
          os.path.lexists(os.path.join(contents, helper[9:])), f"{bundle_id}.server-helper",
          ["cmux-server-helper", "--app", bundle_id],
          {"MachServices": {f"{bundle_id}.server-helper": True}}, True)
    cli = "Contents/Resources/bin/cmux"
    stamp(contents, bundle_id, "LaunchAgents", "com.cmux.server.plist", cli,
          os.path.isfile(os.path.join(contents, cli[9:])), f"{bundle_id}.server",
          [cli, "host", "run", "--mode", "user"],
          {"RunAtLoad": True, "KeepAlive": {"SuccessfulExit": False},
           "ThrottleInterval": 10, "ProcessType": "Standard"}, True)
    preread = "Contents/Resources/bin/cmux-launch-preread"
    stamp(contents, bundle_id, "LaunchAgents", "com.cmux.launch-preread.plist", preread,
          os.path.isfile(os.path.join(contents, preread[9:])), f"{bundle_id}.launch-preread",
          [preread], {"RunAtLoad": True, "ProcessType": "Background",
                      "LowPriorityIO": True, "Nice": 10}, False)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
