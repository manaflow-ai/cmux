#!/usr/bin/env python3
# What a woken agent reads first (RFD 0158 §10, idle-time digests): in Claude Code transcripts,
# a wake is a typed prompt after >=120 s of quiet; its first three tool calls are sorted into
# git-state reads, CI/PR reads and log tails, the state an idle digest file can hold.
# Run: python3 scripts/measure/wake-first-reads.py   (reads ~/.claude/projects/*/*.jsonl)
import json,glob,re,os,sys
from datetime import datetime
files=glob.glob(os.path.expanduser('~/.claude/projects/*/*.jsonl'))
GAP=120
cats={'git-state':re.compile(r'\bgit (status|log|diff|show|fetch|rev-parse|branch)\b'),
      'ci-pr':re.compile(r'\bgh (run|pr) (view|checks|list)\b|glaeda-gh (status|wait)|cmux-ci (status|log)'),
      'tail-log':re.compile(r'\btail\b|bg_output')}
wakes=0;first_calls=0;hits={k:0 for k in cats};wake_with_hit=0;chars=0;tok_in=0
def ts(r):
    t=r.get('timestamp');
    return datetime.fromisoformat(t.replace('Z','+00:00')).timestamp() if t else None
for f in files:
    try: recs=[json.loads(l) for l in open(f)]
    except Exception: continue
    last=None; pending=None
    for r in recs:
        t=ts(r)
        if r.get('type')=='user' and isinstance(r.get('message',{}).get('content'),str) and t:
            if last and t-last>=GAP:
                wakes+=1; pending={'n':0,'hit':False}
            else: pending=None
        if r.get('type')=='assistant' and pending is not None:
            for c in r['message'].get('content',[]):
                if c.get('type')=='tool_use' and pending['n']<3:
                    pending['n']+=1; first_calls+=1
                    s=json.dumps(c.get('input',{}))
                    if c.get('name')=='mcp__acpmux__bg_output': s+=' bg_output'
                    for k,rx in cats.items():
                        if rx.search(s): hits[k]+=1; pending['hit'] or None; 
                    if any(rx.search(s) for rx in cats.values()) and not pending['hit']:
                        pending['hit']=True; wake_with_hit+=1
        if t: last=t
print(json.dumps({'transcripts':len(files),'wakes(user msg after >=2min quiet)':wakes,'first3_tool_calls':first_calls,'by_kind':hits,'wakes_whose_first3_read_state':wake_with_hit}))
