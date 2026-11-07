#!/usr/bin/env python3
# Remove caches, temp files and histories before the snapshot; print bytes freed per item as JSON.
import glob, json, os, shutil, subprocess

ITEMS = {
    "apt-lists": ["/var/lib/apt/lists/*"],
    "apt-cache": ["/var/cache/apt/*.bin", "/var/cache/apt/archives/*.deb", "/var/cache/apt/archives/partial/*"],
    # The work user's npm cache content stays (dep-cache.ts bakes it); its logs and anything else go.
    "npm-cache": ["/root/.npm", "/home/cmux/.npm/*", "/home/cmux/.npm/.[!.]*"],
    # The dev tree's Zig package cache stays (bake.ts --dev-tree); nothing else under ~/.cache does.
    "user-caches": ["/root/.cache", "/home/cmux/.cache/*", "/home/cmux/.cache/.[!.]*", "/root/.bun/install/cache"],
    "tmp": ["/tmp/*", "/tmp/.[!.]*", "/var/tmp/*"],
    "shell-history": ["/root/.bash_history", "/home/cmux/.bash_history", "/root/.python_history", "/root/.lesshst"],
    "claude-json-seed": ["/root/.claude.json", "/home/cmux/.claude.json"],
    # acpmux's login-shell cache is one machine's: it holds the bake's environment, and its fingerprint (the startup
    # files) cannot see the model-plane file they source at boot, so a clone kept the bake's copy and never read its
    # own login shell (Codex started without the edge's placeholder key; gateway-e2e run 42382330319).
    "acpmux-login-env": ["/root/.acpmux/login-env.json", "/home/cmux/.acpmux/login-env.json"],
    # A clone gets its own kind at its bind or team enroll (cmux-host VM_KIND_FILE).
    "vm-kind": ["/etc/cmux/vm-kind"],
}
KEEP = {"/home/cmux/.cache/zig", "/home/cmux/.npm/_cacache", "/var/lib/apt/lists/partial", "/var/lib/apt/lists/lock", "/var/cache/apt/archives/partial", "/var/cache/apt/archives/lock"}

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
