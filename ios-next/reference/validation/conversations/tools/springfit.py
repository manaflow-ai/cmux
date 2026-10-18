"""springfit.py: fit SwiftUI spring(response, damping) + onset to progress samples.
usage: springfit.py FILE [--x0 START --x1 END] (FILE: 't_ms value' lines; value mapped to progress via x0->0, x1->1)
       springfit.py --ref 't1,t2,..' 'p1,p2,..'"""
import sys, math, numpy as np, argparse
def spring(t, R, D):
    w=2*math.pi/R; t=np.maximum(t,0)
    if D>=1: return 1-(1+w*t)*np.exp(-w*t)
    wd=w*math.sqrt(1-D*D); return 1-np.exp(-D*w*t)*(np.cos(wd*t)+D*w/wd*np.sin(wd*t))
def fit(t,p):
    best=None
    for R in np.arange(0.10,0.80,0.005):
        for D in np.arange(0.60,1.001,0.02):
            for t0 in np.arange(-0.06,0.03,0.002):
                e=np.sqrt(np.mean((spring(t-t0,R,D)-p)**2))
                if best is None or e<best[0]: best=(e,R,D,t0)
    return best
def settle(R,D,frac=0.99):
    for ms in range(0,3000):
        tt=np.arange(ms,ms+600)/1000
        if np.all(np.abs(1-spring(tt,R,D))<=1-frac): return ms
ap=argparse.ArgumentParser(); ap.add_argument('file',nargs='?'); ap.add_argument('--x0',type=float); ap.add_argument('--x1',type=float)
ap.add_argument('--ref',nargs=2); ap.add_argument('--skip',type=float,default=-1)
a=ap.parse_args()
if a.ref:
    t=np.array([float(x) for x in a.ref[0].split(',')])/1000; p=np.array([float(x) for x in a.ref[1].split(',')])
else:
    d=[l.split() for l in open(a.file)]; d=[(float(x),float(y)) for x,y in d if float(y)!=a.skip]
    t=np.array([x for x,_ in d])/1000; v=np.array([y for _,y in d])
    p=(v-a.x0)/(a.x1-a.x0)
    # onset: first sample with p>0.01
    i0=np.argmax(p>0.01); t=t-t[i0]; keep=t>-0.05; t=t[keep]; p=p[keep]
e,R,D,t0=fit(t,p)
s=settle(R,D)
print(f'response={R:.3f} damping={D:.2f} onset_shift_ms={t0*1000:.0f} rmse={e:.4f} settle99_ms={s} frames60={round(s/16.667)}')
for tt,pp in zip(t,p):
    if tt<=0.6: print(f'  t={tt*1000:6.1f} p={pp:.3f} model={spring(tt-t0,R,D):.3f}')
