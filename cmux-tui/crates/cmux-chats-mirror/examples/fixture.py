import json, random, sys
random.seed(7)
n = int(sys.argv[1]) if len(sys.argv) > 1 else 5000
harnesses = ["claude-code", "codex", "opencode", "gemini", "cursor"]
words = "fix the build sidebar typing lag home chat restore panes cloud chief invite team settings redesign rust audit store".split()
chats = []
for i in range(n):
    h = random.choice(harnesses)
    sid = "%08x-%04x-%04x-%04x-%012x" % (random.getrandbits(32), random.getrandbits(16), random.getrandbits(16), random.getrandbits(16), random.getrandbits(48))
    cwd = "/Users/lawrence/fun/" + random.choice(["cmux", "cmux-next", "hq", "subrouter", "web", "a-%d" % random.randint(0, 400)])
    c = {"key": f"{h}:{sid}", "sessionId": sid, "harness": h,
         "title": " ".join(random.choice(words) for _ in range(random.randint(3, 9))).capitalize(),
         "titleSource": "summary", "cwd": cwd, "createdMs": 1760000000000 + i * 1000,
         "updatedMs": 1760000000000 + (n - i) * 60000, "messageCount": random.randint(1, 900),
         "sourcePath": f"/Users/lawrence/.claude/projects/-Users-lawrence-fun-cmux/{sid}.jsonl",
         "originator": None, "archived": False, "resume": {"kind": "session"},
         "accounts": ["lawrence"], "roots": ["claude-default"], "brand": h,
         "attention": None, "preview": None, "parent": None}
    if i % 7 == 0:
        c["preview"] = "I landed the fix on feat-cmux-next and the tests pass; numbers are in the report " * 2
        c["attention"] = "unread"
    if i % 23 == 0 and i > 0:
        c["parent"] = chats[i - 1]["key"]
    chats.append(c)
page = {"jsonrpc": "2.0", "id": 2, "result": {"chats": chats, "ready": True, "enabled": True, "seq": 100}}
open("page.json", "w").write(json.dumps(page))
# 2000 change lines: 80% activity, 15% upsert (bump updated), 5% removed
lines = []
seq = 100
for j in range(2000):
    c = random.choice(chats)
    r = random.random()
    if r < 0.8:
        lines.append({"jsonrpc": "2.0", "method": "_acpmux/chat_changed", "params": {"kind": "activity", "key": c["key"], "attention": "unread", "preview": "reply %d" % j, "parent": None}})
    elif r < 0.95:
        seq += 1
        d = dict(c); d["updatedMs"] = 1770000000000 + j
        lines.append({"jsonrpc": "2.0", "method": "_acpmux/chat_changed", "params": {"kind": "upsert", "seq": seq, "key": c["key"], "chat": d}})
    else:
        seq += 1
        lines.append({"jsonrpc": "2.0", "method": "_acpmux/chat_changed", "params": {"kind": "removed", "seq": seq, "key": c["key"]}})
open("changes.jsonl", "w").write("\n".join(json.dumps(l) for l in lines) + "\n")
