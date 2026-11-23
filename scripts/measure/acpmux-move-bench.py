#!/usr/bin/env python3
"""Measure acpmux chat moves between two isolated sibling daemons, under message load.

Starts daemons A and B (own HOME, ACPMUX_HOME, ACPMUX_SOCKET; nothing of this machine's real
config or mesh), creates one chat on a zero-cost cli-agent harness (a shell script that sleeps
0..--turn-secs and echoes), moves it A->B->A... --moves times with `acpmux session transfer`,
and while it moves a sender sends numbered messages ("msg-000123") with `acpmux send --no-wait`:
  --sender current : to the daemon that holds the chat now
  --sender origin  : always to the daemon that held it at the start (A)
  --sender none    : no load
Then it reads every user_message on both daemons and counts each number: once, duplicated, lost.

The daemons' state lives in a private mkdtemp under /tmp: acpmux refuses a state directory with a
group-writable, non-sticky ancestor (config.rs validate_private_state_ancestors), and
~/Projects and ~/Projects/briefs are group-writable. HOME (harness profile) stays under bench/.

Run with python3 -I. Results: <--out>/results/<timestamp>-<label>.json and .md.

Copied from the super-highway goal's bench (cmuxterm-hq goals/super-highway.md) for the acked
hand-off prototype: `--transfer-arg` passes extra flags to every `session transfer` (e.g.
`--transfer-arg=--acked-handoff`), `--out` picks where runs and results go. Run, before and after:
  nice -n 10 python3 -I scripts/measure/acpmux-move-bench.py --acpmux BIN --moves 100 \
    --turn-secs 1.0 --sender current --label NAME [--transfer-arg=--acked-handoff]
"""

import argparse
import json
import os
import random
import re
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

DEFAULT_OUT = "/tmp/acpmux-move-bench"
BENCH = Path(DEFAULT_OUT)
CHAT = "benchchat"
MSG_RE = re.compile(r"msg-(\d{6})")
DELIVERY_RE = re.compile(r"delivery ([0-9a-f-]{36})")


def now_ms():
    return time.monotonic() * 1000.0


class Daemon:
    def __init__(self, name, acpmux, run_dir, state_dir):
        self.name = name
        self.acpmux = acpmux
        self.home = run_dir / f"home{name}"
        self.state = state_dir / name
        self.socket = state_dir / f"{name.lower()}.sock"
        self.log_path = run_dir / f"daemon{name}.log"
        self.proc = None
        self.log = None

    def env(self):
        return {
            "HOME": str(self.home),
            "PATH": f"{Path(self.acpmux).parent}:/usr/bin:/bin",
            "LANG": "C.UTF-8",
            "ACPMUX_HOME": str(self.state),
            "ACPMUX_SOCKET": str(self.socket),
            "ACPMUX_UNUSED_EXIT_SECS": "0",
        }

    def run(self, args, timeout=60, check=False):
        try:
            p = subprocess.run([self.acpmux, *args], env=self.env(), cwd=str(self.home),
                               capture_output=True, text=True, timeout=timeout)
            rc, out, err = p.returncode, p.stdout, p.stderr
        except subprocess.TimeoutExpired as e:
            rc, out, err = 124, e.stdout or "", f"timeout after {timeout}s"
            out = out.decode() if isinstance(out, bytes) else out
        if check and rc != 0:
            raise RuntimeError(f"{self.name}: acpmux {' '.join(args)} -> {rc}: {err.strip()}")
        return rc, out, err

    def start(self):
        self.log = open(self.log_path, "w")
        self.proc = subprocess.Popen([self.acpmux, "daemon", "run"], env=self.env(),
                                     cwd=str(self.home), stdout=self.log,
                                     stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                     start_new_session=True)
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline:
            if self.proc.poll() is not None:
                raise RuntimeError(f"daemon {self.name} exited {self.proc.returncode}; "
                                   f"see {self.log_path}")
            rc, _, _ = self.run(["daemon", "status"], timeout=10)
            if rc == 0:
                return
            time.sleep(0.2)
        raise RuntimeError(f"daemon {self.name} not ready in 30 s; see {self.log_path}")

    def stop(self):
        if self.proc is None:
            return
        if self.proc.poll() is None:
            self.run(["daemon", "shutdown", "--end-agents"], timeout=30)
            try:
                self.proc.wait(timeout=15)
            except subprocess.TimeoutExpired:
                # Our own daemon, by its process group (start_new_session made it the leader).
                os.killpg(self.proc.pid, signal.SIGTERM)
                try:
                    self.proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(self.proc.pid, signal.SIGKILL)
                    self.proc.wait(timeout=10)
        if self.log:
            self.log.close()


def write_harness(run_dir, daemons, acpmux, turn_secs):
    agent = run_dir / "echo_agent.sh"
    agent.write_text(
        "#!/bin/bash\n"
        "# Zero-cost harness: prompt on stdin, sleep 0..TURN_SECS, echo the message numbers.\n"
        "p=$(cat)\n"
        f"max=$(cat '{run_dir / 'turn_ms'}' 2>/dev/null || echo 0)\n"
        "if [ \"$max\" -gt 0 ]; then ms=$(( (RANDOM * 32768 + RANDOM) % (max + 1) )); "
        "sleep \"$(printf '%d.%03d' $((ms / 1000)) $((ms % 1000)))\"; fi\n"
        "ids=$(printf '%s' \"$p\" | grep -o 'msg-[0-9]\\{6\\}' | tr '\\n' ' ')\n"
        "printf 'echo: %s\\n' \"${ids:-ok}\"\n")
    agent.chmod(0o755)
    (run_dir / "turn_ms").write_text(f"{int(turn_secs * 1000)}\n")
    for d in daemons:
        hdir = d.home / ".config" / "cmux" / "harnesses"
        hdir.mkdir(parents=True, exist_ok=True)
        os.chmod(d.home, 0o700)
        prof = hdir / "benchecho.toml"
        prof.write_text(
            'schema = 1\nid = "benchecho"\nname = "Bench Echo"\nprotocol = "acp"\n'
            f'command = "{acpmux}"\nargs = ["cli-agent", "--", "{agent}"]\n')
        prof.chmod(0o600)


def pct(values, q):
    if not values:
        return None
    s = sorted(values)
    k = max(0, min(len(s) - 1, int(round(q / 100.0 * len(s) + 0.5)) - 1))
    return round(s[k], 1)


class Sender(threading.Thread):
    def __init__(self, mode, daemons, holder, interval):
        super().__init__(daemon=True)
        self.mode, self.daemons, self.holder, self.interval = mode, daemons, holder, interval
        self.stop_evt = threading.Event()
        self.sent = []  # {n, target, rc, ms, err}

    def run(self):
        n = 0
        while not self.stop_evt.is_set():
            t0 = time.monotonic()
            n += 1
            target = self.holder["now"] if self.mode == "current" else "A"
            d = self.daemons[target]
            s = now_ms()
            rc, out, err = d.run(["send", "--no-wait", CHAT, f"msg-{n:06d}"], timeout=20)
            self.sent.append({"n": n, "target": target, "rc": rc, "ms": round(now_ms() - s, 1),
                              "err": (err.strip() or out.strip())[:300] if rc else "",
                              "delivery": (DELIVERY_RE.findall(out) or [None])[0]})
            left = self.interval - (time.monotonic() - t0)
            if left > 0:
                self.stop_evt.wait(left)


def read_user_messages(d, sid, kinds=("user_message", "turn_result")):
    rc, out, err = d.run(["--json", "session", "tail", sid, "--last", "1000000"], timeout=120)
    events = []
    for line in out.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if ev.get("kind") in kinds:
            events.append(ev)
    return rc, events, err.strip()[:300]


def freeze_ms(daemons, sid):
    """Each move's freeze on its source: from its `transfer_out` record (the chat frozen, its
    bundle made) to its `transferred` record (committed), by transferId. With --after-turn the
    wait for the turn comes before `transfer_out` and is no freeze: the chat runs meanwhile."""
    outs, done = {}, {}
    for d in daemons.values():
        _, evs, _ = read_user_messages(d, sid, ("transfer_out", "transferred"))
        for ev in evs:
            tid = (ev.get("msg") or {}).get("transferId")
            at = ev.get("at") or ev.get("ts")
            if not tid or not isinstance(at, (int, float)):
                continue
            (outs if ev["kind"] == "transfer_out" else done)[tid] = at
    return [done[t] - outs[t] for t in outs if t in done]


def outbox(d):
    rc, out, _ = d.run(["--json", "send", "--status"], timeout=30)
    try:
        dels = json.loads(out).get("deliveries", [])
    except ValueError:
        return {"error": out[:200]}
    by = {}
    open_ids = [x.get("deliveryId") for x in dels if x.get("status") != "delivered"]
    for x in dels:
        by[x.get("status")] = by.get(x.get("status"), 0) + 1
    errs = sorted({(x.get("error") or "")[:120] for x in dels if x.get("status") != "delivered"})
    return {"total": len(dels), "byStatus": by, "openErrors": errs[:5], "openIds": open_ids}


def chat_state(d):
    rc, out, _ = d.run(["--json", "ls"], timeout=20)
    try:
        for s in json.loads(out).get("sessions", []):
            if s.get("name") == CHAT:
                return s.get("status"), s.get("queued")
    except ValueError:
        pass
    return None, None


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--acpmux", default="/home/cmux/.local/bin/acpmux")
    ap.add_argument("--moves", type=int, default=100)
    ap.add_argument("--turn-secs", type=float, default=0.0,
                    help="each turn sleeps uniform 0..S seconds")
    ap.add_argument("--sender", choices=["none", "current", "origin"], default="current")
    ap.add_argument("--send-interval", type=float, default=0.2)
    ap.add_argument("--move-gap", type=float, default=0.3, help="seconds between moves")
    ap.add_argument("--drain-secs", type=float, default=240.0,
                    help="after the last send, turns stop sleeping and the bench waits up to this "
                         "long for the chat to go idle with an empty queue and no outbox "
                         "delivery in flight before counting")
    ap.add_argument("--label", default="run")
    ap.add_argument("--keep", action="store_true", help="keep run and state dirs")
    ap.add_argument("--transfer-arg", action="append", default=[],
                    help="an extra flag for every `session transfer` (repeatable)")
    ap.add_argument("--out", default=DEFAULT_OUT, help="where runs/ and results/ go")
    a = ap.parse_args()
    global BENCH
    BENCH = Path(a.out)

    acpmux = str(Path(a.acpmux).resolve())
    ver = subprocess.run([acpmux, "--version"], capture_output=True, text=True).stdout.strip()
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    run_dir = BENCH / "runs" / f"{stamp}-{a.label}"
    run_dir.mkdir(parents=True)
    BENCH.chmod(0o700)
    os.chmod(run_dir, 0o700)
    state_dir = Path(tempfile.mkdtemp(prefix="acpmux-bench-", dir="/tmp"))
    daemons = {n: Daemon(n, acpmux, run_dir, state_dir) for n in ("A", "B")}
    for d in daemons.values():
        d.home.mkdir()
    write_harness(run_dir, daemons.values(), acpmux, a.turn_secs)
    work = daemons["A"].home / "work"
    work.mkdir()

    moves, sender, notes = [], None, []
    result = {"label": a.label, "stamp": stamp, "acpmux": acpmux, "version": ver,
              "params": vars(a), "runDir": str(run_dir)}
    try:
        for d in daemons.values():
            d.start()
        A = daemons["A"]
        rc, out, err = A.run(["--json", "new", "-n", CHAT, "-m", "benchecho", "--cwd", str(work),
                              "-d", "-q", "bench start"], timeout=90, check=True)
        sid = json.loads(out)["sessionId"]
        result["sessionId"] = sid
        _, help_out, _ = A.run(["session", "transfer", "--help"], timeout=10)
        knows_after_turn = "--after-turn" in help_out
        result["knowsAfterTurn"] = knows_after_turn

        holder = {"now": "A"}
        if a.sender != "none":
            sender = Sender(a.sender, daemons, holder, a.send_interval)
            sender.start()
            time.sleep(1.0)

        after_turn_probe = None
        for i in range(a.moves):
            src = holder["now"]
            dst = "B" if src == "A" else "A"
            attempts = []
            t0 = now_ms()
            flags = (["--after-turn"] if knows_after_turn else []) + list(a.transfer_arg)
            if not knows_after_turn and after_turn_probe is None:
                # Record what this build says to --after-turn (once; it is not a move).
                rc, out, err = daemons[src].run(["session", "transfer", CHAT, "--to",
                                                 str(daemons[dst].socket), "--after-turn"])
                after_turn_probe = {"rc": rc, "err": err.strip().splitlines()[:1]}
                t0 = now_ms()
            ok = False
            for extra in ([flags, ["--interrupt"]] if not knows_after_turn else [flags]):
                s = now_ms()
                rc, out, err = daemons[src].run(["session", "transfer", CHAT, "--to",
                                                 str(daemons[dst].socket), *extra], timeout=120)
                attempts.append({"flags": extra, "rc": rc, "ms": round(now_ms() - s, 1),
                                 "err": err.strip()[:300]})
                if rc == 0:
                    ok = True
                    break
                if "busy" not in err:
                    break
            total = round(now_ms() - t0, 1)
            if ok:
                holder["now"] = dst
            moves.append({"i": i, "from": src, "to": dst, "ok": ok, "ms": total,
                          "attempts": attempts})
            print(f"move {i:3d} {src}->{dst} {'ok' if ok else 'FAIL'} {total:.0f} ms "
                  f"{'(interrupt)' if len(attempts) > 1 else ''}", flush=True)
            if not ok:
                # Is the chat stuck where it was? Keep going: the next move tries again.
                notes.append(f"move {i} failed: {attempts[-1]['err'][:200]}")
            time.sleep(a.move_gap)
        result["afterTurnProbe"] = after_turn_probe

        if sender:
            sender.stop_evt.set()
            sender.join(timeout=30)
        (run_dir / "turn_ms").write_text("0\n")
        drain_t0 = time.monotonic()
        idle_polls, drained = 0, False
        while time.monotonic() - drain_t0 < a.drain_secs:
            status, queued = chat_state(daemons[holder["now"]])
            busy_out = any(o.get("byStatus", {}).get("delivering")
                           for o in (outbox(d) for d in daemons.values()))
            if status in ("idle", "ready") and not queued and not busy_out:
                idle_polls += 1
                if idle_polls >= 5:
                    drained = True
                    break
            else:
                idle_polls = 0
            time.sleep(1.0)
        result["drain"] = {"secs": round(time.monotonic() - drain_t0, 1), "idle": drained,
                           "finalChat": chat_state(daemons[holder["now"]])}

        # Every user_message and turn_result either daemon's copy of the chat holds. A moved
        # chat's history travels with it, so one event shows on both: keyed by its promptId.
        # A turn a move interrupts is run again on the target as promptId `<id>~resume-N` with
        # the same text: a re-run, not a second delivery. A second delivery is a second base id.
        freezes = freeze_ms(daemons, sid)
        result["freeze"] = {"count": len(freezes), "p50": pct(freezes, 50), "p95": pct(freezes, 95),
                            "max": max(freezes) if freezes else None}
        prompts, completed = {}, set()
        reads = {}
        for n, d in daemons.items():
            rc, evs, err = read_user_messages(d, sid)
            reads[n] = {"rc": rc, "userMessages": sum(e["kind"] == "user_message" for e in evs),
                        "err": err}
            for ev in evs:
                m = ev.get("msg", {})
                pid = m.get("promptId") or f"noid-{ev.get('at')}"
                if ev["kind"] == "user_message":
                    prompts.setdefault(pid, m.get("text") or "")
                elif m.get("status") == "completed":
                    completed.add(pid)
        bases, reruns, answered = {}, {}, set()
        for pid, text in prompts.items():
            base = pid.split("~resume-")[0]
            for num in {int(x) for x in MSG_RE.findall(text)}:
                if "~resume-" in pid:
                    reruns[num] = reruns.get(num, 0) + 1
                else:
                    bases.setdefault(num, set()).add(base)
                if pid in completed:
                    answered.add(num)
        counts = {num: len(b) for num, b in bases.items()}
        for num in reruns:
            counts.setdefault(num, 1)  # seen only as a re-run: still delivered once
        result["reads"] = reads
        result["outbox"] = {n: outbox(d) for n, d in daemons.items()}
        _, ls_out, _ = daemons[holder["now"]].run(["ls"], timeout=20)
        result["finalHolder"] = holder["now"]
        result["finalLs"] = ls_out.strip()[:400]

        mv_ms = [m["ms"] for m in moves if m["ok"]]
        result["moves"] = {
            "count": len(moves), "ok": sum(m["ok"] for m in moves),
            "failed": sum(not m["ok"] for m in moves),
            "neededInterrupt": sum(1 for m in moves if len(m["attempts"]) > 1),
            "p50_ms": pct(mv_ms, 50), "p95_ms": pct(mv_ms, 95),
            "max_ms": round(max(mv_ms), 1) if mv_ms else None,
            "mean_ms": round(statistics.mean(mv_ms), 1) if mv_ms else None,
        }
        if sender:
            sent_ok = [s for s in sender.sent if s["rc"] == 0]
            nums = [s["n"] for s in sent_ok]
            once = [n for n in nums if counts.get(n, 0) == 1]
            dup = [n for n in nums if counts.get(n, 0) > 1]
            lost = [n for n in nums if counts.get(n, 0) == 0]
            failed_nums = {s["n"] for s in sender.sent if s["rc"] != 0}
            open_ids = {i for o in result["outbox"].values() for i in o.get("openIds", [])}
            stuck = [s["n"] for s in sent_ok
                     if counts.get(s["n"], 0) == 0 and s.get("delivery") in open_ids]
            errs = {}
            for s in sender.sent:
                if s["rc"]:
                    k = s["err"].splitlines()[0][:120] if s["err"] else f"rc {s['rc']}"
                    errs[k] = errs.get(k, 0) + 1
            result["messages"] = {
                "mode": a.sender, "sent": len(sender.sent), "accepted": len(sent_ok),
                "deliveredOnce": len(once), "duplicated": len(dup), "lost": len(lost),
                "lostStuckInOutbox": len(stuck),
                "rerunAfterInterrupt": sum(1 for n in nums if reruns.get(n)),
                "rerunTurns": sum(reruns.get(n, 0) for n in nums),
                "neverAnswered": sum(1 for n in nums if counts.get(n) and n not in answered),
                "sendErrors": len(failed_nums),
                "deliveredDespiteSendError": sum(1 for n in failed_nums if counts.get(n)),
                "sendErrorKinds": errs,
                "lostNumbers": lost[:50], "duplicatedNumbers": dup[:50],
                "send_p50_ms": pct([s["ms"] for s in sender.sent], 50),
                "send_p95_ms": pct([s["ms"] for s in sender.sent], 95),
            }
        result["notes"] = notes
        result["moveLog"] = moves
        if sender:
            result["sendLog"] = sender.sent
    except Exception as e:  # noqa: BLE001 - recorded in the results, then re-raised
        result["error"] = f"{type(e).__name__}: {e}"
        raise
    finally:
        if sender and sender.is_alive():
            sender.stop_evt.set()
            sender.join(timeout=30)
        for d in daemons.values():
            try:
                d.stop()
            except Exception as e:  # noqa: BLE001
                notes.append(f"stop {d.name}: {e}")
        write_results(result)
        if not a.keep:
            shutil.rmtree(state_dir, ignore_errors=True)


def write_results(r):
    out = BENCH / "results"
    out.mkdir(exist_ok=True)
    base = out / f"{r['stamp']}-{r['label']}"
    base.with_suffix(".json").write_text(json.dumps(r, indent=2) + "\n")
    mv, msg = r.get("moves", {}), r.get("messages")
    lines = [f"# acpmux move bench: {r['label']}", "",
             f"- binary: `{r['acpmux']}` ({r['version']})",
             f"- params: moves={r['params']['moves']} turn-secs={r['params']['turn_secs']} "
             f"sender={r['params']['sender']} send-interval={r['params']['send_interval']}s "
             f"move-gap={r['params']['move_gap']}s",
             f"- knows --after-turn: {r.get('knowsAfterTurn')} "
             f"(probe: {r.get('afterTurnProbe')})", ""]
    if r.get("error"):
        lines += [f"**error:** {r['error']}", ""]
    if mv:
        lines += ["## Moves", "",
                  f"{mv['ok']}/{mv['count']} ok, {mv['failed']} failed, "
                  f"{mv['neededInterrupt']} needed --interrupt; "
                  f"p50 {mv['p50_ms']} ms, p95 {mv['p95_ms']} ms, max {mv['max_ms']} ms "
                  "(wall time of the move command, with any wait for the turn)", "",
                  f"freeze (transfer_out to transferred on the source): {r.get('freeze')}", ""]
    if msg:
        lines += ["## Messages", "",
                  f"mode `{msg['mode']}`: sent {msg['sent']}, accepted {msg['accepted']}, "
                  f"delivered once {msg['deliveredOnce']}, duplicated {msg['duplicated']}, "
                  f"lost {msg['lost']} ({msg['lostStuckInOutbox']} of them still queued in a "
                  f"daemon's outbox), send errors {msg['sendErrors']}", "",
                  f"- re-run after an interrupted move (`~resume-N` turns, same text): "
                  f"{msg['rerunAfterInterrupt']} messages, {msg['rerunTurns']} extra turns",
                  f"- delivered but no completed turn ever carried it: {msg['neverAnswered']}",
                  f"- drain: {r.get('drain')}", ""]
        if msg["sendErrorKinds"]:
            lines += ["Send errors:", ""] + [f"- {v}x {k}" for k, v in msg["sendErrorKinds"].items()] + [""]
    if r.get("outbox"):
        lines += ["## Outbox at the end", ""] + [f"- {k}: {json.dumps(v)}" for k, v in r["outbox"].items()] + [""]
    if r.get("notes"):
        lines += ["## Notes", ""] + [f"- {n}" for n in r["notes"][:20]] + [""]
    base.with_suffix(".md").write_text("\n".join(lines))
    print(f"results: {base}.json / .md", flush=True)


if __name__ == "__main__":
    sys.exit(main())
