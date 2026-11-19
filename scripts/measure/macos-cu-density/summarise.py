"""summary.md for scripts/measure/macos-cu-density.sh: python3 -I summarise.py OUT_DIR."""
import json
import os
import sys


def rows(path):
    out = []
    if os.path.exists(path):
        for line in open(path):
            line = line.strip()
            if line.startswith("{"):
                try:
                    out.append(json.loads(line))
                except ValueError:
                    pass
    return out


def p(d, key="p50", scale=1000.0, unit="ms"):
    if not isinstance(d, dict) or d.get(key) is None:
        return "-"
    return f"{d[key] * scale:.0f} {unit}" if scale != 1 else f"{d[key]}"


def jobs_table(title, rs):
    rs = [r for r in rs if r.get("stage") in ("jobs", "jobs-host")]
    if not rs:
        return []
    lines = ["", f"## {title}", ""]
    for r in rs:
        if r.get("stage") == "jobs-host":
            lines.append(f"Grants {r.get('grants')}, {r.get('ncpu')} CPU, displays online {r.get('displays_online')}.")
    lines += ["",
              "| mode | N | up | isolated | AXPress ok, p50/p99 | AX set value ok | key to pid ok | stamped click ok | raw pixel click ok | token wait p50/p99 | token hold p50/p99 | capture window p50/p99 | capture display p50/p99 | leaks click/key/field/capture | actions/s/job | host cores | footprint MB |",
              "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in rs:
        if r.get("stage") != "jobs":
            continue
        if r.get("skipped"):
            lines.append(f"| {r.get('mode')} | {r.get('n')} | skipped: {r['skipped']} |" + " |" * 14)
            continue
        ro, tk, lk = r.get("routes", {}), r.get("token", {}), r.get("leaks", {})

        def rate(route, lat=False):
            x = ro.get(route)
            if not x:
                return "-"
            t = f"{x['delivered']}/{x['n']}"
            if lat and x.get("latency_s"):
                t += f", {p(x['latency_s'])}/{p(x['latency_s'], 'p99')}"
            return t
        cw, cd = ro.get("capture-window", {}), ro.get("capture-display", {})
        leaks = (f"{lk.get('click_jobs')}/{lk.get('key_jobs')}/{lk.get('field_jobs')}/"
                 f"{(lk.get('capture_window_jobs') or 0) + (lk.get('capture_display_jobs') or 0)}")
        lines.append(
            f"| {r.get('mode')} | {r.get('n')} | {r.get('up')} | {r.get('isolated')} | {rate('ax-press', True)} | {rate('ax-setvalue')} | "
            f"{rate('cg-key')} | {rate('stamped-cg')} | {rate('hid-click')} | {p(tk.get('wait_s'))}/{p(tk.get('wait_s'), 'p99')} | "
            f"{p(tk.get('hold_s'))}/{p(tk.get('hold_s'), 'p99')} | {p(cw.get('latency_s'))}/{p(cw.get('latency_s'), 'p99')} | "
            f"{p(cd.get('latency_s'))}/{p(cd.get('latency_s'), 'p99')} | {leaks} | {round(r.get('actions_per_s_per_job') or 0, 1)} | "
            f"{round(r.get('host_cores_busy') or 0, 2)} | {r.get('footprint_total_mb')} |")
    proofs = [r for r in rs if r.get("stage") == "jobs" and r.get("capture_proof")]
    if proofs:
        lines += ["", "Cross-job proofs per row: raw and stamped clicks by tag (own / another job's app / no app), the capture check's "
                  "own-colour mean (lowest job), low-own and blank window captures, and the calibrated palette.", "",
                  "| mode | N | raw clicks own/foreign/lost | stamped own/foreign/lost | untagged mouse-downs | jobs receiving a foreign click | own-colour mean (min job) | low-own / blank window captures | blank display captures | capture proven | palette radius, closest pair, calibration missed |",
                  "|---|---|---|---|---|---|---|---|---|---|---|"]
        for r in proofs:
            ci, cp, pa = r.get("click_ids", {}), r["capture_proof"], r.get("palette", {})
            lines.append(
                f"| {r.get('mode')} | {r.get('n')} | {ci.get('hid_own')}/{ci.get('hid_foreign')}/{ci.get('hid_lost')} | "
                f"{ci.get('stamped_own')}/{ci.get('stamped_foreign')}/{ci.get('stamped_lost')} | {ci.get('untagged_mouse_downs')} | "
                f"{ci.get('jobs_receiving_foreign')} | {round(cp.get('own_mean_min') or 0, 3)} | {cp.get('low_own')} / {cp.get('blank')} | "
                f"{cp.get('display_blank')} | {cp.get('proven')} | {round(pa.get('radius') or 0, 1)}, {round(pa.get('closest_pair') or 0, 1)}, "
                f"{pa.get('calibration_missed')} |")
    bad = [r for r in rs if r.get("stage") == "jobs" and r.get("first_error")]
    for r in bad:
        lines.append(f"\n{r.get('mode')} N={r.get('n')}: first error: {r.get('first_error')}")
    return lines


def sims_table(rs):
    if not rs:
        return []
    lines = ["", "## iOS simulators beside the jobs (worker, own device set)", ""]
    for r in rs:
        if r.get("stage") == "sim-boot":
            lines.append(f"Boot: `{json.dumps(r, sort_keys=True)}`")
        if r.get("stage") == "sim-default-set":
            lines.append(f"Default device set booted devices {r.get('when')}: {r.get('booted')}")
    loops = [r for r in rs if r.get("stage") == "sim"]
    if loops:
        def pc(xs, q):
            xs = sorted(xs)
            return xs[min(len(xs) - 1, round(q * (len(xs) - 1)))] if xs else None
        shots = [r["screenshot_s"] for r in loops if r.get("screenshot_exit") == 0]
        launches = [r["launch_s"] for r in loops if r.get("launch_exit") == 0]
        lines.append(f"\nRounds {len(loops)}: screenshots ok {len(shots)}/{len(loops)}, p50 {pc(shots, .5)} s, p99 {pc(shots, .99)} s; "
                     f"launches ok {len(launches)}/{len(loops)}, p50 {pc(launches, .5)} s, p99 {pc(launches, .99)} s.")
    return lines


def main(out):
    lines = ["# macOS computer-use density", ""]
    host = {}
    if os.path.exists(os.path.join(out, "host.json")):
        try:
            host = json.load(open(os.path.join(out, "host.json")))
        except ValueError:
            pass
    if host:
        lines.append(f"Host {host.get('host')} ({host.get('model')}, {host.get('cpu')}, {host.get('ncpu')} CPU, "
                     f"{host.get('memsize_gb')} GB, macOS {host.get('macos')}), rev {host.get('rev', '')[:12]}.")
    blocked = os.path.join(out, "blocked.txt")
    if os.path.exists(blocked):
        lines.append(f"\n**Blocked:** {open(blocked).read().strip()}")
    for name in ("host-vdisplay.json",):
        r = rows(os.path.join(out, name))
        if r:
            v = r[-1]
            lines.append(f"\nVirtual displays on the worker: {v.get('created')} created ({v.get('size')}), "
                         f"stopped because: {v.get('stopped_because')}; online {v.get('online_before')} -> {v.get('online_during')}.")
    vz = rows(os.path.join(out, "vz.jsonl"))
    if vz:
        lines += ["", "## Virtualization.framework guests", "", "| step | result |", "|---|---|"]
        for r in vz:
            res = r.get("result", {k: v for k, v in r.items() if k != "step"})
            lines.append(f"| {r.get('step')} | `{json.dumps(res, sort_keys=True)[:400]}` |")
    g = rows(os.path.join(out, "guest", "results.jsonl"))
    for r in g:
        if r.get("stage") == "host":
            lines.append(f"\nGuest: macOS {r.get('macos')}, {r.get('ncpu')} CPU, {r.get('memsize_gb')} GB, grants {r.get('grants')}.")
        if r.get("stage") == "vdisplay":
            v = r["result"]
            lines.append(f"Virtual displays in the guest: {v.get('created')} created, stopped because: {v.get('stopped_because')}; "
                         f"online {v.get('online_before')} -> {v.get('online_during')} -> {v.get('online_after_release')}.")
    agents = [r for r in g if r.get("stage") == "agents"]
    if agents:
        lines += ["", "## Agents in one session", "",
                  "| N | up | footprint each p50 | capture seq p50/p99 | capture all-at-once p50/p99, fps/agent | AXPress ok, p50 | AX set value ok | CGEventPostToPid ok | stamped ok | loop resume-to-click p50/p99 | loop failed | host cores | broke |",
                  "|---|---|---|---|---|---|---|---|---|---|---|---|---|"]
        for r in agents:
            la, c, i, lo = r.get("launch", {}), r.get("capture", {}), r.get("input", {}), r.get("loop", {})

            def rate(route):
                x = i.get(route) or {}
                return f"{x.get('delivered', '-')}/{x.get('n', '-')}" + (f", {p(x.get('latency_s'))}" if x.get("latency_s") else "")
            fps = c.get("per_agent_fps_all_at_once")
            lines.append(
                f"| {r.get('n')} | {la.get('agents')} | {p(la.get('footprint_mb_each'), scale=1, unit='')} MB | "
                f"{p(c.get('sequential_s'))} / {p(c.get('sequential_s'), 'p99')} | "
                f"{p(c.get('all_at_once_s'))} / {p(c.get('all_at_once_s'), 'p99')}, {fps if fps is None else round(fps, 1)} | "
                f"{rate('ax-press')} | {rate('ax-setvalue')} | {rate('cg-pid')} | {rate('stamped-cg')} | "
                f"{p(lo.get('resume_to_acted_click_s'))} / {p(lo.get('resume_to_acted_click_s'), 'p99')} | "
                f"{lo.get('failed_cycles', '-')}/{lo.get('cycles', '-')} | {round(lo.get('host_cores_busy') or 0, 2)} | {r.get('broke', '')} |")
        a = agents[0].get("appnap", {})
        if a:
            lines.append(f"\nApp Nap (agent 0, 10 Hz timer): visible background {a.get('timer_hz_visible_background')}, hidden "
                         f"{a.get('timer_hz_hidden')}, taskpolicy -b {a.get('timer_hz_taskpolicy_b')} Hz.")
    for r in g:
        if r.get("stage") == "evict":
            lines.append(f"\nEvict: `{json.dumps({k: v for k, v in r.items() if k != 'trace'}, sort_keys=True)[:1500]}`")
    lines += jobs_table("Concurrent GUI jobs in the guest's session", g)
    lines += jobs_table("Concurrent GUI jobs in the worker's own console session", rows(os.path.join(out, "host-jobs", "results.jsonl")))
    lines += sims_table(rows(os.path.join(out, "sims.jsonl")))
    print("\n".join(lines))


if __name__ == "__main__":
    main(sys.argv[1])
