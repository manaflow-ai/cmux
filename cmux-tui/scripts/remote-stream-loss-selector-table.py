"""Medians per (row, arm) of remote-stream-loss-selector-bench.sh's lines, as Markdown tables."""
import json
import statistics
import sys

rows = {}
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    r = json.loads(line)
    counters = dict(
        (k, int(v)) for k, v in (c.split("=") for c in r.get("counters", "").split(",") if "=" in c)
    )
    rows.setdefault((r["rtt_ms"], r["loss_pct"], r["arm"]), []).append((r["result"], counters))


def med(values):
    values = [v for v in values if isinstance(v, (int, float))]
    return statistics.median(values) if values else float("nan")


def pct(results, key, p):
    return med([(r.get(key) or {}).get(p) for r in results])


print("| RTT / loss | arm | on-time fps | frame p50 / p95 ms | input-to-photon p50 / p95 ms | runs | final path |")
print("|---|---|---|---|---|---|---|")
for (rtt, loss, arm), entries in rows.items():
    results = [e[0] for e in entries]
    fps = med([r.get("fps_on_time") for r in results])
    paths = ",".join(sorted({r.get("final_path") or "-" for r in results}))
    ok = sum(1 for r in results if "fps_on_time" in r)
    print(
        f"| {rtt} ms / {loss} % | {arm} | {fps:.1f} | {pct(results, 'frame_ms', 'p50'):.1f} / "
        f"{pct(results, 'frame_ms', 'p95'):.1f} | {pct(results, 'input_to_photon_ms', 'p50'):.1f} / "
        f"{pct(results, 'input_to_photon_ms', 'p95'):.1f} | {ok}/{len(results)} | {paths} |"
    )

keys = ["Ip.FragCreates", "Ip.ReasmReqds", "Ip.FragFails", "Udp.RcvbufErrors", "Udp.SndbufErrors",
        "Udp.InErrors", "Udp.InDatagrams", "Tcp.RetransSegs"]
print()
print("| RTT / loss | arm | " + " | ".join(keys) + " |")
print("|---|---|" + "---|" * len(keys))
for (rtt, loss, arm), entries in rows.items():
    cells = [str(int(med([e[1].get(k) for e in entries]))) if any(k in e[1] for e in entries) else "-" for k in keys]
    print(f"| {rtt} ms / {loss} % | {arm} | " + " | ".join(cells) + " |")
