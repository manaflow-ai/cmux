#!/usr/bin/env python3
"""How often best-of-N's trigger (RFD 0158 §3) would fire on this machine's Claude transcripts.

Mirrors cmux-tui/crates/acpmux/src/hub/best_of_n.rs: a check (test, build, type check, linter)
is red when its call errored, exited non-zero or printed a failure; the trigger fires when one
check goes red twice in a row with no green run of it between. Reads ~/.claude/projects/*/*.jsonl
line by line (each result's last 64 KB). Prints one JSON line.
"""
import json,glob,re,os,sys,collections
CHECK=re.compile(r"\b(cargo\s+(\+\S+\s+)?(test|nextest|check|clippy|build)|cmux-ci\s+(test|compile-check)|pytest|python3?\s+-m\s+(pytest|unittest|mypy)|(npm|pnpm|yarn|bun)\s+(run\s+)?(test|typecheck|lint|build)|vitest|jest|playwright\s+test|go\s+(test|vet|build)|swift\s+(test|build)|xcodebuild\b.*\b(test|build)|tsc\b|make\s+(test|check)|bazel\s+(test|build)|ctest|ruff|mypy|eslint)\b")
EXIT=re.compile(r"(?m)^Exit code (\d+)\s*$")
FAILTXT=re.compile(r"test result: FAILED|error: could not compile|cmux-ci test: FAILURE|lane-gh ci: FAILURE|Found \d+ errors?")
def norm(c): return " ".join(c.split())[:200]
files=glob.glob(os.path.expanduser("~/.claude/projects/*/*.jsonl"))
sess=0;sess_checks=0;fires=0;sess_fired=0;reds=0;greens=0;checks=0;after=collections.Counter()
for f in files:
    sess+=1
    calls={}
    streak=collections.Counter(); fired_cmds=set(); any_check=False; fired=False
    # turn boundaries: user text prompts
    try:
        lines=open(f,errors='replace')
    except Exception: continue
    for ln in lines:
        try: r=json.loads(ln)
        except Exception: continue
        m=r.get("message") or {}
        cont=m.get("content")
        if not isinstance(cont,list): continue
        for it in cont:
            if not isinstance(it,dict): continue
            if it.get("type")=="tool_use" and it.get("name")=="Bash":
                c=(it.get("input") or {}).get("command","")
                if isinstance(c,str) and CHECK.search(c): calls[it.get("id")]=norm(c)
            elif it.get("type")=="tool_result" and it.get("tool_use_id") in calls:
                c=calls.pop(it["tool_use_id"]); any_check=True; checks+=1
                t=it.get("content")
                if isinstance(t,list): t="\n".join(x.get("text","") for x in t if isinstance(x,dict))
                t=(t if isinstance(t,str) else "")[-65536:]
                e=EXIT.search(t); red=bool(it.get("is_error")) or (e and e.group(1)!="0") or bool(FAILTXT.search(t))
                if red:
                    reds+=1; streak[c]+=1
                    if streak[c]==2: fires+=1; fired=True
                else:
                    greens+=1
                    if streak[c]>=2: after["green_after_fire"]+=1
                    streak[c]=0
    for c,n in streak.items():
        if n>=2: after["still_red_at_end"]+=1
    sess_checks+=any_check; sess_fired+=fired
print(json.dumps(dict(transcripts=sess,with_checks=sess_checks,check_runs=checks,red=reds,green=greens,fires=fires,transcripts_fired=sess_fired,**after)))
