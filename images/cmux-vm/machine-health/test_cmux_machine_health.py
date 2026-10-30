"""Unit tests for cmux-machine-health with a fake host (no root, no systemd, no network).

Run: python3 -m unittest test_cmux_machine_health (from this directory); web/tests/vm-image-cmux-vm-machine-health.test.ts runs it in CI.
"""
import contextlib, fnmatch, importlib.machinery, importlib.util, io, json, os, socket, tempfile, threading, unittest
from types import SimpleNamespace

HERE = os.path.dirname(os.path.abspath(__file__))
_loader = importlib.machinery.SourceFileLoader("cmh", os.path.join(HERE, "cmux-machine-health"))
cmh = importlib.util.module_from_spec(importlib.util.spec_from_loader("cmh", _loader))
_loader.exec_module(cmh)
GiB = 2**30
HANDSHAKE = "WebSocket protocol error: Handshake not finished"


class FakeHost:
    def __init__(self):
        self.t = 1_800_000_000.0
        self.files, self.calls = {}, []
        self.resolving = {"github.com"}
        self.free, self.total = 100 * cmh.GB, 256 * cmh.GB
        self.avail, self.memtotal = 40 * GiB, 63 * GiB
        self.linked = self.stub = True
        self.tailscale = None
        self.tailscaled = False
        self.hygiene = False
        self.linger, self.failed, self.start_ok = [], {}, True
        self.peers, self.reconnect_heals = [], False
        self.heal = {}  # restarted unit -> callable
        self.step = 0.1  # seconds each command takes
        self.manager_alive = True

    def now(self):
        return self.t

    def mono(self):
        return self.t

    def sleep(self, s):
        self.t += s

    def is_root(self):
        return True

    @contextlib.contextmanager
    def lock(self):
        yield True

    def getpwnam(self, name):
        if name == "gone":
            raise KeyError(name)
        return SimpleNamespace(pw_name=name, pw_uid=1000, pw_gid=1000, pw_dir=f"/home/{name}")

    def users(self):
        return [self.getpwnam("cmux"), SimpleNamespace(pw_name="root", pw_uid=0, pw_gid=0, pw_dir="/root")]

    def which(self, name):
        return name if {"tailscale": self.tailscale is not None, cmh.HYGIENE: self.hygiene}.get(name) else None

    def disk(self, path):
        return self.free, self.total

    def meminfo(self):
        return self.avail, self.memtotal

    def stub_linked(self):
        return self.linked

    def stub_ready(self):
        return self.stub

    def relink(self):
        self.calls.append("relink")
        self.linked = True

    def linger_users(self):
        return self.linger

    def read_json(self, path):
        return json.loads(self.files[path]) if path in self.files else None

    def write(self, path, text, mode=0o644):
        self.files[path] = text

    def remove(self, path):
        self.calls.append(f"rm {path}")

    def set_oom_score(self, pid, score, unit):
        self.calls.append(f"oom {pid} {score} {unit}")
        return self.manager_alive

    def run(self, argv, timeout, user=None):
        self.t += self.step
        self.calls.append(" ".join(argv))
        if argv[0] == "getent":
            return (0, "140.82.112.3 STREAM x\n") if argv[2] in self.resolving else (2, "")
        if argv[:2] == ["tailscale", "status"]:
            return 0, json.dumps(self.tailscale)
        if argv[:2] == ["systemctl", "restart"]:
            self.heal.get(argv[2], lambda: None)()
            return 0, ""
        if argv[:2] == ["systemctl", "show"] and argv[-1] == "tailscaled.service":
            return 0, "loaded\n" if self.tailscaled else "not-found\n"
        if argv[:2] == ["systemctl", "--user"] or (argv[0] == "systemctl" and argv[1] in ("list-units", "reset-failed", "start")):
            name, verb = (argv[3][:-1], argv[4]) if argv[1] == "--user" else ("", argv[1])
            if verb == "list-units":
                patterns = argv[argv.index("--") + 1:]
                return 0, "".join(f"{u} loaded failed failed unit\n" for u in self.failed.get(name, []) if any(fnmatch.fnmatch(u, g) for g in patterns))
            if verb == "start":
                if self.start_ok:
                    self.failed[name].remove(argv[-1])
                return (0 if self.start_ok else 1), ""
            return 0, ""
        if "rpc" in argv:
            method, params = argv[-2], json.loads(argv[-1])
            if method == "_acpmux/peer_reconnect" and self.reconnect_heals:
                for p in self.peers:
                    if p["name"] == params["name"]:
                        p.update(connected=True, error=None, downSince=None)
            return 0, json.dumps({"peers": self.peers})
        return 0, ""


def run(host, config=None):
    if config is not None:
        host.files[cmh.CONFIG_FILE] = json.dumps(config)
    with contextlib.redirect_stdout(io.StringIO()):
        assert cmh.main(["run"], host=host) == 0
    return json.loads(host.files[cmh.HEALTH_FILE])


def details(health):
    return [p["detail"] for p in health["problems"]]


class HealthTests(unittest.TestCase):
    def test_a_healthy_machine_reports_no_problems_in_the_contract_shape(self):
        h = run(FakeHost())
        self.assertEqual(h["schema"], 1)
        self.assertRegex(h["checkedAt"], r"^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$")
        self.assertEqual((h["problems"], h["fixed"]), ([], []))

    def test_dns_heals_by_restarting_resolved_relinking_and_restarting_tailscaled_when_opted_in(self):
        host = FakeHost()
        host.resolving, host.linked, host.tailscaled = set(), False, True
        host.heal["tailscaled.service"] = lambda: host.resolving.add("github.com")
        config = {"restartTailscaled": True}
        for _ in range(2):
            run(host, config)
            host.t += 60
        h = run(host, config)
        self.assertEqual(h["problems"], [])
        self.assertEqual([f["action"] for f in h["fixed"]], ["restarted systemd-resolved", "relinked /etc/resolv.conf to the systemd-resolved stub", "restarted tailscaled so it picks systemd-resolved"])
        order = [c for c in host.calls if c.startswith("systemctl restart") or c == "relink"]
        self.assertEqual(order, ["systemctl restart systemd-resolved.service", "relink", "systemctl restart tailscaled.service"])

    def test_dns_never_restarts_tailscaled_by_default(self):
        host = FakeHost()
        host.resolving, host.tailscaled = set(), True
        for _ in range(40):
            h = run(host)
            host.t += 60
        self.assertFalse(any("tailscaled" in c for c in host.calls if c.startswith("systemctl restart")))
        self.assertTrue(any(c == "systemctl restart systemd-resolved.service" for c in host.calls))
        self.assertNotIn("restarted tailscaled so it picks systemd-resolved", [f["action"] for f in h["fixed"]])

    def test_dns_heals_only_after_failures_in_a_row_and_a_good_pass_resets_the_count(self):
        host = FakeHost()
        restarts = lambda: sum(c == "systemctl restart systemd-resolved.service" for c in host.calls)
        for resolving in (set(), set(), {"github.com"}, set(), set()):
            host.resolving = resolving
            run(host)
            host.t += 60
        self.assertEqual(restarts(), 0, "a good pass in between starts the count again")
        host.resolving = set()
        run(host)
        self.assertEqual(restarts(), 1)
        host.t += 60
        run(host, {"dnsFailuresBeforeHeal": 1})
        self.assertEqual(restarts(), 1, "still once per 15 min")

    def test_a_heal_that_resolves_every_name_starts_the_count_again(self):
        host = FakeHost()
        host.resolving = set()
        host.heal["systemd-resolved.service"] = lambda: host.resolving.add("github.com")
        config = {"dnsFailuresBeforeHeal": 2}
        run(host, config)
        host.t += 60
        self.assertEqual(run(host, config)["problems"], [])
        self.assertEqual(json.loads(host.files[cmh.STATE_FILE])["dnsFailures"], 0)

    def test_a_hostile_stored_failure_count_is_ignored_and_the_count_saturates(self):
        for stored in ("true", "-1", '"3"', "1.5", "9" * 4300, str(cmh.DNS_FAILURES_MAX + 1)):
            host = FakeHost()
            host.resolving = set()
            host.files[cmh.STATE_FILE] = '{"dnsFailures": %s}' % stored
            run(host)
            self.assertEqual(json.loads(host.files[cmh.STATE_FILE])["dnsFailures"], 1, stored[:20])
        host = FakeHost()
        host.resolving = set()
        host.files[cmh.STATE_FILE] = json.dumps({"dnsFailures": cmh.DNS_FAILURES_MAX})
        run(host)
        self.assertEqual(json.loads(host.files[cmh.STATE_FILE])["dnsFailures"], cmh.DNS_FAILURES_MAX)

    def test_a_dns_check_that_raises_keeps_the_count(self):
        host = FakeHost()
        host.resolving = set()
        run(host)
        host.t += 60
        real, host.run = host.run, lambda argv, timeout, **kw: (_ for _ in ()).throw(OSError("getent")) if argv[0] == "getent" else real(argv, timeout, **kw)
        self.assertIn("machine health: the dns check failed: OSError", details(run(host)))
        self.assertEqual(json.loads(host.files[cmh.STATE_FILE])["dnsFailures"], 1)

    def test_dns_fixes_once_per_15_minutes_and_keeps_the_problem_since(self):
        host = FakeHost()
        host.resolving = set()
        first = run(host)
        self.assertEqual(details(first), ["DNS: github.com does not resolve"])
        self.assertEqual(sum(c == "systemctl restart systemd-resolved.service" for c in host.calls), 0)
        for _ in range(3):
            host.t += 60
            second = run(host)
        self.assertEqual(sum(c == "systemctl restart systemd-resolved.service" for c in host.calls), 1)
        self.assertEqual(second["problems"][0]["since"], first["problems"][0]["since"])
        host.t += 15 * 60
        run(host)
        self.assertEqual(sum(c == "systemctl restart systemd-resolved.service" for c in host.calls), 2)

    def test_the_tailnet_name_is_checked_only_when_logged_in_with_magicdns(self):
        host = FakeHost()
        host.tailscale = {"BackendState": "Running", "MagicDNSSuffix": "tail1.ts.net", "CurrentTailnet": {"MagicDNSEnabled": True}, "Self": {"DNSName": "huge-blue.tail1.ts.net."}}
        self.assertEqual(details(run(host)), ["DNS: huge-blue.tail1.ts.net does not resolve"])
        host.tailscale = {"BackendState": "NeedsLogin"}
        host.t += 3600
        self.assertEqual(run(host)["problems"], [])

    def test_low_disk_starts_hygiene_as_transient_units_and_critical_under_the_hard_floor(self):
        host = FakeHost()
        host.hygiene, host.free = True, 5 * cmh.GB
        h = run(host)
        self.assertEqual(details(h), ["disk: 5.0 GB free on /, under the floor of 12.8 GB"])
        self.assertEqual(h["problems"][0]["severity"], "warning")
        started = [c for c in host.calls if c.startswith("systemd-run")]
        self.assertEqual(len(started), 1)
        self.assertIn("--unit=cmux-machine-health-hygiene-0 -p RuntimeMaxSec=900", started[0])
        self.assertTrue(started[0].endswith("-- runuser -u cmux -- /usr/local/bin/cmux-machine-hygiene --apply --home /home/cmux --root /home/cmux"))
        self.assertEqual(h["fixed"][0]["action"], "started disk hygiene (1 of 1 commands)")
        host.free, host.t = 2 * cmh.GB, host.t + 60
        h = run(host)
        self.assertEqual(details(h), ["disk: CRITICAL: 2.0 GB free on /, under the hard floor of 3.0 GB"])
        self.assertEqual(h["problems"][0]["severity"], "critical")
        self.assertEqual(len([c for c in host.calls if c.startswith("systemd-run")]), 1, "rate limited")

    def test_floors_scale_with_a_small_disk_and_ram_and_config_overrides_them(self):
        host = FakeHost()
        host.free, host.total, host.avail, host.memtotal = 4 * cmh.GB, 16 * cmh.GB, 300 * 2**20, 4 * GiB
        self.assertEqual(details(run(host)), ["RAM: 0.3 GB available of 4.3 GB, under the floor of 0.4 GB"])
        h = run(host, {"diskFloorBytes": 5 * cmh.GB, "hygieneCommands": [["systemctl", "start", "--no-block", "disk-hygiene-pressure.service"]], "ramFloorBytes": 1})
        self.assertEqual(details(h), ["disk: 4.0 GB free on /, under the floor of 5.0 GB"])
        self.assertTrue(any(c.endswith("-- systemctl start --no-block disk-hygiene-pressure.service") for c in host.calls))

    def test_a_failed_acpmux_unit_is_reset_and_started_at_most_once_per_5_minutes(self):
        host = FakeHost()
        host.linger, host.failed = ["leo"], {"leo": ["acpmux-agent-huge-blue.service"]}
        h = run(host)
        self.assertIn("systemctl --user -M leo@ reset-failed -- acpmux-agent-huge-blue.service", host.calls)
        self.assertEqual((h["problems"], h["fixed"][0]["action"]), ([], "reset and started acpmux-agent-huge-blue.service for leo"))
        host.start_ok, host.failed["leo"], host.t = False, ["acpmux-agent-huge-blue.service"], host.t + 60
        self.assertEqual(details(run(host)), ["acpmux: acpmux-agent-huge-blue.service for leo failed"])
        self.assertEqual(sum("start --" in c for c in host.calls), 1)

    def test_a_peer_down_10_minutes_gets_one_forced_reconnect_whatever_the_error(self):
        host = FakeHost()
        t0 = host.t
        down = (t0 - 18 * 3600) * 1000
        host.linger = ["leo"]
        host.peers = [
            {"name": "cosmic-gray", "connected": False, "downSince": down, "error": HANDSHAKE + "; `acpmux host doctor cosmic-gray` checks it"},
            {"name": "air-blue", "connected": False, "downSince": down, "error": "connection refused"},
            {"name": "big-red", "connected": False, "downSince": (t0 - 60) * 1000, "error": HANDSHAKE},
            {"name": "cmux16", "connected": True, "downSince": None, "error": None},
            {"name": "new-mini", "connected": False, "downSince": None, "error": None},
        ]
        h = run(host, {"acpmuxSockets": ["~/.acpmux-supervised/huge-blue/acpmux.sock"]})
        rpcs = [c for c in host.calls if " rpc " in c]
        self.assertEqual(len(rpcs), 3, "one listing, then one reconnect per peer down 10 min")
        self.assertIn(" /home/leo/.acpmux-supervised/huge-blue/acpmux.sock _acpmux/peer_reconnect ", rpcs[1])
        since = cmh.iso(down / 1000)
        recent = cmh.iso(t0 - 60)
        self.assertEqual(h["problems"], [
            {"check": "peer", "detail": f"peer link to cosmic-gray down since {since} (18h): WebSocket handshake not finished", "since": since},
            {"check": "peer", "detail": f"peer link to air-blue down since {since} (18h): connection refused", "since": since},
            {"check": "peer", "detail": f"peer link to big-red down since {recent} (60s): WebSocket handshake not finished", "since": recent},
            {"check": "peer", "detail": "peer link to new-mini has not connected", "since": h["checkedAt"]},
        ])
        self.assertEqual([f["action"] for f in h["fixed"]], ["forced a reconnect of the peer link to cosmic-gray", "forced a reconnect of the peer link to air-blue"])
        host.t += 60
        run(host)
        self.assertEqual(sum("peer_reconnect" in c for c in host.calls), 2, "once per 15 min per peer")
        host.t, host.reconnect_heals = host.t + 15 * 60, True
        # big-red is down 10 min by now too: its reconnect heals it as well.
        self.assertEqual([p["detail"].split(" ")[3] for p in run(host)["problems"]], ["new-mini"])

    def test_an_expected_peer_the_daemon_lacks_is_reported_not_added(self):
        host = FakeHost()
        host.linger = ["leo"]
        host.peers = [{"name": "cosmic-gray", "connected": True}]
        h = run(host, {"expectedPeers": ["big-red", "cosmic-gray"]})
        self.assertEqual(details(h), ["no acpmux peer for big-red: sessions there can't be reached from here"])
        self.assertFalse(any("peer_add" in c for c in host.calls))
        host.linger = []
        self.assertEqual(details(run(host)), ["acpmux: no acpmux daemon answers on this machine, so its peers cannot be checked"])
        self.assertEqual(run(host, {"expectedPeers": []})["problems"], [])

    def test_problems_come_most_important_first_and_at_most_8(self):
        host = FakeHost()
        host.resolving, host.free, host.linger, host.start_ok = set(), 1 * cmh.GB, ["leo"], False
        host.failed = {"leo": ["acpmux.service"]}
        host.peers = [{"name": f"p{i}", "connected": False, "downSince": None, "error": "x"} for i in range(9)]
        h = run(host)
        self.assertEqual([p["check"] for p in h["problems"]], ["disk", "acpmux", "dns"] + ["peer"] * 5)

    def test_failed_unit_flood_keeps_critical_disk_and_each_other_check_visible(self):
        host = FakeHost()
        host.linger, host.start_ok = ["leo"], False
        host.failed = {"leo": [f"acpmux-{i}.service" for i in range(12)]}
        host.free, host.avail = 1 * cmh.GB, 0
        host.resolving = set()
        host.peers = [{"name": "cosmic-gray", "connected": False, "downSince": None, "error": HANDSHAKE}]
        h = run(host)
        self.assertEqual(len(h["problems"]), cmh.MAX_PROBLEMS)
        self.assertEqual((h["problems"][0]["check"], h["problems"][0]["severity"]), ("disk", "critical"))
        self.assertTrue({"acpmux", "dns", "disk", "ram", "peer"}.issubset(
            {p["check"] for p in h["problems"]}))
        self.assertEqual(h["problems"][1]["check"], "acpmux", "critical stays first under truncation")
        self.assertEqual(len(host.failed["leo"]), 12, "the failed units were inspected without a successful heal")

    def test_fixed_keeps_24_hours_and_at_most_20(self):
        host = FakeHost()
        old = {"check": "disk", "action": "started disk hygiene (9 of 9 commands)", "at": cmh.iso(host.t - 90000)}
        host.files[cmh.STATE_FILE] = json.dumps({"fixed": [old] + [{"check": "disk", "action": f"started disk hygiene ({i} of 30 commands)", "at": cmh.iso(host.t - 60)} for i in range(25)]})
        fixed = run(host)["fixed"]
        self.assertEqual((len(fixed), fixed[0]["action"]), (20, "started disk hygiene (5 of 30 commands)"))

    def test_a_broken_check_is_reported_and_the_others_still_run(self):
        host = FakeHost()
        host.meminfo = lambda: (_ for _ in ()).throw(KeyError("MemAvailable"))
        host.free = 1 * cmh.GB
        self.assertEqual(details(run(host)), ["disk: CRITICAL: 1.0 GB free on /, under the hard floor of 3.0 GB", "machine health: the ram check failed: KeyError"])

    def test_a_slow_machine_still_writes_its_report_within_the_budget(self):
        host = FakeHost()
        host.step, host.resolving, host.linger, host.failed = 4, set(), ["leo"], {"leo": ["acpmux.service"]}
        start = host.t
        h = run(host)
        self.assertLess(host.t - start, cmh.BUDGET_S + 1)
        self.assertIn("DNS: github.com does not resolve", details(h))

    def test_the_report_holds_no_home_paths_or_credentials(self):
        self.assertEqual(cmh.clean("open /home/leo/.acpmux/x.sock failed for ws://h?token=abc; `acpmux host doctor h`"), "open ~/.acpmux/x.sock failed for ws://h?token=...")
        self.assertEqual(cmh.clean('401 Bearer sk-123 {"token": "abc", "key":"x"} \x1b[31mred\x1b[0m\nnext', homes={"/srv/team/leo"}), '401 Bearer ... {"token": ..., "key":...}  red  next')
        self.assertEqual(cmh.clean("cd /srv/team/leo/x failed", homes={"/srv/team/leo"}), "cd ~/x failed")

    def test_daemon_text_is_cleaned_and_a_huge_peer_list_is_bounded(self):
        host = FakeHost()
        host.linger = ["leo"]
        host.peers = [{"name": "evil\x1b[2Jname", "connected": False, "downSince": "soon", "error": "handshake refused: Bearer abc at /home/leo/.ssh/id"}]
        h = run(host)
        self.assertEqual(details(h), ["peer link to a peer with an unreadable name has not connected: WebSocket handshake not finished"])
        host.peers = [{"name": f"p{i}", "connected": False} for i in range(5000)]
        host.t += 3600
        h = run(host, {"expectedPeers": ["p4999", "absent"]})
        self.assertEqual(len(h["problems"]), cmh.MAX_PROBLEMS)
        self.assertEqual(details(h)[:2], ["acpmux lists 5000 peers; only the first 256 were checked", "no acpmux peer for absent: sessions there can't be reached from here"], "a peer past the cap is still known")
        self.assertLessEqual(sum(" rpc " in c for c in host.calls), 2 + 1 + 4, "listings, then reconnects only while the budget lasts")

    def test_credentials_are_redacted_whole_whatever_their_key_or_quoting(self):
        for raw, want in [
            ("refused: access_token=abc123 then", "refused: access_token=... then"),
            ('{"api_key": "sk live with spaces", "x": 1}', '{"api_key": ..., "x": 1}'),
            ("password='a b c' rest", "password=... rest"),
            ("X-Auth-Token: \"q r\"", "X-Auth-Token: ..."),
            ("Authorization: Bearer xyz", "Authorization: ... ..."),
            ("wss://user:pw@host/x failed", "wss://...@host/x failed"),
            ("keyboard handshake not finished", "keyboard handshake not finished"),
            ('{"token":"abc\\"SECRET", "x": 1}', '{"token":..., "x": 1}'),
            ("secret='it\\'s hidden' ok", "secret=... ok"),
        ]:
            self.assertEqual(cmh.clean(raw), want)

    def test_no_unit_patterns_means_no_unit_is_touched(self):
        host = FakeHost()
        host.linger, host.failed = ["leo"], {"leo": ["ssh-agent.service"]}
        self.assertEqual(run(host, {"acpmuxUnits": [], "cmuxUserUnits": [], "cmuxSystemUnits": []})["problems"], [])
        self.assertFalse(any(" list-units " in c for c in host.calls if c.startswith("systemctl")))

    def test_long_peer_names_reconnect_by_their_full_name_and_never_share_a_limit(self):
        host = FakeHost()
        host.linger = ["leo"]
        a, b = "h" * 70 + "-a", "h" * 70 + "-b"
        host.peers = [{"name": n, "connected": False, "downSince": (host.t - 3600) * 1000, "error": "x"} for n in (a, b)]
        run(host)
        sent = [json.loads(c.split(" _acpmux/peer_reconnect ", 1)[1])["name"] for c in host.calls if "peer_reconnect" in c]
        self.assertEqual(sent, [a, b])

    def test_a_custom_home_never_reaches_the_report_even_from_an_early_check(self):
        host = FakeHost()
        host.users = lambda: [SimpleNamespace(pw_name="leo", pw_uid=1000, pw_gid=1000, pw_dir="/srv/team/leo"), SimpleNamespace(pw_name="bin", pw_uid=2, pw_gid=2, pw_dir="/bin")]
        host.free = 1 * cmh.GB
        h = run(host, {"diskPath": "/srv/team/leo/data"})
        self.assertIn("~/data", details(h)[0])
        self.assertNotIn("/srv/team", json.dumps(h))

    def test_expected_peer_names_are_validated_and_never_stored_raw(self):
        for bad in (["/home/leo/x"], ["a" * 81], ["token=abc"], ["-x"]):
            self.assertTrue(any(p.startswith("expectedPeers must be peer names") for p in cmh.config_problems({"expectedPeers": bad})), bad)
        host = FakeHost()
        host.linger = ["leo"]
        host.peers = []
        run(host, {"expectedPeers": ["big-red"]})
        self.assertNotIn("big-red", host.files[cmh.STATE_FILE])

    def test_a_custom_home_in_an_old_fixed_entry_never_reaches_the_report(self):
        host = FakeHost()
        host.users = lambda: [SimpleNamespace(pw_name="leo", pw_uid=1000, pw_gid=1000, pw_dir="/srv/team/leo")]
        at = cmh.iso(host.t - 60)
        host.files[cmh.STATE_FILE] = json.dumps({"fixed": [{"check": "disk", "action": "cleaned /srv/team/leo/cache", "at": at}, {"check": "acpmux", "action": "reset and started acpmux.service for leo", "at": at}]})
        h = run(host)
        self.assertEqual([f["action"] for f in h["fixed"]], ["reset and started acpmux.service for leo"])
        self.assertNotIn("/srv/team", json.dumps(h))

    def test_malformed_daemon_rows_never_hide_a_down_or_missing_peer(self):
        host = FakeHost()
        host.linger = ["leo"]
        host.peers = [{"name": 123, "connected": True}, {"name": "far", "connected": False, "downSince": (host.t - 3600) * 1000, "error": "x"}]
        real = host.run
        def run_(argv, timeout, user=None):
            if "_acpmux/peer_reconnect" in argv:
                host.calls.append(" ".join(argv))
                return 0, json.dumps({"peers": [{"name": "far", "connected": "yes"}]})
            return real(argv, timeout, user)
        host.run = run_
        h = run(host, {"expectedPeers": ["123"]})
        self.assertIn("no acpmux peer for 123: sessions there can't be reached from here", details(h))
        self.assertTrue(any(d.startswith("peer link to far down since") for d in details(h)), details(h))
        def bad(argv, timeout, user=None):
            if "_acpmux/peer_reconnect" in argv:
                return 0, json.dumps({"peers": {"far": 1}})
            return real(argv, timeout, user)
        host.run, host.t = bad, host.t + 16 * 60
        self.assertTrue(any(d.startswith("peer link to far down since") for d in details(run(host))))

    def test_a_daemon_cannot_put_a_command_or_a_cli_token_in_the_report(self):
        host = FakeHost()
        host.linger = ["leo"]
        host.peers = [{"name": "x; rm -rf /", "connected": False, "error": "run --token SECRET1 now; rm -rf / && curl x"},
                      {"name": "ok-host", "connected": False, "error": "refused: cmux --api-key=SECRET2 | sh"}]
        out = json.dumps(run(host))
        for bad in ("rm -rf", "SECRET1", "SECRET2", "curl", "| sh"):
            self.assertNotIn(bad, out)
        self.assertIn("peer link to a peer with an unreadable name has not connected: an error it did not name (acpmux host doctor shows it)", out)
        self.assertIn("peer link to ok-host has not connected: connection refused", out)
        host.peers = [{"name": "a", "connected": False, "error": "rm -rf /"}, {"name": "b", "connected": False, "error": "refused\nrm -rf /"}]
        host.t += 60
        self.assertNotIn("rm -rf", json.dumps(run(host)))

    def test_redaction_stays_linear_on_hostile_text(self):
        import time
        for text in ("--" + "auth" * 500, "token=" * 400, "a" * 2000, "=:" * 1000, '"' * 2000):
            t0 = time.monotonic()
            cmh.clean(text)
            self.assertLess(time.monotonic() - t0, 0.25, text[:20])

    def test_a_reconnect_record_survives_the_next_pass_whatever_the_name(self):
        for name in ("h" * 80, "x; rm -rf /"):
            host = FakeHost()
            host.linger = ["leo"]
            host.peers = [{"name": name, "connected": False, "downSince": (host.t - 3600) * 1000, "error": "x"}]
            first = run(host)["fixed"]
            host.t += 60
            self.assertEqual(run(host)["fixed"], first, name)

    def test_a_failed_cmux_tui_unit_is_reset_and_started_system_and_user_alike(self):
        host = FakeHost()
        host.linger = ["leo"]
        host.failed = {"": ["cmux-tui-daemon.service", "ssh.service"], "leo": ["cmux-server.service", "acpmux.service"]}
        host.start_ok = False
        h = run(host)
        self.assertEqual(sorted(details(h)), sorted([
            "cmux: cmux-tui-daemon.service failed",
            "cmux: cmux-server.service for leo failed",
            "acpmux: acpmux.service for leo failed",
        ]))
        self.assertEqual([p["check"] for p in h["problems"]], ["acpmux", "cmux", "cmux"], "ordered acpmux, cmux, then the rest")
        self.assertIn("systemctl reset-failed -- cmux-tui-daemon.service", host.calls)
        self.assertNotIn("systemctl start -- ssh.service", host.calls)
        self.assertIn("reset and started cmux-tui-daemon.service", [f["action"] for f in h["fixed"]])
        host.t += 60
        run(host)
        self.assertEqual(sum(c == "systemctl start -- cmux-tui-daemon.service" for c in host.calls), 1, "once per 5 min")
        host.t, host.start_ok = host.t + 5 * 60, True
        self.assertEqual([p["check"] for p in run(host)["problems"]], [])
        for bad in (["*"], ["*.service"], ["ssh.service"], ["x.service; rm -rf /"], ["cmux-*"], ["cmux*.service"], ["cmux-" + "a" * 5000 + ".service"]):
            self.assertEqual(cmh.config_problems({"cmuxSystemUnits": bad}), ["cmuxSystemUnits must be cmux service names (a trailing * before .service at most)"], bad)
            self.assertEqual(cmh.config_problems({"cmuxUserUnits": bad}), ["cmuxUserUnits must be cmux service names (a trailing * before .service at most)"], bad)
        for bad in (["*"], ["*.service"], ["sshd.service"]):
            self.assertEqual(cmh.config_problems({"acpmuxUnits": bad}), ["acpmuxUnits must be acpmux service names (a trailing * before .service at most)"], bad)
        self.assertEqual(cmh.config_problems({"cmuxSystemUnits": ["cmux-tui*.service", "cmux-host.service"], "acpmuxUnits": ["acpmux*.service", "acpmux-agent-huge-blue.service"]}), [])
        # A listed unit outside the namespace is never touched, even if systemctl returned it.
        host = FakeHost()
        host.failed = {"": ["ssh.service"]}
        p = cmh.Pass(host, dict(cmh.DEFAULTS, cmuxSystemUnits=["cmux-tui-daemon.service"]), {})
        real = host.run
        host.run = lambda argv, timeout, user=None: (0, "ssh.service loaded failed failed x\n") if "list-units" in argv else real(argv, timeout, user)
        p.check_cmux()
        self.assertFalse(any("ssh.service" in c for c in host.calls if "reset-failed" in c or " start " in c))

    def test_reconnect_limits_are_per_daemon_socket(self):
        host = FakeHost()
        host.linger = ["leo"]
        host.peers = [{"name": "cosmic-gray", "connected": False, "downSince": (host.t - 3600) * 1000, "error": "x"}]
        run(host, {"acpmuxSockets": ["~/a.sock", "~/b.sock"]})
        self.assertEqual(sum("peer_reconnect" in c for c in host.calls), 2, "one per daemon, not one shared")

    def test_a_bad_config_falls_back_to_the_defaults_and_says_so(self):
        host = FakeHost()
        host.files[cmh.CONFIG_FILE] = "{"
        self.assertEqual(details(run(host)), ["/etc/cmux/machine-health.json is not valid JSON; the defaults apply"])
        host.t += 60
        host.files[cmh.CONFIG_FILE] = "[]"
        self.assertEqual(details(run(host)), ["/etc/cmux/machine-health.json: the config must be a JSON object; the defaults apply"])
        # A string where a list belongs is refused, not probed character by character.
        host.t += 60
        host.files[cmh.CONFIG_FILE] = json.dumps({"dnsNames": "github.com"})
        self.assertEqual(details(run(host)), ["/etc/cmux/machine-health.json: dnsNames must be a list of non-empty strings; the defaults apply"])
        self.assertFalse(any(c.startswith("getent ahosts g ") or c == "getent ahosts g" for c in host.calls))
        for bad in ({"hygieneCommand": []}, {"hygieneCommands": ["systemctl start x"]}, ["not", "an", "object"], {"diskFloorBytes": -1}, {"ramFloorBytes": True}, {"tailnetName": "yes"}, {"restartTailscaled": 1}, {"dnsFailuresBeforeHeal": 0}, {"dnsFailuresBeforeHeal": 61}, {"dnsFailuresBeforeHeal": 2.0}, {"dnsFailuresBeforeHeal": True}, {"diskPath": "home"}, {"peerDownMinutes": "10"}, {"expectedPeers": "big-red"}, {"acpmuxSockets": ["acpmux.sock"]}):
            with self.assertRaises(SystemExit, msg=bad):
                cmh.check_config(bad)
        cmh.check_config({"hygieneCommands": [["systemctl", "start", "x"]], "dnsNames": ["github.com"], "diskFloorBytes": 0, "acpmuxUnits": ["acpmux-agent-huge-blue.service"], "expectedPeers": ["big-red"], "peerDownMinutes": 10})

    def test_disk_hygiene_that_could_not_start_is_tried_again_next_pass(self):
        host = FakeHost()
        host.hygiene, host.free = True, 5 * cmh.GB
        real = host.run
        host.run = lambda argv, timeout, **kw: (1, "") if argv[0] == "systemd-run" else real(argv, timeout, **kw)
        h = run(host)
        self.assertEqual(h["fixed"], [])
        host.run, host.t = real, host.t + 60
        h = run(host)
        self.assertEqual(h["fixed"][0]["action"], "started disk hygiene (1 of 1 commands)")

    def test_disk_runs_before_a_slow_dns_heal_so_it_is_never_starved(self):
        host = FakeHost()
        host.step, host.resolving, host.hygiene, host.free = 4, set(), True, 1 * cmh.GB
        h = run(host)
        self.assertEqual(h["fixed"][0]["action"], "started disk hygiene (1 of 1 commands)")
        self.assertIn("disk: CRITICAL: 1.0 GB free on /, under the hard floor of 3.0 GB", details(h))

    def test_a_corrupt_state_file_is_ignored_and_the_report_still_written(self):
        for state in ("[]", '{"last": [], "since": 3, "fixed": {}}', '{"last": {"fix:dns": "soon"}, "fixed": [1, {"check": 2}]}',
                      '{"since": {"dns:github.com": "/home/leo/.ssh token=abc"}, "fixed": [{"check": "dns", "action": "x", "at": "/root/secret"}, {"check": "rm -rf /home/leo", "action": "y", "at": "2026-10-25T00:00:00Z"}]}'):
            host = FakeHost()
            host.resolving = set()
            host.files[cmh.STATE_FILE] = state
            h = run(host, {"dnsFailuresBeforeHeal": 1})
            self.assertEqual(details(h), ["DNS: github.com does not resolve"], state)
            self.assertEqual([f["action"] for f in h["fixed"]], ["restarted systemd-resolved"], state)
            self.assertNotIn("/home", json.dumps(h), state)
            self.assertNotIn("abc", json.dumps(h), state)

    def test_a_scalar_where_a_list_belongs_is_refused_not_crashed_on(self):
        for bad in (1, True, 1.5, "~/x.sock", None):
            self.assertIn("acpmuxSockets must be a list of non-empty strings", cmh.config_problems({"acpmuxSockets": bad}))

    def test_old_fixed_entries_are_kept_only_when_a_pass_could_have_written_them(self):
        host = FakeHost()
        at = cmh.iso(host.t - 60)
        host.files[cmh.STATE_FILE] = json.dumps({"fixed": [
            {"check": "dns", "action": "restarted systemd-resolved", "at": at},
            {"check": "disk", "action": "started disk hygiene (1 of 1 commands)", "at": at},
            {"check": "dns", "action": "curl -H 'Authorization: Bearer abc' https://x", "at": at},
            {"check": "disk", "action": "started disk hygiene (1 of 1 commands); rm -rf /", "at": at},
        ]})
        self.assertEqual([f["action"] for f in run(host)["fixed"]], ["restarted systemd-resolved", "started disk hygiene (1 of 1 commands)"])

    def test_an_unknown_config_key_is_never_echoed(self):
        problems = cmh.config_problems({"token:secret": 1, "rm -rf /": 2})
        self.assertTrue(problems[0].startswith("2 unknown config keys"), problems)
        self.assertNotIn("secret", " ".join(problems))
        self.assertNotIn("rm -rf", " ".join(problems))

    @unittest.skipUnless(os.path.isdir("/proc/self"), "Linux /proc")
    def test_the_oom_write_finds_the_unit_as_the_last_cgroup_component_too(self):
        # This process is in no user@ unit; its own last component (whatever it is) must match.
        with open("/proc/self/cgroup") as f:
            last = f.read().strip().splitlines()[-1].split(":", 2)[-1].rstrip("/").rsplit("/", 1)[-1]
        if last and open("/proc/self/comm").read().strip() != "systemd":
            self.assertFalse(cmh.Host().set_oom_score(os.getpid(), 0, last), "comm must be systemd")

    def test_the_hard_floor_is_reported_even_above_a_lower_soft_floor(self):
        host = FakeHost()
        host.free = int(1.5 * cmh.GB)
        p = cmh.Pass(host, dict(cmh.DEFAULTS, diskFloorBytes=1 * cmh.GB, diskHardFloorBytes=2 * cmh.GB), {})
        p.check_disk()
        self.assertTrue(p.problems[0]["detail"].startswith("disk: CRITICAL: 1.5 GB free"), p.problems)
        self.assertEqual(cmh.config_problems({"diskFloorBytes": 1, "diskHardFloorBytes": 2}), ["diskHardFloorBytes must not be above diskFloorBytes"])

    def test_dns_names_must_be_host_names_so_none_can_carry_a_credential(self):
        for bad in (["https://user:pw@example.com"], ["a b"], ["-x.com"], ["x" * 300]):
            with self.assertRaises(SystemExit, msg=bad):
                cmh.check_config({"dnsNames": bad})
        cmh.check_config({"dnsNames": ["github.com", "huge-blue.tail1.ts.net.", "10.0.0.1"]})

    def test_accounts_come_from_etc_passwd_without_nss(self):
        real = cmh.pwd.getpwall
        cmh.pwd.getpwall = lambda: (_ for _ in ()).throw(AssertionError("NSS lookup"))
        try:
            users = cmh.Host().users()
        finally:
            cmh.pwd.getpwall = real
        self.assertTrue(any(u.pw_uid == 0 for u in users) or users == [])

    def test_a_clock_that_goes_back_neither_extends_the_budget_nor_blocks_a_fix(self):
        host = FakeHost()
        host.resolving = set()
        run(host, {"dnsFailuresBeforeHeal": 1})
        host.t -= 3600  # wall clock corrected backwards
        run(host, {"dnsFailuresBeforeHeal": 1})
        self.assertEqual(sum(c == "systemctl restart systemd-resolved.service" for c in host.calls), 2)


class InstallTests(unittest.TestCase):
    def install(self, argv, default="200"):
        host = FakeHost()
        runs = {"systemctl list-units": "user@1000.service loaded active running User Manager for UID 1000\n", "systemctl show -p MainPID": "4242\n", "systemctl --user -M cmux@ show": default + "\n"}
        real = host.run
        host.run = lambda argv, timeout, **kw: next((host.calls.append(" ".join(argv)) or (0, v) for k, v in runs.items() if " ".join(argv).startswith(k)), None) or real(argv, timeout)
        with contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(cmh.main(argv, host=host), 0)
        return host, out.getvalue()

    def test_install_writes_the_units_and_drop_ins_and_enables_the_timer(self):
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump({"hygieneCommands": [["systemctl", "start", "--no-block", "disk-hygiene-pressure.service"]]}, f)
        host, _ = self.install(["install", "--config", f.name])
        os.unlink(f.name)
        for path in [*cmh.UNITS, cmh.SBIN, cmh.CONFIG_FILE]:
            self.assertIn(path, host.files)
        self.assertIn("ExecStart=/usr/local/sbin/cmux-machine-health run\nTimeoutStartSec=45", host.files["/etc/systemd/system/cmux-machine-health.service"])
        self.assertIn("OnActiveSec=60\nOnUnitActiveSec=60", host.files["/etc/systemd/system/cmux-machine-health.timer"])
        self.assertNotIn("OnBootSec", host.files["/etc/systemd/system/cmux-machine-health.timer"])
        self.assertIn("MemoryHigh=70%\nMemoryMax=80%\nMemorySwapMax=25%\nTasksMax=8192", host.files["/etc/systemd/system/session-.scope.d/50-cmux-guard.conf"])
        self.assertIn("MemoryMax=90%", host.files["/etc/systemd/system/user.slice.d/50-cmux-guard.conf"])
        self.assertIn("OOMScoreAdjust=-900", host.files["/etc/systemd/system/user@.service.d/50-cmux-guard.conf"])
        self.assertIn("systemctl enable --now cmux-machine-health.timer", host.calls)

    def test_a_running_user_manager_is_protected_only_once_its_services_get_200(self):
        host, out = self.install(["install"])
        self.assertIn("systemctl kill --kill-whom=main --signal=SIGRTMIN+25 user@1000.service", host.calls)
        self.assertIn("oom 4242 -900 user@1000.service", host.calls)
        host, out = self.install(["install"], default="100")
        self.assertFalse(any(c.startswith("oom ") for c in host.calls))
        self.assertIn("user@1000.service: not protected until it starts again (DefaultOOMScoreAdjust 100)", out)

    def test_a_manager_that_went_away_is_not_reported_protected(self):
        real = FakeHost.__init__
        FakeHost.__init__ = lambda self: (real(self), setattr(self, "manager_alive", False))[0]
        try:
            _, out = self.install(["install"])
        finally:
            FakeHost.__init__ = real
        self.assertIn("user@1000.service: not protected until it starts again", out)

    @unittest.skipUnless(os.path.isdir("/proc/self"), "Linux /proc")
    def test_the_oom_write_refuses_a_process_that_is_not_the_units_manager(self):
        self.assertFalse(cmh.Host().set_oom_score(os.getpid(), 0, "user@0.service"))
        self.assertFalse(cmh.Host().set_oom_score(2**22 + 1, 0, "user@0.service"))

    def test_a_check_only_pass_reports_and_starts_no_fix(self):
        host = FakeHost()
        host.resolving, host.free, host.hygiene = set(), 1 * cmh.GB, True
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(cmh.main(["run", "--check-only"], host=host), 0)
        h = json.loads(host.files[cmh.HEALTH_FILE])
        self.assertEqual([p["check"] for p in h["problems"]], ["dns", "disk"])
        self.assertEqual(h["fixed"], [])
        self.assertFalse(any(c.startswith(("systemctl restart", "systemd-run")) for c in host.calls), host.calls)

    def test_install_no_start_enables_without_starting(self):
        host, _ = self.install(["install", "--no-start"])
        self.assertIn("systemctl enable cmux-machine-health.timer", host.calls)
        self.assertNotIn("systemctl enable --now cmux-machine-health.timer", host.calls)

    def test_uninstall_stops_the_timer_and_removes_what_install_wrote(self):
        host = FakeHost()
        with contextlib.redirect_stdout(io.StringIO()):
            cmh.main(["uninstall"], host=host)
        self.assertEqual(host.calls[0], "systemctl disable --now cmux-machine-health.timer")
        self.assertEqual(sorted(c[3:] for c in host.calls if c.startswith("rm ")), sorted([*cmh.UNITS, cmh.SBIN]))


class HostRunTests(unittest.TestCase):
    def test_a_command_as_a_user_drops_every_group_and_gets_only_its_home(self):
        seen = {}
        real = cmh.subprocess.run
        cmh.subprocess.run = lambda argv, **kw: (seen.update(kw), SimpleNamespace(returncode=0, stdout="ok"))[1]
        try:
            user = SimpleNamespace(pw_name="leo", pw_uid=1000, pw_gid=1000, pw_dir="/home/leo")
            self.assertEqual(cmh.Host().run(["true"], 5, user=user), (0, "ok"))
        finally:
            cmh.subprocess.run = real
        self.assertEqual((seen["user"], seen["group"], seen["extra_groups"], seen["cwd"]), (1000, 1000, [], "/"))
        self.assertEqual(seen["env"], {"PATH": cmh.PATH, "LANG": "C.UTF-8", "HOME": "/home/leo"})
        self.assertIs(seen["stdin"], cmh.subprocess.DEVNULL)


class RpcTests(unittest.TestCase):
    def test_rpc_skips_notifications_and_prints_the_reply_and_never_needs_a_daemon(self):
        d = tempfile.mkdtemp(prefix="cmh-")
        path = os.path.join(d, "s.sock")
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(path)
        srv.listen(1)

        def serve():
            conn, _ = srv.accept()
            req = json.loads(conn.makefile().readline())
            conn.sendall(b'{"jsonrpc":"2.0","method":"note","params":{}}\n' + json.dumps({"jsonrpc": "2.0", "id": req["id"], "result": {"peers": [], "m": req["method"]}}).encode() + b"\n")
            conn.close()

        threading.Thread(target=serve, daemon=True).start()
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            self.assertEqual(cmh.rpc(path, "_acpmux/peers", "{}", 5), 0)
        self.assertEqual(json.loads(out.getvalue()), {"peers": [], "m": "_acpmux/peers"})
        srv.close()
        os.unlink(path)
        self.assertEqual(cmh.rpc(path, "_acpmux/peers", "{}", 5), 3)
        os.rmdir(d)

    def serve_once(self, reply):
        d = tempfile.mkdtemp(prefix="cmh-")
        path = os.path.join(d, "s.sock")
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(path)
        srv.listen(1)

        def serve():
            conn, _ = srv.accept()
            try:
                reply(conn)
            except OSError:
                pass
            conn.close()
            srv.close()

        threading.Thread(target=serve, daemon=True).start()
        return d, path

    def test_a_socket_that_is_not_a_daemon_or_streams_without_end_gives_up(self):
        d, path = self.serve_once(lambda conn: None)  # accepts, then closes
        with contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(cmh.rpc(path, "_acpmux/peers", "{}", 5), 1)
        self.assertEqual(out.getvalue(), "")
        os.unlink(path)
        os.rmdir(d)
        d, path = self.serve_once(lambda conn: [conn.sendall(b"x" * 65536) for _ in range(cmh.MAX_REPLY // 65536 + 8)])
        with contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(cmh.rpc(path, "_acpmux/peers", "{}", 10), 1)
        self.assertEqual(out.getvalue(), "")
        os.unlink(path)
        os.rmdir(d)


if __name__ == "__main__":
    unittest.main()
