"""Unit tests for cmux-machine-health with a fake host (no root, no systemd, no network).

Run: python3 -m unittest test_cmux_machine_health (from this directory); web/tests/vm-image-cmux-vm-machine-health.test.ts runs it in CI.
"""
import contextlib, importlib.machinery, importlib.util, io, json, os, tempfile, unittest
from types import SimpleNamespace

HERE = os.path.dirname(os.path.abspath(__file__))
_loader = importlib.machinery.SourceFileLoader("cmh", os.path.join(HERE, "cmux-machine-health"))
cmh = importlib.util.module_from_spec(importlib.util.spec_from_loader("cmh", _loader))
_loader.exec_module(cmh)
GiB = 2**30


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
        self.heal = {}  # restarted unit -> callable
        self.step = 0.1  # seconds each command takes

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

    def users(self):
        return [SimpleNamespace(pw_name="cmux", pw_uid=1000, pw_gid=1000, pw_dir="/home/cmux"), SimpleNamespace(pw_name="root", pw_uid=0, pw_gid=0, pw_dir="/root")]

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

    def read_json(self, path):
        return json.loads(self.files[path]) if path in self.files else None

    def write(self, path, text, mode=0o644):
        self.files[path] = text

    def remove(self, path):
        self.calls.append(f"rm {path}")

    def run(self, argv, timeout):
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

    def test_dns_heals_by_restarting_resolved_relinking_and_restarting_tailscaled(self):
        host = FakeHost()
        host.resolving, host.linked, host.tailscaled = set(), False, True
        host.heal["tailscaled.service"] = lambda: host.resolving.add("github.com")
        h = run(host)
        self.assertEqual(h["problems"], [])
        self.assertEqual([f["action"] for f in h["fixed"]], ["restarted systemd-resolved", "relinked /etc/resolv.conf to the systemd-resolved stub", "restarted tailscaled so it picks systemd-resolved"])
        order = [c for c in host.calls if c.startswith("systemctl restart") or c == "relink"]
        self.assertEqual(order, ["systemctl restart systemd-resolved.service", "relink", "systemctl restart tailscaled.service"])

    def test_dns_fixes_once_per_15_minutes_and_keeps_the_problem_since(self):
        host = FakeHost()
        host.resolving = set()
        first = run(host)
        self.assertEqual(details(first), ["DNS: github.com does not resolve"])
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
        started = [c for c in host.calls if c.startswith("systemd-run")]
        self.assertEqual(len(started), 1)
        self.assertIn("--unit=cmux-machine-health-hygiene-0 -p RuntimeMaxSec=900", started[0])
        self.assertTrue(started[0].endswith("-- runuser -u cmux -- /usr/local/bin/cmux-machine-hygiene --apply --home /home/cmux --root /home/cmux"))
        self.assertEqual(h["fixed"][0]["action"], "started disk hygiene (1 of 1 commands)")
        host.free, host.t = 2 * cmh.GB, host.t + 60
        h = run(host)
        self.assertEqual(details(h), ["disk: CRITICAL: 2.0 GB free on /, under the hard floor of 3.0 GB"])
        self.assertEqual(len([c for c in host.calls if c.startswith("systemd-run")]), 1, "rate limited")

    def test_floors_scale_with_a_small_disk_and_ram_and_config_overrides_them(self):
        host = FakeHost()
        host.free, host.total, host.avail, host.memtotal = 4 * cmh.GB, 16 * cmh.GB, 300 * 2**20, 4 * GiB
        self.assertEqual(details(run(host)), ["RAM: 0.3 GB available of 4.3 GB, under the floor of 0.4 GB"])
        h = run(host, {"diskFloorBytes": 5 * cmh.GB, "hygieneCommands": [["systemctl", "start", "--no-block", "disk-hygiene-pressure.service"]], "ramFloorBytes": 1})
        self.assertEqual(details(h), ["disk: 4.0 GB free on /, under the floor of 5.0 GB"])
        self.assertTrue(any(c.endswith("-- systemctl start --no-block disk-hygiene-pressure.service") for c in host.calls))

    def test_fixed_keeps_24_hours_and_at_most_20(self):
        host = FakeHost()
        old = {"check": "dns", "action": "old", "at": cmh.iso(host.t - 90000)}
        host.files[cmh.STATE_FILE] = json.dumps({"fixed": [old] + [{"check": "dns", "action": f"a{i}", "at": cmh.iso(host.t - 60)} for i in range(25)]})
        fixed = run(host)["fixed"]
        self.assertEqual((len(fixed), fixed[0]["action"]), (20, "a5"))

    def test_a_broken_check_is_reported_and_the_others_still_run(self):
        host = FakeHost()
        host.meminfo = lambda: (_ for _ in ()).throw(KeyError("MemAvailable"))
        host.free = 1 * cmh.GB
        self.assertEqual(details(run(host)), ["disk: CRITICAL: 1.0 GB free on /, under the hard floor of 3.0 GB", "machine health: the ram check failed: KeyError"])

    def test_a_slow_machine_still_writes_its_report_within_the_budget(self):
        host = FakeHost()
        host.step, host.resolving, host.free, host.hygiene = 4, set(), 1 * cmh.GB, True
        start = host.t
        h = run(host)
        self.assertLess(host.t - start, cmh.BUDGET_S + 1)
        self.assertIn("DNS: github.com does not resolve", details(h))

    def test_the_report_holds_no_home_paths_or_credentials(self):
        self.assertEqual(cmh.clean("open /home/leo/.acpmux/x.sock failed for ws://h?token=abc; `acpmux host doctor h`"), "open ~/.acpmux/x.sock failed for ws://h?token=...")

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
        for bad in ({"hygieneCommand": []}, {"hygieneCommands": ["systemctl start x"]}, ["not", "an", "object"], {"diskFloorBytes": -1}, {"ramFloorBytes": True}, {"tailnetName": "yes"}, {"diskPath": "home"}):
            with self.assertRaises(SystemExit, msg=bad):
                cmh.check_config(bad)
        cmh.check_config({"hygieneCommands": [["systemctl", "start", "x"]], "dnsNames": ["github.com"], "diskFloorBytes": 0})

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

    def test_a_clock_that_goes_back_neither_extends_the_budget_nor_blocks_a_fix(self):
        host = FakeHost()
        host.resolving = set()
        run(host)
        host.t -= 3600  # wall clock corrected backwards
        run(host)
        self.assertEqual(sum(c == "systemctl restart systemd-resolved.service" for c in host.calls), 2)


class InstallTests(unittest.TestCase):
    def test_install_writes_the_units_and_drop_ins_and_enables_the_timer(self):
        host = FakeHost()
        with tempfile.NamedTemporaryFile("w", suffix=".json", delete=False) as f:
            json.dump({"hygieneCommands": [["systemctl", "start", "--no-block", "disk-hygiene-pressure.service"]]}, f)
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(cmh.main(["install", "--config", f.name], host=host), 0)
        os.unlink(f.name)
        for path in [*cmh.UNITS, cmh.SBIN, cmh.CONFIG_FILE]:
            self.assertIn(path, host.files)
        self.assertIn("ExecStart=/usr/local/sbin/cmux-machine-health run\nTimeoutStartSec=45", host.files["/etc/systemd/system/cmux-machine-health.service"])
        self.assertIn("MemoryHigh=70%\nMemoryMax=80%\nTasksMax=8192", host.files["/etc/systemd/system/session-.scope.d/50-cmux-guard.conf"])
        self.assertIn("OOMScoreAdjust=-900", host.files["/etc/systemd/system/user@.service.d/50-cmux-guard.conf"])
        self.assertIn("systemctl enable --now cmux-machine-health.timer", host.calls)
        self.assertEqual([c for c in host.calls if c.startswith("systemctl")], ["systemctl daemon-reload", "systemctl enable --now cmux-machine-health.timer"])

    def test_uninstall_stops_the_timer_and_removes_what_install_wrote(self):
        host = FakeHost()
        with contextlib.redirect_stdout(io.StringIO()):
            cmh.main(["uninstall"], host=host)
        self.assertEqual(host.calls[0], "systemctl disable --now cmux-machine-health.timer")
        self.assertEqual(sorted(c[3:] for c in host.calls if c.startswith("rm ")), sorted([*cmh.UNITS, cmh.SBIN]))


if __name__ == "__main__":
    unittest.main()
