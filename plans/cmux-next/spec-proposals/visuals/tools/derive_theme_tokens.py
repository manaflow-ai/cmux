"""Python port of CmuxTheme ThemeTokens.derive (ThemeTokens.swift), AppTheme.derive (AppTheme.swift,
for the hued accent of appearance.accent) and ChromeEmphasis.emphasized.

A reference theme's 'accent' is appearance.accent (default neutral); 'accentColor' is the theme's own
accent (appearance.themeEdits <theme>/accent, else the theme file's '# cmux-accent = #rrggbb'), which
wins over 'accent'; 'cursor' is cursor-color (caret).
The AppTheme port reproduces schemas/theme/app-theme-vectors.json (the web module's output):
  derive_theme_tokens.py --check-app-vectors app-theme-vectors.json
The ink port writes and checks schemas/theme/theme-ink-vectors.json: every bundled theme's text inks
and popup surface (ThemeTokens.opaqueOverlayFill), which the Swift, Rust and web ports replay
(CmuxNextDesignTests ThemeInkVectorsTests checks the file is Swift's output):
  derive_theme_tokens.py --theme-ink-vectors          # write
  derive_theme_tokens.py --check-theme-ink-vectors    # exit 1 when stale

Hex output rounds each channel half away from zero, as Swift's .rounded() does in
ThemeRGB.description (0.30 * 255 = 76.5 -> 77 = 0x4D). Do not use Python round(),
which rounds half to even.

usage: derive_theme_tokens.py [OUT.json]   (stdout when no path is given)
"""
import json, math, os, re, sys
FADE_STEP=0.02      # ChromeEmphasis.swift ThemeTokens.emphasized: fade() steps the fraction down by 0.02
READABLE_STEP=0.02  # ThemeTokens.readable: steps toward white or black by 0.02
MUTED_STEP=0.01     # ThemeTokens.muted: steps the mix fraction down by 0.01
def ch(v): return int(math.floor(v*255+0.5))  # Swift (v * 255).rounded(), v >= 0
def clamp(v): return min(max(v,0.0),1.0)
class C:
    def __init__(s,r,g,b,a=1.0): s.r,s.g,s.b,s.a=clamp(r),clamp(g),clamp(b),clamp(a)
    @staticmethod
    def hex(h,a=1.0): return C(((h>>16)&255)/255,((h>>8)&255)/255,(h&255)/255,a)
    def lum(s):
        f=lambda c: c/12.92 if c<=0.04045 else ((c+0.055)/1.055)**2.4
        return 0.2126*f(s.r)+0.7152*f(s.g)+0.0722*f(s.b)
    def contrast(s,o):
        a,b=s.lum(),o.lum(); return (max(a,b)+0.05)/(min(a,b)+0.05)
    def mixed(s,o,t):
        t=clamp(t); return C(s.r+(o.r-s.r)*t,s.g+(o.g-s.g)*t,s.b+(o.b-s.b)*t,s.a)
    def wa(s,a): return C(s.r,s.g,s.b,a)
    def comp(s,base): return base.mixed(s.wa(1),s.a).wa(1)
    def css(s):
        h='#%02X%02X%02X'%(ch(s.r),ch(s.g),ch(s.b))
        return h if s.a>=1 else h+'%02X'%ch(s.a)
BLACK,WHITE=C(0,0,0),C(1,1,1)
def readable(c,surf,m):
    if c.contrast(surf)>=m: return c
    pole=WHITE if surf.lum()<0.18 else BLACK
    step=0.0; cand=c
    while step<1 and cand.contrast(surf)<m:
        step+=READABLE_STEP; cand=c.mixed(pole,step)
    return cand
def readable_over(c,surfs,pole,m):
    """ThemeTokens.readable(_:over:toward:minimum:): c walked toward pole until it reads on every surface."""
    step=0.0; cand=c
    while step<1 and not all(cand.contrast(x)>=m for x in surfs):
        step+=READABLE_STEP; cand=c.mixed(pole,step)
    return cand
def inks(fg,rows,see_through,bg):
    """ThemeTokens.inks: primary, secondary and tertiary text read on every surface in rows (the
    strongest row fill and the bare background). fg is walked toward white and toward black (the pole
    that reads better on rows[0] first); the candidate whose primary and secondary keep the higher
    least contrast over rows wins, capped at 4.5 (a tie keeps the first)."""
    least=lambda ink: min(ink.contrast(r) for r in rows)
    poles=sorted([WHITE,BLACK],key=lambda p: p.contrast(rows[0]),reverse=True)
    chosen=None
    for pole in poles:
        primary=readable_over(fg,rows,pole,4.5)
        ink=min(rows+see_through,key=lambda c: primary.contrast(c))
        secondary=muted(primary,bg,0.38,ink,4.5); tertiary=muted(primary,bg,0.55,ink,3.0)
        score=min(least(primary),least(secondary),4.5)
        if chosen is None or score>chosen[0]: chosen=(score,(primary,secondary,tertiary))
    return chosen[1]
def muted(c,target,limit,surf,m):
    f=limit
    while f>0:
        cand=c.mixed(target,f)
        if cand.contrast(surf)>=m: return cand
        f-=MUTED_STEP
    return c
# AppTheme.swift AppColor (the web color.ts): 8-bit quantizing, WCAG contrast, OKLCH lightness fits.
def q(c): return C(ch(c.r)/255,ch(c.g)/255,ch(c.b)/255)
def lin(c): return c/12.92 if c<=0.04045 else ((c+0.055)/1.055)**2.4
def gam(c): return c*12.92 if c<=0.0031308 else 1.055*c**(1/2.4)-0.055
def cbrt(v): return math.copysign(abs(v)**(1/3),v)
def oklch(c):
    r,g,b=lin(c.r),lin(c.g),lin(c.b)
    l=cbrt(0.4122214708*r+0.5363325363*g+0.0514459929*b); m=cbrt(0.2119034982*r+0.6806995451*g+0.1073969566*b); s=cbrt(0.0883024619*r+0.2817188376*g+0.6299787005*b)
    L=0.2104542553*l+0.793617785*m-0.0040720468*s; a=1.9779984951*l-2.428592205*m+0.4505937099*s; bb=0.0259040371*l+0.7827717662*m-0.808675766*s
    h=math.degrees(math.atan2(bb,a)); return (L,math.hypot(a,bb),h+360 if h<0 else h)
def to_lin(L,c,h):
    a,b=c*math.cos(math.radians(h)),c*math.sin(math.radians(h))
    l=(L+0.3963377774*a+0.2158037573*b)**3; m=(L-0.1055613458*a-0.0638541728*b)**3; s=(L-0.0894841775*a-1.291485548*b)**3
    return (4.0767416621*l-3.3077115913*m+0.2309699292*s,-1.2684380046*l+2.6097574011*m-0.3413193965*s,-0.0041960863*l-0.7034186147*m+1.707614701*s)
def gamut(rgb): return all(-1e-4<=v<=1+1e-4 for v in rgb)
def from_oklch(L,c,h):
    L=clamp(L); lo,hi=0.0,max(c,0.0)
    if not gamut(to_lin(L,hi,h)):
        for _ in range(24):
            mid=(lo+hi)/2
            if gamut(to_lin(L,mid,h)): lo=mid
            else: hi=mid
        hi=lo
    r,g,b=to_lin(L,hi,h); f=lambda v: clamp(gam(clamp(v)))
    return C(f(r),f(g),f(b))
def meets(c,cons): return all(c.contrast(on)>=m for on,m in cons)
def fit(color,cons,prefer):
    start=q(color)
    if meets(start,cons): return start
    L,c,h=oklch(start)
    avg=sum(on.lum() for on,_ in cons)/max(len(cons),1)
    first=prefer or ('lighter' if avg<0.18 else 'darker')
    for d in (first,'darker' if first=='lighter' else 'lighter'):
        pole=1.0 if d=='lighter' else 0.0
        at=lambda t: q(from_oklch(L+(pole-L)*t,c,h))
        if not meets(at(1),cons): continue
        lo,hi=0.0,1.0
        for _ in range(28):
            mid=(lo+hi)/2
            if meets(at(mid),cons): hi=mid
            else: lo=mid
        return at(hi)
    w=min([WHITE.contrast(on) for on,_ in cons] or [0]); k=min([BLACK.contrast(on) for on,_ in cons] or [0])
    return WHITE if w>=k else BLACK
ACCENT_SLOT=dict(red=1,green=2,yellow=3,blue=4,magenta=5,cyan=6)
PLAIN=['window','sidebar','content','elevated']; TEXTS=PLAIN+['control','hover','pressed','selection']; STATUS=PLAIN+['hover']
APP_CONTRACT=([('text',o,4.5) for o in TEXTS]+[('textSecondary',o,4.5) for o in TEXTS]+[('icon',o,3.0) for o in TEXTS]
  +[('controlStroke',o,3.0) for o in PLAIN+['control']]+[('accent',o,3.0) for o in PLAIN]+[('focusRing',o,3.0) for o in PLAIN]
  +[('onAccent','accent',4.5)]+[('accentText',o,4.5) for o in STATUS+['selection']]
  +[(n,o,4.5) for n in ('danger','warning','success') for o in STATUS])
def colorful(pal,n,b): return pal[b] if oklch(pal[b])[1]>oklch(pal[n])[1]+0.02 else pal[n]
def accent_seed(accent,fg,pal):
    if isinstance(accent,C): return accent  # AccentSource.color: the theme's own accent
    neutral=from_oklch(oklch(fg)[0],0,0)
    if accent in ACCENT_SLOT: s=ACCENT_SLOT[accent]; return colorful(pal,s,s+8)
    if accent!='theme': return neutral
    for name in ('magenta','blue','cyan'):
        s=ACCENT_SLOT[name]; c=colorful(pal,s,s+8)
        if oklch(c)[1]>=0.05: return c
    return neutral
def app_derive_at(bg,fg,pal,accent,tint):
    dark=bg.lum()<fg.lum(); d=lambda a,b: a if dark else b
    t={}; window=q(bg); t['window']=window; t['content']=q(bg)
    t['sidebar']=q(bg.mixed(fg,d(0.04,0.035)*tint)); t['elevated']=q(bg.mixed(fg,0.075*tint) if dark else bg.mixed(WHITE,0.7*tint))
    t['control']=q(bg.mixed(fg,d(0.1,0.065)*tint)); t['hover']=q(bg.mixed(fg,d(0.06,0.045)*tint)); t['pressed']=q(bg.mixed(fg,d(0.12,0.09)*tint))
    t['separator']=q(bg.mixed(fg,d(0.13,0.11)))
    on=lambda names,m: [(t[n],m) for n in names]
    away='lighter' if dark else 'darker'
    want=window if dark else WHITE
    acc=fit(accent_seed(accent,fg,pal),on(PLAIN,3.0)+[(want,4.5)],away); t['accent']=acc; t['focusRing']=acc
    t['onAccent']=want if meets(want,[(acc,4.5)]) else fit(BLACK if dark else WHITE,[(acc,4.5)],None)
    t['selection']=q(bg.mixed(acc,d(0.26,0.16)*tint))
    text=fit(fg,on(TEXTS,4.5),None); t['text']=text
    t['textSecondary']=fit(text.mixed(bg,0.34),on(TEXTS,4.5),away); t['icon']=fit(text.mixed(bg,0.3),on(TEXTS,3.0),away)
    t['controlStroke']=fit(bg.mixed(fg,0.42),on(PLAIN+['control'],3.0),away)
    t['accentText']=fit(acc,on(STATUS+['selection'],4.5),away)
    t['danger']=fit(colorful(pal,1,9),on(STATUS,4.5),away); t['warning']=fit(colorful(pal,3,11),on(STATUS,4.5),away); t['success']=fit(colorful(pal,2,10),on(STATUS,4.5),away)
    return dark,t
def app_derive(bg,fg,pal,accent='neutral'):
    """AppTheme.derive: bg, fg and the 16 palette colors as C; tint scales tried until every contract pair passes."""
    bg,fg=bg.wa(1),fg.wa(1)
    for tint in (1,0.7,0.45,0.25,0.1,0):
        dark,t=app_derive_at(bg,fg,pal,accent,tint)
        if all(t[a].contrast(t[b])>=m for a,b,m in APP_CONTRACT): break
    return dark,t
GHOSTTY_DEFAULT_PAL=[0x1D1F21,0xCC6666,0xB5BD68,0xF0C674,0x81A2BE,0xB294BB,0x8ABEB7,0xC5C8C6,0x666666,0xD54E53,0xB9CA4A,0xE7C547,0x7AA6DA,0xC397D8,0x70C0B1,0xEAEAEA]
def derive(bg,fg,pal,sel=None,opacity=1.0,accent='neutral',cursor=None,accent_color=None):
    # AppTheme fills a missing slot with Ghostty's default; ThemeTokens takes the default palette under 8 slots.
    app_pal=[C.hex(pal[i] if i<len(pal) else GHOSTTY_DEFAULT_PAL[i]) for i in range(16)]
    bg,fg=C.hex(bg),C.hex(fg); pal=[C.hex(p) for p in (pal if len(pal)>=8 else GHOSTTY_DEFAULT_PAL)]
    dark=bg.lum()<fg.lum()
    # The app accent when appearance.accent or the theme names one; None keeps the neutral fills.
    source=C.hex(accent_color) if accent_color is not None else accent
    app=app_derive(bg,fg,app_pal,source)[1] if accent!='neutral' or accent_color is not None else None
    acc=app['accent'] if app else None
    hover=fg.wa(0.06 if dark else 0.05); pressed=fg.wa(0.14 if dark else 0.11)
    selection=acc.wa(0.26 if dark else 0.16) if acc else fg.wa(0.10 if dark else 0.08)
    # Swift: the lower-contrast of pressedFill and selectionFill over bg (pressed, with the neutral accent).
    worst=min([pressed.comp(bg),selection.comp(bg)],key=lambda c: fg.contrast(c))
    # See-through window: the quieter inks also hold over the tint on the worst desktop for the theme.
    see=[]
    if opacity<1:
        tint=bg.wa(opacity).comp(WHITE if dark else BLACK)
        see=[tint,pressed.comp(tint),selection.comp(tint)]
    primary,secondary,tertiary=inks(fg,[worst,bg],see,bg)
    status=lambda i: readable(pal[i],bg,3.0)
    hl=acc if acc else status(4)
    best=lambda cs: max(cs,key=lambda c:c.contrast(hl))
    themed=best([bg.wa(1),primary.wa(1)])
    hlt=themed if themed.contrast(hl)>=4.5 else best([C.hex(0),C.hex(0xFFFFFF)])
    surf=bg.wa(opacity)
    # The config's selection-background only when textPrimary reads on it (not an inverse-video selection).
    csel=C.hex(sel) if sel is not None and primary.contrast(C.hex(sel).comp(bg))>=3.0 else None
    t=dict(windowBackground=surf,sidebarBackground=surf,contentBackground=surf,
      chromeBackground=bg.mixed(fg,0.05 if dark else 0.035),elevatedBackground=bg.mixed(fg,0.07 if dark else 0.02),
      stripBackground=surf,
      sidebarStep=fg.wa(0.04),stripStep=BLACK.wa(0.22 if dark else 0.05),
      textPrimary=primary,textSecondary=secondary,textTertiary=tertiary,hoverFill=hover,selectionFill=selection,
      secondarySelectionFill=acc.wa(0.18 if dark else 0.11) if acc else fg.wa(0.07 if dark else 0.055),pressedFill=pressed,badgeFill=fg.wa(0.14 if dark else 0.10),
      separator=fg.wa(0.08 if dark else 0.07),paneBorder=fg.wa(0.07 if dark else 0.09),focusRing=acc if acc else fg.wa(0.40),
      glassTint=bg.wa(0.40 if dark else 0.30),shadow=bg.mixed(BLACK,0.85),
      textSelection=csel if csel is not None else bg.mixed(fg,0.22),
      attention=status(3),danger=status(1),success=status(2),highlight=hl,highlightText=hlt,
      accent=acc if acc else primary,onAccent=app['onAccent'] if app else bg.wa(1),
      caret=readable(C.hex(cursor),bg,3.0) if cursor is not None else primary)
    return dark,t,pal
OVERLAY_LIFT=0.14  # ChromeTunables.opaqueOverlayLift default (the vectors file's "lift")
def opaque_overlay_fill(t,dark,lift):
    """ThemeTokens.opaqueOverlayFill (OverlayMaterial.swift): the opaque window background lifted by lift
    toward white, or on a dark theme whose text is lighter than its page toward the text, stepping down
    by 0.01 until secondary text keeps 4.5:1 on a hovered row."""
    page=t['windowBackground'].wa(1); text=t['textPrimary'].wa(1)
    if not dark or text.lum()<page.lum(): return page.mixed(WHITE,lift)
    secondary=t['textSecondary'].wa(1); step=math.floor(lift*100+0.5)/100
    while step>0:
        fill=page.mixed(text,step)
        if secondary.contrast(t['hoverFill'].comp(fill))>=4.5: return fill
        step-=0.01
    return page
def emphasized(t,style,s):
    t=dict(t); page=t['contentBackground'].wa(1)
    def fade(c,f,floor):
        target=min(floor,c.contrast(page))
        while f>0 and c.mixed(page,f).contrast(page)<target: f-=FADE_STEP
        return c.mixed(page,max(f,0))
    p,se,te,sel,hov=t['textPrimary'],t['textSecondary'],t['textTertiary'],t['selectionFill'],t['hoverFill']
    if style=='fade':
        t['textPrimary']=fade(p,s,3.5); t['textSecondary']=fade(se,s,2.5); t['textTertiary']=fade(te,s,2.0)
        t['selectionFill']=sel.wa(sel.a*(1-s)); t['hoverFill']=hov.wa(hov.a*(1-s))
    elif style=='tonal':
        t['textPrimary']=se; t['textSecondary']=te; t['textTertiary']=fade(te,s*0.5,2.0); t['selectionFill']=hov.wa(hov.a*(1-s*0.5))
    elif style=='quiet':
        t['textPrimary']=se; t['textSecondary']=fade(te,s*0.5,2.5); t['textTertiary']=fade(te,s*0.5,2.0); t['selectionFill']=sel.wa(0)
    return t
THEMES={
 'appleSystemDark':dict(name='Apple System Colors (cmux default, dark appearance)',bg=0x1E1E1E,fg=0xFFFFFF,sel=0x3F638B,pal=[0x1a1a1a,0xcc372e,0x26a439,0xcdac08,0x0869cb,0x9647bf,0x479ec2,0x98989d,0x464646,0xff453a,0x32d74b,0xffd60a,0x0a84ff,0xbf5af2,0x76d6ff,0xffffff]),
 'appleSystemLight':dict(name='Apple System Colors Light (cmux default, light appearance)',bg=0xFEFFFF,fg=0x000000,sel=0xABD8FF,pal=[0x1a1a1a,0xcc372e,0x26a439,0xcdac08,0x0869cb,0x9647bf,0x479ec2,0x98989d,0x464646,0xff453a,0x32d74b,0xe5bc00,0x0a84ff,0xbf5af2,0x69c9f2,0xffffff]),
 'ghosttyDefault':dict(name="Ghostty built-in default (ThemeInput.ghosttyDefault, used until the config is read)",bg=0x282C34,fg=0xFFFFFF,sel=None,pal=GHOSTTY_DEFAULT_PAL),
 'monokaiClassic':dict(name='Monokai Classic (test fixture)',bg=0x272822,fg=0xFDFFF1,sel=0x57584F,pal=[0x272822,0xF92672,0xA6E22E,0xE6DB74,0xFD971F,0xAE81FF,0x66D9EF,0xFDFFF1,0x6E7066,0xF92672,0xA6E22E,0xE6DB74,0xFD971F,0xAE81FF,0x66D9EF,0xFDFFF1]),
 'githubLight':dict(name='GitHub Light Default (test fixture)',bg=0xFFFFFF,fg=0x1F2328,sel=None,pal=[0x24292F,0xCF222E,0x116329,0x4D2D00,0x0969DA,0x8250DF,0x1B7C83,0x6E7781,0x57606A,0xA40E26,0x1A7F37,0x633C01,0x218BFF,0xA475F9,0x3192AA,0x8C959F]),
}
# The Apple System Colors files name cursor-color = #98989d (caret).
for k in ('appleSystemDark','appleSystemLight'): THEMES[k]['cursor']=0x98989D
# appearance.accent cases (the hued accent): the cmux default theme in both appearances, and theme on Monokai.
for k in ('appleSystemDark','appleSystemLight'):
    for a in ('red','green','blue'):
        THEMES[k+a.capitalize()]=dict(THEMES[k],name=THEMES[k]['name']+', appearance.accent = '+a,accent=a)
THEMES['monokaiClassicTheme']=dict(THEMES['monokaiClassic'],name=THEMES['monokaiClassic']['name']+', appearance.accent = theme',accent='theme')
# A theme's own accent (a <theme>/accent edit or the file's # cmux-accent) wins over appearance.accent = blue.
THEMES['appleSystemDarkOwnAccent']=dict(THEMES['appleSystemDark'],name=THEMES['appleSystemDark']['name']+", appearance.accent = blue, the theme's own accent #ff9f0a",accent='blue',accent_color=0xFF9F0A)
THEMES['githubLightOwnAccent']=dict(THEMES['githubLight'],name=THEMES['githubLight']['name']+", the theme's own accent #bf3989",accent_color=0xBF3989)
if len(sys.argv)>2 and sys.argv[1]=='--check-app-vectors':
    # Replays the web module's vectors (neutral and theme accents) through the AppTheme port; exit 1 on any difference.
    # input.accentColor is the theme's own accent (# cmux-accent); it wins over the case's accent, as in derive().
    cases=json.load(open(sys.argv[2]))['cases']; bad=0
    for case in cases:
        i=case['input']; h=lambda x: C.hex(int(x[1:],16))
        source=h(i['accentColor']) if i.get('accentColor') else case.get('accent','neutral')
        dark,t=app_derive(h(i['background']),h(i['foreground']),[h(x) for x in i['palette']]+[C.hex(GHOSTTY_DEFAULT_PAL[n]) for n in range(len(i['palette']),16)],source)
        for n,want in case['tokens'].items():
            if t[n].css().lower()!=want.lower(): bad+=1; print(case['name'],n,'want',want,'got',t[n].css())
        if dark!=case['isDark']: bad+=1; print(case['name'],'isDark')
    print(len(cases),'cases,',bad,'differences'); sys.exit(1 if bad else 0)
ROOT=os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)),'../../../../..'))
INK_VECTORS=os.path.join(ROOT,'schemas/theme/theme-ink-vectors.json')
THEME_FOLDERS=('Resources/ghostty/themes','Resources/cmux-themes')  # what the app bundles
NEWLINES=re.compile('\r\n|[\n\r\x0b\x0c\x85\u2028\u2029]')
def six_digit(text):
    d=text[1:] if text.startswith('#') else text
    return int(d,16) if len(d)==6 and re.fullmatch('[0-9A-Fa-f]{6}',d) else None
def theme_file_colors(text):
    """ThemeFileColors(name:themeFile:): background, foreground, palette (None where unset) and the
    '# cmux-accent = #rrggbb' accent; None without a background and a foreground."""
    values={}; pal=[None]*16; accent=None
    for raw in NEWLINES.split(text):
        line=raw.strip(' \t').replace('\ufeff','')
        if line.startswith('#'):
            body=line[1:].strip(' \t')
            if '=' in body and body.split('=',1)[0].strip(' \t')=='cmux-accent':
                c=six_digit(body.split('=',1)[1].strip(' \t'))
                if c is not None: accent=c
        if not line or line.startswith('#') or '=' not in line: continue
        key,value=(x.strip(' \t') for x in line.split('=',1))
        if key=='palette':
            parts=[x.strip(' \t') for x in value.split('=',1)]
            if len(parts)!=2 or not re.fullmatch('[0-9]+',parts[0]) or not 0<=int(parts[0])<16: continue
            c=six_digit(parts[1])
            if c is not None: pal[int(parts[0])]=c
        else:
            c=six_digit(value)
            if c is not None: values[key]=c
    if 'background' not in values or 'foreground' not in values: return None
    return values['background'],values['foreground'],pal,accent
def theme_ink_vectors():
    """schemas/theme/theme-ink-vectors.json: one row per bundled theme, in the app's reading
    (CardNeverOpaqueTests.bundledThemes: the Ghostty default fills an unset palette slot)."""
    rows=[]
    for folder in THEME_FOLDERS:
        directory=os.path.join(ROOT,folder)
        for name in sorted(n for n in os.listdir(directory) if not n.startswith('.')):
            colors=theme_file_colors(open(os.path.join(directory,name),encoding='utf-8').read())
            if colors is None: continue
            bg,fg,pal,accent=colors
            pal=[p if p is not None else GHOSTTY_DEFAULT_PAL[i] for i,p in enumerate(pal)]
            dark,t,_=derive(bg,fg,pal,accent_color=accent)
            inp={'background':C.hex(bg).css(),'foreground':C.hex(fg).css()}
            # The palette only reaches the inks through the theme's own accent (AppTheme).
            if accent is not None: inp.update(accentColor=C.hex(accent).css(),palette=[C.hex(p).css() for p in pal])
            rows.append({'theme':folder[len('Resources/'):]+'/'+name,'input':inp,'isDark':dark,
                **{n:t[n].css() for n in ('textPrimary','textSecondary','textTertiary')},
                'opaqueOverlayFill':opaque_overlay_fill(t,dark,OVERLAY_LIFT).css()})
    head={'generator':'plans/cmux-next/spec-proposals/visuals/tools/derive_theme_tokens.py --theme-ink-vectors (do not edit)',
          'checkedBy':'CmuxNextDesignTests ThemeInkVectorsTests (Swift), cmux-theme-tokens derive_matches_the_swift_ink_vectors (Rust), webviews/test/theme-ink-vectors.test.ts (web, this tool)',
          'lift':OVERLAY_LIFT}
    # One theme per line keeps the file short and its diffs readable.
    return ('{\n'+''.join('%s: %s,\n'%(json.dumps(k),json.dumps(v)) for k,v in head.items())
            +'"cases": [\n'+',\n'.join(json.dumps(r,separators=(',',':'),ensure_ascii=False) for r in rows)+'\n]\n}\n')
if len(sys.argv)>1 and sys.argv[1] in ('--theme-ink-vectors','--check-theme-ink-vectors'):
    path=sys.argv[2] if len(sys.argv)>2 else INK_VECTORS; text=theme_ink_vectors()
    if sys.argv[1]=='--theme-ink-vectors':
        open(path,'w',encoding='utf-8').write(text); print('wrote',path); sys.exit(0)
    current=open(path,encoding='utf-8').read() if os.path.exists(path) else ''
    if current==text: print(path,'is current'); sys.exit(0)
    want={r['theme']:r for r in (json.loads(l.rstrip(',')) for l in current.splitlines() if l.startswith('{"theme"'))}
    got={r['theme']:r for r in (json.loads(l.rstrip(',')) for l in text.splitlines() if l.startswith('{"theme"'))}
    for k in sorted(set(want)|set(got)):
        if want.get(k)!=got.get(k): print(k,'file',json.dumps(want.get(k)),'port',json.dumps(got.get(k)))
    print(path,'differs from this port; regenerate with --theme-ink-vectors once the ports agree'); sys.exit(1)
out={}
for k,v in THEMES.items():
    dark,t,pal=derive(v['bg'],v['fg'],v['pal'],v['sel'],accent=v.get('accent','neutral'),cursor=v.get('cursor'),accent_color=v.get('accent_color'))
    bg=C.hex(v['bg'])
    inp={'background':C.hex(v['bg']).css(),'foreground':C.hex(v['fg']).css(),
        'selectionBackground':C.hex(v['sel']).css() if v['sel'] is not None else None,'palette':[p.css() for p in pal]}
    if v.get('cursor') is not None: inp['cursor']=C.hex(v['cursor']).css()
    if v.get('accent','neutral')!='neutral': inp['accent']=v['accent']
    if v.get('accent_color') is not None: inp['accentColor']=C.hex(v['accent_color']).css()
    e={'name':v['name'],'isDark':dark,'input':inp,
       'tokens':{n:c.css() for n,c in t.items()},
       'composited':{n:c.comp(bg).css() for n,c in t.items() if c.a<1},
       'focusRing':{lvl:t['focusRing'].wa(a).css() for lvl,a in (('subtle',0.20),('standard',0.55),('strong',0.85))},
       'inactiveTabs':{st:{n:emphasized(t,st,0.35)[n].css() for n in ('textPrimary','textSecondary','textTertiary','selectionFill','hoverFill')} for st in ('fade','tonal','quiet')}}
    out[k]=e
if len(sys.argv)>1:
    json.dump(out,open(sys.argv[1],'w'),indent=1)
else:
    json.dump(out,sys.stdout,indent=1); print()
