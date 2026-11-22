"""Split a chat-open CPU profile's attach-to-latest stretch (PROFILE_OUT of chat-open.bench.ts).

The stretch starts at the first sample inside attachWatched and ends at the first idle gap of GAP ms after it.
Each sample is put in one phase by its stack (React render / commit / passive effects / store / other), and native
layout and style samples are charged to their nearest JS caller.
"""
import json
import sys
from collections import Counter, defaultdict

GAP = float(sys.argv[2]) if len(sys.argv) > 2 else 30.0
p = json.load(open(sys.argv[1]))
nodes = {n["id"]: n for n in p["nodes"]}
parent = {}
for n in p["nodes"]:
    for c in n.get("children", []):
        parent[c] = n["id"]


def stack(i):
    out = []
    while i in nodes:
        out.append(nodes[i])
        i = parent.get(i)
    return out  # leaf first


def name(n):
    f = n["callFrame"]
    w = n.get("where") or ""
    w = w.split("webviews/")[-1]
    return f"{f['functionName'] or '(anon)'} {w}".strip()


t = 0.0
samples = []
for sid, dt in zip(p["samples"], p["timeDeltas"]):
    t += dt / 1000
    samples.append((t, sid))

start = None
for t, sid in samples:
    if any(n["callFrame"]["functionName"] == "attachWatched" for n in stack(sid)):
        start = t
        break
if start is None:
    sys.exit("no attachWatched sample")
LEN = float(sys.argv[3]) if len(sys.argv) > 3 else None
end = start
idle_since = None
for t, sid in samples:
    if t < start:
        continue
    idle = nodes[sid]["callFrame"]["functionName"] in ("(idle)",)
    if idle:
        if idle_since is None:
            idle_since = t
        elif t - idle_since >= GAP:
            break
    else:
        idle_since = None
        end = t
if LEN is not None:
    end = start + LEN
print(f"stretch {start:.1f}..{end:.1f} ms = {end - start:.1f} ms (gap {GAP} ms ends it)")

PHASES = [
    ("passive effects", ("flushPassiveEffects", "commitPassiveMountOnFiber")),
    ("commit: layout effects", ("commitLayoutEffects", "commitHookLayoutEffects", "commitLayoutEffectOnFiber")),
    ("commit: mutation (DOM)", ("commitMutationEffects", "commitMutationEffectsOnFiber")),
    ("commit: other", ("commitRoot", "commitRootImpl")),
    ("render", ("performUnitOfWork", "beginWork", "renderRootSync", "renderRootConcurrent", "completeWork")),
    ("store: attach/reduce", ("attachWatched", "reduceEvent", "receive")),
]
NATIVE_LAYOUT = {"(program)", "(garbage collector)"}
phase = Counter()
by_comp = defaultdict(Counter)
native_by_caller = Counter()
selfs = Counter()
busy = 0.0
prev = start
for t, sid in samples:
    if t <= start or t > end:
        continue
    dt = t - prev
    prev = t
    leaf = nodes[sid]
    fn = leaf["callFrame"]["functionName"]
    if fn == "(idle)":
        phase["idle"] += dt
        continue
    busy += dt
    st = stack(sid)
    names = [n["callFrame"]["functionName"] for n in st]
    ph = "other"
    for label, keys in PHASES:
        if any(k in names for k in keys):
            ph = label
            break
    phase[ph] += dt
    # nearest app-source frame (not react-dom/node_modules)
    comp = next((name(n) for n in st if (n.get("where") or "") and "node_modules" not in n.get("where", "")), "(none)")
    by_comp[ph][comp] += dt
    selfs[name(leaf)] += dt
    if not leaf["callFrame"]["url"]:
        native_by_caller[f"{fn} <- {comp}"] += dt

print(f"busy {busy:.1f} ms")
for k, v in phase.most_common():
    print(f"  {v:7.1f}  {k}")
    for c, cv in by_comp[k].most_common(6):
        print(f"           {cv:6.1f}  {c[:140]}")
print("native (layout/style/gc/program) by nearest app caller:")
for k, v in native_by_caller.most_common(15):
    print(f"  {v:6.1f}  {k[:160]}")
print("top self:")
for k, v in selfs.most_common(20):
    print(f"  {v:6.1f}  {k[:160]}")

# Inclusive time per app frame (counted once per sample), render phase only, and commits in the stretch.
incl = Counter()
commits = 0
in_commit = False
prev = start
for t, sid in samples:
    if t <= start or t > end:
        continue
    dt = t - prev
    prev = t
    st = stack(sid)
    names = [n["callFrame"]["functionName"] for n in st]
    c = "commitRoot" in names or "commitRootImpl" in names
    if c and not in_commit:
        commits += 1
    in_commit = c
    if not any(k in names for k in ("performUnitOfWork", "beginWork", "completeWork")):
        continue
    seen = set()
    for n in st:
        w = n.get("where") or ""
        if not w or "node_modules" in w:
            continue
        k = name(n)
        if k in seen:
            continue
        seen.add(k)
        incl[k] += dt
print(f"commit stretches seen: {commits}")
print("render, inclusive per app frame:")
for k, v in incl.most_common(40):
    print(f"  {v:6.1f}  {k[:150]}")
