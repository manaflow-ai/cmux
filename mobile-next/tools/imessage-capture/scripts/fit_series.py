#!/usr/bin/env python3
"""Fit a damped spring (SwiftUI response/dampingFraction) to a 60 fps series.

Usage: fit_series.py --from V0 --to V1 [--v0 initial_velocity_pt_per_s] v1 v2 v3 ...
The first sample is frame 0. Start time t0 (<= frame 0) is fitted too, so the
series may begin mid-animation (e.g. when the element first enters the screen).
Model: x(t) = V1 + (V0 - V1) * e(t - t0), where e is the spring's normalized
displacement with initial velocity v0 (default 0).
"""
import argparse, math

def disp(t, om, z, v):
    # normalized displacement from target, starting at 1 with velocity v (in units of the full distance / s)
    if t <= 0:
        return 1.0
    if z < 1:
        wd = om * math.sqrt(1 - z*z)
        return math.exp(-z*om*t) * (math.cos(wd*t) + (z*om + v) / wd * math.sin(wd*t))
    if abs(z - 1) < 1e-6:
        return math.exp(-om*t) * (1 + (om + v) * t)
    s = math.sqrt(z*z - 1); r1, r2 = -om*(z - s), -om*(z + s)
    # x = A e^{r1 t} + B e^{r2 t}, x(0)=1, x'(0)=v
    B = (v - r1) / (r2 - r1); A = 1 - B
    return A*math.exp(r1*t) + B*math.exp(r2*t)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--from", dest="a", type=float, required=True)
    ap.add_argument("--to", dest="b", type=float, required=True)
    ap.add_argument("--v0", type=float, default=0.0, help="initial velocity in pt/s toward target (positive = toward)")
    ap.add_argument("--fix-t0", action="store_true", help="animation starts exactly at the first sample")
    ap.add_argument("vals", nargs="+", type=float)
    a = ap.parse_args()
    D = a.a - a.b
    v = -a.v0 / D if D else 0  # normalized velocity of displacement
    best = None
    t0s = [0.0] if a.fix_t0 else [x / 240 for x in range(0, -80, -1)]
    for t0 in t0s:
        for ri in range(10, 150):
            resp = ri / 100; om = 2*math.pi/resp
            for zi in range(30, 161, 2):
                z = zi / 100
                e = sum((a.b + D*disp(i/60 - t0, om, z, v) - x)**2 for i, x in enumerate(a.vals))
                if best is None or e < best[0]:
                    best = (e, t0, resp, z)
    e, t0, resp, z = best
    print(f"response={resp:.2f}s dampingFraction={z:.2f} start={-t0*1000:.0f}ms before first sample rms={math.sqrt(e/len(a.vals)):.2f}pt")
    om = 2*math.pi/resp
    pred = [a.b + D*disp(i/60 - t0, om, z, v) for i in range(len(a.vals))]
    print("frame measured model: " + "  ".join(f"{i}:{x:.1f}/{p:.1f}" for i, (x, p) in enumerate(zip(a.vals, pred))))

if __name__ == "__main__":
    main()
