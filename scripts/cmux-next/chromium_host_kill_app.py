"""The `--kill-app` rows of chromium-host-bench.py (task p01-process-150): the Chromium Host outlives a crash of cmux.

In a Debug build with `browserHost.helper` and `browserHost.tabs` on and the feature chromiumHostSurvivesAppCrash
(the bench sets all three with --kill-app), every Chromium tab runs in the supervisor's one host, spawned with
--survives-app-crash. The rows open the probe page in a Chromium tab, read its `performance.timeOrigin`, then:

  survives     SIGKILL to cmux: 2 s later the supervisor's host still runs and its adoption socket
               (<root cache>/chromium-host.sock, host_adoption.h) exists
  refused      during that orphan period this bench (an unsigned Python process: not this app's signed cmux)
               connects and sends an offer: the host closes the connection with no reply
  adopted      the relaunched cmux's supervisor (`debug.cef` host_supervisor) reports hosts_adopted 1 and
               hosts_started 0, with the same host pid
  time_origin  the tab of the probe's URL after the relaunch has the same `performance.timeOrigin`: the page was
               never reloaded (the relaunched cmux shows the adopted page; task 152 binds restored tabs to it)
  expires      a second SIGKILL with no relaunch: the host ends between kGraceSeconds (30 s) and 30 s + the quit
               limit (15 s) + 2 s
  mismatch     a relaunch of another wire version cannot be made from one build: not run here
               (host_adoption_test.cpp and ChromiumHostAdoptionTests check the verdict and the restart)

Pass: survives, refused, adopted, time_origin and expires. A build whose backend is not the host, or a build with no
signing team (it never adopts, by design), says not_run for the rows after `survives`.
"""

GRACE_S = 30
QUIT_LIMIT_S = 15
TIME_ORIGIN = "performance.timeOrigin"


def run(bench, url):
    """The rows; returns (row, ok). `bench` is the bench's KillAppBench (the test passes a fake):
    rpc(method), open_page(url) -> tab, page_eval(script, tab), find_tab(url) -> tab, kill_app(), relaunch(),
    pid_alive(pid), socket_exists(), offer_refused() -> bool, sleep(seconds), monotonic()."""
    backend = (bench.rpc("debug.cef") or {}).get("backend")
    if backend != "host":
        return {"not_run": f"the Chromium backend is {backend!r}, not the Chromium Host", "pass": False}, False
    row = {"backend": backend}
    tab = bench.open_page(url)
    origin = bench.page_eval(TIME_ORIGIN, tab) if tab else None
    supervisor = host_supervisor(bench)
    host = supervisor.get("pid")
    row["before"] = {"tab": tab, "time_origin": origin, "host": host}
    if not tab or origin is None or not host:
        row["error"] = "the probe page did not load in the supervisor's host"
        row["pass"] = False
        return row, False

    bench.kill_app()
    bench.sleep(2)
    row["survives"] = {"host_alive": bench.pid_alive(host), "socket": bench.socket_exists()}
    row["survives"]["pass"] = row["survives"]["host_alive"] and row["survives"]["socket"]
    row["refused"] = {"pass": bench.offer_refused()} if row["survives"]["pass"] else {"not_run": "no orphaned host"}

    bench.relaunch()
    after = host_supervisor(bench)
    row["adopted"] = {"hosts_adopted": after.get("hosts_adopted"), "hosts_started": after.get("hosts_started"),
                      "host": after.get("pid"), "adoption": after.get("adoption")}
    row["adopted"]["pass"] = (after.get("hosts_adopted") == 1 and after.get("hosts_started") == 0
                              and after.get("pid") == host)
    if row["adopted"]["pass"]:
        tab_after = bench.find_tab(url)
        origin_after = bench.page_eval(TIME_ORIGIN, tab_after) if tab_after else None
        row["time_origin"] = {"tab": tab_after, "before": origin, "after": origin_after,
                              "pass": origin_after is not None and origin_after == origin}
    else:
        row["time_origin"] = {"not_run": "the relaunched cmux did not adopt the host", "pass": False}

    expires = {"host": after.get("pid")}
    if after.get("pid"):
        bench.kill_app()
        began = bench.monotonic()
        while bench.pid_alive(after["pid"]) and bench.monotonic() - began < GRACE_S + QUIT_LIMIT_S + 5:
            bench.sleep(0.25)
        expires["ended"] = not bench.pid_alive(after["pid"])
        expires["seconds"] = round(bench.monotonic() - began, 2)
        expires["pass"] = expires["ended"] and GRACE_S - 1 <= expires["seconds"] <= GRACE_S + QUIT_LIMIT_S + 2
    else:
        expires.update({"not_run": "no host after the relaunch", "pass": False})
    row["expires"] = expires
    row["mismatch"] = {"not_run": "needs a cmux of another wire version; host_adoption_test.cpp covers the verdict"}
    row["pass"] = all(row[name].get("pass") is True for name in ("survives", "refused", "adopted", "time_origin", "expires"))
    return row, True


def host_supervisor(bench):
    """`debug.cef` host_supervisor ({} when it reports none)."""
    return (bench.rpc("debug.cef") or {}).get("host_supervisor") or {}


def offer_frame(app_pid, wire=b"bench-wire", abi=b"bench-abi", min_fork_api=30, framework=(0, 0, 0, 0)):
    """A kOpAdopt frame (host_adoption.h) naming `app_pid`; by default with a wire and ABI no host has. The host must
    close a peer it does not trust before it reads this."""
    fields = [(5, wire), (5, abi), (1, min_fork_api.to_bytes(4, "little")),
              *((2, value.to_bytes(8, "little", signed=True)) for value in framework), (1, app_pid.to_bytes(4, "little"))]
    body = b"".join(bytes([kind, 0]) + len(value).to_bytes(2, "little") + value for kind, value in fields)
    return len(body).to_bytes(4, "little") + (0x8020).to_bytes(2, "little") + b"\0\0" + b"\0\0\0\0" + body
