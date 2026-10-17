import csv, numpy as np, json, sys
R='/Users/azizalbahar/nxios-ref/'
def load(path, cols):
    rows=list(csv.reader(open(R+path))); h=rows[0]; idx=[i for i,c in enumerate(h) if c in cols]
    t=[];p=[]
    for r in rows[1:]:
        vals=[float(r[i]) for i in idx if r[i]!='']
        if not vals: continue
        t.append(float(r[0])); p.append(np.mean(vals))
    return np.array(t),np.array(p)
specs={
 'zoomIn':('tabs-reaudit-3/1-zoom/1a-zoomin.csv',['safA','safB','safDone']),
 'zoomOut':('tabs-reaudit-3/1-zoom/1c-zoomout.csv',['safA','safB']),
 'reflow':('tabs-reaudit-3/safari/saf-3b-check.csv',['s1','s2','s3']),
 'twoToOne':('tabs-audit/3-close/two-to-one.csv',['saf']),
 'snapBack':('tabs-reaudit-3/3-close/3g-snapback.csv',['saf1','saf2','saf3']),
 'lastTab':('tabs-reaudit-3/3-close/d2-lasttab.csv',['s1','s2']),
 'swipeUp':('tabs-reaudit-3/1-zoom/1d-swipeup-sameinput.csv',['s1','s2','s3']),
}
out={}
for k,(path,cols) in specs.items():
    t,p=load(path,cols)
    grid=np.arange(0,t.max()+1e-6,1000/60)
    q=np.interp(grid,t,p)
    # settle: trim tail once within 0.001 of 1 for 3 samples
    end=len(q)
    for i in range(len(q)-3):
        if all(abs(q[j]-1)<0.0015 for j in range(i,len(q))): end=i+1; break
    q=q[:end]; q[0]=0.0; q=np.append(q,1.0)
    out[k]=[round(float(x),4) for x in q]
    print(k,len(out[k]),'samples, ',round((len(out[k])-1)/60,3),'s; crossings',[round(float(np.argmax(np.array(out[k])>=c))*16.7) for c in (0.1,0.5,0.9,0.99)])
json.dump(out,open('curves.json','w'))
