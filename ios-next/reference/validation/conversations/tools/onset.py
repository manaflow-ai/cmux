"""onset.py VIDEO [x y w h pts]: first frame time (ms) whose crop differs from the first frame (>0.3% px changed by >24)."""
import sys, subprocess, numpy as np
v=sys.argv[1]; x,y,w,h=[float(a) for a in sys.argv[2:6]] if len(sys.argv)>5 else (0,0,402,874)
after=float(sys.argv[6]) if len(sys.argv)>6 else 0
pts=[float(p.rstrip(',')) for p in subprocess.run(['ffprobe','-v','error','-select_streams','v','-show_entries','frame=pts_time','-of','csv=p=0',v],capture_output=True,text=True).stdout.split()]
W,H=int(w),int(h)
raw=subprocess.run(['ffmpeg','-v','error','-i',v,'-fps_mode','passthrough','-vf',f'crop={int(w*3)}:{int(h*3)}:{int(x*3)}:{int(y*3)},scale={W}:{H},format=gray','-f','rawvideo','-'],capture_output=True).stdout
n=len(raw)//(W*H); base=None
for i in range(n):
    a=np.frombuffer(raw[i*W*H:(i+1)*W*H],dtype=np.uint8).astype(int)
    if pts[i]*1000<after: continue
    if base is None: base=a; continue
    if (np.abs(a-base)>24).mean()>0.003: print(f'{pts[i]*1000:.1f}'); break
