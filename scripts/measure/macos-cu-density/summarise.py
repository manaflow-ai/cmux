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
    print("\n".join(lines))


if __name__ == "__main__":
    main(sys.argv[1])
