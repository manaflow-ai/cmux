#!/usr/bin/env bash
# Create and boot a fresh, uniquely named iPhone simulator for this run and
# print its UDID. Newest available iOS runtime, then the newest iPhone that
# runtime supports: the "iPhone" product family also lists iPod touch, and the
# last device type overall may have no runtime on the image.
#
# Usage: boot-simulator.sh <name>
set -euo pipefail
name="${1:?simulator name}"

read -r runtime devtype < <(xcrun simctl list runtimes -j | python3 -c '
import json, sys
runtimes = [r for r in json.load(sys.stdin)["runtimes"]
            if r.get("isAvailable") and r.get("platform") == "iOS"]
if not runtimes:
    sys.exit("no available iOS runtime")
runtime = max(runtimes, key=lambda r: [int(x) for x in r["version"].split(".")])
phones = [d for d in runtime.get("supportedDeviceTypes", [])
          if d.get("productFamily") == "iPhone" and d["name"].startswith("iPhone")]
if not phones:
    sys.exit("runtime " + runtime["identifier"] + " supports no iPhone")
def generation(device):
    digits = "".join(c if c.isdigit() else " " for c in device["name"]).split()
    return (int(digits[0]) if digits else 0, "Pro" in device["name"], "Max" not in device["name"])
print(runtime["identifier"], max(phones, key=generation)["identifier"])')

udid="$(xcrun simctl create "$name" "$devtype" "$runtime")"
xcrun simctl boot "$udid"
xcrun simctl bootstatus "$udid" -b >/dev/null
echo "simulator: $udid ($devtype, $runtime)" >&2
echo "$udid"
