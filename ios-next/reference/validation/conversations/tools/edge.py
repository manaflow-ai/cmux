"""edge.py VIDEO Y [--lo 228 --hi 240 --run 30] : per native frame, leftmost x (pt) of a >=run px neutral-gray run
whose pixel 1 pt to the left is brighter than 240. Prints 't_ms x_pt' relative to the first frame."""
import sys, subprocess, json, numpy as np
from PIL import Image
import io, argparse
ap = argparse.ArgumentParser(); ap.add_argument('video'); ap.add_argument('y', type=float)
ap.add_argument('--lo', type=int, default=228); ap.add_argument('--hi', type=int, default=240)
ap.add_argument('--run', type=int, default=30); ap.add_argument('--right', action='store_true')
ap.add_argument('--blue', action='store_true'); ap.add_argument('--bright', type=int, default=240)
ap.add_argument('--start', type=float, default=0); ap.add_argument('--dur', type=float, default=99)
a = ap.parse_args()
pts = subprocess.run(['ffprobe','-v','error','-select_streams','v','-show_entries','frame=pts_time','-of','csv=p=0',a.video],capture_output=True,text=True).stdout.split()
pts=[float(p.rstrip(',')) for p in pts]
w=1206; h=2622
raw = subprocess.run(['ffmpeg','-v','error','-i',a.video,'-fps_mode','passthrough','-vf',f'crop={w}:3:0:{int(a.y*3)}','-f','rawvideo','-pix_fmt','rgb24','-'],capture_output=True).stdout
n=len(raw)//(w*3*3)
for i in range(n):
    t=pts[i]
    if t < a.start or t > a.start + a.dur: continue
    row=np.frombuffer(raw[i*w*9:i*w*9+w*3],dtype=np.uint8).reshape(w,3).astype(int)
    r,g,b=row[:,0],row[:,1],row[:,2]
    ok=((b-r)>60)&(b>200) if a.blue else (abs(r-g)<6)&(abs(b-r)<8)&(r>=a.lo)&(r<=a.hi)
    idx=np.nonzero(ok)[0]; L=-1
    rng = range(len(idx)-a.run)
    if a.right: rng = range(len(idx)-1, a.run-1, -1)
    for k in rng:
        if not a.right:
            if idx[k+a.run]-idx[k]==a.run and idx[k]>=3 and row[idx[k]-3].min()>a.bright: L=idx[k]/3; break
        else:
            if idx[k]-idx[k-a.run]==a.run and idx[k]+3<w and row[idx[k]+3].min()>a.bright: L=(idx[k]+1)/3; break
    print(f'{t*1000:.1f} {L:.1f}')
