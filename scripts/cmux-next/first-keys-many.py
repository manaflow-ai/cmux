#!/usr/bin/env python3
"""SCRATCH (never lands): new-terminal-first-keys.py on several fleet apps in one step: --apps-sha256 A,B,C [--modes ...]."""
import argparse, os, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__))
p = argparse.ArgumentParser()
p.add_argument("--app"); p.add_argument("--out", required=True); p.add_argument("--json"); p.add_argument("--tag")
p.add_argument("--apps-sha256", required=True)
p.add_argument("--variants", default="debug", help="comma list of debug, real, background")
opts, rest = p.parse_known_args()
status = 0
for sha in opts.apps_sha256.split(","):
    got = subprocess.run([sys.executable, os.path.join(HERE, "fleet-app-fetch.py"), "--sha256", sha, "--dest",
                          os.path.join(opts.out, "apps", sha[:12])], capture_output=True, text=True, check=True)
    app = got.stdout.strip().splitlines()[-1]
    for variant in opts.variants.split(","):
        extra = {"debug": [], "real": ["--input", "real"], "background": ["--background"]}[variant]
        out = os.path.join(opts.out, f"{sha[:12]}-{variant}")
        print(f"=== {sha[:12]} {os.path.basename(app)} {variant}", flush=True)
        run = subprocess.run([sys.executable, os.path.join(HERE, "new-terminal-first-keys.py"), "--app", app, "--out", out,
                              "--json", os.path.join(out, "first-keys.json")] + extra + rest)
        status = max(status, run.returncode)
sys.exit(0)
