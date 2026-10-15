import json, sys
def pct(v, p):
    v = sorted(v); return v[min(len(v)-1, max(0, int(-(-p*len(v)//1))-1))] if v else 0
for path in sys.argv[1:]:
    rows = [json.loads(l) for l in open(path) if l.strip()]
    groups = {}
    for r in rows:
        groups.setdefault(r["phase"] + ("+streaming" if r["streaming"] else ""), []).append(r)
    print(path)
    for k, rs in sorted(groups.items()):
        dt = [r["dt_ms"] for r in rs]; w = [r["work_ms"] for r in rs]
        tgt = pct([r["target_ms"] for r in rs], 0.5)
        hitch = sum(1 for x in dt if x > 1.5 * tgt)
        print(f"  {k:24s} n={len(dt):5d} frame={tgt:.1f} p50={pct(dt,.5):.1f} p95={pct(dt,.95):.1f} p99={pct(dt,.99):.1f} max={max(dt):.1f} hitches={hitch} ({100*hitch/len(dt):.1f}%) work p50={pct(w,.5):.2f} p95={pct(w,.95):.2f} p99={pct(w,.99):.2f} max={max(w):.2f}")
        names = sorted({n for r in rs for n in r.get("parts", {})})
        for n in names:
            pv = [r["parts"][n] for r in rs if n in r.get("parts", {})]
            print(f"    {n:18s} frames={len(pv):5d} mean={sum(pv)/len(pv):.3f} p99={pct(pv,.99):.3f} max={max(pv):.3f} total={sum(pv):.1f} ms")
