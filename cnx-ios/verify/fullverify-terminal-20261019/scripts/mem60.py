import fv, tq, time, json, sys, subprocess
s, m, j = tq.ctx()
part = int(sys.argv[1]); out = fv.EV + "/mem60.jsonl"
if part == 0:
    tq.paste_composer("clear; python3 cnx-ios-e2e/fvterm/fx/stream20.py 3600 20"); fv.touch("tap", what="send-mem60")
    time.sleep(1.5); j.hide_keyboard(); time.sleep(2)
pid = j.app_pid()
def ct():
    t = subprocess.run(["ps", "-o", "time=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    sec = 0
    for p in t.replace("-", ":").split(":"): sec = sec * 60 + float(p)
    return sec
t_end = time.time() + float(sys.argv[2]) if len(sys.argv) > 2 else time.time() + 480
while time.time() < t_end:
    c0, w0 = ct(), time.time()
    time.sleep(28)
    x = fv.mem(f"mem60-part{part}")
    x["cpu_avg_30s"] = round(100 * (ct() - c0) / (time.time() - w0), 1)
    fv.jl(out, x)
print(json.dumps({k: x[k] for k in ("ts", "pid", "footprint_mb", "rss_mb", "cpu_avg_30s")}), [ (y["cmd"], y["rss_mb"], y["cpu"]) for y in x["mac"]])
