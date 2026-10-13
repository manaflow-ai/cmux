# scroll-reversals.py <frames dir>: per-frame vertical shift by row-profile correlation; counts frames that move against their fling (row-sized = rows and view position out of step).
import glob, sys, numpy as np
from PIL import Image
files = sorted(glob.glob(sys.argv[1] + "/f_*.png"))
prof = [np.asarray(Image.open(f), dtype=np.float32).mean(axis=1) for f in files]
def shift(a, b, maxs=110):
    a=a-a.mean(); b=b-b.mean(); best,bs=-1e18,0
    for s in range(-maxs,maxs+1):
        x=a[max(0,s):len(a)+min(0,s)]; y=b[max(0,-s):len(b)+min(0,-s)]
        v=float((x*y).sum())/len(x)
        if v>best: best,bs=v,s
    return bs
d=[shift(prof[i-1],prof[i]) for i in range(1,len(prof))]
segs=[];cur=[];last=-10
for i,v in enumerate(d):
    if v:
        if cur and i-last>3: segs.append(cur);cur=[]
        cur.append(v); last=i
segs.append(cur)
tot=0; big=0; moving=0
for vals in segs:
    if len(vals)<6: continue
    main=1 if sum(vals)>0 else -1
    moving+=len(vals)
    rev=[v for v in vals if v*main<0]
    tot+=len(rev); big+=sum(1 for v in rev if abs(v)>=12)
print(f"{sys.argv[1]}: frames {len(files)} moving {moving} reversals {tot} row-sized reversals {big}")
