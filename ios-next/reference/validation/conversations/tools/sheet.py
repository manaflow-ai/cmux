"""sheet.py OUT STEP_MS N CROP(x,y,w,h pts) WIDTH REF REF_T0 IMPL IMPL_T0 : two-row strip, ref on top, impl below."""
import sys, subprocess, io
from PIL import Image, ImageDraw
out, step, n, crop, width = sys.argv[1], float(sys.argv[2]), int(sys.argv[3]), [float(a) for a in sys.argv[4].split(',')], int(sys.argv[5])
pairs = [(sys.argv[6], float(sys.argv[7])), (sys.argv[8], float(sys.argv[9]))]
x, y, w, h = crop
rows = []
for v, t0 in pairs:
    row = []
    for k in range(n):
        t = (t0 + k * step) / 1000
        png = subprocess.run(['ffmpeg', '-v', 'error', '-ss', f'{t:.3f}', '-i', v, '-frames:v', '1', '-vf',
                              f'crop={int(w*3)}:{int(h*3)}:{int(x*3)}:{int(y*3)},scale={width}:-2', '-f', 'image2pipe', '-vcodec', 'png', '-'],
                             capture_output=True).stdout
        row.append(Image.open(io.BytesIO(png)).convert('RGB'))
    rows.append(row)
fw, fh = rows[0][0].size
sheet = Image.new('RGB', (fw * n, (fh + 14) * 2), 'white')
d = ImageDraw.Draw(sheet)
for r, row in enumerate(rows):
    for k, im in enumerate(row):
        sheet.paste(im.resize((fw, fh)), (k * fw, r * (fh + 14) + 14))
        d.text((k * fw + 3, r * (fh + 14) + 1), f"{'ref' if r == 0 else 'impl'} +{int(k*step)}ms", fill=(200, 0, 0))
sheet.quantize(colors=128).save(out, optimize=True)
