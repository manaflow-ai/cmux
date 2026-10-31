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


def fetch_all(builds):
    """Every arm's exact commit in this checkout, fetched by id before any build (a fleet step's checkout is shallow
    and has only its own ref). One that cannot be fetched fails the step now, not after 25-minute builds."""
    for label, sha, _tag in builds:
        have = subprocess.run(["git", "cat-file", "-e", f"{sha}^{{commit}}"], cwd=ROOT,
                              stderr=subprocess.DEVNULL).returncode == 0
        if not have:
            for depth in (["--depth", "1"], []):
                got = subprocess.run(["git", "fetch", "--no-tags", *depth, REPO_URL, sha], cwd=ROOT,
                                     capture_output=True, text=True)
                if got.returncode == 0:
                    break
            else:
                sys.exit(f"AB-FETCH {label} {sha}: not fetchable from {REPO_URL}: {got.stderr.strip()[-400:]}")
        print(f"AB-FETCH {label} {sha[:12]}: {'here' if have else 'fetched'}", flush=True)


def run_logged(cmd, cwd, env, log, label):
    """Runs `cmd` into `log`, printing one AB-BUILD heartbeat line every 2 minutes so the controller's silent-output
    limit (45 min) never takes a long build for a hung step (job deef8936797d8cd32aa495fc)."""
    start = time.time()
    with open(log, "a") as f:
        proc = subprocess.Popen(cmd, cwd=cwd, env=env, stdout=f, stderr=subprocess.STDOUT)
        while proc.poll() is None:
            time.sleep(5)  # harness poll of its own child process
            if int(time.time() - start) % 120 < 5:
                print(f"AB-BUILD {label}: building, {time.time() - start:.0f} s", flush=True)
    return proc.returncode


def build(label, sha, tag, out, derived):
    """The bench app of `sha`, built in this checkout (switched to `sha`) into the one shared DerivedData `derived`,
    then copied into the step (hold). Building every arm at one source path into one DerivedData lets Xcode reuse
    what did not change between arms; a per-arm worktree and per-tag DerivedData built each arm cold (1506 s on
    cmux19, job deef8936797d8cd32aa495fc)."""
    cache_root = os.environ.get("CI_SHARED_CACHE_DIR")
    log = os.path.join(out, f"build-{label}.log")
    start = time.time()
    ghostty_before = subprocess.run(["git", "rev-parse", "HEAD:ghostty"], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    if sh(["git", "checkout", "--quiet", "--force", "--detach", sha], ROOT, log) != 0:
        print(open(log).read()[-2000:], flush=True)
        sys.exit(f"AB-BUILD {label}: could not check out {sha} (see {log})")
    if subprocess.run(["git", "rev-parse", "HEAD:ghostty"], cwd=ROOT, capture_output=True, text=True).stdout.strip() != ghostty_before:
        shutil.rmtree(os.path.join(ROOT, "GhosttyKit.xcframework"), ignore_errors=True)  # another ghostty: its own prebuilt
    for sub in ("ghostty", "ghostty-next"):
        sh(["git", "submodule", "update", "--init", "--depth", "1", sub], ROOT, log)
    if not os.path.exists(os.path.join(ROOT, "GhosttyKit.xcframework", "Info.plist")):
        env_cache = os.environ.get("GHOSTTYKIT_ARCHIVE_CACHE_DIR") or (os.path.join(cache_root, "ghosttykit-archives") if cache_root else "")
        env = dict(os.environ, **({"GHOSTTYKIT_ARCHIVE_CACHE_DIR": env_cache} if env_cache else {}))
        with open(log, "a") as f:
            subprocess.run(["./scripts/download-prebuilt-ghosttykit.sh"], cwd=ROOT, stdout=f, stderr=subprocess.STDOUT, env=env)
    env = dict(os.environ, CMUX_DEV_BACKEND_MODE="local")
    code = run_logged(["./scripts/reload.sh", "--tag", tag, "--config", "bench", "--derived-data", derived], ROOT, env, log, label)
    text = open(log).read()
    lines = text.splitlines()
    app = next((lines[i + 1].strip() for i in range(len(lines) - 1) if lines[i].startswith("App path:")), None)
    if code != 0 or not app or not os.path.isdir(app):
        print("\n".join([l for l in lines if "error" in l][:40]), flush=True)
        print(text[-3000:], flush=True)
        sys.exit(f"AB-BUILD {label}: reload.sh exit {code}, app path {app!r} (see {log})")
    print(f"AB-BUILD {label} {sha[:12]} tag {tag}: built in {time.time() - start:.0f} s: {app}", flush=True)
    return hold(label, app, out)


def free_gib():
    st = os.statvfs(os.path.expanduser("~"))
    return st.f_bavail * st.f_frsize / 2 ** 30


def hold(label, app, out):
    """Copies a built app into the step's out folder: the next arm builds into the same DerivedData, which replaces
    this one's products. One DerivedData for every arm keeps the disk to one build's intermediates (reload.sh wants
    40 GiB free; per-arm DerivedData did not fit, job a861baa35e87bb620f0d0729)."""
    dest_dir = os.path.join(out, "apps", label)
    os.makedirs(dest_dir, exist_ok=True)
    dest = os.path.join(dest_dir, os.path.basename(app))
    if subprocess.run(["ditto", app, dest]).returncode != 0:
        sys.exit(f"AB-BUILD {label}: could not copy {app}")
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
    own = [b for b in builds if opts.app and b[1] in [head, *parents] and b[2] == opts.tag]
    fetch_all([b for b in builds if b not in own])
    # The segments run this harness from a copy: the builds below switch this checkout to each arm's commit.
    harness = os.path.join(out, "harness")
    shutil.copytree(HERE, harness, dirs_exist_ok=True, ignore=shutil.ignore_patterns("__pycache__"))
    # Every built arm reuses the step's own DerivedData (warm for this checkout's path), one build at a time.
    own_app = os.path.abspath(opts.app.rstrip("/")) if opts.app else ""
    derived = own_app.split("/Build/Products/")[0] if "/Build/Products/" in own_app else os.path.join(out, "DerivedData")
    try:
        # The step's own app is copied out first: a built arm replaces the products of the DerivedData it shares.
        for label, sha, tag in own + [b for b in builds if b not in own]:
            # The step's own app (instant-new-surfaces.sh built it) serves the build whose commit is the step's
            # parent: the step's commit adds only the harness files to it.
            if (label, sha, tag) in own:
                print(f"AB-BUILD {label} {sha[:12]}: the step's own app {opts.app}", flush=True)
                apps[label] = hold(label, own_app, out)
            else:
                apps[label] = build(label, sha, tag, out, derived)
    finally:
        subprocess.run(["git", "checkout", "--quiet", "--force", "--detach", head], cwd=ROOT)
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
            cmd = [sys.executable, os.path.join(harness, "instant-new-surfaces-bench.py"), "--tag", tag, "--app", apps[label],
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
