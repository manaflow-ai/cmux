"""SHORTCUT FRAMES floor probe (lead 2026-11-02): the macOS key-to-photon floor on the same mini, display and real HID.

driver.py loads this file (stock /usr/bin/python3, standard library only). Step (`do`):
  key_floor  {seconds?: 40, presses?: 20, interval?: 0.5}
             builds key_floor_probe.swift on the mini (once), opens it in the GUI session (it records its own window
             with the harness recorder's ScreenCaptureKit set-up), waits until its stream delivers, then sends REAL
             HID keys (CuaDriver desktop scope, as ext_realkey.press): `presses` x "a" (layer in keyDown), `presses`
             x cmd+k (menu key equivalent), "1", `presses` letters typed into an NSTextView. Returns the probe's JSON
             (every frame: display time, status, region checksums; every key: NSEvent.timestamp) in the step result.
The floor judge is scripts/cmux-next/shortcut-frames/floor.py.
"""
import json
import os
import subprocess
import time

D = None
R = None


def install(driver):
    global D, R
    D = driver
    import ext_realkey
    R = ext_realkey


def _send(j, key, mods=()):
    args = {"scope": "desktop"}
    if mods:
        bad, data, raw = R._session(j).call("hotkey", dict(args, keys=list(mods) + [key]))
    else:
        bad, data, raw = R._session(j).call("press_key", dict(args, key=key))
    return {"key": key, "mods": list(mods), "bad": bool(bad), "t": round(D.now(), 4)}


def step_key_floor(j, step):
    here = os.path.dirname(os.path.abspath(__file__))
    work = os.path.join(os.path.dirname(here), "keyfloor")
    app = os.path.join(work, "KeyFloor.app")
    exe_dir = os.path.join(app, "Contents", "MacOS")
    os.makedirs(exe_dir, exist_ok=True)
    built = subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-O", "-target", "arm64-apple-macos14.4",
                            os.path.join(here, "key_floor_probe.swift"), "-o", os.path.join(exe_dir, "KeyFloor")],
                           capture_output=True, text=True, timeout=300)
    if built.returncode:
        raise D.StepError(f"key_floor: build failed: {built.stderr[-600:]}")
    with open(os.path.join(app, "Contents", "Info.plist"), "w") as f:
        f.write('<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key>'
                '<string>KeyFloor</string><key>CFBundleIdentifier</key><string>ai.manaflow.shortcut-frames.keyfloor</string>'
                '<key>CFBundleName</key><string>KeyFloor</string><key>CFBundlePackageType</key><string>APPL</string>'
                '<key>LSMinimumSystemVersion</key><string>14.4</string></dict></plist>')
    subprocess.run(["codesign", "-s", "-", "--force", app], capture_output=True, timeout=60)
    out, ready = os.path.join(work, "floor.json"), os.path.join(work, "floor.ready")
    for path in (out, ready):
        if os.path.exists(path):
            os.remove(path)
    seconds = float(step.get("seconds", 40))
    presses, interval = int(step.get("presses", 20)), float(step.get("interval", 0.5))
    proc = subprocess.Popen(["open", "-W", "-n", app, "--args", str(seconds), out, ready],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    end = time.monotonic() + 20
    while not os.path.exists(ready) and time.monotonic() < end:
        time.sleep(0.1)
    if not os.path.exists(ready):
        proc.kill()
        raise D.NotRun("key_floor: the probe's stream gave no frame in 20 s")
    time.sleep(1.0)
    sent = []
    for _ in range(presses):
        sent.append(_send(j, "a")); time.sleep(interval)
    for _ in range(presses):
        sent.append(_send(j, "k", ["cmd"])); time.sleep(interval)
    sent.append(_send(j, "1")); time.sleep(interval)
    for i in range(presses):
        sent.append(_send(j, "bcdefghijlmnopqrstuvwxyz"[i % 23])); time.sleep(interval)
    proc.wait(timeout=seconds + 60)
    if not os.path.exists(out):
        raise D.StepError("key_floor: the probe wrote no result")
    with open(out) as f:
        data = json.load(f)
    data["sent"] = sent
    return data


STEPS = {"key_floor": step_key_floor}
