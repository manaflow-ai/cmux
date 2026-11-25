#!/usr/bin/env python3
"""Run the P0 journey quit-leaves-no-helpers against the app of one fleet build, on a capture slot.

    python3 scripts/journeys/quit-leaves-no-helpers/run.py --build JOB [--quit applescript|menu] [--out DIR]

The route scripts/journeys/run.py (cp/journeys-framework) and `cmux-ci capture` take: `capture-host
acquire --slot` leases one slot on a GUI capture mini (released in every case; at most 10 minutes),
the slot downloads the build's artifact (`cmux-ci artifact JOB`), `capture-host launch` starts the app
there (its own clone, bundle id, HOME, TMPDIR, socket and empty settings), and journey.py drives it,
quits it and lists what of the bundle still runs. Capture hosts come from the fleet registry, or
`--hosts "cmux17 cmux18 ..."` (sets CAPTURE_HOST_SLOT_HOSTS). cmux16 and cmux20 are never leased.

Writes DIR/result.json (default artifacts/journeys/quit-leaves-no-helpers/<job12>-<UTC time>/).
Exit 0 pass, 1 fail, 75 not run.
"""
import argparse
import io
import json
import os
import shutil
import subprocess
import sys
import tarfile
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
TEARDOWN = ROOT / "scripts" / "cmux-next" / "tag_teardown.py"
SSH = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10"]
NEVER = ("cmux16", "cmux20")


def log(message):
    print(f"quit-journey: {message}", file=sys.stderr, flush=True)


def q(text):
    return "'" + str(text).replace("'", "'\"'\"'") + "'"


def run(argv, *, input=None, timeout=None, check=True):
    done = subprocess.run(argv, input=input, capture_output=True, timeout=timeout)
    if check and done.returncode != 0:
        raise RuntimeError(f"{' '.join(map(str, argv[:3]))} ... exited {done.returncode}: "
                           f"{(done.stderr or done.stdout).decode(errors='replace').strip()[-500:]}")
    return done


def remote(host, script, *, input=None, timeout=600, check=True):
    return run(SSH + [host, "zsh -lc " + q(script)], input=input, timeout=timeout, check=check)


def capture_host():
    found = os.environ.get("CAPTURE_HOST") or shutil.which("capture-host")
    return found or str(Path.home() / ".local/share/cmux/hq-tools/current/build-fleet/capture-host")


def kit():
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w") as tar:
        tar.add(HERE / "journey.py", arcname="journey.py")
        tar.add(TEARDOWN, arcname="tag_teardown.py")
    return buf.getvalue()


def launch_facts(text):
    line = next((l for l in reversed(text.splitlines()) if "socket=" in l), "")
    head, _, app = line.partition(" app=")
    facts = dict(kv.split("=", 1) for kv in head.split() if "=" in kv)
    if app.strip():
        facts["app"] = app.strip()
    return facts


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--build", required=True, help="a done fleet build job id (cmux-ci build cmux ...)")
    ap.add_argument("--quit", choices=("applescript", "menu"), default="applescript")
    ap.add_argument("--hosts", help="capture hosts, spaces between (sets CAPTURE_HOST_SLOT_HOSTS)")
    ap.add_argument("--out")
    a = ap.parse_args(argv)
    if a.hosts:
        hosts = [h for h in a.hosts.split() if h not in NEVER]
        os.environ["CAPTURE_HOST_SLOT_HOSTS"] = " ".join(hosts)
    os.environ["CAPTURE_HOST_EXCLUDE"] = " ".join(filter(None, [os.environ.get("CAPTURE_HOST_EXCLUDE", ""), *NEVER]))
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    out = Path(a.out or ROOT / "artifacts" / "journeys" / "quit-leaves-no-helpers" / f"{a.build[:12]}-{stamp}")
    out.mkdir(parents=True, exist_ok=True)
    ch = capture_host()
    acquired = run([ch, "acquire", "--slot"], timeout=330).stdout.decode().split()
    if not acquired:
        log("capture-host acquire printed no lease")
        return 75
    lease = acquired[-1]
    log(f"leased {lease}")
    status = 75
    try:
        info = dict(kv.split("=", 1) for kv in run([ch, "slot-info", lease]).stdout.decode().split() if "=" in kv)
        host, root = info["host"], info["root"]
        if host in NEVER:
            raise RuntimeError(f"leased {host}, which this journey never uses")
        work = f"{root}/quit-journey"
        remote(host, f"mkdir -p {q(work + '/kit')} && tar x -C {q(work + '/kit')}", input=kit(), timeout=120)
        log(f"downloading build {a.build} on {host}")
        app = remote(host, f"set -e; cd {q(work)}; cmux-ci artifact {q(a.build)} app.zip >&2; ditto -x -k app.zip build; "
                           f"rm -f app.zip; find \"$PWD/build\" -maxdepth 2 -name '*.app' -type d | head -1",
                     timeout=420).stdout.decode().strip()
        if not app.endswith(".app"):
            raise RuntimeError(f"build {a.build} has no app bundle")
        launched = run([ch, "launch", lease, app, "quit-journey", "--"], timeout=180, check=False)
        facts = launch_facts(launched.stdout.decode())
        if facts.get("socket", "none") == "none":
            raise RuntimeError("the app did not answer on its control socket: "
                               f"{(launched.stdout + launched.stderr).decode(errors='replace').strip()[-400:]}")
        log(f"launched pid {facts.get('pid')} on {host}; driving")
        drove = remote(host, f"/usr/bin/python3 -I {q(work + '/kit/journey.py')} --socket {q(facts['socket'])} "
                             f"--app {q(facts.get('app', app))} --out {q(work + '/out')} --quit {a.quit}",
                       timeout=300, check=False)
        for line in drove.stdout.decode(errors="replace").splitlines():
            log(f"[{host}] {line}")
        if drove.stderr:
            log(f"[{host}] stderr: {drove.stderr.decode(errors='replace').strip()[-800:]}")
        text = remote(host, f"cat {q(work + '/out/result.json')}", timeout=60, check=False).stdout.decode()
        result = json.loads(text) if text.strip().startswith("{") else {"status": "not run", "reason": "no result.json"}
        result.update(build_job=a.build, host=host, lease=lease)
        (out / "result.json").write_text(json.dumps(result, indent=1) + "\n")
        log(f"{result['status']}: {result.get('reason')} ({out / 'result.json'})")
        status = {"pass": 0, "fail": 1}.get(result["status"], 75)
    except (RuntimeError, subprocess.TimeoutExpired, KeyError, ValueError) as error:
        log(f"lease {lease}: {error}")
    finally:
        released = subprocess.run([ch, "release", lease], capture_output=True, timeout=120)
        log(f"released {lease}" if released.returncode == 0 else f"release of {lease} exited {released.returncode}")
    return status


if __name__ == "__main__":
    sys.exit(main())
