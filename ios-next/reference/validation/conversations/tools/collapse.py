"""collapse.py VIDEO: per frame, large-title ink top (x16-150, y 64-175) and inline title ink amount (x150-252, y74-96)."""
import sys, subprocess, numpy as np
v=sys.argv[1]; dark=len(sys.argv)>2
pts=[float(p.rstrip(',')) for p in subprocess.run(['ffprobe','-v','error','-select_streams','v','-show_entries','frame=pts_time','-of','csv=p=0',v],capture_output=True,text=True).stdout.split()]
W,H=1206,2622
raw=subprocess.run(['ffmpeg','-v','error','-i',v,'-fps_mode','passthrough','-vf','crop=1206:540:0:0,format=gray','-f','rawvideo','-'],capture_output=True).stdout
n=len(raw)//(W*540)
prev=None
for i in range(n):
    a=np.frombuffer(raw[i*W*540:(i+1)*W*540],dtype=np.uint8).reshape(540,W).astype(int)
    big=a[64*3:175*3, 16*3:150*3] < 90
    rows=np.nonzero(big.sum(1)>3)[0]
    top=(rows[0]/3+64) if len(rows) else -1
    inl=(a[74*3:96*3, 150*3:252*3] < 90).sum()
    line=f'{pts[i]*1000:.1f} {top:.1f} {inl}'
    if line.split()[1:]!=prev: print(line)
    prev=line.split()[1:]
