#!/usr/bin/env python3
# Remove caches, temp files and histories before the snapshot; print bytes freed per item as JSON.
import glob, json, os, shutil, subprocess

ITEMS = {
    "apt-lists": ["/var/lib/apt/lists/*"],
    "apt-cache": ["/var/cache/apt/*.bin", "/var/cache/apt/archives/*.deb", "/var/cache/apt/archives/partial/*"],
    "npm-cache": ["/root/.npm", "/home/cmux/.npm"],
    "user-caches": ["/root/.cache", "/home/cmux/.cache", "/root/.bun/install/cache"],
    "tmp": ["/tmp/*", "/tmp/.[!.]*", "/var/tmp/*"],
    "shell-history": ["/root/.bash_history", "/home/cmux/.bash_history", "/root/.python_history", "/root/.lesshst"],
    "claude-json-seed": ["/root/.claude.json", "/home/cmux/.claude.json"],
}
KEEP = {"/var/lib/apt/lists/partial", "/var/lib/apt/lists/lock", "/var/cache/apt/archives/partial", "/var/cache/apt/archives/lock"}

def size(p: str) -> int:
    if os.path.islink(p):
        return 0
    if os.path.isfile(p):
        return os.path.getsize(p)
    total = 0
    for r, _, fs in os.walk(p):
        for f in fs:
            fp = os.path.join(r, f)
            try:
                if not os.path.islink(fp):
                    total += os.lstat(fp).st_blocks * 512
            except OSError:
                pass
    return total

out = {}
for key, patterns in ITEMS.items():
    freed = 0
    for pattern in patterns:
        for p in glob.glob(pattern):
            if p in KEEP:
                continue
            freed += size(p)
            try:
                if os.path.isdir(p) and not os.path.islink(p):
                    shutil.rmtree(p)
                else:
                    os.remove(p)
            except OSError as e:
                print("skip", p, e)
    out[key] = freed
before = size("/var/log/journal")
subprocess.run("journalctl --rotate >/dev/null 2>&1; journalctl --vacuum-time=1s >/dev/null 2>&1", shell=True)
out["journal"] = before - size("/var/log/journal")
print("CLEAN_JSON", json.dumps(out))
