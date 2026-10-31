#!/usr/bin/env python3
"""Run one interleaved A/B plan on one fleet mini, one pinned step at a time (fast benches, cmux-ad 2026-10-31).

  driver.py PLAN.json

PLAN: {"worker": "cmux22-perf", "pool": "perf-lead",
       "steps": [{"key", "ref", "script", "args": [...], "artifact", "adopt": "<job id>" (optional)}, ...]}
The steps alternate the two commits (A B A B, or B A B A on a second mini). Each step is a reviewed measure script
(scripts/measure/split-spring.sh, scripts/measure/instant-new-surfaces.sh), run as `cmux-ci run --class exclusive
--measurement --label measure --pool POOL --target-worker WORKER`. "adopt" follows a step that is already submitted.

Fleet rules this follows (2026-10-31):
- A pin waits for the worker: the controller moves a pinned step that waits 10 min to another worker of the pool.
  So the driver submits a step only when the worker is idle (no running step, no queued pin, its pool is POOL and not
  a capture lease, at least MIN_FREE_GIB free), reads the step's worker every 15 s for its first 10 min, cancels a
  step that is still queued after QUEUE_LIMIT, and cancels at once a step that starts on another worker.
- Never the reserved hosts in REFUSED (cmux17: the Cua grant).
- One step at a time per mini, the next only when the previous one ended, so a pin never waits behind its own queue.
- A verdict comes from the bench's own artifact, never from "done": each ended step and its artifact path are a line
  in PLAN.state.jsonl, and the artifact is in artifacts/<key>.json beside the plan.
Environment: CMUX_CI (default: cmux-ci on PATH), CMUX_CI_CONTROLLER (default http://100.89.225.106:18765).
"""
import json, os, shutil, subprocess, sys, time, urllib.request

CI = os.environ.get("CMUX_CI") or shutil.which("cmux-ci") or "cmux-ci"
CONTROLLER = os.environ.get("CMUX_CI_CONTROLLER", "http://100.89.225.106:18765")
QUEUE_LIMIT = 6 * 60
MIN_FREE_GIB = 40
REFUSED = ("cmux17",)
ENDED = ("done", "failed", "cancelled", "timeout", "error")


def worker_ready(status, worker, pool, min_free_gib=MIN_FREE_GIB):
    """(ready, why) for WORKER in a controller /v1/status body."""
    w = next((w for w in status.get("workers") or [] if w.get("name") == worker), None)
    if w is None:
        return False, "not in /v1/status"
    if w.get("pool") != pool:
        return False, f"pool is {w.get('pool')} (a capture lease or another reservation)"
    free = (w.get("free_bytes") or 0) / 2**30
    if free < min_free_gib:
        return False, f"{free:.1f} GiB free, under {min_free_gib}"
    m = next((m for m in status.get("measure_hosts") or [] if m.get("name") == worker), None)
    if m is None or not m.get("online", True):
        return False, "offline"
    if m.get("running"):
        return False, f"runs {m['running'].get('step_key') or m['running'].get('id')}"
    if m.get("queued_pinned"):
        return False, f"{m['queued_pinned']} pinned step(s) queued"
    return True, "idle"


def step_action(job, worker, queued_for):
    """What to do with a submitted step from its status: wait, cancel-wrong-worker, cancel-queued or ended."""
    w = job.get("worker") or ""
    if w and w != worker:
        return "cancel-wrong-worker"
    if job.get("state") in ENDED:
        return "ended"
    if job.get("state") == "queued" and queued_for > QUEUE_LIMIT:
        return "cancel-queued"
    return "wait"


def step_command(step, worker, pool, key):
    return [CI, "run", "--class", "exclusive", "--measurement", "--label", "measure", "--pool", pool,
            "--target-worker", worker, "--ref", step["ref"], "--key", key, "--interval", "60", "--timeout", "5400",
            "--script", step["script"], *[f"--arg={a}" for a in step["args"]], "--artifact", step["artifact"]]


class Driver:
    def __init__(self, plan_path):
        self.plan_path = plan_path
        with open(plan_path) as f:
            self.plan = json.load(f)
        self.worker = self.plan["worker"]
        self.pool = self.plan.get("pool", "perf-lead")
        if any(r in self.worker for r in REFUSED):
            raise SystemExit(f"driver: {self.worker} is reserved; never submit there")
        base = os.path.splitext(plan_path)[0]
        self.state_path = base + ".state.jsonl"
        self.art_dir = os.path.join(os.path.dirname(os.path.abspath(plan_path)), "artifacts")
        os.makedirs(self.art_dir, exist_ok=True)
        self.run_id = time.strftime("%H%M", time.gmtime())  # a restarted driver never reuses a step key

    def log(self, **kw):
        kw["t"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        with open(self.state_path, "a") as f:
            f.write(json.dumps(kw) + "\n")
        print(json.dumps(kw), flush=True)

    def ci(self, *args, timeout=120):
        p = None
        for attempt in range(5):
            try:
                p = subprocess.run([CI, *args], capture_output=True, text=True, timeout=timeout)
            except subprocess.TimeoutExpired:
                p = None
            if p and "cannot reach the build controller" not in (p.stdout + p.stderr):
                return p
            time.sleep(20 * (attempt + 1))
        return p

    def status(self, job):
        p = self.ci("status", job)
        try:
            return json.loads(p.stdout)
        except (AttributeError, ValueError):
            return None

    def ready(self):
        try:
            with urllib.request.urlopen(f"{CONTROLLER}/v1/status", timeout=60) as r:
                body = json.load(r)
        except (OSError, ValueError):
            return False, "controller unreachable"
        return worker_ready(body, self.worker, self.pool)

    def submit(self, step, attempt):
        last = None
        for _ in range(240):  # up to 2 h for the mini to be idle
            ok, why = self.ready()
            if ok:
                break
            if why != last:
                self.log(key=step["key"], result="waiting", why=why)
                last = why
            time.sleep(30)
        else:
            return None
        key = f"{step['key']}-{self.run_id}-t{attempt}"
        out = os.path.join(os.path.dirname(self.state_path), f"{key}.client.log")
        with open(out, "w") as f:
            proc = subprocess.Popen(step_command(step, self.worker, self.pool, key), stdout=f, stderr=subprocess.STDOUT,
                                    stdin=subprocess.DEVNULL, start_new_session=True)
        job = None
        for _ in range(150):
            time.sleep(2)
            with open(out) as f:
                for line in f:
                    if line.startswith("cmux-ci: step "):
                        job = line.split()[2]
                        break
            if job or proc.poll() is not None:
                break
        try:
            os.killpg(proc.pid, 15)  # this driver's own client only; the step continues on the controller
        except ProcessLookupError:
            pass
        return job

    def run_step(self, step):
        attempt, job = 0, step.get("adopt")
        while True:
            if not job:
                attempt += 1
                if attempt > 4:
                    self.log(key=step["key"], result="gave-up", why=f"4 attempts did not start on {self.worker}")
                    return
                job = self.submit(step, attempt)
                if not job:
                    self.log(key=step["key"], result="submit-failed", attempt=attempt)
                    time.sleep(120)
                    continue
                self.log(key=step["key"], job=job, result="submitted", attempt=attempt)
            since = time.time()
            while True:
                time.sleep(15 if time.time() - since < 600 else 60)
                s = self.status(job)
                if not s:
                    continue
                action = step_action(s, self.worker, time.time() - since)
                if action == "wait":
                    continue
                if action.startswith("cancel"):
                    self.ci("cancel", job, "--reason", f"bench driver: {action} (pinned to {self.worker})")
                    self.log(key=step["key"], job=job, result=action, worker=s.get("worker"))
                    job = None
                    time.sleep(30 if action == "cancel-wrong-worker" else 180)
                    break
                art = None
                if s["state"] == "done":
                    art = os.path.join(self.art_dir, f"{step['key']}.json")
                    self.ci("artifact", job, art, timeout=600)
                    art = art if os.path.exists(art) else None
                self.log(key=step["key"], job=job, result=s["state"], artifact=art, started=s.get("started_at"),
                         ended=s.get("updated_at"))
                return

    def run(self):
        for step in self.plan["steps"]:
            self.run_step(step)
        self.log(key="plan", result="finished")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    Driver(sys.argv[1]).run()
