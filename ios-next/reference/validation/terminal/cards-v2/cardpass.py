# cardpass.py DIR LABEL: all captures in DIR (png + ax.json, grid at various
# scrolls). Terminal cards = buttons whose label is a known terminal title
# (has a matching "Close <title>" and a terminal glyph in the title row is not
# in AX, so: buttons titled Terminal/zsh/cmux/... given by regex in env TITLES).
# Dedupes cards by their index among all cards in the AX list (stable order).
import sys, json, re, glob, os
import numpy as np
from PIL import Image
d, label = sys.argv[1:3]
rx = os.environ.get("TITLES", r"Terminal|zsh.*|top|cmux|Respond to greeting.*")
seen = {}
for png in sorted(glob.glob(d + "/*.png")):
    axp = png[:-4] + ".ax.json"
    if not os.path.exists(axp): continue
    im = np.asarray(Image.open(png).convert("RGB")).astype(np.int16)
    H, W, _ = im.shape; s = W / 402.0
    cards = []
    def walk(n):
        if isinstance(n, list):
            for x in n: walk(x)
        elif isinstance(n, dict):
            l = n.get("AXLabel") or ""; f = n.get("frame") or {}
            if n.get("type") == "Button" and 240 < f.get("height", 0) < 320: cards.append((l, f))
            walk(n.get("children", []))
    walk(json.load(open(axp)))
    for idx, (l, f) in enumerate(cards):
        if not re.fullmatch(rx, l): continue
        top, bottom = max(f["y"] + 8, 60), min(f["y"] + f["height"] - 25 - 8, 650)
        # The card's top (where a shell prompt draws) must be on screen, and
        # at least 120 pt of it.
        if f["y"] + 8 < 60 or bottom - top < 120: continue
        x0, x1 = int((f["x"] + 6) * s), int((f["x"] + f["width"] - 6) * s)
        c = im[int(top * s):int(bottom * s), x0:x1].reshape(-1, 3)
        bg = np.median(c, axis=0); diff = np.abs(c - bg).max(axis=1)
        content = (diff > 40).mean()
        chroma = c.max(axis=1) - c.min(axis=1)
        colour = ((chroma > 50) & (diff > 40)).mean()
        lum = 0.2126*bg[0] + 0.7152*bg[1] + 0.0722*bg[2]
        key = idx
        rec = (l, "dark" if lum < 90 else "light", content, colour, os.path.basename(png))
        if key not in seen or content > seen[key][2]: seen[key] = rec
print("label,card_index,title,bg,content_frac,colour_frac,glyph_px_colour_share,verdict,capture")
blank = 0
for k in sorted(seen):
    l, bg, content, colour, cap = seen[k]
    share = colour / content if content else 0
    v = "BLANK" if content < 0.0005 else "content"
    blank += v == "BLANK"
    print(f"{label},{k},{l},{bg},{content*100:.2f}%,{colour*100:.3f}%,{share*100:.1f}%,{v},{cap}")
print(f"# {label}: {len(seen)} terminal cards, {blank} blank, bg={sorted(set(r[1] for r in seen.values()))}", file=sys.stderr)
