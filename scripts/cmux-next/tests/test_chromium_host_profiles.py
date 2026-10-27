#!/usr/bin/env python3
"""chromium_host_profiles.py, the --modes profiles row of chromium-host-bench.py (p01-process-080), against a fake
app: two profiles' tabs in one Chromium Host pass; a second host for the second profile, a tab that never loads, or
one storage shared by both profiles fails the row; a build without the host backend does not run. Runs anywhere (no
app).
Run: python3 -I scripts/cmux-next/tests/test_chromium_host_profiles.py"""
import os, sys, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, ".."))
import chromium_host_profiles as profiles  # noqa: E402


class FakeApp:
    """Profiles, tabs and hosts. `host_per_profile`: each profile's first tab starts a host of its own;
    `never_loads`: tabs never finish loading; `shared_storage`: every tab sees one localStorage."""

    def __init__(self, backend="host", host_per_profile=False, never_loads=False, shared_storage=False):
        self.backend, self.host_per_profile = backend, host_per_profile
        self.never_loads, self.shared_storage = never_loads, shared_storage
        self.profiles, self.tabs, self.hosts, self.storage = {}, {}, [], {}

    def rpc(self, method, params=None, timeout=None):
        return {"backend": self.backend} if method == "debug.cef" else None

    def cli(self, *args):
        if args[:3] == ("browser", "profile", "create"):
            profile = f"p{len(self.profiles) + 1}"
            self.profiles[args[4]] = profile
            return 0, {"browser_profile": {"id": profile, "name": args[4]}}
        if args[:3] == ("browser", "profile", "open"):
            profile = self.profiles[args[5]]
            if not self.hosts or self.host_per_profile:
                self.hosts.append(4000 + len(self.hosts))
            tab = f"t{len(self.tabs) + 1}"
            self.tabs[tab] = profile
            return 0, {"tab": {"tab_id": tab}}
        return 1, {"error": "unknown"}

    def page_eval(self, script, tab):
        store = self.storage.setdefault("shared" if self.shared_storage else self.tabs[tab], {})
        if script == "document.readyState === 'complete'":
            return not self.never_loads
        if "setItem" in script:
            store[profiles.ORIGIN_KEY] = "a"
            return True
        if "getItem" in script:
            return profiles.ORIGIN_KEY not in store
        return None


def wait(check, seconds, step=0.1):
    return check()


def run(app):
    return profiles.run(app.rpc, wait, app.page_eval, "file:///probe.html", app.cli, lambda: list(app.hosts), "r1")


class ProfilesRowTests(unittest.TestCase):
    def test_two_profiles_in_one_host_pass(self):
        row, ok = run(FakeApp())
        self.assertTrue(ok)
        self.assertTrue(row["pass"], row)
        self.assertEqual([entry["profile"] for entry in row["tabs"]], ["p1", "p2"])
        self.assertEqual(row["tabs"][1]["host_pids"], [4000])

    def test_a_host_per_profile_fails(self):
        row, ok = run(FakeApp(host_per_profile=True))
        self.assertTrue(ok)
        self.assertFalse(row["one_host"])
        self.assertFalse(row["pass"])

    def test_a_tab_that_never_loads_fails(self):
        row, ok = run(FakeApp(never_loads=True))
        self.assertTrue(ok)
        self.assertFalse(row["loaded"])
        self.assertFalse(row["pass"])

    def test_one_storage_for_both_profiles_fails(self):
        row, ok = run(FakeApp(shared_storage=True))
        self.assertTrue(ok)
        self.assertFalse(row["isolated"])
        self.assertFalse(row["pass"])

    def test_without_the_host_backend_the_row_does_not_run(self):
        row, ok = run(FakeApp(backend="inProcess"))
        self.assertFalse(ok)
        self.assertIn("not_run", row)


if __name__ == "__main__":
    unittest.main()
