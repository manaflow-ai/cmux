#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The bounded test window of cua-helper-v2-live.py: one fixed-size window with one checkbox.

  cua_v2_probe_window.py STATE_FILE STOP_FILE TITLE [--seconds N]

An accessory app (no Dock icon, never activated) shows one titled, non-resizable 360x180
window at a fixed place with a checkbox named "cua-probe-target". The window is ordered front
without becoming key, so it takes no focus. STATE_FILE (JSON, rewritten on each change) holds the
pid, window number, frame, the checkbox state, a click count and whether this app is active or
its window is key. The window closes and the process exits when STOP_FILE appears, after
--seconds (default 300), or on SIGTERM. AppKit through the Objective-C runtime (ctypes) only: no
build step, no PyObjC.
"""
import ctypes, ctypes.util, json, os, signal, sys, time

STATE, STOP, TITLE = sys.argv[1], sys.argv[2], sys.argv[3]
SECONDS = float(sys.argv[sys.argv.index("--seconds") + 1]) if "--seconds" in sys.argv else 300.0

objc = ctypes.cdll.LoadLibrary(ctypes.util.find_library("objc"))
appkit = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/AppKit.framework/AppKit")
foundation = ctypes.cdll.LoadLibrary("/System/Library/Frameworks/Foundation.framework/Foundation")
objc.objc_getClass.restype = ctypes.c_void_p
objc.objc_getClass.argtypes = [ctypes.c_char_p]
objc.sel_registerName.restype = ctypes.c_void_p
objc.sel_registerName.argtypes = [ctypes.c_char_p]
_send = objc.objc_msgSend
id_t = ctypes.c_void_p


class NSRect(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double), ("w", ctypes.c_double), ("h", ctypes.c_double)]


def send(receiver, selector, *args, restype=id_t, argtypes=()):
    """objc_msgSend with an exact prototype (arm64 needs one; never variadic)."""
    _send.restype = restype
    _send.argtypes = [id_t, id_t, *argtypes]
    return _send(receiver, objc.sel_registerName(selector.encode()), *args)


def cls(name):
    return objc.objc_getClass(name.encode())


def nsstring(text):
    return send(cls("NSString"), "stringWithUTF8String:", text.encode(), argtypes=[ctypes.c_char_p])


stopping = False


def on_term(_signum, _frame):
    global stopping
    stopping = True


signal.signal(signal.SIGTERM, on_term)

pool = send(send(cls("NSAutoreleasePool"), "alloc"), "init")
app = send(cls("NSApplication"), "sharedApplication")
# NSApplicationActivationPolicyAccessory: no Dock icon, no menu bar; the app is never activated here.
send(app, "setActivationPolicy:", 1, restype=ctypes.c_bool, argtypes=[ctypes.c_long])
send(app, "finishLaunching", restype=None)

FRAME = NSRect(120.0, 160.0, 360.0, 180.0)  # bottom-left origin, points; fixed
TITLED = 1  # NSWindowStyleMaskTitled only: not resizable, not closable by the user, no miniaturize
window = send(send(cls("NSWindow"), "alloc"), "initWithContentRect:styleMask:backing:defer:",
              FRAME, TITLED, 2, False, argtypes=[NSRect, ctypes.c_ulong, ctypes.c_ulong, ctypes.c_bool])
send(window, "setReleasedWhenClosed:", False, restype=None, argtypes=[ctypes.c_bool])
send(window, "setTitle:", nsstring(TITLE), restype=None, argtypes=[id_t])

button = send(send(cls("NSButton"), "alloc"), "initWithFrame:", NSRect(40.0, 60.0, 280.0, 60.0), argtypes=[NSRect])
send(button, "setButtonType:", 3, restype=None, argtypes=[ctypes.c_ulong])  # NSButtonTypeSwitch (a checkbox)
send(button, "setTitle:", nsstring("cua-probe-target"), restype=None, argtypes=[id_t])
send(send(window, "contentView"), "addSubview:", button, restype=None, argtypes=[id_t])
# Front without becoming key and without activating this app: the window takes no focus.
send(window, "orderFrontRegardless", restype=None)

mode = id_t.in_dll(foundation, "NSDefaultRunLoopMode")
window_number = send(window, "windowNumber", restype=ctypes.c_long)
last = None
clicks = 0


def state(closing=False):
    frame = (FRAME.x, FRAME.y, FRAME.w, FRAME.h)
    return {"pid": os.getpid(), "window_number": window_number, "title": TITLE, "frame": frame,
            "checkbox_state": send(button, "state", restype=ctypes.c_long),
            "clicks": clicks,
            "app_active": bool(send(app, "isActive", restype=ctypes.c_bool)),
            "window_key": bool(send(window, "isKeyWindow", restype=ctypes.c_bool)),
            "window_visible": bool(send(window, "isVisible", restype=ctypes.c_bool)),
            "closing": closing, "at": time.time()}


def write(value):
    with open(STATE + ".tmp", "w") as f:
        json.dump(value, f)
    os.replace(STATE + ".tmp", STATE)


deadline = time.time() + SECONDS
ever_active = False
ever_key = False
while not stopping and time.time() < deadline and not os.path.exists(STOP):
    inner = send(send(cls("NSAutoreleasePool"), "alloc"), "init")
    until = send(cls("NSDate"), "dateWithTimeIntervalSinceNow:", ctypes.c_double(0.1), argtypes=[ctypes.c_double])
    event = send(app, "nextEventMatchingMask:untilDate:inMode:dequeue:", ctypes.c_ulonglong(0xFFFFFFFFFFFFFFFF),
                 until, mode, True, argtypes=[ctypes.c_ulonglong, id_t, id_t, ctypes.c_bool])
    if event:
        send(app, "sendEvent:", event, restype=None, argtypes=[id_t])
    current = state()
    ever_active = ever_active or current["app_active"]
    ever_key = ever_key or current["window_key"]
    if last is not None and current["checkbox_state"] != last["checkbox_state"]:
        clicks += 1
        current["clicks"] = clicks
    current["ever_active"], current["ever_key"] = ever_active, ever_key
    key = {k: v for k, v in current.items() if k != "at"}
    if last is None or key != {k: v for k, v in last.items() if k != "at"}:
        write(current)
    last = current
    send(inner, "drain", restype=None)

final = state(closing=True)
final["ever_active"], final["ever_key"] = ever_active, ever_key
send(window, "close", restype=None)
final["window_visible_after_close"] = bool(send(window, "isVisible", restype=ctypes.c_bool))
write(final)
send(pool, "drain", restype=None)
