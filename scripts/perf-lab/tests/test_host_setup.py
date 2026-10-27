#!/usr/bin/env python3
"""host-setup.sh on a fake Mac (--root) and pool.json against its readers (p12-perf-process-130).

A second run prints only ok lines and calls no tool that changes state; sudoers entries exist only with
--grant-privileged and each allows one exact command line.

  python3 -m unittest scripts/perf-lab/tests/test_host_setup.py
"""
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
LAB = HERE.parent
SCRIPT = LAB / "host-setup.sh"
POOL = LAB / "pool.json"
BENCH = "benchuser"

# Tools the fake Mac provides, and which calls change its state (logged to calls.log).
TOOLS = ["/usr/bin/pmset", "/usr/bin/mdutil", "/usr/bin/defaults", "/usr/bin/tmutil", "/usr/bin/fdesetup",
         "/usr/sbin/sysadminctl", "/usr/bin/sudo", "/bin/launchctl", "/usr/bin/id", "/usr/bin/stat",
         "/usr/sbin/sysctl", "/usr/bin/dscl", "/usr/bin/git", "/opt/homebrew/bin/go", "/usr/bin/xcrun",
         "/usr/bin/codesign", "/usr/bin/shasum", "/usr/sbin/chown", "/usr/sbin/visudo", "/bin/cat"]
TIME_MACHINE_PLIST = "Library/Preferences/com.apple.TimeMachine.plist"
UPDATE_KEYS = [f"/Library/Preferences/com.apple.SoftwareUpdate/{key}" for key in (
    "AutomaticCheckEnabled", "AutomaticDownload", "AutomaticallyInstallMacOSUpdates", "CriticalUpdateInstall",
    "ConfigDataInstall", "AutomaticallyInstallAppUpdates")] + ["/Library/Preferences/com.apple.commerce/AutoUpdate"]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def fake(root, tool, args):
    """One call of a fake macOS tool. State lives in ROOT/state.json; state changes append to ROOT/calls.log."""
    root = Path(root)
    state = json.loads((root / "state.json").read_text())
    name = os.path.basename(tool)

    def changed():
        (root / "state.json").write_text(json.dumps(state))
        with open(root / "calls.log", "a") as log:
            log.write(" ".join([name, *args]) + "\n")

    if name == "pmset":
        if args == ["-g"]:
            print("".join(f" {key}\t\t{value}\n" for key, value in state["pmset"].items()), end="")
            return 0
        pairs = args[1:]
        state["pmset"].update(dict(zip(pairs[::2], pairs[1::2])))
        changed()
    elif name == "mdutil":
        if args[0] == "-s":
            print(f"{args[1]}:\n\tIndexing {'enabled' if state['indexing'] else 'and searching disabled'}.")
            return 0
        state["indexing"] = False
        changed()
    elif name == "defaults":
        scope = "host:" if args[0] == "-currentHost" else ""
        args = args[1:] if scope else args
        key = f"{scope}{args[1]}/{args[2]}"
        if args[0] == "read":
            if key not in state["prefs"]:
                return 1
            print(state["prefs"][key])
            return 0
        state["prefs"][key] = {"false": "0"}.get(args[-1], args[-1])
        changed()
    elif name == "tmutil":
        state["prefs"]["/Library/Preferences/com.apple.TimeMachine/AutoBackup"] = "0"
        changed()
    elif name == "fdesetup":
        print("FileVault is Off.")
    elif name == "sysadminctl":
        if args[:2] == ["-screenLock", "status"]:
            print(f"2026-10-26 sysadminctl[1:2] screenLock {'is off' if not state['screen_lock'] else 'delay is immediate'}",
                  file=sys.stderr)
            return 0
        if args[:2] == ["-screenLock", "off"]:
            state["screen_lock"] = False
        elif args[:2] == ["-autologin", "set"]:
            state["prefs"]["/Library/Preferences/com.apple.loginwindow/autoLoginUser"] = args[3]
            (root / "etc/kcpassword").write_text("x")
        changed()
    elif name in ("sudo", "launchctl"):
        rest = list(args)
        if name == "launchctl":
            rest = rest[2:]  # asuser UID
        while rest[0].startswith("-"):
            rest = rest[2:] if rest[0] == "-u" else rest[1:]
        os.execv(rest[0], rest)
    elif name == "id":
        print(state["uid"] if args == ["-u"] else 501)
    elif name == "cat":
        if state["tcc_denied"]:  # TCC refuses the open even to root when sshd lacks Full Disk Access
            print(f"cat: {args[0]}: Operation not permitted", file=sys.stderr)
            return 1
        sys.stdout.write(Path(args[0]).read_text())
    elif name == "stat":
        print(state["console"])
    elif name == "sysctl":
        print({"machdep.cpu.brand_string": state["chip"], "hw.memsize": state["memsize"]}[args[1]])
    elif name == "dscl":
        print(f"NFSHomeDirectory: {root / 'home' / BENCH}")
    elif name == "git":
        directory = Path(args[1])
        if "checkout" in args:
            (directory / "src").mkdir(exist_ok=True)
            (directory / "wpr_public_hash.txt").write_text("hash\n")
        changed()
    elif name == "go":
        out = Path(args[1]) / args[args.index("-o") + 1]
        out.write_text("#!/bin/sh\n")
        out.chmod(0o755)
        changed()
    elif name == "xcrun":
        out = Path(args[args.index("-o") + 1])
        out.write_text("#!/bin/sh\necho 'ready 7 8.34 main=7 size=1920x1080 visible=1920x1050'\n")
        out.chmod(0o755)
        changed()
    elif name in ("codesign", "chown", "visudo"):
        changed()
    elif name == "shasum":
        import hashlib
        print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest() + "  -")
    return 0


class FakeMac:
    def __init__(self, base):
        self.root = Path(base) / "root"
        for tool in TOOLS:
            path = self.root / tool.lstrip("/")
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"#!/bin/sh\nexec {sys.executable} -I {__file__} --fake {self.root} {tool} \"$@\"\n")
            path.chmod(0o755)
        (self.root / "etc/sudoers.d").mkdir(parents=True)
        (self.root / "home" / BENCH).mkdir(parents=True)
        (self.root / TIME_MACHINE_PLIST).parent.mkdir(parents=True)
        (self.root / TIME_MACHINE_PLIST).write_text("<plist/>\n")
        self.state = {"pmset": {"sleep": "1", "displaysleep": "10", "disksleep": "10", "standby": "1"},
                      "indexing": True, "prefs": {}, "screen_lock": True, "console": BENCH,
                      "chip": "Apple M6", "memsize": str(16 * 2**30), "uid": 0, "tcc_denied": False}
        self.save()

    def save(self):
        (self.root / "state.json").write_text(json.dumps(self.state))

    def calls(self):
        log = self.root / "calls.log"
        return log.read_text().splitlines() if log.exists() else []

    def run(self, *args, host="cmux17"):
        result = subprocess.run(["bash", str(SCRIPT), "--root", str(self.root), "--host", host, "--bench-user", BENCH,
                                 *args], capture_output=True, text=True, timeout=60)
        lines = [line for line in result.stdout.splitlines() if line]
        return result.returncode, {line.split(":", 1)[0].split(" ", 1)[1]: line.split(" ", 1)[0] for line in lines}, \
            result


ITEMS = ["pool-entry", "power", "spotlight", "time-machine", "auto-updates", "auto-login", "screen-lock", "wpr",
         "vdisplay-helper", "vdisplay", "sudoers"]


class HostSetupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.mac = FakeMac(self.tmp.name)
        self.sudoers = self.mac.root / "etc/sudoers.d/cmux-perf-lab"

    def tearDown(self):
        self.tmp.cleanup()

    def test_second_run_prints_ok_and_changes_nothing(self):
        code, items, result = self.mac.run()
        self.assertEqual(code, 0, result.stdout + result.stderr)
        self.assertEqual(list(items), ITEMS)
        for name in ("power", "spotlight", "time-machine", "auto-updates", "auto-login", "screen-lock", "wpr",
                     "vdisplay-helper"):
            self.assertEqual(items[name], "changed", name)
        self.assertEqual(items["sudoers"], "ok")
        calls = self.mac.calls()
        self.assertTrue(calls)
        code, items, result = self.mac.run()
        self.assertEqual(code, 0, result.stdout)
        self.assertEqual(set(items.values()), {"ok"}, result.stdout)
        self.assertEqual(self.mac.calls(), calls, "a second run called a tool that changes state")
        self.assertFalse(self.sudoers.exists())
        prefs = json.loads((self.mac.root / "state.json").read_text())["prefs"]
        self.assertEqual({key: prefs.get(key) for key in UPDATE_KEYS}, dict.fromkeys(UPDATE_KEYS, "0"))

    def test_check_reports_and_changes_nothing(self):
        code, items, result = self.mac.run("--check")
        self.assertEqual(code, 1)
        self.assertEqual(items["power"], "needs", result.stdout)
        self.assertEqual(items["wpr"], "needs")
        self.assertEqual(self.mac.calls(), [])

    def test_sudoers_only_with_grant_and_one_command_each(self):
        code, items, result = self.mac.run("--grant-privileged")
        self.assertEqual(code, 0, result.stdout + result.stderr)
        self.assertEqual(items["sudoers"], "changed")
        rules = [line for line in self.sudoers.read_text().splitlines() if not line.startswith("#")]
        self.assertEqual(rules, [
            f"{BENCH} ALL=(root) NOPASSWD: /usr/bin/powermetrics --samplers cpu_power\\,gpu_power\\,ane_power "
            "-i 1000 -n 600 -f plist",
            f'{BENCH} ALL=(root) NOPASSWD: /usr/sbin/purge ""'])
        self.assertEqual(self.sudoers.stat().st_mode & 0o777, 0o440)
        self.assertEqual([p.name for p in self.sudoers.parent.iterdir()], ["cmux-perf-lab"])
        code, items, _ = self.mac.run("--grant-privileged")
        self.assertEqual(items["sudoers"], "ok")
        code, items, _ = self.mac.run()
        self.assertEqual(items["sudoers"], "changed")
        self.assertFalse(self.sudoers.exists())

    def test_pool_entry_must_match_the_host(self):
        self.mac.state["memsize"] = str(32 * 2**30)
        self.mac.save()
        code, items, result = self.mac.run()
        self.assertEqual(code, 1)
        self.assertEqual(items["pool-entry"], "fail")
        self.assertIn("apple-m6/32gb", result.stdout)

    def test_vdisplay_needs_the_bench_user_at_the_console(self):
        self.mac.state["console"] = "loginwindow"
        self.mac.save()
        code, items, result = self.mac.run()
        self.assertEqual(code, 1)
        self.assertEqual(items["vdisplay"], "fail")
        self.assertIn("reboot so auto-login takes effect", result.stdout)

    def test_check_refuses_a_user_who_is_not_root(self):
        self.mac.state["uid"] = 501
        self.mac.save()
        for args in (("--check",), ()):
            with self.subTest(args):
                code, items, result = self.mac.run(*args)
                self.assertEqual(code, 2)
                self.assertEqual(items, {}, "no item line may be printed without root")
                self.assertIn("run it with sudo, --check too", result.stderr)
        self.assertEqual(self.mac.calls(), [])

    def test_a_flag_without_its_value_is_a_usage_error(self):
        for flag in ("--host", "--bench-user", "--pool", "--root"):
            with self.subTest(flag):
                result = subprocess.run(["bash", str(SCRIPT), "--root", str(self.mac.root), "--bench-user", BENCH,
                                         "--check", flag], capture_output=True, text=True, timeout=10)
                self.assertEqual(result.returncode, 2)
                self.assertIn(f"{flag} needs a value", result.stderr)

    def test_time_machine_without_full_disk_access_says_so(self):
        self.mac.state["tcc_denied"] = True
        self.mac.save()
        code, items, result = self.mac.run()
        self.assertEqual(code, 1)
        self.assertEqual(items["time-machine"], "fail")
        line = next(line for line in result.stdout.splitlines() if line.startswith("fail time-machine:"))
        self.assertIn("Operation not permitted", line)
        self.assertIn("Full Disk Access", line)
        self.assertNotIn("backs up automatically", line)
        self.assertFalse([call for call in self.mac.calls() if call.startswith("tmutil")], "tmutil ran without access")
        self.assertEqual(items["power"], "changed", "the other items still run")
        self.mac.state = json.loads((self.mac.root / "state.json").read_text())
        self.mac.state["tcc_denied"] = False  # the operator gave sshd Full Disk Access
        self.mac.save()
        code, items, result = self.mac.run()
        self.assertEqual(code, 0, result.stdout)
        self.assertEqual(items["time-machine"], "changed")

    def test_unknown_host_is_a_usage_error(self):
        code, _, result = self.mac.run(host="cmux99")
        self.assertEqual(code, 2)
        self.assertIn("not a lab host", result.stderr)


class PoolTests(unittest.TestCase):
    def setUp(self):
        self.pool = json.loads(POOL.read_text())

    def test_six_hosts_the_scheduler_and_admission_read(self):
        scheduler = load("scheduler_for_pool", LAB / "scheduler.py")
        admission = load("try_admission_for_pool", LAB / "try_admission.py")
        hosts = scheduler.hosts_from_document(self.pool)
        self.assertEqual(len(hosts), 6)
        self.assertEqual(len(admission.lab_hosts(POOL)), 6)
        m6 = [h for h in hosts if h.lab_class == "m6"]
        self.assertEqual(sorted(h.role for h in m6), ["pinpoint", "pinpoint", "waterfall", "waterfall"])
        self.assertEqual(len({h.host_class for h in m6}), 1, "pinpoint M6 hosts share the waterfall host class")
        builders = {b["name"] for b in self.pool["builders"]}
        self.assertFalse(builders & {h.name for h in hosts}, "a builder is never a lab host")

    def test_waterfall_classes_of_one_host_class_own_no_common_story(self):
        """store.series_key has no host name, so one story on two classes of one host class is one series."""
        shard_map = json.loads((LAB / "shard_map.json").read_text())["classes"]
        owners = {}
        for host in self.pool["hosts"]:
            if host["role"] != "waterfall":
                continue
            for tier, stories in shard_map[host["class"]]["shards"][host["shard"]]["stories"].items():
                for story in stories:
                    owners.setdefault((host["host_class"], tier, story), set()).add(host["class"])
        shared = {key: sorted(classes) for key, classes in owners.items() if len(classes) > 1}
        self.assertEqual(shared, {})

    def test_every_shard_has_one_waterfall_owner(self):
        shard_map = json.loads((LAB / "shard_map.json").read_text())["classes"]
        owners = sorted((h["class"], h["shard"]) for h in self.pool["hosts"] if h["role"] == "waterfall")
        expected = sorted((name, shard["index"]) for name, spec in shard_map.items() for shard in spec["shards"])
        self.assertEqual(owners, expected)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--fake":
        sys.exit(fake(sys.argv[2], sys.argv[3], sys.argv[4:]))
    unittest.main()
