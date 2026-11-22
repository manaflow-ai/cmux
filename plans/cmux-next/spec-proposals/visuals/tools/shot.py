import sys, subprocess
from PIL import Image
# usage: shot.py out.png [x y w h in points]
out = sys.argv[1]
wid = open('/tmp/specvis/wid').read().strip()
subprocess.run(['screencapture','-x','-o','-l',wid,'/tmp/specvis/_full.png'],check=True)
im = Image.open('/tmp/specvis/_full.png')
if len(sys.argv) > 2:
    x,y,w,h = [float(v)*2 for v in sys.argv[2:6]]
    im = im.crop((int(x),int(y),int(x+w),int(y+h)))
im.save(out, optimize=True)
print(out, im.size)
