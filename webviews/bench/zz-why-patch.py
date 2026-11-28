# Temporary instrumentation for the redraw-reason probe; applied only inside the pool copy.
import sys
p='src/agent-session/acpmux/pane/paneSnapshot.ts'; s=open(p).read()
K='const __zk=(k:string)=>{const w=window as any;const m=(w.__zzWhy??={});m[k]=(m[k]??0)+1;};\n'
s=s.replace("  const redrawPane = (next: AcpmuxSnapshot, urgent: boolean) => {\n", "  const redrawPane = (next: AcpmuxSnapshot, urgent: boolean) => {\n    "+K+"    __zk('redraw:'+(urgent?'urgent':'normal'));\n",1)
s=s.replace("    if (!cancelled && next) redrawPane(next, true);","    if (!cancelled && next) { ((window as any).__zzWhy ??= {}).lineFlush = (((window as any).__zzWhy.lineFlush)??0)+1; redrawPane(next, true); }",1)
old="          if (hiddenChange) acpmuxPerf.render(\"pane:row-hidden\");\n          redrawPane(next, false);"
assert old in s
new='''          {
            '''+K+'''            if (!drawn) __zk('why:nodrawn'); else {
              const b = drawn as any, a = next as any;
              const keys = Object.keys(a).filter((x) => x !== "rows" && !Object.is(b[x], a[x]));
              __zk('top:' + (keys.join(',') || '-'));
              const r = received ?? drawn;
              const ch: string[] = [];
              const n = Math.max(r.rows.length, next.rows.length);
              for (let i = 0; i < n; i++) if (r.rows[i] !== next.rows[i]) ch.push(i + ':' + (next.rows[i]?.kind ?? 'gone') + (next.rows[i]?.streaming ? '*' : '') + '/' + (r.rows[i]?.kind ?? 'new'));
              const rel = ch.map((c) => { const i = Number(c.split(':')[0]); return (i - n) + c.slice(c.indexOf(':')); });
              __zk('rows:' + (r.rows.length !== next.rows.length ? 'len' + (next.rows.length - r.rows.length) + ' ' : '') + rel.slice(0, 4).join(','));
              __zk('state:pending=' + pendingPaneDraw.pending + ',blocked=' + streamingRowBlocked() + ',recvIsDrawn=' + (received === drawn));
            }
          }
''' + old
s=s.replace(old,new,1)
s=s.replace("          const drawn = drawnSnapshot.current;\n          const received = receivedSnapshot.current;\n","          ((window as any).__zzWhy ??= {}).listener = (((window as any).__zzWhy.listener)??0)+1;\n          const drawn = drawnSnapshot.current;\n          const received = receivedSnapshot.current;\n",1)
open(p,'w').write(s)
a='src/agent-session/acpmux/App.tsx'; t=open(a).read()
t=t.replace('      acpmuxPerf.markLaunch("restoredTailDrawn");\n      setSnapshot(next);','      acpmuxPerf.markLaunch("restoredTailDrawn");\n      ((window as any).__zzWhy ??= {}).restored = 1;\n      setSnapshot(next);',1)
open(a,'w').write(t)
print("patched")
