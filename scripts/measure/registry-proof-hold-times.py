#!/usr/bin/env python3
"""The time of each hold of the registry lock in a run of registry-migration-proof.py.

The proof tool reads the lock statistics of a daemon one time, at the end of an arm: it gets
the count, the sum and the max of the holds of a site, and no time of a hold. So a max cannot
be checked against a stall of the host. This tool is a sidecar that gives each hold a time.

  watch <socket glob> <out.jsonl> <seconds> [period]
      Each period (0.1 s) one `server-stats` request with `locks` on the newest socket that
      the glob gives. The daemon answers it from a statistics mutex: it takes no registry
      lock. For each watched site (a source file and line, no data) a line is written when
      its counters changed, with the send time of the poll before and the reply time of this
      poll. In the same loop `pgrep -x bluetoothd`: a line at each new PID, with the time of
      the look before and of this look. A file `<out.jsonl>.stop` ends the watch.
  judge <out.jsonl> [report.json] [arm=pr|base] [nosidecar=report.json]
      For each daemon start and site: the holds, the bracket of each hold, the holds that a
      bluetoothd start disturbed, and the max of the holds that are NOT disturbed. `arm`
      says which bound is the verdict number where a max is a bound: the UPPER bound on the
      arm of the change (pr), the LOWER bound on the base arm; so a bound can only work
      against the change. `nosidecar` is the report of a run of the same arms with NO
      sidecar: its final hold_max_us of each site is printed beside the max, so that a
      reader sees if the polls moved the holds. That difference is said, not judged.
  selftest
      A stub daemon and a stub pgrep: no daemon and no host process is needed.

Limits. A poll reads counters. When 2 or more holds of a site end between 2 polls, the tool
gives a lower and an upper bound of the longest, not its value; it is exact when one hold
ended, or when the site's max rose in that poll. Each poll is an answered request, and an
answered request wakes the daemon's syncer when commits wait: do not run this sidecar in a
row that measures the WAL. The daemon lists at most 20 sites two ways; a site in neither
list is absent here, and that proves no "no hold".

Times are the wall clock of the host in UTC milliseconds. The data is generated; the output
holds site names, counts and times only.
"""

import glob
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time

SITE_WORDS = ("journal_segment_retention", "workspace_rename", "journal_maintenance")
SITE_LIST = 20  # diagnostics.rs DETAIL_SITES
# The host clock rule (FLEET.md): a start of bluetoothd stalls the host for less than 0.8 s
# after it. The start is somewhere between 2 looks, so the "disturbed" window is from the
# look BEFORE the one that saw the new PID to 0.8 s after the look that saw it.
BT_BEFORE_MS = 0
BT_AFTER_MS = 800


def now_ms():
    return int(time.time() * 1000)


def ask(path, timeout=5.0):
    """One server-stats request with the locks section: the reply's data, or None."""
    request = {"id": 7, "cmd": "server-stats", "include": ["locks"]}
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(timeout)
            conn.connect(path)
            conn.sendall(json.dumps(request).encode() + b"\n")
            data = b""
            while b"\n" not in data:
                chunk = conn.recv(1 << 20)
                if not chunk:
                    return None
                data += chunk
        reply = json.loads(data.split(b"\n", 1)[0])
    except (OSError, ValueError):
        return None
    data = reply.get("data") if isinstance(reply, dict) else None
    return data if isinstance(data, dict) else None


def watched_sites(data):
    """(site -> (acquisitions, hold_total_us, hold_max_us), sites seen) of the registry lock."""
    registry = (data.get("locks") or {}).get("registry")
    if not isinstance(registry, dict):
        return {}, None
    sites = {}
    for value in registry.values():
        if not isinstance(value, list):
            continue
        for row in value:
            if not isinstance(row, dict) or "site" not in row:
                continue
            # The source file under src/ and the line: no path of the build host.
            site = str(row["site"]).rsplit("/src/", 1)[-1]
            if any(word in site for word in SITE_WORDS):
                sites[site] = (int(row.get("acquisitions") or 0),
                               int(row.get("hold_total_us") or 0),
                               int(row.get("hold_max_us") or 0))
    seen = registry.get("sites")
    return sites, seen if isinstance(seen, int) and not isinstance(seen, bool) else None


def bluetoothd_pids():
    """The PIDs of bluetoothd by its exact name, or None when the look failed."""
    try:
        done = subprocess.run(["pgrep", "-x", "bluetoothd"], capture_output=True, timeout=5)
    except (OSError, subprocess.SubprocessError):
        return None
    return tuple(sorted(int(word) for word in done.stdout.split() if word.isdigit()))


def newest_socket(pattern):
    best, best_time = None, -1.0
    for path in glob.glob(pattern):
        try:
            changed = os.stat(path).st_mtime
        except OSError:
            continue
        if changed > best_time:
            best, best_time = path, changed
    return best


def watch(pattern, out_path, seconds, period=0.1, look=bluetoothd_pids, stop=None):
    """Poll until `seconds` passed, the stop file is there or `stop` is set."""
    stop_file = out_path + ".stop"
    end = time.monotonic() + seconds
    owner = 0
    path_before = None
    start_before = None
    counters = {}  # site -> (n, sum, max) at the last poll that listed the site
    listed_at = {}  # site -> the send time of that poll
    # The send time of the last poll that listed ALL sites (at most SITE_LIST seen): a site
    # that no poll listed yet had no hold until then. It begins at the daemon's start.
    all_listed_at = None
    pids_before = None
    look_before = now_ms()
    polls = failed = 0
    slowest_ms = 0
    next_note = time.monotonic() + 10
    with open(out_path, "a", buffering=1) as out:
        def line(row):
            out.write(json.dumps(row, separators=(",", ":")) + "\n")

        line({"watch": now_ms(), "period_s": period, "pattern_name": os.path.basename(pattern)})
        while time.monotonic() < end and not os.path.exists(stop_file):
            if stop is not None and stop.is_set():
                break
            tick = time.monotonic()
            path = newest_socket(pattern)
            if path is not None:
                sent = now_ms()
                data = ask(path)
                got = now_ms()
                polls += 1
                if data is None:
                    failed += 1
                else:
                    slowest_ms = max(slowest_ms, got - sent)
                    up = data.get("uptime_ms")
                    up = int(up) if isinstance(up, (int, float)) else 0
                    start = got - up
                    # A new daemon: another socket, or a start time that moved by more than
                    # the time of one request (the uptime is read inside the request).
                    new = (path != path_before or start_before is None
                           or abs(start - start_before) > max(1000, 2 * (got - sent)))
                    if new:
                        owner += 1
                        counters = {}
                        listed_at = {}
                        all_listed_at = start
                        line({"owner": owner, "start": start, "seen": got,
                              "dir": os.path.basename(os.path.dirname(path))})
                    path_before, start_before = path, start
                    sites, seen = watched_sites(data)
                    for site, values in sites.items():
                        before = counters.get(site, (0, 0, 0))
                        if values != before:
                            line({"o": owner, "s": site,
                                  "a": listed_at.get(site, all_listed_at), "b": got,
                                  "n": values[0], "sum": values[1], "max": values[2],
                                  "pn": before[0], "psum": before[1], "pmax": before[2],
                                  "sites": seen})
                        counters[site] = values
                        listed_at[site] = sent
                    if seen is not None and seen <= SITE_LIST:
                        all_listed_at = sent
            look_now = now_ms()
            pids = look()
            looked = now_ms()
            if pids is not None:
                if pids_before is not None and pids and pids != pids_before:
                    line({"bt": list(pids), "a": look_before, "b": looked})
                if pids:
                    pids_before = pids
                look_before = look_now
            if time.monotonic() >= next_note:
                next_note = time.monotonic() + 10
                try:
                    load = round(os.getloadavg()[0], 2)
                except OSError:
                    load = None
                line({"t": now_ms(), "load": load, "polls": polls, "failed": failed,
                      "slowest_poll_ms": slowest_ms})
            rest = period - (time.monotonic() - tick)
            if rest > 0:
                time.sleep(rest)
        line({"end": now_ms(), "polls": polls, "failed": failed, "slowest_poll_ms": slowest_ms})
    return 0


def percentile(values, share):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(share * len(ordered)))]


def judge_rows(rows):
    """The verdict numbers of a watch file, as a dict: by daemon start, then by site."""
    starts = [(row["a"] - BT_BEFORE_MS, row["b"] + BT_AFTER_MS) for row in rows if "bt" in row]
    # A file can hold 2 or more watches (it is opened to append): each watch counts its
    # daemon starts from 1, so the owners get one number through the file.
    base = top = 0
    numbered = []
    for row in rows:
        if "watch" in row:
            base = top
        elif "owner" in row:
            row = dict(row, owner=base + row["owner"])
            top = max(top, row["owner"])
        elif "s" in row:
            row = dict(row, o=base + row["o"])
            top = max(top, row["o"])
        numbered.append(row)
    rows = numbered
    owners = {}
    for row in rows:
        if "owner" in row:
            owners[row["owner"]] = {"start_ms": row["start"], "first_seen_ms": row["seen"],
                                    "sites": {}}
    loads = [row["load"] for row in rows if row.get("load") is not None]
    end = next((row for row in reversed(rows) if "end" in row), None)
    for row in rows:
        if "s" not in row:
            continue
        owner = owners.setdefault(row["o"], {"start_ms": None, "first_seen_ms": None,
                                             "sites": {}})
        site = owner["sites"].setdefault(row["s"], {"intervals": [], "sites_seen": None})
        site["sites_seen"] = row.get("sites")
        count = row["n"] - row["pn"]
        total = row["sum"] - row["psum"]
        if count <= 0 or total < 0:
            # The counters went back: not a hold of this daemon start. It is counted and
            # the row says so; it gives no number.
            site["intervals"].append({"bad": True})
            continue
        rose = row["max"] > row["pmax"]
        if count == 1:
            low = high = total
        elif rose:
            low = high = row["max"]
        else:
            low = -(-total // count)  # the longest of `count` holds is at least their mean
            high = min(row["pmax"], total)
        begin = row["a"] - total / 1000.0
        disturbed = any(first <= row["b"] and begin <= last for first, last in starts)
        site["intervals"].append({
            "count": count, "total_us": total, "low_us": low, "high_us": high,
            "exact": low == high, "width_ms": row["b"] - begin, "disturbed": disturbed,
            "last": (row["n"], row["sum"], row["max"])})
    result = {"bluetoothd_starts": len(starts), "window_ms": [BT_BEFORE_MS, BT_AFTER_MS],
              "load_1m": {"first": loads[0], "last": loads[-1], "max": max(loads)}
              if loads else None,
              "period_s": next((row.get("period_s") for row in rows if "watch" in row), None),
              "polls": end and end.get("polls"), "failed_polls": end and end.get("failed"),
              "slowest_poll_ms": end and end.get("slowest_poll_ms"), "owners": []}
    for number in sorted(owners):
        owner = owners[number]
        sites = {}
        for name, site in sorted(owner["sites"].items()):
            good = [i for i in site["intervals"] if not i.get("bad")]
            clean = [i for i in good if not i["disturbed"]]
            dirty = [i for i in good if i["disturbed"]]
            widths = [i["width_ms"] for i in good]
            holds = sum(i["count"] for i in good)
            clean_holds = sum(i["count"] for i in clean)
            last = good[-1]["last"] if good else (0, 0, 0)
            seen = site["sites_seen"]
            sites[name] = {
                "holds": holds,
                "holds_disturbed": sum(i["count"] for i in dirty),
                "holds_not_disturbed": clean_holds,
                "max_not_disturbed_us": [max((i["low_us"] for i in clean), default=None),
                                         max((i["high_us"] for i in clean), default=None)],
                "max_disturbed_us": [max((i["low_us"] for i in dirty), default=None),
                                     max((i["high_us"] for i in dirty), default=None)],
                "max_exact": all(i["exact"] for i in clean) if clean else None,
                "polls_with_one_hold": sum(1 for i in good if i["count"] == 1),
                "polls_with_more_holds": sum(1 for i in good if i["count"] > 1),
                "mean_not_disturbed_us": round(sum(i["total_us"] for i in clean) / clean_holds)
                if clean_holds else None,
                "mean_all_us": round(sum(i["total_us"] for i in good) / holds) if holds else None,
                "bracket_width_ms": {"p50": round(percentile(widths, 0.5), 1),
                                     "max": round(max(widths), 1)} if widths else None,
                "counters_went_back": sum(1 for i in site["intervals"] if i.get("bad")),
                "counters_at_the_end": {"acquisitions": last[0], "hold_total_us": last[1],
                                        "hold_max_us": last[2]},
                "site_lists_cut": seen is not None and seen > SITE_LIST,
            }
        result["owners"].append({"owner": number, "start_ms": owner["start_ms"],
                                 "first_seen_ms": owner["first_seen_ms"], "sites": sites})
    return result


def arms_of(report):
    """(arm name, site -> acquisitions) for each step of a proof report with a locks row."""
    arms = []
    for step in report.get("steps") or []:
        locks = step.get("locks") if isinstance(step, dict) else None
        rows = (locks or {}).get("retention_sites")
        if not isinstance(rows, list):
            continue
        arms.append((str(step.get("arm")), {str(row.get("site")): int(row.get("acquisitions") or 0)
                                            for row in rows if isinstance(row, dict)}))
    return arms


def match_arms(result, report):
    """Name the arm of each daemon start. The report gives the counters at the END of an arm
    and the watch saw them rise: an owner is the arm whose counts are not below the owner's
    and are the nearest. A tie, or a distance above 0, is printed and not hidden."""
    arms = arms_of(report)
    for owner in result["owners"]:
        mine = {name: site["counters_at_the_end"]["acquisitions"]
                for name, site in owner["sites"].items()}
        if not mine:
            owner["arm"] = None
            continue
        best = []
        for arm, counts in arms:
            if any(counts.get(name, 0) < count for name, count in mine.items()):
                continue
            distance = sum(counts.get(name, 0) - count for name, count in mine.items())
            best.append((distance, arm))
        best.sort()
        owner["arm"] = best[0][1] if best else None
        owner["arm_distance"] = best[0][0] if best else None
        owner["arm_tie"] = len(best) > 1 and best[0][0] == best[1][0]
    return result


def verdict(result, arm):
    """The verdict number of each site: the max of the holds NOT disturbed, with the bound
    that works against the change (upper on the arm of the change, lower on the base)."""
    result["verdict_arm"] = arm
    for owner in result["owners"]:
        for site in owner["sites"].values():
            low, high = site["max_not_disturbed_us"]
            site["verdict_max_us"] = high if arm == "pr" else low
            site["verdict_is_a_bound"] = low != high
    return result


def beside(result, report):
    """Beside each max: the final hold_max_us of the same site in the same arm of a run with
    NO sidecar (a proof report), and its count of holds."""
    quiet = {}
    for step in report.get("steps") or []:
        rows = ((step.get("locks") if isinstance(step, dict) else None) or {}).get(
            "retention_sites")
        if isinstance(rows, list):
            quiet[str(step.get("arm"))] = {str(row.get("site")): row for row in rows
                                           if isinstance(row, dict)}
    for owner in result["owners"]:
        rows = quiet.get(owner.get("arm") or "")
        for name, site in owner["sites"].items():
            row = (rows or {}).get(name)
            site["no_sidecar"] = None if row is None else {
                "hold_max_us": row.get("hold_max_us"), "acquisitions": row.get("acquisitions")}
    return result


def ms(pair):
    if pair is None or pair[0] is None:
        return "none"
    low, high = pair[0] / 1000.0, pair[1] / 1000.0
    return "%.1f" % low if pair[0] == pair[1] else "%.1f to %.1f" % (low, high)


def print_result(result):
    print("bluetoothd starts seen: %s; window: the look before the new PID (less %d ms) to "
          "%d ms after the look that saw it; poll period %s s, polls %s (failed %s, slowest "
          "%s ms); load %s; bound used: %s"
          % (result["bluetoothd_starts"], BT_BEFORE_MS, BT_AFTER_MS, result.get("period_s"),
             result["polls"], result["failed_polls"], result["slowest_poll_ms"],
             result["load_1m"],
             {"pr": "UPPER (the arm of the change)", "base": "LOWER (the base arm)"}.get(
                 result.get("verdict_arm"), "none named")))
    for owner in result["owners"]:
        if not owner["sites"]:
            continue
        start = owner["start_ms"]
        print("owner %s arm %s (distance %s%s) start %s" % (
            owner["owner"], owner.get("arm"), owner.get("arm_distance"),
            ", TIE" if owner.get("arm_tie") else "",
            time.strftime("%H:%M:%SZ", time.gmtime(start / 1000.0)) if start else None))
        for name, site in owner["sites"].items():
            print("  %s: holds %d, disturbed %d, not disturbed %d; max not disturbed %s ms%s; "
                  "max disturbed %s ms; mean not disturbed %s us; bracket p50 %s ms max %s ms; "
                  "polls with 1 hold %d, with more %d%s%s%s%s" % (
                      name, site["holds"], site["holds_disturbed"], site["holds_not_disturbed"],
                      ms(site["max_not_disturbed_us"]),
                      "" if site["max_exact"] else " (a bound)",
                      ms(site["max_disturbed_us"]), site["mean_not_disturbed_us"],
                      (site["bracket_width_ms"] or {}).get("p50"),
                      (site["bracket_width_ms"] or {}).get("max"),
                      site["polls_with_one_hold"], site["polls_with_more_holds"],
                      "; SITE LISTS CUT" if site["site_lists_cut"] else "",
                      "; COUNTERS WENT BACK %d" % site["counters_went_back"]
                      if site["counters_went_back"] else "",
                      "; VERDICT max %s ms%s" % (
                          "none" if site.get("verdict_max_us") is None
                          else "%.1f" % (site["verdict_max_us"] / 1000.0),
                          " (DEPENDS ON A BOUND)" if site.get("verdict_is_a_bound") else "")
                      if "verdict_max_us" in site else "",
                      "; with NO sidecar: max %s ms in %s holds" % (
                          "%.1f" % (int(site["no_sidecar"]["hold_max_us"] or 0) / 1000.0),
                          site["no_sidecar"]["acquisitions"])
                      if site.get("no_sidecar") else ""))


def read_rows(path):
    rows = []
    with open(path) as lines:
        for text in lines:
            text = text.strip()
            if not text:
                continue
            try:
                rows.append(json.loads(text))
            except ValueError:
                pass  # a line cut by a kill of the watch
    return rows


def judge(path, report_path=None, out_json=None, arm=None, nosidecar=None):
    result = judge_rows(read_rows(path))
    if report_path:
        with open(report_path) as handle:
            match_arms(result, json.load(handle))
    if arm:
        verdict(result, arm)
    if nosidecar:
        with open(nosidecar) as handle:
            beside(result, json.load(handle))
    print_result(result)
    if out_json:
        with open(out_json, "w") as handle:
            json.dump(result, handle, indent=1)
    return 0


class StubDaemon:
    """A socket that answers server-stats from a list of counter states, one a request."""

    def __init__(self, folder, states, hidden=None):
        self.hidden = hidden
        self.path = os.path.join(folder, "mux.sock")
        self.states = list(states)
        self.asked = 0
        self.started = time.time()
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(self.path)
        self.listener.listen(8)
        self.listener.settimeout(0.05)
        self.done = threading.Event()
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self):
        while not self.done.is_set():
            try:
                conn, _ = self.listener.accept()
            except OSError:
                continue
            with conn:
                try:
                    conn.settimeout(1)
                    conn.recv(1 << 16)
                    state = self.states[min(self.asked, len(self.states) - 1)]
                    self.asked += 1
                    rows = [{"site": "/build/crates/core/src/" + site, "acquisitions": n,
                             "hold_total_us": total, "hold_max_us": longest}
                            for site, (n, total, longest) in state.items()]
                    # With a hidden site in play the stub says 21 sites when it lists it
                    # not: the lists are cut, so an absent site proves no "no hold".
                    count = len(rows)
                    if self.hidden and self.hidden not in state and self.asked > 3:
                        count = SITE_LIST + 1
                    reply = {"ok": True, "data": {
                        "uptime_ms": int((time.time() - self.started) * 1000),
                        "locks": {"registry": {"sites": count, "by_hold_total": rows,
                                               "by_hold_p99": rows[:1]}}}}
                    conn.sendall(json.dumps(reply).encode() + b"\n")
                except OSError:
                    pass

    def close(self):
        self.done.set()
        self.thread.join(2)
        self.listener.close()


def selftest():
    failures = []

    def check(name, got, want):
        if got != want:
            failures.append("%s: got %r, want %r" % (name, got, want))

    # 1. judge on hand-made rows: an exact hold, a disturbed hold, 2 holds in one poll with a
    #    new max (exact), 2 holds in one poll with no new max (a bound), a second owner.
    site, other = "mux/journal_segment_retention.rs:271", "mux/workspace_rename.rs:172"
    rows = [
        {"owner": 1, "start": 1000, "seen": 1100},
        {"o": 1, "s": site, "a": 2000, "b": 2100, "n": 1, "sum": 30000, "max": 30000,
         "pn": 0, "psum": 0, "pmax": 0, "sites": 12},
        {"bt": [77], "a": 5000, "b": 5100},
        {"o": 1, "s": site, "a": 5200, "b": 5300, "n": 2, "sum": 930000, "max": 900000,
         "pn": 1, "psum": 30000, "pmax": 30000, "sites": 12},  # 4300 to 5300: disturbed
        {"o": 1, "s": site, "a": 8000, "b": 8100, "n": 4, "sum": 990000, "max": 900000,
         "pn": 2, "psum": 930000, "pmax": 900000, "sites": 12},  # 2 holds, 60 ms: a bound
        {"o": 1, "s": other, "a": 9000, "b": 9100, "n": 2, "sum": 50000, "max": 45000,
         "pn": 0, "psum": 0, "pmax": 0, "sites": 12},  # 2 holds, a new max: exact
        {"t": 9500, "load": 3.5, "polls": 80, "failed": 0, "slowest_poll_ms": 4},
        {"owner": 2, "start": 20000, "seen": 20100},
        {"o": 2, "s": site, "a": 20000, "b": 20100, "n": 1, "sum": 7000, "max": 7000,
         "pn": 0, "psum": 0, "pmax": 0, "sites": 25},
        {"o": 2, "s": site, "a": 20200, "b": 20300, "n": 1, "sum": 100, "max": 100,
         "pn": 1, "psum": 7000, "pmax": 7000, "sites": 25},  # the counters went back
        {"end": 21000, "polls": 90, "failed": 1, "slowest_poll_ms": 4},
    ]
    rows = [{"watch": 900}] + rows
    result = judge_rows(rows)
    first = result["owners"][0]["sites"]
    check("holds", first[site]["holds"], 4)
    check("disturbed", first[site]["holds_disturbed"], 1)
    check("not disturbed", first[site]["holds_not_disturbed"], 3)
    check("max not disturbed", first[site]["max_not_disturbed_us"], [30000, 60000])
    check("max disturbed", first[site]["max_disturbed_us"], [900000, 900000])
    check("a bound", first[site]["max_exact"], False)
    check("mean not disturbed", first[site]["mean_not_disturbed_us"], 30000)
    check("width of the first", first[site]["bracket_width_ms"]["p50"], 160.0)
    check("new max is exact", first[other]["max_not_disturbed_us"], [45000, 45000])
    check("new max exact flag", first[other]["max_exact"], True)
    check("not cut", first[site]["site_lists_cut"], False)
    second = result["owners"][1]["sites"][site]
    check("owner 2 holds", second["holds"], 1)
    check("owner 2 went back", second["counters_went_back"], 1)
    check("owner 2 cut", second["site_lists_cut"], True)
    check("starts", result["bluetoothd_starts"], 1)
    again = judge_rows(rows + rows)
    check("2 watches in one file", [owner["owner"] for owner in again["owners"]], [1, 2, 3, 4])
    check("the second watch", again["owners"][2]["sites"][site]["holds"], 4)
    # The window is from the look before the new PID (1000) to 0.8 s after the look that saw
    # it (1100 + 800). A hold that ended 1 ms before it is not disturbed; one whose bracket
    # ends at its first millisecond is; one that began at its last millisecond is; one that
    # began 1 ms after it is not.
    def one(number, a, b):
        return {"o": 1, "s": site, "a": a, "b": b, "n": number, "sum": 1000 * number,
                "max": 1000, "pn": number - 1, "psum": 1000 * (number - 1),
                "pmax": 1000 if number > 1 else 0}

    edge = [{"owner": 1, "start": 0, "seen": 1}, {"bt": [5], "a": 1000, "b": 1100},
            one(1, 900, 999), one(2, 950, 1000), one(3, 1901, 1950), one(4, 1902, 1960)]
    edge_site = judge_rows(edge)["owners"][0]["sites"][site]
    check("edge disturbed", edge_site["holds_disturbed"], 2)
    check("edge not disturbed", edge_site["holds_not_disturbed"], 2)

    # 2. the arm match by the counters of a report.
    report = {"steps": [
        {"arm": "in-place", "locks": {"retention_sites": [
            {"site": site, "acquisitions": 9}, {"site": other, "acquisitions": 9}]}},
        {"arm": "in-place-kept", "locks": {"retention_sites": [
            {"site": site, "acquisitions": 4}, {"site": other, "acquisitions": 2}]}},
        {"arm": "base-kept", "locks": {"retention_sites": [
            {"site": other, "acquisitions": 3}]}}]}
    match_arms(result, report)
    check("arm of owner 1", result["owners"][0]["arm"], "in-place-kept")
    check("distance of owner 1", result["owners"][0]["arm_distance"], 0)
    check("arm of owner 2", result["owners"][1]["arm"], "in-place-kept")
    # The bound that works against the change, and the number of a run with no sidecar.
    verdict(result, "pr")
    check("upper bound on the arm of the change", first[site]["verdict_max_us"], 60000)
    check("the verdict depends on a bound", first[site]["verdict_is_a_bound"], True)
    check("an exact max is no bound", first[other]["verdict_is_a_bound"], False)
    verdict(result, "base")
    check("lower bound on the base arm", first[site]["verdict_max_us"], 30000)
    beside(result, {"steps": [{"arm": "in-place-kept", "locks": {"retention_sites": [
        {"site": site, "acquisitions": 5, "hold_max_us": 41000}]}}]})
    check("beside", first[site]["no_sidecar"], {"hold_max_us": 41000, "acquisitions": 5})
    check("beside, a site that the other run has not", first[other]["no_sidecar"], None)
    print_result(result)

    # 3. watch against a stub daemon and a stub pgrep, then judge its file.
    folder = tempfile.mkdtemp(prefix="hold-times-selftest.")
    out_path = os.path.join(folder, "watch.jsonl")
    # The site `other` is in no list for 2 polls (the stub gives 21 sites then), and it comes
    # back with one hold more: that hold's bracket begins at the last poll that listed it.
    states = [{site: (0, 0, 0)}, {site: (0, 0, 0)}, {site: (1, 40000, 40000)},
              {site: (1, 40000, 40000), other: (1, 9, 9)}, {site: (3, 100000, 40000)},
              {site: (3, 100000, 40000), "mux/other.rs:1": (5, 5, 5)},
              {site: (3, 100000, 40000), other: (2, 20, 11)}]
    stub = StubDaemon(folder, states, hidden=other)
    looks = {"count": 0}

    def look():
        looks["count"] += 1
        return (100,) if looks["count"] < 8 else (200,)

    try:
        watch(os.path.join(folder, "mux.soc?"), out_path, 0.9, 0.05, look)
    finally:
        stub.close()
    seen = read_rows(out_path)
    check("one owner line", sum(1 for row in seen if "owner" in row), 1)
    mine = [row for row in seen if row.get("s") == site]
    back = [row for row in seen if row.get("s") == other]
    check("site lines", [(row["pn"], row["n"]) for row in mine], [(0, 1), (1, 3)])
    check("the site that came back", [(row["pn"], row["n"]) for row in back], [(0, 1), (1, 2)])
    check("only the watched sites", {row["s"] for row in seen if "s" in row}, {site, other})
    if len(back) == 2 and not (back[1]["a"] <= back[0]["b"] and back[1]["b"] - back[1]["a"] > 100):
        failures.append("the bracket of the site that came back does not begin at the last "
                        "poll that listed it: %r" % (back,))
    check("one bluetoothd line", [row["bt"] for row in seen if "bt" in row], [[200]])
    check("an end line", sum(1 for row in seen if "end" in row), 1)
    changes = mine
    if len(changes) == 2:
        if not changes[0]["a"] <= changes[0]["b"] <= changes[1]["b"]:
            failures.append("the times of the site lines are not in order")
        if changes[1]["a"] < changes[0]["a"]:
            failures.append("the send time before went back")
    watched = judge_rows(seen)["owners"][0]["sites"][site]
    check("watched holds", watched["holds"], 3)
    check("watched counters", watched["counters_at_the_end"],
          {"acquisitions": 3, "hold_total_us": 100000, "hold_max_us": 40000})
    # A stop file ends a watch at once.
    open(out_path + ".stop", "w").close()
    began = time.monotonic()
    watch(os.path.join(folder, "none.sock"), out_path, 30, 0.05, look)
    if time.monotonic() - began > 2:
        failures.append("the stop file did not end the watch")
    for name in ("watch.jsonl", "watch.jsonl.stop", "mux.sock"):
        try:
            os.unlink(os.path.join(folder, name))
        except OSError:
            pass
    os.rmdir(folder)

    for text in failures:
        print("FAIL " + text)
    print("selftest: %s" % ("FAILED %d" % len(failures) if failures else "ok"))
    return 1 if failures else 0


def main(argv):
    if len(argv) >= 2 and argv[1] == "selftest":
        return selftest()
    if len(argv) >= 5 and argv[1] == "watch":
        period = float(argv[5]) if len(argv) > 5 else 0.1
        return watch(argv[2], argv[3], float(argv[4]), period)
    if len(argv) >= 3 and argv[1] == "judge":
        named = dict(word.split("=", 1) for word in argv[3:] if "=" in word)
        plain = [word for word in argv[3:] if "=" not in word]
        if named.get("arm") not in (None, "pr", "base"):
            sys.stderr.write("arm= is pr or base\n")
            return 2
        return judge(argv[2], plain[0] if plain else None, argv[2] + ".judge.json",
                     named.get("arm"), named.get("nosidecar"))
    sys.stderr.write(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
