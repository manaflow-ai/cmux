#!/usr/bin/env python3
"""Replay real session turn traces through idle-hibernation policies: RAM-hours saved against wakes.

Input: a folder of `acpmux history QUALIFIED_ID --json -n 400` answers (one file per session, any host the
hub reaches; `--collect` writes them from `acpmux ls --json`). Each session is its turns' (startedAt,
endedAt); a gap is the time from one turn's end to the next one's start, and the last turn's end to the
recorded observation time (the trailing gap) only when the session was open. Legacy files without
observation metadata contribute completed gaps only; --now-ms can shorten, never extend a capture.

A policy decides, at each turn's end, how long the idle harness stays resident before it hibernates
(hub/idle.rs; today a static 2 min). In a gap g with timeout T the harness holds `min(g, T)` of RAM-time; a
gap longer than T ends with a wake (the next start of the agent, `woke ... took_ms` in daemon.log). Never
hibernating is the baseline; every policy is scored by:
  ram_gbh_saved   (g - min(g, T)) summed, times the resident tree's RSS (--rss-mb, median measured by
                  scripts/measure/idle-residents.py), in GB-hours, against never hibernating
  wakes           gaps longer than T that end in a turn
  wake_s          wakes x the measured wake (--wake-ms, daemon.log p50)
  person_wakes    of those, wakes whose next prompt came from a person (no [notice ...] / [inbox] prefix)
Static policies sweep fixed timeouts. The adaptive-v1 row matches the daemon policy, assuming zero
where end-of-turn background counts are missing (reported explicitly). Other dynamic rows are
exploratory parameter sweeps; their wait signal uses future notices and is not a causal measurement:
  history  the session's own last gaps: when their median is above H the next gap is predicted long and the
           harness goes after `short`; else it stays `long`
  wait     the next prompt is a "Background command finished" notice: it goes after `short`;
           this proxy cannot establish what the daemon knew when the turn ended
  pressure the host's resident harnesses at that moment (from the same traces): above the host's cap the
           timeout is divided by the overload
  combo    all three
The comparison is at equal wakes: each dynamic policy's RAM saved against the static frontier interpolated
at its wake count (the gap), so no exchange rate between RAM and latency is assumed.

    scripts/measure/idle-replay.py DIR [--rss-mb 320] [--wake-ms 409] [--now-ms MS] [--json]
    scripts/measure/idle-replay.py --collect DIR [--ls FILE] [--hosts a,b] [--per-host 70]
"""
from __future__ import annotations

import argparse
import bisect
import glob
import json
import os
import statistics
import subprocess
import sys
import time

MIN = 60_000


def load(folder: str) -> list[dict]:
    out = []
    for path in sorted(glob.glob(os.path.join(folder, "*.json"))):
        try:
            with open(path) as f:
                doc = json.load(f)
        except (OSError, ValueError):
            continue
        turns = [t for t in doc.get("turns") or [] if t.get("startedAt")]
        if not turns:
            continue
        turns.sort(key=lambda t: t["startedAt"])
        host = doc.get("peer") or os.path.basename(path).split("_")[0]
        out.append({"host": host, "id": doc.get("sessionId") or path, "turns": turns,
                    "observedAt": doc.get("observedAt"), "open": doc.get("open")})
    return out


def notice(prompt: str) -> bool:
    return prompt.startswith("[")


def bg_finished(prompt: str) -> bool:
    return prompt.startswith("[notice from acpmux") and "Background command finished" in prompt[:120]


def cutoff(session: dict, now_ms: int) -> int:
    """--now-ms can shorten any captured interval, never extend its observation."""
    observed = session.get("observedAt")
    return min(now_ms, observed) if observed is not None else now_ms


def gaps(sessions: list[dict], now_ms: int) -> list[dict]:
    """Every gap with what the daemon knew at its start."""
    out = []
    for s in sessions:
        t = s["turns"]
        until = cutoff(s, now_ms)
        past: list[int] = []
        who: list[bool] = []
        for i, turn in enumerate(t):
            end = turn.get("endedAt")
            if not end or end > until or turn["startedAt"] > until:
                continue
            nxt = t[i + 1] if i + 1 < len(t) else None
            if nxt is None and (s.get("open") is not True or s.get("observedAt") is None):
                continue  # old/closed traces prove no trailing idle interval
            if nxt is not None and nxt["startedAt"] > until:
                nxt = None  # a future turn proves no wake/person event inside this capture
            start = nxt["startedAt"] if nxt else until
            g = start - end
            if g < 0:
                continue  # an overlapping (queued) turn: no idle time
            prompt = (nxt or {}).get("prompt") or ""
            out.append({
                "host": s["host"], "session": s["id"], "at": end, "g": g, "ends_in_turn": nxt is not None,
                "person": nxt is not None and not notice(prompt),
                "wait_pending": nxt is not None and bg_finished(prompt),
                "bg_notifying_count": turn.get("bgNotifyingCount"),
                "history": list(past[-20:]),
                "persons": list(who[-20:]),
                "to_agent_ms": (nxt or {}).get("toAgentMs"),
            })
            past.append(g)
            who.append(nxt is not None and not notice(prompt))
    return out


def residents_at(gs: list[dict], sessions: list[dict], now_ms: int) -> dict:
    """Union running and static-2min idle spans per session before counting host load."""
    by = {}
    for g in gs:
        by.setdefault((g["host"], g["session"]), []).append(
            (g["at"], g["at"] + min(g["g"], 2 * MIN)))
    for s in sessions:
        until = cutoff(s, now_ms)
        for turn in s["turns"]:
            end = turn.get("endedAt") or s.get("observedAt")
            if end:
                by.setdefault((s["host"], s["id"]), []).append(
                    (turn["startedAt"], min(end, until)))
    hosts = {}
    for (host, _), spans in by.items():
        merged = []
        for start, end in sorted(spans):
            if end <= start:
                continue
            if merged and start <= merged[-1][1]:
                merged[-1][1] = max(merged[-1][1], end)
            else:
                merged.append([start, end])
        hosts.setdefault(host, []).extend(merged)
    return {host: (sorted(a for a, _ in spans), sorted(b for _, b in spans))
            for host, spans in hosts.items()}


def adaptive_v1(g, base=2 * MIN):
    """hub/residency.rs: SHORT=15s, SPARSE=10min, LONG=30min, lower median of 20 gaps.

    Missing end-of-turn background counts are assumed zero, never inferred from future prompts.
    The report exposes missing counts so this row is not mistaken for a fully observed experiment.
    """
    if (g.get("bg_notifying_count") or 0) > 0:
        return 15_000
    history = sorted(g["history"][-20:])
    if not history:
        return base
    return 15_000 if history[(len(history) - 1) // 2] > 10 * MIN else 30 * MIN


def count_at(table, host, t) -> int:
    starts, ends = table.get(host, ([], []))
    return bisect.bisect_right(starts, t) - bisect.bisect_right(ends, t)


def score(gs, timeout, rss_gb, wake_s) -> dict:
    saved = wakes = person = 0.0
    for g in gs:
        T = timeout(g)
        held = min(g["g"], T)
        saved += g["g"] - held
        if g["g"] > T and g["ends_in_turn"]:
            wakes += 1
            person += g["person"]
    return {"ram_gbh_saved": round(saved / 3_600_000 * rss_gb, 1), "wakes": int(wakes),
            "wake_s": round(wakes * wake_s, 1), "person_wakes": int(person)}


def frontier_at(static_rows, wakes, key="wakes") -> float:
    """Static RAM saved interpolated at `wakes` (static rows sorted by `key`: all wakes or a person's)."""
    pts = sorted((r[key], r["ram_gbh_saved"]) for r in static_rows)
    if wakes <= pts[0][0]:
        return pts[0][1] * wakes / pts[0][0] if pts[0][0] else pts[0][1]
    for (w0, s0), (w1, s1) in zip(pts, pts[1:]):
        if w0 <= wakes <= w1:
            return s0 + (s1 - s0) * (wakes - w0) / (w1 - w0) if w1 != w0 else max(s0, s1)
    return pts[-1][1]


def net(r, wake_gbh) -> float:
    """RAM saved less what the wakes cost, each worth `wake_gbh` GB-hours (its start's CPU, priced as RAM)."""
    return round(r["ram_gbh_saved"] - r["wakes"] * wake_gbh, 1)


def run(folder, rss_mb, wake_ms, now_ms, cap, wake_gbh=0.0) -> dict:
    sessions = load(folder)
    gs = gaps(sessions, now_ms)
    rss_gb, wake_s = rss_mb / 1000, wake_ms / 1000
    table = residents_at(gs, sessions, now_ms)
    rows = {"never": score(gs, lambda g: float("inf"), rss_gb, wake_s)}
    statics = []
    for m in (0.05, 0.1, 0.25, 0.5, 1, 2, 3, 5, 10, 15, 30, 60, 120):
        r = score(gs, lambda g, m=m: m * MIN, rss_gb, wake_s)
        r["policy"] = f"static {m:g} min"
        statics.append(r)
    actual = score(gs, adaptive_v1, rss_gb, wake_s)
    actual.update(policy="adaptive-v1 (missing background counts assumed zero)", family="adaptive-v1")
    dyn = [actual]

    def med(h):
        return statistics.median(h) if h else None

    for H in (0.5, 1, 2, 5, 10, 20):
        for short in (0.05, 0.1, 0.25, 0.5, 1):
            for long_ in (1, 2, 5, 10, 15):
                def hist(g, H=H, short=short, long_=long_):
                    m = med(g["history"])
                    return (short if m is not None and m > H * MIN else long_) * MIN
                r = score(gs, hist, rss_gb, wake_s)
                r["policy"] = f"history H={H}m short={short:g}m long={long_}m"
                r["family"] = "history"
                dyn.append(r)
                def combo(g, H=H, short=short, long_=long_):
                    if g["wait_pending"]:
                        return short * MIN
                    m = med(g["history"])
                    T = (short if m is not None and m > H * MIN else long_) * MIN
                    n = count_at(table, g["host"], g["at"])
                    return T / max(1.0, n / cap)
                r = score(gs, combo, rss_gb, wake_s)
                r["policy"] = f"combo H={H}m short={short:g}m long={long_}m cap={cap}"
                r["family"] = "combo"
                dyn.append(r)
    # Who prompts next: a session whose recent gaps ended in a person's prompt keeps its harness `long_`, one
    # driven by notices and inbox (an agent, who does not feel the wake) hibernates after `short`.
    for frac in (0.1, 0.25, 0.5):
        for short in (0.05, 0.25, 0.5, 1, 2):
            for long_ in (2, 5, 10, 15, 30):
                def person(g, frac=frac, short=short, long_=long_):
                    p = g["persons"][-10:]
                    return (long_ if p and sum(p) / len(p) >= frac else short) * MIN
                r = score(gs, person, rss_gb, wake_s)
                r["policy"] = f"person frac>={frac} short={short:g}m long={long_}m"
                r["family"] = "person"
                dyn.append(r)
                def both(g, frac=frac, short=short, long_=long_):
                    p = g["persons"][-10:]
                    if not (p and sum(p) / len(p) >= frac):
                        return short * MIN
                    m = med(g["history"])
                    return (short if m is not None and m > 10 * MIN else long_) * MIN
                r = score(gs, both, rss_gb, wake_s)
                r["policy"] = f"person+history frac>={frac} short={short:g}m long={long_}m H=10m"
                r["family"] = "person+history"
                dyn.append(r)
    for short in (0.05, 0.1, 0.25, 0.5, 1):
        for long_ in (1, 2, 5, 10, 15):
            r = score(gs, lambda g, s=short, l=long_: (s if g["wait_pending"] else l) * MIN, rss_gb, wake_s)
            r["policy"] = f"wait short={short:g}m long={long_}m"
            r["family"] = "wait"
            dyn.append(r)
    for base in (2, 5, 10, 15):
        def press(g, base=base):
            n = count_at(table, g["host"], g["at"])
            return base * MIN / max(1.0, n / cap)
        r = score(gs, press, rss_gb, wake_s)
        r["policy"] = f"pressure base={base}m cap={cap}"
        r["family"] = "pressure"
        dyn.append(r)
    for r in dyn:
        r["static_at_same_wakes"] = round(frontier_at(statics, r["wakes"]), 1)
        r["gap_gbh"] = round(r["ram_gbh_saved"] - r["static_at_same_wakes"], 1)
        r["static_at_same_person_wakes"] = round(frontier_at(statics, r["person_wakes"], "person_wakes"), 1)
        r["person_gap_gbh"] = round(r["ram_gbh_saved"] - r["static_at_same_person_wakes"], 1)
    # Oracle: hibernate at once when the gap will be longer than the break-even (any gap that ends in no turn
    # or is long), never otherwise: the bound no causal policy passes at its wake count.
    for be in (1, 2, 5):
        r = score(gs, lambda g, be=be: 0 if g["g"] > be * MIN else float("inf"), rss_gb, wake_s)
        r["policy"] = f"oracle (knows the gap) break-even {be} min"
        r["static_at_same_wakes"] = round(frontier_at(statics, r["wakes"]), 1)
        r["gap_gbh"] = round(r["ram_gbh_saved"] - r["static_at_same_wakes"], 1)
        dyn.append(r)
        r["family"] = "oracle"
    # Wake penalty measured in the traces: the prompt's time to the agent after a gap past 2 min (a wake under
    # today's policy) against one within it (a resident harness).
    for r in statics + dyn:
        r["net_gbh"] = net(r, wake_gbh)
    woke = [g["to_agent_ms"] for g in gs if g["ends_in_turn"] and g["g"] > 2 * MIN and g["to_agent_ms"] is not None]
    warm = [g["to_agent_ms"] for g in gs if g["ends_in_turn"] and g["g"] <= 2 * MIN and g["to_agent_ms"] is not None]
    hours = sum(g["g"] for g in gs) / 3_600_000
    return {
        "sessions": len(sessions), "hosts": sorted({s["host"] for s in sessions}), "gaps": len(gs),
        "idle_session_hours": round(hours, 1), "rss_mb": rss_mb, "wake_ms": wake_ms, "wake_gbh": wake_gbh,
        "to_agent_ms_p50": {"after_wake": statistics.median(woke) if woke else None,
                            "resident": statistics.median(warm) if warm else None,
                            "n_wake": len(woke), "n_resident": len(warm)},
        "adaptive_v1_missing_background_counts": sum(g["bg_notifying_count"] is None for g in gs),
        "person_gaps": sum(1 for g in gs if g["person"]),
        "never": rows["never"], "static": statics, "dynamic": dyn,
    }


def collect(folder, ls_file, hosts, per_host) -> None:
    os.makedirs(folder, exist_ok=True)
    observed_at = int(time.time() * 1000) if not ls_file else None
    if ls_file:
        with open(ls_file) as f:
            raw = f.read()
    else:
        raw = subprocess.run(["acpmux", "ls", "--json"],
                             capture_output=True, text=True, timeout=300).stdout
    listing = json.loads(raw)
    rows = listing["sessions"]
    observed_at = listing.get("observedAt", observed_at)
    for host in hosts:
        mine = [s for s in rows if (s.get("qualifiedSessionId") or "").split("/")[0] == host and s.get("status") != "closed"]
        mine.sort(key=lambda s: -(s.get("updatedAt") or 0))
        for s in mine[:per_host]:
            q = s["qualifiedSessionId"]
            path = os.path.join(folder, q.replace("/", "_") + ".json")
            for _ in range(4):
                out = subprocess.run(["acpmux", "history", q, "--json", "-n", "400"], capture_output=True, text=True, timeout=120).stdout
                if '"turns"' in out:
                    doc = json.loads(out)
                    doc.update(observedAt=observed_at, open=s.get("status") != "closed")
                    with open(path, "w") as f:
                        json.dump(doc, f)
                    break
                time.sleep(3)  # the hub's mesh rate limit


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--rss-mb", type=float, default=320)
    ap.add_argument("--wake-ms", type=float, default=409)
    ap.add_argument("--now-ms", type=int, default=None)
    ap.add_argument("--cap", type=int, default=12, help="resident harnesses a host holds before pressure shortens timeouts")
    ap.add_argument("--wake-cpu-s", type=float, default=2.0, help="CPU seconds one wake's harness start uses")
    ap.add_argument("--cpu-s-per-gbh", type=float, default=490.0,
                    help="CPU seconds that cost as much as one GB-hour of RAM (GCE list price: $0.033/vCPU-h, $0.0045/GB-h)")
    ap.add_argument("--person-prices", type=lambda v: [float(x) for x in v.split(",")], default=[0, 0.05, 0.1, 0.25, 0.5, 1, 2],
                    help="GB-hours one person-facing wake costs (swept)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--collect", action="store_true")
    ap.add_argument("--ls")
    ap.add_argument("--hosts", default="local")
    ap.add_argument("--per-host", type=int, default=70)
    a = ap.parse_args()
    if a.collect:
        collect(a.dir, a.ls, a.hosts.split(","), a.per_host)
        return 0
    now_ms = a.now_ms or int(time.time() * 1000)
    out = run(a.dir, a.rss_mb, a.wake_ms, now_ms, a.cap, a.wake_cpu_s / a.cpu_s_per_gbh)
    if a.json:
        print(json.dumps(out, indent=1))
        return 0
    print(f"{out['sessions']} sessions on {', '.join(out['hosts'])}; {out['gaps']} gaps, {out['idle_session_hours']} idle session-hours; "
          f"{out['person_gaps']} gaps end in a person's prompt")
    print(f"to-agent p50 after a wake {out['to_agent_ms_p50']['after_wake']} ms vs resident {out['to_agent_ms_p50']['resident']} ms")
    print(f"adaptive-v1: {out['adaptive_v1_missing_background_counts']} gaps lack background counts (assumed zero)")
    print(f"never hibernate: {out['never']}")
    print(f"{'policy':48} {'GBh saved':>10} {'wakes':>7} {'wake s':>8} {'person':>7} {'net GBh':>8} {'static@=wakes':>14} {'gap':>7}")
    for r in out["static"]:
        print(f"{r['policy']:48} {r['ram_gbh_saved']:>10} {r['wakes']:>7} {r['wake_s']:>8} {r['person_wakes']:>7} {r['net_gbh']:>8}")
    best = {}
    for r in out["dynamic"]:
        if r["family"] not in best or r["net_gbh"] > best[r["family"]]["net_gbh"]:
            best[r["family"]] = r
    for r in best.values():
        print(f"{r['policy']:48} {r['ram_gbh_saved']:>10} {r['wakes']:>7} {r['wake_s']:>8} {r['person_wakes']:>7} {r['net_gbh']:>8} {r['static_at_same_wakes']:>14} {r['gap_gbh']:>7}")
    # The resume-latency penalty: a wake a person waits on (their prompt after a hibernation) priced in
    # GB-hours, swept, since what a person's half second is worth against RAM is a choice, not a measurement.
    print(f"\n{'person wake =':>14} {'static best':28} {'net':>8} {'dynamic best':58} {'net':>8} {'gap':>7} {'oracle':>8}")
    for price in a.person_prices:
        def val(r, price=price):
            return r["net_gbh"] - r["person_wakes"] * price
        sb = max(out["static"], key=val)
        db = max((r for r in out["dynamic"] if r["family"] != "oracle"), key=val)
        ob = max((r for r in out["dynamic"] if r["family"] == "oracle"), key=val)
        print(f"{price:>10} GBh {sb['policy']:28} {val(sb):>8.1f} {db['policy']:58} {val(db):>8.1f} {val(db) - val(sb):>7.1f} {val(ob):>8.1f}"
              f"   (wakes {sb['wakes']}/{db['wakes']}, person {sb['person_wakes']}/{db['person_wakes']})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
