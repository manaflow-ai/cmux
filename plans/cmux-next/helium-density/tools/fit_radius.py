# fit_radius.py IMG x0 y0 x1 y1 [corner=tl]  -- box in px of a filled rounded rect; fits its corner radius (px)
import sys
from PIL import Image
import numpy as np
im=np.asarray(Image.open(sys.argv[1]).convert('RGB')).astype(float)
x0,y0,x1,y1=map(int,sys.argv[2:6])
fill=im[(y0+y1)//2, x0+3]
bg=im[y0-2 if y0>=2 else y0, x0-2 if x0>=2 else x0] if True else None
bg=im[y0+1, max(0,x0-3)]
def cov(px): 
    d=fill-bg; n=np.dot(d,d)
    return np.clip(np.dot(px-bg,d)/n,0,1) if n>0 else 0
S=24; best=None
N=30
meas=np.array([[cov(im[y0+j,x0+i]) for i in range(N)] for j in range(N)])
for r10 in range(20,400,2):
    r=r10/10
    ys,xs=np.mgrid[0:N*S,0:N*S]/S
    cx=cy=r
    inside=~((xs<cx)&(ys<cy)&((xs-cx)**2+(ys-cy)**2>r*r))
    model=inside.reshape(N,S,N,S).mean(axis=(1,3))
    err=((model-meas)**2).sum()
    if best is None or err<best[0]: best=(err,r)
print('fill',fill,'bg',bg,'radius_px',best[1],'pt',best[1]/2,'err',round(best[0],3))
