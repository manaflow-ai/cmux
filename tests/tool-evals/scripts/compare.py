#!/usr/bin/env python3 -I
"""Per-model table of panel runs (<tag>-<surface>-<model> dirs under the given root) and the cases the newest run fails, by number of models."""
import json, glob, os, sys, collections
runs = sorted(glob.glob(os.path.join(sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser('~/tool-evals-runs'), '*-*-*', 'results.jsonl')))
def load(p): return [json.loads(l) for l in open(p) if l.strip()]
def stats(rows):
    by = collections.defaultdict(list)
    for r in rows: by[r['case']].append(r)
    cases_pass = sum(1 for xs in by.values() if sum(x.get('pass', False) for x in xs) * 2 > len(xs))
    harness = sum(1 for r in rows if r.get('category') == 'harness_error')
    tok = sum((r.get('usage') or {}).get('input', 0) + (r.get('usage') or {}).get('cacheRead', 0) for r in rows)
    steps = sorted(r.get('steps') or 0 for r in rows)
    return by, dict(cases=f"{cases_pass}/{len(by)}", samples=f"{sum(r.get('pass', False) for r in rows)}/{len(rows)}",
                    cost=round(sum(r.get('cost_usd') or 0 for r in rows), 2), mtok=round(tok / 1e6, 2),
                    med_steps=steps[len(steps) // 2] if steps else 0, docs=sum(r.get('docs_calls') or 0 for r in rows),
                    errors=sum(r.get('op_errors') or 0 for r in rows), harness=harness)
table = {}
for p in runs:
    label = os.path.basename(os.path.dirname(p))
    tag, surface, model = label.split('-', 2)
    phase = tag + '-' + surface
    table.setdefault(model, {})[phase] = stats(load(p))
fails = collections.Counter()
print(f"{'model':40} {'phase':6} cases  samples  cost  Mtok steps docs errs harness")
for model, phases in sorted(table.items()):
    for phase in sorted(phases):
        by, s = phases[phase]
        print(f"{model:40} {phase:6} {s['cases']:6} {s['samples']:8} {s['cost']:5} {s['mtok']:5} {s['med_steps']:5} {s['docs']:4} {s['errors']:4} {s['harness']}")
        if phase == sorted(phases)[-1]:
            for case, xs in by.items():
                if sum(x.get('pass', False) for x in xs) * 2 <= len(xs):
                    fails[case] += 1
print('\ncases failing after, by number of models:')
for case, n in fails.most_common(): print(f"  {n}  {case}")
