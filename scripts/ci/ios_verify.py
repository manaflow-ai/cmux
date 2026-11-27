#!/usr/bin/env python3
"""`cmux ios verify`: prove a pull request's iOS flows on its exact head before review, in minutes, and post the proof.

    cmux ios verify [--pr N] [--workers cmux22,cmux23] [--pair-e2e auto|always|never] [--no-merge-base] [--plan]

1. Base first. When the PR's base has moved past the head, merge it (no conflicts) and push, so the verified head
   holds the base: a merge-combination break (iOS regressions rows 4, 5, 7) fails here, not after landing.
   --no-merge-base skips it. A conflict stops with the files to resolve.
2. Select. cmux-next-ios/FlowSuite/select_flows.py picks the flows the diff can affect (flows.json).
3. Run, in parallel, on the warm pool (env CMUX_IOS_VERIFY_WORKERS, default cmux22,cmux23; never cosmic-gray or
   air-blue): one `cmux-ci run --class simulator` per shard of `test only=KIT ui=UI video` against
   scripts/ci/cmux-next-ios-sim.sh, pinned (--target-worker) so each worker's cached DerivedData, FFI/cargo cache and
   booted slim simulator (--sim-features none) are reused; `pair-e2e` (a tagged DEBUG Mac pairs by QR, drops and
   reconnects) when a selected flow has "pair_e2e": true; the flows' `scripts` here. A flow's macOS `swift` tests
   are named as delegated to pr-pipeline's mac job, which runs them on the same head.
4. Compare. Each screenshot is diffed against the newest passing ios-flows proof on a PR merged into the base (the
   last green build's captures); a change is evidence, not a failure. No baseline yet is said as such.
5. Post. The proof record (scripts/ci/proof_record.py, ci/proof-record/) goes on the PR keyed to the head, and the
   PR's `cmux/ios-fast` gate job is rerun so it reads it: the gate needs a passing proof at the current head.

--plan prints the selection and the steps without running anything.
"""

from __future__ import annotations

import argparse
import concurrent.futures as cf
import datetime as dt
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import time
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE))
sys.path.insert(0, str(REPO_ROOT / "cmux-next-ios" / "FlowSuite"))
import proof_record  # noqa: E402
import select_flows  # noqa: E402

SUITE = "ios-flows"
SIM_SCRIPT = "scripts/ci/cmux-next-ios-sim.sh"
ARTIFACT = "artifacts/ios-sim/evidence.zip"
DEFAULT_WORKERS = "cmux22,cmux23"
FORBIDDEN_WORKERS = {"cosmic-gray", "air-blue"}
GATE_JOB = "ios fast verdict status"
BROKER_ID = re.compile(r"through the broker as (\S+)")
STEP_ID = re.compile(r"\bstep[: ]+([0-9a-f]{8,})\b")
SAME_RATIO = 0.002


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def sh(*cmd: str, check: bool = True, cwd: Path | None = None) -> str:
    p = subprocess.run(cmd, capture_output=True, text=True, cwd=cwd)
    if check and p.returncode:
        raise SystemExit(f"ios verify: {' '.join(cmd[:3])} failed ({p.returncode}): {p.stderr.strip()[-600:]}")
    return p.stdout


def git(*args: str, check: bool = True) -> str:
    return sh("git", "-C", str(REPO_ROOT), *args, check=check).strip()


def gh_json(*args: str):
    return json.loads(sh("gh", *args) or "null")


def workers_from(spec: str) -> list[str]:
    out = [w.strip() for w in spec.split(",") if w.strip()]
    bad = [w for w in out if w.split(".")[0] in FORBIDDEN_WORKERS]
    if bad:
        raise SystemExit(f"ios verify: {', '.join(bad)} take no builds (Leo's GUI Macs); pick fleet minis")
    return out or [w for w in DEFAULT_WORKERS.split(",")]


# ---------- plan ----------

def plan(selection: dict, flows: list[dict], workers: list[str], pair: str) -> list[dict]:
    """The cmux-ci simulator runs for SELECTION, one per worker shard, plus pair-e2e when it applies."""
    steps = []
    lines = select_flows.sim_args(selection, len(workers)) if selection["ios"] else []
    for i, line in enumerate(lines):
        words = line.split()
        if words[0] == "test":
            words.append("video")
        steps.append({"name": f"sim {i + 1}/{len(lines)}: {line}", "mode": words[0], "args": words,
                      "worker": workers[i % len(workers)]})
    chosen = {f["id"] for f in flows if f["id"] in selection["flows"]}
    wants_pair = any(f.get("pair_e2e") for f in flows if f["id"] in chosen)
    if selection["ios"] and (pair == "always" or (pair == "auto" and wants_pair)):
        steps.append({"name": "pair-e2e: tagged Mac pairs, drops, reconnects", "mode": "pair-e2e",
                      "args": ["pair-e2e"], "worker": workers[len(steps) % len(workers)]})
    return steps


def delegated(selection: dict) -> list[dict]:
    return [{"name": f"swift {s['package']} {s['filter']}", "result": "skipped",
             "note": "delegated: pr pipeline / mac runs it on this head"} for s in selection.get("swift", [])]


# ---------- run ----------

def run_step(step: dict, head: str, pr: int, strict: bool) -> dict:
    cmd = ["cmux-ci", "run", "--class", "simulator", "--script", SIM_SCRIPT, "--ref", head,
           "--key", f"ios-verify-{pr}-{step['mode']}-{step['worker']}", "--target-worker", step["worker"],
           "--sim-features", "none", "--artifact", ARTIFACT, "--priority", "agent",
           "--reason", f"cmux ios verify #{pr}"]
    if strict:
        cmd.append("--pin-strict")
    for a in step["args"]:
        cmd += ["--arg", a]
    t0 = time.monotonic()
    p = subprocess.run(cmd, capture_output=True, text=True)
    text = p.stdout + "\n" + p.stderr
    m = BROKER_ID.search(text) or STEP_ID.search(text)
    return {"name": step["name"], "mode": step["mode"], "worker": step["worker"], "args": step["args"],
            "step": m.group(1) if m else None, "result": "pass" if p.returncode == 0 else "fail",
            "exit": p.returncode, "seconds": round(time.monotonic() - t0), "tail": text.strip()[-400:]}


def run_script(script: str) -> dict:
    t0 = time.monotonic()
    p = subprocess.run(shlex.split(script), capture_output=True, text=True, cwd=REPO_ROOT)
    # exit 2 from a macOS-only helper on Linux (tagged-sim.sh: "xcrun not found") is skipped, not passed.
    result = "pass" if p.returncode == 0 else ("skipped" if p.returncode == 2 and "only" in p.stderr else "fail")
    return {"name": f"script: {script}", "mode": "script", "worker": os.uname().nodename, "args": [script],
            "result": result, "exit": p.returncode, "seconds": round(time.monotonic() - t0),
            "tail": (p.stdout + p.stderr).strip()[-400:]}


# ---------- captures ----------

def fetch(step_id: str, into: Path) -> list[Path]:
    into.mkdir(parents=True, exist_ok=True)
    z = into / "evidence.zip"
    if subprocess.run(["cmux-ci", "artifact", step_id, str(z)], capture_output=True).returncode or not z.is_file():
        return []
    with zipfile.ZipFile(z) as zf:
        for n in zf.namelist():
            if n.endswith((".png", ".mp4")) and ".." not in n and not n.startswith("/"):
                zf.extract(n, into)
    return sorted(p for p in into.rglob("*") if p.suffix in (".png", ".mp4"))


def diff_ratio(a: Path, b: Path) -> float | None:
    try:
        from PIL import Image, ImageChops
    except ImportError:
        return None
    with Image.open(a) as x, Image.open(b) as y:
        if x.size != y.size:
            return 1.0
        d = ImageChops.difference(x.convert("RGB"), y.convert("RGB")).convert("L").point(lambda v: 255 if v > 16 else 0)
        return round(sum(1 for v in d.getdata() if v) / (x.size[0] * x.size[1]), 4)


def compare(shots: list[Path], base: dict[str, Path]) -> list[dict]:
    out = []
    for s in shots:
        rec = {"name": s.name, "sha256": hashlib.sha256(s.read_bytes()).hexdigest()}
        b = base.get(s.name)
        if not base:
            rec["verdict"] = "unbaselined"
        elif b is None:
            rec["verdict"] = "new"
        else:
            r = diff_ratio(s, b)
            rec["diff_ratio"] = r
            rec["verdict"] = "same" if r is not None and r <= SAME_RATIO else "changed"
        out.append(rec)
    for name in sorted(set(base) - {s.name for s in shots}):
        out.append({"name": name, "verdict": "missing"})
    return out


NIGHTLY_TAG = os.environ.get("CMUX_IOS_VERIFY_NIGHTLY_TAG", "nightly-next")


def search_prs(repo: str, q: str) -> list[dict]:
    """Issue search for REPO. On a lane VM the broker refuses `gh pr list --search`; `lane-gh call search_issues` is
    its route. Elsewhere, `gh api search/issues`. Each item: number and pull_request.merged_at."""
    if shutil.which("lane-gh"):
        out = sh("lane-gh", "call", "search_issues", repo, json.dumps({"q": q, "per_page": 30}), "--field", "items",
                 check=False)
        try:
            return json.loads(out) if out.strip().startswith("[") else []
        except ValueError:
            return []
    got = gh_json("api", "-X", "GET", "search/issues", "-f", f"q=repo:{repo} {q}", "-f", "per_page=30")
    return (got or {}).get("items") or []


def nightly_sha() -> str | None:
    """The commit the NIGHTLY Leo runs was built from: the NIGHTLY_TAG tag (fetched fresh)."""
    git("fetch", "-q", "--no-tags", "origin", f"+refs/tags/{NIGHTLY_TAG}:refs/tags/{NIGHTLY_TAG}", check=False)
    return git("rev-parse", "-q", "--verify", f"refs/tags/{NIGHTLY_TAG}^{{commit}}", check=False) or None


def in_nightly(sha: str | None, nightly: str | None) -> bool:
    if not (sha and nightly):
        return False
    git("fetch", "-q", "--no-tags", "origin", sha, check=False)
    return subprocess.run(["git", "-C", str(REPO_ROOT), "merge-base", "--is-ancestor", sha, nightly]).returncode == 0


def baseline(repo: str, base_ref: str, work: Path) -> tuple[dict | None, dict[str, Path]]:
    """The screens to diff against: the newest passing ios-flows proof on a PR merged into BASE_REF whose merge commit
    is in the NIGHTLY (NIGHTLY_TAG), so a diff reads as against NIGHTLY. With none in the NIGHTLY yet, the newest
    merged proof, labelled source "merged" so Tier 1 can tell; none at all is no baseline."""
    nightly = nightly_sha()
    try:
        items = search_prs(repo, f"is:pr is:merged base:{base_ref} \"{proof_record.KIND} {SUITE}\" in:comments")
    except SystemExit:
        return None, {}
    fallback: tuple[dict | None, dict[str, Path]] = (None, {})
    for item in items[:15]:
        number = item["number"]
        try:
            merge = (gh_json("api", f"repos/{repo}/pulls/{number}") or {}).get("merge_commit_sha")
            comments = gh_json("api", f"repos/{repo}/issues/{number}/comments?per_page=100")
        except SystemExit:
            continue
        nightly_hit = in_nightly(merge, nightly)
        if fallback[0] and not nightly_hit:
            continue
        recs = [r for c in comments if proof_record.trusted(c, proof_record.DEFAULT_BOTS.split(","))
                for r in [proof_record.parse(c.get("body") or "")] if r and r["verdict"] == "pass"]
        for r in reversed(recs):
            run = next((x for x in r["runs"] if x.get("step") and x.get("mode") == "test"), None)
            shots = [s for s in fetch(run["step"], work / f"base-{number}") if s.suffix == ".png"] if run else []
            if not shots:
                continue
            meta = {"source": "nightly" if nightly_hit else "merged", "nightly_tag": NIGHTLY_TAG,
                    "nightly_sha": nightly, "pr": number, "sha": r["head_sha"], "merge_commit": merge,
                    "step": run["step"]}
            if nightly_hit:
                return meta, {s.name: s for s in shots}
            fallback = (meta, {s.name: s for s in shots})
            break
    return fallback


def visual(captures: list[dict], base_meta: dict | None, video: str | None) -> dict:
    """What Tier 1 (land-judge, visual changes) checks: real-sim screens diffed against the last green build."""
    changed = [c["name"] for c in captures if c["verdict"] in ("changed", "new", "missing")]
    return {"screens": sum(1 for c in captures if c["verdict"] != "missing"), "baselined": base_meta is not None,
            "baseline_source": (base_meta or {}).get("source", "none"),
            "changed": changed, "video": bool(video), "diffed": base_meta is not None and bool(captures)}


# ---------- PR ----------

def pr_view(pr: str | None, repo: str | None) -> dict:
    args = ["pr", "view"] + ([pr] if pr else []) + ["--json",
            "number,headRefName,headRefOid,baseRefName,url,isCrossRepository"]
    if repo:
        args += ["--repo", repo]
    return gh_json(*args)


def merge_base_first(view: dict) -> tuple[str, bool]:
    """Merge the moved base into the checked-out head and push; returns (head, merged)."""
    git("fetch", "-q", "origin", view["baseRefName"], view["headRefName"])
    head = git("rev-parse", "HEAD")
    if head != view["headRefOid"]:
        raise SystemExit(f"ios verify: this checkout is at {head[:10]}, the PR head is {view['headRefOid'][:10]}: "
                         "push or pull first, the proof is for the PR's head")
    base = f"origin/{view['baseRefName']}"
    if subprocess.run(["git", "-C", str(REPO_ROOT), "merge-base", "--is-ancestor", base, head]).returncode == 0:
        return head, False
    p = subprocess.run(["git", "-C", str(REPO_ROOT), "merge", "--no-edit", "-q", base], capture_output=True, text=True)
    if p.returncode:
        files = git("diff", "--name-only", "--diff-filter=U", check=False)
        git("merge", "--abort", check=False)
        raise SystemExit(f"ios verify: merging {base} conflicts in:\n{files}\nresolve, push, rerun "
                         "(or --no-merge-base to verify the head as it is)")
    git("push", "-q", "origin", f"HEAD:{view['headRefName']}")
    return git("rev-parse", "HEAD"), True


def pushed_at(repo: str, sha: str) -> str:
    try:
        c = gh_json("api", f"repos/{repo}/commits/{sha}")
        return c["commit"]["committer"]["date"]
    except (SystemExit, KeyError, TypeError):
        return now()


def rerun_gate(repo: str, sha: str) -> str:
    """Rerun the PR's `cmux/ios-fast` job at SHA so it reads the proof; a job not run yet reads it when it runs."""
    try:
        runs = gh_json("api", f"repos/{repo}/actions/workflows/pr-router.yml/runs?head_sha={sha}&per_page=5")
        for run in runs.get("workflow_runs", []):
            jobs = gh_json("api", f"repos/{repo}/actions/runs/{run['id']}/jobs?per_page=100")
            for j in jobs.get("jobs", []):
                if j["name"] == GATE_JOB and j.get("status") == "completed" and j.get("conclusion") != "skipped":
                    sh("gh", "run", "rerun", str(run["id"]), "--job", str(j["id"]), "--repo", repo)
                    return f"reran {GATE_JOB} (job {j['id']})"
    except SystemExit as e:
        return f"gate not rerun: {e}"
    return "gate job has not run yet: it reads the proof when it does"


def summary_md(record: dict) -> str:
    t = record["timing"]
    lines = [f"**`cmux ios verify`** at `{record['head_sha'][:10]}`: **{record['verdict']}**"
             f" ({len(record['selection']['flows'])} flows, push to proof {t.get('push_to_proof_s')} s)", "",
             "| run | worker | result | s |", "|---|---|---|---|"]
    for r in record["runs"]:
        lines.append(f"| {r['name']} | {r.get('worker', '')} | {r['result']} | {r.get('seconds', '')} |")
    changed = [c["name"] for c in record.get("captures", []) if c["verdict"] in ("changed", "new", "missing")]
    b = record.get("baseline")
    lines += ["", f"Screens: {len(record.get('captures', []))}, " +
              (f"vs #{b['pr']} at `{b['sha'][:10]}`: {len(changed)} differ" + (f" ({', '.join(changed[:8])})" if changed else "")
               if b else "no baseline yet (no passing proof merged into the base)")]
    if record.get("merged_base"):
        lines.append(f"The base was merged into the head first ({record['base_sha'][:10]}).")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0], epilog=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pr")
    ap.add_argument("--repo")
    ap.add_argument("--workers", default=os.environ.get("CMUX_IOS_VERIFY_WORKERS", DEFAULT_WORKERS))
    ap.add_argument("--pair-e2e", choices=("auto", "always", "never"), default="auto")
    ap.add_argument("--no-merge-base", action="store_true")
    ap.add_argument("--pin-strict", action="store_true", help="never fall back off the named workers")
    ap.add_argument("--plan", action="store_true")
    ap.add_argument("--no-post", action="store_true")
    ap.add_argument("--out", help="write the record here too")
    a = ap.parse_args(argv)
    t_start = time.monotonic()
    workers = workers_from(a.workers)
    view = pr_view(a.pr, a.repo)
    repo = a.repo or view["url"].split("github.com/")[1].rsplit("/pull/", 1)[0]
    merged = False
    if a.no_merge_base or a.plan:
        git("fetch", "-q", "origin", view["baseRefName"], check=False)
        head = view["headRefOid"]
    else:
        head, merged = merge_base_first(view)
    base_sha = git("merge-base", f"origin/{view['baseRefName']}", head)
    manifest = json.loads(select_flows.MANIFEST.read_text())
    changed = select_flows.changed_from_git(base_sha, head)
    selection = select_flows.select(manifest, changed)
    steps = plan(selection, manifest["flows"], workers, a.pair_e2e)
    if a.plan or not selection["ios"]:
        print(json.dumps({"head": head, "ios": selection["ios"], "flows": selection["flows"],
                          "steps": steps, "scripts": selection["scripts"], "delegated": delegated(selection)}, indent=1))
        if not selection["ios"]:
            print("not iOS-affecting: cmux/ios-fast passes without a proof", file=sys.stderr)
        return 0
    with cf.ThreadPoolExecutor(max_workers=len(steps) + len(selection["scripts"]) or 1) as pool:
        futs = [pool.submit(run_step, s, head, int(view["number"]), a.pin_strict) for s in steps]
        futs += [pool.submit(run_script, s) for s in selection["scripts"]]
        runs = [f.result() for f in futs]
    runs += delegated(selection)
    work = Path(tempfile.mkdtemp(prefix="ios-verify-"))
    shots, video = [], None
    for r in runs:
        if r.get("step") and r["mode"] == "test":
            got = fetch(r["step"], work / r["step"])
            shots += [p for p in got if p.suffix == ".png"]
            video = video or next((str(p.relative_to(work)) for p in got if p.name == "ui-video-small.mp4"), None)
    base_meta, base_shots = baseline(repo, view["baseRefName"], work)
    captures = compare(shots, base_shots)
    proof_at = now()
    pushed = pushed_at(repo, head)
    p2p = int((dt.datetime.fromisoformat(proof_at.replace("Z", "+00:00"))
               - dt.datetime.fromisoformat(pushed.replace("Z", "+00:00"))).total_seconds())
    record = {
        "kind": proof_record.KIND, "version": proof_record.VERSION, "suite": SUITE, "repo": repo,
        "pr": int(view["number"]), "head_sha": head, "base_ref": view["baseRefName"], "base_sha": base_sha,
        "merged_base": merged,
        "selection": {k: selection[k] for k in ("flows", "kit", "ui", "swift", "scripts", "compile")},
        "runs": [{k: v for k, v in r.items() if k != "tail"} for r in runs],
        "captures": captures, "baseline": base_meta, "video": video,
        "visual": visual(captures, base_meta, video),
        "verdict": "fail" if any(r["result"] in ("fail", "error") for r in runs) else "pass",
        "timing": {"pushed_at": pushed, "proof_at": proof_at, "push_to_proof_s": p2p,
                   "verify_s": round(time.monotonic() - t_start)},
        "tool": "scripts/ci/ios_verify.py@" + git("rev-parse", "--short=12", "HEAD", check=False),
    }
    for r in runs:
        if r["result"] in ("fail", "error"):
            print(f"FAIL {r['name']}:\n{r.get('tail', '')}\n", file=sys.stderr)
    body = proof_record.render(record, summary_md(record))
    if a.out:
        Path(a.out).write_text(json.dumps(record, indent=1))
    if not a.no_post:
        f = work / "comment.md"
        f.write_text(body)
        sh("gh", "pr", "comment", str(view["number"]), "--repo", repo, "--body-file", str(f))
        print(rerun_gate(repo, head), file=sys.stderr)
    else:
        print(body)
    print(f"ios verify: {record['verdict']} at {head[:10]} in {record['timing']['verify_s']} s "
          f"(push to proof {p2p} s)", file=sys.stderr)
    return 0 if record["verdict"] == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
