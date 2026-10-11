"""Python port of CmuxTheme ThemeTokens.derive (ThemeTokens.swift) and ChromeEmphasis.emphasized.

Hex output rounds each channel half away from zero, as Swift's .rounded() does in
ThemeRGB.description (0.30 * 255 = 76.5 -> 77 = 0x4D). Do not use Python round(),
which rounds half to even.

usage: derive_theme_tokens.py [OUT.json]   (stdout when no path is given)
"""
import json, math, sys
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
def muted(c,target,limit,surf,m):
    f=limit
    while f>0:
        cand=c.mixed(target,f)
        if cand.contrast(surf)>=m: return cand
        f-=MUTED_STEP
    return c
GHOSTTY_DEFAULT_PAL=[0x1D1F21,0xCC6666,0xB5BD68,0xF0C674,0x81A2BE,0xB294BB,0x8ABEB7,0xC5C8C6,0x666666,0xD54E53,0xB9CA4A,0xE7C547,0x7AA6DA,0xC397D8,0x70C0B1,0xEAEAEA]
def derive(bg,fg,pal,sel=None,opacity=1.0):
    bg,fg=C.hex(bg),C.hex(fg); pal=[C.hex(p) for p in (pal if len(pal)>=8 else GHOSTTY_DEFAULT_PAL)]
    dark=bg.lum()<fg.lum()
    hover=fg.wa(0.06 if dark else 0.05); selection=fg.wa(0.10 if dark else 0.08); pressed=fg.wa(0.14 if dark else 0.11)
    worst=pressed.comp(bg)
    primary=readable(fg,worst,4.5); secondary=muted(primary,bg,0.38,worst,4.5); tertiary=muted(primary,bg,0.55,worst,3.0)
    status=lambda i: readable(pal[i],bg,3.0)
    hl=status(4)
    best=lambda cs: max(cs,key=lambda c:c.contrast(hl))
    themed=best([bg.wa(1),primary.wa(1)])
    hlt=themed if themed.contrast(hl)>=4.5 else best([C.hex(0),C.hex(0xFFFFFF)])
    surf=bg.wa(opacity)
    t=dict(windowBackground=surf,sidebarBackground=surf,contentBackground=surf,
      chromeBackground=bg.mixed(fg,0.05 if dark else 0.035),elevatedBackground=bg.mixed(fg,0.07 if dark else 0.02),
      stripBackground=bg.mixed(BLACK,0.22 if dark else 0.05).wa(opacity),
      sidebarStep=fg.wa(0.04),stripStep=BLACK.wa(0.22 if dark else 0.05),
      textPrimary=primary,textSecondary=secondary,textTertiary=tertiary,hoverFill=hover,selectionFill=selection,
      secondarySelectionFill=fg.wa(0.07 if dark else 0.055),pressedFill=pressed,badgeFill=fg.wa(0.14 if dark else 0.10),
      separator=fg.wa(0.08 if dark else 0.07),paneBorder=fg.wa(0.07 if dark else 0.09),focusRing=fg.wa(0.40),
      glassTint=bg.wa(0.40 if dark else 0.30),shadow=bg.mixed(BLACK,0.85),
      textSelection=C.hex(sel) if sel is not None else bg.mixed(fg,0.22),
      attention=status(3),danger=status(1),success=status(2),highlight=hl,highlightText=hlt)
    return dark,t,pal
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
out={}
for k,v in THEMES.items():
    dark,t,pal=derive(v['bg'],v['fg'],v['pal'],v['sel'])
    bg=C.hex(v['bg'])
    e={'name':v['name'],'isDark':dark,'input':{'background':C.hex(v['bg']).css(),'foreground':C.hex(v['fg']).css(),
        'selectionBackground':C.hex(v['sel']).css() if v['sel'] is not None else None,'palette':[p.css() for p in pal]},
       'tokens':{n:c.css() for n,c in t.items()},
       'composited':{n:c.comp(bg).css() for n,c in t.items() if c.a<1},
       'focusRing':{lvl:t['focusRing'].wa(a).css() for lvl,a in (('subtle',0.20),('standard',0.55),('strong',0.85))},
       'inactiveTabs':{st:{n:emphasized(t,st,0.35)[n].css() for n in ('textPrimary','textSecondary','textTertiary','selectionFill','hoverFill')} for st in ('fade','tonal','quiet')}}
    out[k]=e
if len(sys.argv)>1:
    json.dump(out,open(sys.argv[1],'w'),indent=1)
else:
    json.dump(out,sys.stdout,indent=1); print()
