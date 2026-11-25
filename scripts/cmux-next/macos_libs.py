"""macOS's libproc and libSystem for the benches, loaded so a bench imports anywhere.

On a Mac `library(path)` is `ctypes.CDLL(path)`. Off a Mac (a Linux lane, CI) it is a stand-in: importing the bench
works, so its `--help` answers and its pure helpers' tests need no ctypes mock, and any call into the library raises
OSError naming the Mac. Read a timebase with `timebase_of(lib, struct)`: 1/1 off a Mac.
(Dogfood 2026-11-24: `idle_cpu.py --help` died at import on a Linux lane: "cannot open /usr/lib/libproc.dylib".)
"""
from __future__ import annotations

import ctypes
import sys

ON_MAC = sys.platform == "darwin"


class OffMac:
    """A macOS library off a Mac: every function raises OSError when called."""

    def __init__(self, path: str):
        self._path = path

    def __getattr__(self, name: str):
        if name.startswith("__"):
            raise AttributeError(name)
        path = self._path

        def call(*_args, **_kwargs):
            raise OSError(f"{name} ({path}) reads macOS process tables; run the bench on a Mac")
        return call


def library(path: str, **kwargs):
    """`ctypes.CDLL(path, **kwargs)` on a Mac, an ``OffMac`` elsewhere."""
    return ctypes.CDLL(path, **kwargs) if ON_MAC else OffMac(path)


def timebase_of(lib, timebase):
    """Fills a mach_timebase_info struct from `lib` on a Mac; 1/1 elsewhere. Returns the struct."""
    if ON_MAC:
        lib.mach_timebase_info(ctypes.byref(timebase))
    else:
        timebase.numer, timebase.denom = 1, 1
    return timebase
