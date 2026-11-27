#!/usr/bin/env python3
"""Select or create the requested iPhone/iPad simulator for iOS CI."""

from __future__ import annotations

import json
import os
import subprocess
import sys


def simctl_json(*args: str):
    return json.loads(subprocess.check_output(["xcrun", "simctl", "list", *args, "-j"]))


def version_key(runtime):
    parts = []
    for part in str(runtime.get("version") or "").split("."):
        try:
            parts.append(int(part))
        except ValueError:
            parts.append(0)
    return tuple(parts)


def sdk_version():
    """The active Xcode's iOS Simulator SDK as (major, minor), or None."""
    try:
        out = subprocess.check_output(
            ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], text=True
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return None
    if not out:
        return None
    return (version_key({"version": out}) + (0,))[:2]


def runtime_key_version(identifier: str):
    # com.apple.CoreSimulator.SimRuntime.iOS-26-5 -> (26, 5)
    tail = identifier.rsplit(".", 1)[-1]
    if not tail.startswith("iOS-"):
        return None
    return (version_key({"version": tail[4:].replace("-", ".")}) + (0,))[:2]


def main() -> None:
    family = os.environ["DEVICE_FAMILY"]
    if family not in {"iphone", "ipad"}:
        raise SystemExit(f"Unsupported simulator family: {family}")
    requested_version = os.environ.get("IOS_VERSION", "")
    data = simctl_json("devices", "available")
    # A runtime newer than the active Xcode's SDK (a beta someone installed on a
    # shared Mac) still lists its devices as available, but xcodebuild cannot
    # target them, so a default run keeps to runtimes the SDK covers.
    sdk = None if requested_version else sdk_version()
    devices = [
        device
        for runtime_id, runtime_devices in data.get("devices", {}).items()
        for device in runtime_devices
        if device.get("isAvailable", True)
        and (sdk is None or (runtime_key_version(runtime_id) or (0,)) <= sdk)
    ]
    prefix = "iPad" if family == "ipad" else "iPhone"
    preferred = (
        ["iPad Pro 13-inch (M4)", "iPad Air 13-inch (M3)"]
        if family == "ipad"
        else ["iPhone 17", "iPhone 16"]
    )
    selected = next((device for name in preferred for device in devices if device.get("name") == name), None)
    selected = selected or next((device for device in devices if device.get("name", "").startswith(prefix)), None)
    runtime = None
    if requested_version:
        # Explicit compatibility runs always get their own simulator.
        selected = None
    if selected is None:
        runtimes = [
            runtime
            for runtime in simctl_json("runtimes").get("runtimes", [])
            if runtime.get("isAvailable", True)
            and (
                runtime.get("platform") == "iOS"
                or "iOS" in runtime.get("name", "")
                or runtime.get("identifier", "").startswith("com.apple.CoreSimulator.SimRuntime.iOS")
            )
            and (sdk is None or (version_key(runtime) + (0,))[:2] <= sdk)
        ]
        device_types = [
            device_type
            for device_type in simctl_json("devicetypes").get("devicetypes", [])
            if device_type.get("name", "").startswith(prefix)
        ]
        if requested_version:
            runtimes = [
                candidate
                for candidate in runtimes
                if candidate.get("version") == requested_version
                or candidate.get("version", "").startswith(requested_version + ".")
            ]
        runtime = max(runtimes, key=version_key, default=None)
        if requested_version and runtime:
            supported = {device["identifier"] for device in runtime.get("supportedDeviceTypes", [])}
            if supported:
                device_types = [device for device in device_types if device["identifier"] in supported]
            # These devices also run on iOS 17; newer hardware may not.
            preferred = (
                ["iPad Pro (11-inch) (4th generation)"]
                if family == "ipad"
                else ["iPhone 15", "iPhone 14"]
            )
        device_type = next(
            (device for name in preferred for device in device_types if device.get("name") == name),
            None,
        )
        device_type = device_type or (device_types[-1] if device_types else None)
        if runtime is None or device_type is None:
            raise SystemExit(f"No available {family} simulator or creatable iOS runtime/device type found")
        created_name = f"cmux CI {os.environ.get('GITHUB_RUN_ID', 'local')} {device_type['name']}"
        udid = subprocess.check_output(
            ["xcrun", "simctl", "create", created_name, device_type["identifier"], runtime["identifier"]],
            text=True,
        ).strip()
        selected = {"udid": udid, "name": created_name}
        print(f"Created {selected['name']} ({udid}) with {runtime['identifier']}", file=sys.stderr)
    print(f"SIMULATOR_ID={selected['udid']}")
    print(f"SIMULATOR_NAME={selected['name']}")
    if requested_version and runtime:
        print(f"IOS_TEST_RUNTIME={runtime['version']}")


if __name__ == "__main__":
    main()
