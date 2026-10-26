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

    def set_oom_score(self, pid, score, unit):
        self.calls.append(f"oom {pid} {score} {unit}")
        return self.manager_alive

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

    def test_a_corrupt_state_file_is_ignored_and_the_report_still_written(self):
        for state in ("[]", '{"last": [], "since": 3, "fixed": {}}', '{"last": {"fix:dns": "soon"}, "fixed": [1, {"check": 2}]}',
                      '{"since": {"dns:github.com": "/home/leo/.ssh token=abc"}, "fixed": [{"check": "dns", "action": "x", "at": "/root/secret"}, {"check": "rm -rf /home/leo", "action": "y", "at": "2026-10-25T00:00:00Z"}]}'):
            host = FakeHost()
            host.resolving = set()
            host.files[cmh.STATE_FILE] = state
            h = run(host)
            self.assertEqual(details(h), ["DNS: github.com does not resolve"], state)
            self.assertEqual([f["action"] for f in h["fixed"]], ["restarted systemd-resolved"], state)
            self.assertNotIn("/home", json.dumps(h), state)
            self.assertNotIn("abc", json.dumps(h), state)

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
        run(host)
        host.t -= 3600  # wall clock corrected backwards
        run(host)
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


if __name__ == "__main__":
    unittest.main()
