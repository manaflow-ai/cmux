#!/usr/bin/env python3
"""Read the host/Simulator clock used by DispatchTime.uptimeNanoseconds.

Use Mach directly because the system Python can predate 3.10, when Python's
macOS monotonic clock became process-independent. No wall-clock conversion.
"""

import ctypes
import sys


class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


if __name__ == "__main__":
    if sys.platform != "darwin":
        raise SystemExit("the Simulator launch clock requires macOS")
    system = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    system.mach_absolute_time.restype = ctypes.c_uint64
    system.mach_absolute_time.argtypes = []
    system.mach_timebase_info.argtypes = [ctypes.POINTER(Timebase)]
    system.mach_timebase_info.restype = ctypes.c_int
    base = Timebase()
    if system.mach_timebase_info(ctypes.byref(base)) != 0 or base.denom == 0:
        raise SystemExit("unable to read the Mach timebase")
    print(system.mach_absolute_time() * base.numer // base.denom)
