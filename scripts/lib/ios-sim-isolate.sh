# shellcheck shell=bash
# Per-tag isolated iOS simulators. Agent sessions must never share a visible
# or booted simulator with the user or another agent, so each tag gets its own
# uniquely named device: "cmux-dev-<slug>". Created on demand from a base
# device type (default "iPhone 17", override CMUX_IOS_SIM_BASE_DEVICE) and the
# newest available iOS runtime.

# cmux_ios_isolated_sim_name <slug>
cmux_ios_isolated_sim_name() {
  printf 'cmux-dev-%s' "$1"
}

# cmux_ios_isolated_sim_udid <slug>
# Prints the UDID of the isolated simulator for the slug, creating the device
# if it does not exist yet. Returns non-zero when the device cannot be
# resolved or created.
cmux_ios_isolated_sim_udid() {
  local slug="$1"
  local name base
  name="$(cmux_ios_isolated_sim_name "$slug")"
  base="${CMUX_IOS_SIM_BASE_DEVICE:-iPhone 17}"
  SIM_NAME="$name" BASE_DEVICE="$base" /usr/bin/python3 - <<'PY'
import json, os, subprocess, sys

name = os.environ["SIM_NAME"]
base = os.environ["BASE_DEVICE"]

def simctl_json(*args):
    out = subprocess.check_output(["xcrun", "simctl", *args, "-j"])
    return json.loads(out)

devices = simctl_json("list", "devices")
for runtime_devices in devices.get("devices", {}).values():
    for device in runtime_devices:
        if device.get("name") == name and device.get("isAvailable", True):
            print(device["udid"])
            raise SystemExit(0)

# Create it: base device type + newest available iOS runtime.
types = simctl_json("list", "devicetypes").get("devicetypes", [])
device_type = next((t["identifier"] for t in types if t.get("name") == base), None)
if device_type is None:
    print(f"error: simulator device type not found: {base}", file=sys.stderr)
    raise SystemExit(1)

runtimes = [
    r for r in simctl_json("list", "runtimes").get("runtimes", [])
    if r.get("isAvailable", True) and r.get("platform", "iOS") == "iOS"
]
if not runtimes:
    print("error: no available iOS simulator runtime", file=sys.stderr)
    raise SystemExit(1)
runtime = max(runtimes, key=lambda r: [int(p) for p in str(r.get("version", "0")).split(".") if p.isdigit()])

udid = subprocess.check_output(
    ["xcrun", "simctl", "create", name, device_type, runtime["identifier"]],
    text=True,
).strip()
print(f"created isolated simulator {name} ({udid}) [{base}, iOS {runtime.get('version')}]", file=sys.stderr)
print(udid)
PY
}
