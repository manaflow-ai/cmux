#!/usr/bin/env python3
"""Select or create the requested iPhone/iPad simulator for iOS CI.

Default: an existing "iPhone 17"/"iPhone 16" (or iPad) simulator the jobs of a
machine share, else a new "cmux CI <run> <type>" the workflow deletes after the
job. An explicit IOS_VERSION always gets its own new simulator.

Simulator slots. glaeda can let one owned mini run several simulator jobs at
once; it then tells each job its slot as GLAEDA_SIM_SLOT=<k> in $GITHUB_ENV. Two
jobs on one shared device would collide, so on a self-hosted runner with a slot
(and no IOS_VERSION) the job gets that slot's own device, "cmux CI slot <k>
<type>", of the same device type and runtime the default rule picks. It is kept
across jobs and left booted: the next job of the slot finds it booted, and the
workflow neither deletes nor shuts it down (SIMULATOR_KEEP=1). A missing slot
device is cloned from the mini's "cmux CI base <type>", which is created and
booted once, so the first-boot data migration is paid once per mini, then shut
down so it can be cloned. A slot or base device whose type or runtime no longer
matches the pin (an Xcode or runtime update) is deleted and made again. A file
lock serializes the slot jobs of a mini while they create or clone. Without
GLAEDA_SIM_SLOT nothing here changes.
"""

from __future__ import annotations

import contextlib
import fcntl
import json
import os
import re
import subprocess
import sys

SLOT_PREFIX = "cmux CI slot"
BASE_PREFIX = "cmux CI base"
# Serializes base creation and cloning between the slot jobs of one mini (one
# user's simulators share one device set, so one lock per home is enough).
LOCK_PATH = os.path.join(os.path.expanduser("~"), ".cmux-ci-simulator-slots.lock")


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


def simctl(*args: str) -> str:
    return subprocess.check_output(["xcrun", "simctl", *args], text=True).strip()


def sim_slot(env) -> str | None:
    """The job's glaeda simulator slot on a self-hosted runner, or None."""
    slot = (env.get("GLAEDA_SIM_SLOT") or "").strip()
    if not slot or env.get("RUNNER_ENVIRONMENT", "self-hosted") != "self-hosted":
        return None
    if not re.fullmatch(r"\d{1,3}", slot):
        raise SystemExit(f"GLAEDA_SIM_SLOT must be a small number, got {slot!r}")
    return slot


@contextlib.contextmanager
def slot_lock(path: str | None = None):
    with open(path or LOCK_PATH, "a") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def owned_device(name: str, type_id: str, runtime_id: str):
    """The device named `name` of this pin; any other device by that name is deleted (it is ours)."""
    found = None
    for runtime, items in simctl_json("devices").get("devices", {}).items():
        for device in items:
            if device.get("name") != name:
                continue
            if (found is None and runtime == runtime_id and device.get("deviceTypeIdentifier") == type_id
                    and device.get("isAvailable", True)):
                found = device
            else:
                print(f"Deleting stale {name} ({device.get('udid')}) on {runtime}", file=sys.stderr)
                subprocess.run(["xcrun", "simctl", "delete", device["udid"]], check=False)
    return found


def boot(udid: str) -> None:
    # "Unable to boot device in current state: Booted" is fine; bootstatus decides.
    subprocess.run(["xcrun", "simctl", "boot", udid], check=False,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    # bootstatus prints its progress on stdout, which the workflow appends to $GITHUB_ENV: send it to stderr.
    subprocess.check_call(["xcrun", "simctl", "bootstatus", udid, "-b"], stdout=sys.stderr)


def slot_device(slot: str, type_id: str, type_name: str, runtime_id: str):
    """The slot's own device of this pin, cloned from the mini's base device when missing, booted."""
    name = f"{SLOT_PREFIX} {slot} {type_name}"
    with slot_lock():
        device = owned_device(name, type_id, runtime_id)
        if device is None:
            base_name = f"{BASE_PREFIX} {type_name}"
            base = owned_device(base_name, type_id, runtime_id)
            if base is None:
                udid = simctl("create", base_name, type_id, runtime_id)
                print(f"Created {base_name} ({udid}) with {runtime_id}; booting it once", file=sys.stderr)
                boot(udid)
                base = {"udid": udid, "state": "Booted"}
            if base.get("state") != "Shutdown":
                # simctl clone needs the source shut down.
                subprocess.run(["xcrun", "simctl", "shutdown", base["udid"]], check=False,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            udid = simctl("clone", base["udid"], name)
            print(f"Cloned {name} ({udid}) from {base_name}", file=sys.stderr)
            device = {"udid": udid, "state": "Shutdown"}
    if device.get("state") != "Booted":
        boot(device["udid"])
    return {"udid": device["udid"], "name": name}


def main() -> None:
    family = os.environ["DEVICE_FAMILY"]
    if family not in {"iphone", "ipad"}:
        raise SystemExit(f"Unsupported simulator family: {family}")
    requested_version = os.environ.get("IOS_VERSION", "")
    slot = None if requested_version else sim_slot(os.environ)
    data = simctl_json("devices", "available")
    # A runtime newer than the active Xcode's SDK (a beta someone installed on a
    # shared Mac) still lists its devices as available, but xcodebuild cannot
    # target them, so a default run keeps to runtimes the SDK covers.
    sdk = None if requested_version else sdk_version()
    devices = [
        {**device, "runtime": runtime_id}
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
        if slot is not None:
            selected = slot_device(slot, device_type["identifier"], device_type["name"], runtime["identifier"])
        else:
            created_name = f"cmux CI {os.environ.get('GITHUB_RUN_ID', 'local')} {device_type['name']}"
            udid = subprocess.check_output(
                ["xcrun", "simctl", "create", created_name, device_type["identifier"], runtime["identifier"]],
                text=True,
            ).strip()
            selected = {"udid": udid, "name": created_name}
            print(f"Created {selected['name']} ({udid}) with {runtime['identifier']}", file=sys.stderr)
    elif slot is not None:
        # The shared device's own type and runtime: the slot device is its twin.
        selected = slot_device(slot, selected["deviceTypeIdentifier"], selected["name"], selected["runtime"])
    print(f"SIMULATOR_ID={selected['udid']}")
    print(f"SIMULATOR_NAME={selected['name']}")
    if slot is not None:
        # The workflow neither deletes nor shuts down a slot device.
        print("SIMULATOR_KEEP=1")
    if requested_version and runtime:
        print(f"IOS_TEST_RUNTIME={runtime['version']}")


if __name__ == "__main__":
    main()
