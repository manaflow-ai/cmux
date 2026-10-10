"""tracefit.py TRACE: per animation run in the DEBUG trace, fit spring(response, damping) to
normalized progress and report settle frames, overshoot and dropped frames."""
import sys, math, numpy as np
def spring(t, R, D):
    w=2*math.pi/R; t=np.maximum(t,0)
    if D>=1: return 1-(1+w*t)*np.exp(-w*t)
    wd=w*math.sqrt(1-D*D); return 1-np.exp(-D*w*t)*(np.cos(wd*t)+D*w/wd*np.sin(wd*t))
runs=[]; cur=None
for line in open(sys.argv[1]):
    lab, ft, t, v = line.split(); ft=float(ft); t=float(t); v=float(v)
    if cur is None or cur['label']!=lab or t < cur['t'][-1] - 1e-6 or ft - cur['ft'][-1] > 0.5:
        cur={'label':lab,'t':[], 'v':[], 'ft':[]}; runs.append(cur)
    cur['t'].append(t); cur['v'].append(v); cur['ft'].append(ft)
for r in runs:
    t=np.array(r['t']); v=np.array(r['v'])
    if len(t)<4: continue
    end=v[-1]
    # start value: extrapolate from first sample (t0 ~ 1 frame) is unknown; take value at t=0 as first - slope
    start=v[0]
    if abs(end-start)<1e-6: continue
    p=(v-start)/(end-start)
    best=None
    for R in np.arange(0.10,0.80,0.005):
        for D in np.arange(0.50,1.001,0.01):
            e=np.sqrt(np.mean((spring(t,R,D)-p)**2))
            if best is None or e<best[0]: best=(e,R,D)
    e,R,D=best
    dt=np.diff(r['ft'])*1000; drops=int((dt>17.5).sum())
    i99=next((i for i in range(len(p)) if np.all(np.abs(1-p[i:])<=0.01)), len(p)-1)
    print(f"{r['label']:8s} frames={len(t):3d} from={start:8.2f} to={end:8.2f} fit response={R:.3f} damping={D:.2f} rmse={e:.4f} "
          f"99%={t[i99]*1000:.0f}ms ({round(t[i99]/(1/60))} fr) overshoot={max(0,(p.max()-1))*100:.1f}% dropped={drops}")
