# SPDX-License-Identifier: MIT
"""Platform helpers: start fixtures and built-in apps, sample the pointer and
the focused window, snapshot OS settings. Stdlib only (ctypes for pointer).

Everything here runs on the eval machine (a disposable VM or a dedicated
test Mac), never on a person's own desktop.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(os.path.dirname(HERE), "fixtures")


def platform_name() -> str:
    if sys.platform == "darwin":
        return "macos"
    if sys.platform.startswith("win"):
        return "windows"
    return "linux"


# ---------------------------------------------------------------- pointer

class _Point(ctypes.Structure):
    _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]


class _CGPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


_x11 = None


def pointer_position() -> tuple[float, float] | None:
    """The system pointer in global coordinates, or None when it cannot be read."""
    plat = platform_name()
    try:
        if plat == "windows":
            pt = _Point()
            ctypes.windll.user32.GetCursorPos(ctypes.byref(pt))  # type: ignore[attr-defined]
            return (pt.x, pt.y)
        if plat == "macos":
            cg = ctypes.CDLL("/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices")
            cg.CGEventCreate.restype = ctypes.c_void_p
            cg.CGEventGetLocation.restype = _CGPoint
            cg.CGEventGetLocation.argtypes = [ctypes.c_void_p]
            cg.CFRelease.argtypes = [ctypes.c_void_p]
            ev = cg.CGEventCreate(None)
            p = cg.CGEventGetLocation(ev)
            cg.CFRelease(ev)
            return (p.x, p.y)
        global _x11
        if _x11 is None:
            path = ctypes.util.find_library("X11")
            if not path:
                return None
            _x11 = ctypes.CDLL(path)
            _x11.XOpenDisplay.restype = ctypes.c_void_p
            _x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
            _x11.XDefaultRootWindow.restype = ctypes.c_ulong
            _x11.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
            _x11.XQueryPointer.argtypes = [ctypes.c_void_p, ctypes.c_ulong] + [ctypes.c_void_p] * 7
            _x11._dpy = _x11.XOpenDisplay(None)
        if not _x11._dpy:
            return None
        root = _x11.XDefaultRootWindow(_x11._dpy)
        r, c = ctypes.c_ulong(), ctypes.c_ulong()
        rx, ry, wx, wy = (ctypes.c_int() for _ in range(4))
        mask = ctypes.c_uint()
        _x11.XQueryPointer(_x11._dpy, root, ctypes.byref(r), ctypes.byref(c), ctypes.byref(rx),
                           ctypes.byref(ry), ctypes.byref(wx), ctypes.byref(wy), ctypes.byref(mask))
        return (rx.value, ry.value)
    except Exception:
        return None


# ---------------------------------------------------------------- processes

def python_for_fixtures() -> str:
    return os.environ.get("CUEVAL_FIXTURE_PYTHON", sys.executable)


def start_fixture(kind: str, state_path: str, work: str, **opts) -> subprocess.Popen:
    if kind == "web":
        cmd = [python_for_fixtures(), "-I", os.path.join(FIXTURES, "web_form.py"),
               "--port", str(opts.get("port", 8765)), "--state", state_path]
    else:
        cmd = [python_for_fixtures(), "-I", os.path.join(FIXTURES, "fixture_app.py"),
               "--mode", kind, "--state", state_path]
        for key in ("geometry", "code", "title", "wm_class"):
            if opts.get(key):
                cmd += [f"--{key.replace('_', '-')}", str(opts[key])]
    return subprocess.Popen(cmd, cwd=work, stdout=subprocess.DEVNULL, stderr=open(state_path + ".log", "ab"))


def _first(*names: str) -> str | None:
    for n in names:
        if shutil.which(n):
            return n
    return None


def app_command(app: str, arg: str | None) -> list[str]:
    """The command that opens a built-in app without raising it where the OS allows."""
    plat = platform_name()
    if plat == "macos":
        bundle = {"browser": "Safari", "editor": "TextEdit", "calculator": "Calculator"}[app]
        # -g: do not bring it to the front. The eval Mac is a dedicated test machine.
        return ["open", "-g", "-a", bundle] + ([arg] if arg else [])
    if plat == "windows":
        exe = {"browser": "msedge", "editor": "notepad", "calculator": "calc"}[app]
        return ["cmd", "/c", "start", "", "/min", exe] + ([arg] if arg else [])
    exe = {
        "browser": _first("firefox", "chromium", "chromium-browser", "google-chrome", "epiphany"),
        "editor": _first("gedit", "gnome-text-editor", "mousepad", "xed", "pluma"),
        "calculator": _first("gnome-calculator", "galculator", "kcalc", "mate-calc"),
    }[app]
    if not exe:
        raise RuntimeError(f"no {app} app installed on this Linux machine")
    return [exe] + ([arg] if arg else [])


def start_app(app: str, arg: str | None, work: str) -> subprocess.Popen:
    return subprocess.Popen(app_command(app, arg), cwd=work, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def stop_app(app: str) -> None:
    plat = platform_name()
    names = {
        "macos": {"browser": ["Safari"], "editor": ["TextEdit"], "calculator": ["Calculator"]},
        "windows": {"browser": ["msedge.exe"], "editor": ["notepad.exe"], "calculator": ["CalculatorApp.exe", "calc.exe"]},
        "linux": {"browser": ["firefox", "chromium", "epiphany"], "editor": ["gedit", "gnome-text-editor", "mousepad"],
                  "calculator": ["gnome-calculator", "galculator", "kcalc"]},
    }[plat][app]
    for n in names:
        if plat == "windows":
            subprocess.run(["taskkill", "/IM", n, "/F"], capture_output=True)
        else:
            subprocess.run(["pkill", "-x", n], capture_output=True)


# ---------------------------------------------------------------- snapshots

def snapshot(name: str) -> str:
    """A read of an OS setting that a denied task must leave unchanged."""
    if name != "os_appearance":
        raise ValueError(name)
    plat = platform_name()
    if plat == "macos":
        cmd = ["defaults", "read", "-g", "AppleInterfaceStyle"]
    elif plat == "windows":
        cmd = ["reg", "query", r"HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
               "/v", "AppsUseLightTheme"]
    else:
        cmd = ["gsettings", "get", "org.gnome.desktop.interface", "color-scheme"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
        return (r.stdout + r.stderr).strip()
    except (OSError, subprocess.TimeoutExpired) as e:
        return f"unreadable: {e}"
