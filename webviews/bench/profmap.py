#!/usr/bin/env python3
# settled-page.bench.ts PROFILE=1 reader: python3 -I bench/profmap.py ARTIFACT_DIR [WINDOW_MS]
# Map a .cpuprofile's frames through the build's source maps; print top self/total by original source line.
import json,glob,sys,collections,os,bisect
d=sys.argv[1]; W=float(sys.argv[2]) if len(sys.argv)>2 else 80
B64={c:i for i,c in enumerate("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")}
def vlq(s):
    out=[];v=0;sh=0
    for ch in s:
        x=B64[ch];v+=(x&31)<<sh
        if x&32: sh+=5
        else:
            out.append(-(v>>1) if v&1 else v>>1);v=0;sh=0
    return out
maps={}
def load(js):
    if js in maps: return maps[js]
    f=os.path.join(d,js+'.map')
    if not os.path.exists(f): maps[js]=None; return None
    m=json.load(open(f)); lines=[]; src=0;ol=0;oc=0;nm=0
    for seg_line in m['mappings'].split(';'):
        col=0; segs=[]
        for seg in seg_line.split(','):
            if not seg: continue
            v=vlq(seg); col+=v[0]
            if len(v)>=4:
                src+=v[1];ol+=v[2];oc+=v[3]
                if len(v)>=5: nm+=v[4]
                segs.append((col,src,ol))
        lines.append(segs)
    maps[js]=(m['sources'],lines); return maps[js]
def orig(url,line,col):
    js=url.split('/')[-1]; mm=load(js)
    if not mm: return f"{js}:{line+1}"
    sources,lines=mm
    if line>=len(lines) or not lines[line]: return f"{js}:{line+1}"
    segs=lines[line]; i=bisect.bisect_right([s[0] for s in segs],col)-1
    s=segs[max(i,0)]; return f"{sources[s[1]].replace('../','').split('webviews/')[-1]}:{s[2]+1}"
for f in sorted(glob.glob(os.path.join(d,'*.cpuprofile'))):
    p=json.load(open(f)); nodes={n['id']:n for n in p['nodes']}; par={}
    for n in p['nodes']:
        for c in n.get('children',[]): par[c]=n['id']
    def nm(i):
        cf=nodes[i]['callFrame']
        loc=orig(cf['url'],cf['lineNumber'],cf['columnNumber']) if cf['url'] else ''
        return f"{cf['functionName'] or '(anon)'} {loc}"
    t=0;ts=[]
    for x in p['timeDeltas']: t+=x; ts.append(t/1000)
    first=next(ts[i] for i,s in enumerate(p['samples']) if nodes[s]['callFrame']['functionName']!='(idle)')
    self=collections.Counter();tot=collections.Counter()
    for i,s in enumerate(p['samples']):
        if not first<=ts[i]<=first+W: continue
        dt=(p['timeDeltas'][i+1] if i+1<len(p['timeDeltas']) else 100)/1000
        self[nm(s)]+=dt; seen=set(); j=s
        while j is not None:
            k=nm(j)
            if k not in seen: seen.add(k); tot[k]+=dt
            j=par.get(j)
    print('==',os.path.basename(f)); print(' self:')
    for k,v in self.most_common(25): print(f'  {v:6.1f} {k}')
    print(' total (non-react):')
    n=0
    for k,v in tot.most_common(400):
        if 'react-dom' in k or 'node_modules' in k or k.startswith('(root)'): continue
        print(f'  {v:6.1f} {k}'); n+=1
        if n>=45: break
