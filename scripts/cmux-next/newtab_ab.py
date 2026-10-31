"""Scratch A/B driver for Cmd-T to a typeable New Tab field (newtab-ab; never merged).

Builds every commit of --ab (reload.sh --config bench: Release optimization plus the debug.* control surface), then
runs --ab-rounds rounds on this one host; each round runs one segment per build (a fresh launch: the cold press, the
quick pairs, the warm presses), the build order rotated each round. Prints one AB-RESULT line per build and arm:
typeable_ms (Cmd-T sent to the first field read that holds the letter typed right after it) and key_ms.
"""
import json, os, re, shutil, subprocess, sys, time

REPO_URL = "https://github.com/manaflow-ai/cmux.git"
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
import bench_arms  # noqa: E402


def sh(cmd, cwd, log):
    with open(log, "a") as f:
        f.write(f"\n$ {' '.join(cmd)}\n")
        f.flush()
        return subprocess.run(cmd, cwd=cwd, stdout=f, stderr=subprocess.STDOUT).returncode


def build(label, sha, tag, out):
    """The bench app of `sha`, built in a worktree of this checkout, then held in the step (hold)."""
    cache_root = os.environ.get("CI_SHARED_CACHE_DIR")
    log = os.path.join(out, f"build-{label}.log")
    wt = os.path.join(ROOT, ".build", f"newtab-ab-{label}")
    start = time.time()
    if not os.path.isdir(wt):
        # A fleet step's checkout is shallow and has only its own ref: fetch the arm's exact commit by its id
        # from the repository URL (the checkout's remote may have another name, or none).
        have = subprocess.run(["git", "cat-file", "-e", f"{sha}^{{commit}}"], cwd=ROOT).returncode == 0
        if not have and sh(["git", "fetch", "--no-tags", "--depth", "1", REPO_URL, sha], ROOT, log) != 0:
            sh(["git", "fetch", "--no-tags", REPO_URL, sha], ROOT, log)
        if sh(["git", "worktree", "add", "--force", "--detach", wt, sha], ROOT, log) != 0:
            print(open(log).read()[-2000:], flush=True)
            sys.exit(f"AB-BUILD {label}: no worktree of {sha} (see {log})")
    for sub in ("ghostty", "ghostty-next"):
        if not os.path.exists(os.path.join(wt, sub, ".git")):
            sh(["git", "submodule", "update", "--init", "--depth", "1", sub], wt, log)
    if not os.path.exists(os.path.join(wt, "GhosttyKit.xcframework", "Info.plist")):
        env_cache = os.environ.get("GHOSTTYKIT_ARCHIVE_CACHE_DIR") or (os.path.join(cache_root, "ghosttykit-archives") if cache_root else "")
        env = dict(os.environ, **({"GHOSTTYKIT_ARCHIVE_CACHE_DIR": env_cache} if env_cache else {}))
        with open(log, "a") as f:
            subprocess.run(["./scripts/download-prebuilt-ghosttykit.sh"], cwd=wt, stdout=f, stderr=subprocess.STDOUT, env=env)
    env = dict(os.environ, CMUX_DEV_BACKEND_MODE="local")
    proc = subprocess.run(["./scripts/reload.sh", "--tag", tag, "--config", "bench"], cwd=wt, env=env,
                          capture_output=True, text=True)
    open(log, "a").write(proc.stdout + proc.stderr)
    lines = proc.stdout.splitlines()
    app = next((lines[i + 1].strip() for i in range(len(lines) - 1) if lines[i].startswith("App path:")), None)
    if not app or not os.path.isdir(app):
        print("\n".join([l for l in (proc.stdout + proc.stderr).splitlines() if "error" in l][:40]), flush=True)
        print((proc.stdout + proc.stderr)[-3000:], flush=True)
        sys.exit(f"AB-BUILD {label}: reload.sh printed no app path (see {log})")
    print(f"AB-BUILD {label} {sha[:12]} tag {tag}: built in {time.time() - start:.0f} s: {app}", flush=True)
    held = hold(label, app, out)
    shutil.rmtree(wt, ignore_errors=True)
    subprocess.run(["git", "worktree", "prune"], cwd=ROOT)
    return held


def free_gib():
    st = os.statvfs(os.path.expanduser("~"))
    return st.f_bavail * st.f_frsize / 2 ** 30


def hold(label, app, out):
    """Moves a built app out of its DerivedData into the step's out folder and deletes that DerivedData: a mini
    holds one bench build's intermediates at a time (reload.sh wants 40 GiB free; three builds side by side do not
    fit on a 228 GB mini, 2026-10-31 job a861baa35e87bb620f0d0729)."""
    dest_dir = os.path.join(out, "apps", label)
    os.makedirs(dest_dir, exist_ok=True)
    dest = os.path.join(dest_dir, os.path.basename(app))
    if subprocess.run(["ditto", app, dest]).returncode != 0:
        sys.exit(f"AB-BUILD {label}: could not copy {app}")
    derived = app.split("/Build/Products/")[0] if "/Build/Products/" in app else None
    if derived and os.path.basename(derived).startswith("cmux-") and "/DerivedData/" in derived:
        shutil.rmtree(derived, ignore_errors=True)
    print(f"AB-HOLD {label}: {dest}; {free_gib():.0f} GiB free", flush=True)
    return dest


def main(opts, argv):
    out = os.path.abspath(opts.out)
    os.makedirs(out, exist_ok=True)
    builds = []
    for item in [i for i in opts.ab.split(",") if i]:
        label, rest = item.split("=", 1)
        sha, _, tag = rest.partition("@")
        builds.append((label, sha, tag or f"ab-{label}"[:24]))
    apps = {}
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    # The step's parent from the raw commit object: a shallow checkout grafts HEAD as parentless, so HEAD^ fails.
    raw = subprocess.run(["git", "cat-file", "-p", "HEAD"], cwd=ROOT, capture_output=True, text=True).stdout
    parents = re.findall(r"^parent ([0-9a-f]{40})$", raw, re.M)
    print(f"AB-STEP head {head[:12]} parents {[p[:12] for p in parents]}", flush=True)
    for label, sha, tag in builds:
        # The step's own app (instant-new-surfaces.sh built it) serves the build whose commit is the step's parent:
        # the step's commit adds only these two harness files to it.
        if opts.app and sha in [head, *parents] and tag == opts.tag:
            print(f"AB-BUILD {label} {sha[:12]}: the step's own app {opts.app}", flush=True)
            apps[label] = hold(label, os.path.abspath(opts.app.rstrip("/")), out)
        else:
            apps[label] = build(label, sha, tag, out)
    passthrough = []
    skip = {"--ab", "--ab-rounds", "--app", "--tag", "--json", "--out"}
    it = iter(argv[1:])
    for a in it:
        name = a.split("=", 1)[0]
        if name in skip:
            if "=" not in a:
                next(it, None)
            continue
        passthrough.append(a)
    rows = []
    for rnd in range(opts.ab_rounds):
        order = builds[rnd % len(builds):] + builds[:rnd % len(builds)]
        for label, sha, tag in order:
            seg_json = os.path.join(out, f"seg-{label}-{rnd}.json")
            seg_out = os.path.join(out, f"seg-{label}-{rnd}")
            os.makedirs(seg_out, exist_ok=True)
            cmd = [sys.executable, os.path.join(HERE, "instant-new-surfaces-bench.py"), "--tag", tag, "--app", apps[label],
                   "--out", seg_out, "--json", seg_json, "--segment", *passthrough]
            print(f"AB-SEGMENT round {rnd} {label}: {' '.join(cmd[2:])}", flush=True)
            proc = subprocess.run(cmd, capture_output=True, text=True, timeout=1800)
            for line in proc.stdout.splitlines():
                if " new_tab #" in line:
                    print(f"  {label} r{rnd} {line}", flush=True)
            if proc.returncode != 0:
                print(f"  {label} r{rnd}: segment exit {proc.returncode}: {proc.stderr[-600:]}", flush=True)
            try:
                seg = json.load(open(seg_json))["rows"]
            except (OSError, ValueError, KeyError):
                seg = [{"arm": "cold", "error": f"segment wrote no rows (exit {proc.returncode})", "typeable_ms": None}]
            for r in seg:
                r.update({"build": label, "sha": sha, "round": rnd})
            rows += seg
    result = {"bench": "newtab-ab", "host": os.uname().nodename, "builds": builds, "rounds": opts.ab_rounds,
              "end_event": "typeable_ms: Cmd-T sent (debug.key) to the start of the first debug.new_tab field read whose "
                           "field holds the letter sent (debug.key) right after Cmd-T", "rows": rows, "stats": {}}
    for label, sha, tag in builds:
        for arm in ("cold", "quick", "warm"):
            sel = [r for r in rows if r.get("build") == label and r.get("arm") == arm]
            for metric in ("typeable_ms", "key_ms"):
                st = bench_arms.stats([r.get(metric) for r in sel])
                result["stats"][f"{label}/{arm}/{metric}"] = st
                print(f"AB-RESULT {label} ({sha[:12]}) {arm} {metric}: n={st['n']} lost={st['missed']} p50={st['p50']} "
                      f"p95={st['p95']} p99={st['p99']} max={st['max']}", flush=True)
    if opts.json:
        open(opts.json, "w").write(json.dumps(result, indent=1))
    return 0
