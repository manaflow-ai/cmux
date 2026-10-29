#!/usr/bin/env python3
"""sequence-manager S1 codemod (plans/cmux-next/sequence-manager-DESIGN.md section 4): an owner init lost its
`deadlines: MainDeadlineScheduler = MainDeadlineScheduler(work: MainWorkScheduler(...))` default, so every call that
left it out passes `.testing()` (CmuxNextWakeupsTestSupport) at its declared position. In-flight branches run it on
themselves:

  python3 scripts/cmux-next/codemods/seqmgr_s1_deadlines_arg.py . scripts/cmux-next/codemods/seqmgr_s1_deadlines_arg.json

then add `import CmuxNextWakeupsTestSupport` where the compiler asks. Call sites only, never declarations.
"""
import json, os, re, subprocess, sys
root, spec = sys.argv[1], json.load(open(sys.argv[2]))
changed = {}
def top_args(text, i):
    d = 1; j = i; args = []; cur_start = i; in_str = False
    while j < len(text):
        c = text[j]
        if in_str:
            if c == '\\': j += 2; continue
            if c == '"': in_str = False
        elif c == '"': in_str = True
        elif c in "([{": d += 1
        elif c in ")]}":
            d -= 1
            if d == 0:
                args.append((cur_start, j)); return args, j
        elif c == "," and d == 1:
            args.append((cur_start, j)); cur_start = j + 1
        j += 1
    raise ValueError("unbalanced")
for item in spec:
    name, label, value = item["name"], item["label"], item["value"]
    files = subprocess.run(["git", "-C", root, "grep", "-l", name + "(", "--", *item["paths"]], capture_output=True, text=True).stdout.split()
    pat = re.compile(r'(?<![\w.])' + re.escape(name) + r'\(')
    for f in files:
        path = os.path.join(root, f); text = open(path).read(); out = []; last = 0; n = 0
        for m in pat.finditer(text):
            ls = text.rfind("\n", 0, m.start()) + 1
            if text[ls:m.start()].lstrip().startswith("//"): continue
            # skip declarations: `init(` is not NAME(; NAME( in `class NAME(`? not possible
            args, close = top_args(text, m.end())
            labels = []
            for a, b in args:
                seg = text[a:b].strip()
                mm = re.match(r'([A-Za-z_]\w*)\s*:', seg)
                labels.append(mm.group(1) if mm and not seg.startswith(mm.group(1) + "::") else None)
            if label in labels: continue
            if "requires" in item and not all(r in labels for r in item["requires"]): continue
            if "excludes" in item and any(r in labels for r in item["excludes"]): continue
            order = item["order"]
            idx = order.index(label)
            # insert after the last present arg whose label comes before `label` in the order
            pos = None
            for k, lab in enumerate(labels):
                if lab in order and order.index(lab) < idx: pos = k
            if pos is None:
                at = m.end(); ins = f"{label}: {value}" + (", " if args and text[args[0][0]:args[0][1]].strip() else "")
            else:
                at = args[pos][1]; ins = f", {label}: {value}"
            out.append(text[last:at]); out.append(ins); last = at; n += 1
        if n:
            out.append(text[last:]); open(path, "w").write("".join(out)); changed[f] = changed.get(f, 0) + n
for f, n in sorted(changed.items()): print(n, f)
print("total", sum(changed.values()))
