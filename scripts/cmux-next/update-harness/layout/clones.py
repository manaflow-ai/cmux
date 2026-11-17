#!/usr/bin/env python3
"""clones.py BUNDLE_ID APP: the Chromium code-sign clone folder's regular files, matched by inode
against APP's main executable and CmuxNextApp framework binary. Prints one JSON report."""
import json, os, plistlib, subprocess, sys

bundle_id, app = sys.argv[1], sys.argv[2]
temp = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
root = os.path.realpath(os.path.join(temp, "..", "X", bundle_id + ".code_sign_clone"))
with open(os.path.join(app, "Contents/Info.plist"), "rb") as f:
    info = plistlib.load(f)
targets = {"exe": os.path.join(app, "Contents/MacOS", info["CFBundleExecutable"]),
           "framework": os.path.join(app, "Contents/Frameworks/CmuxNextApp.framework/Versions/A/CmuxNextApp")}
app_inodes = {}
for name, path in targets.items():
    if os.path.exists(path):
        st = os.stat(path)
        app_inodes[st.st_ino] = name
report = {"build": info["CFBundleVersion"], "clone_root": root,
          "app": {n: (lambda s: {"inode": s.st_ino, "links": s.st_nlink, "bytes": s.st_size})(os.stat(p))
                  for n, p in targets.items() if os.path.exists(p)},
          "clones": []}
seen, held_other = set(), 0
if os.path.isdir(root):
    for clone in sorted(os.listdir(root)):
        rows = []
        for dirpath, _, files in os.walk(os.path.join(root, clone)):
            for fn in files:
                p = os.path.join(dirpath, fn)
                st = os.lstat(p)
                if not os.path.isfile(p) or os.path.islink(p):
                    continue
                rel = os.path.relpath(p, os.path.join(root, clone))
                main = "/Contents/MacOS/" in "/" + rel or rel.endswith("CmuxNextApp.framework/Versions/A/CmuxNextApp")
                if st.st_nlink < 2 and not main:
                    continue
                rows.append({"file": rel, "inode": st.st_ino, "links": st.st_nlink, "bytes": st.st_size,
                             "matches": app_inodes.get(st.st_ino, "other")})
                if st.st_ino not in seen:
                    seen.add(st.st_ino)
                    if st.st_ino not in app_inodes:
                        held_other += st.st_size
        report["clones"].append({"clone": clone, "hardlinks": rows})
report["bytes_held_by_links_to_files_not_in_app"] = held_other
print(json.dumps(report, indent=1))
