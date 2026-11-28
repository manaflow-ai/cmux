#!/usr/bin/env python3
"""The test cases for process_gone (the helper) and process_gone_lint (the lint), shared by every repo that carries
them: each repo's own test imports these classes, so a fix and its fixture land everywhere together.

    TheScannerFindsTheForms   every form of a signal-0 probe the lint must find, and what it must pass
    TheHelpers                died(), running(), probe() and group_died() against real processes, and
                              process_identity's answers through them

Source of truth: leo-workspace tools/process_gone_cases.py. cmuxterm-hq and cmux carry byte copies in tests/, pinned
in tests/process_gone.pin. It holds raw probes on purpose: each repo's lint skips it.
"""
import builtins
import importlib.util
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock


def _sibling(name):
    """The module NAME.py beside this file, loaded by path (tests run under `python3 -I`: no script folder on
    sys.path), once per process."""
    if name not in sys.modules:
        spec = importlib.util.spec_from_file_location(name, Path(__file__).resolve().parent / ("%s.py" % name))
        module = importlib.util.module_from_spec(spec)
        sys.modules[name] = module
        spec.loader.exec_module(module)
    return sys.modules[name]


process_gone = _sibling("process_gone")
died, running, group_died = process_gone.died, process_gone.running, process_gone.group_died
find_source = _sibling("process_gone_lint").find_source


class TheScannerFindsTheForms(unittest.TestCase):
    def hits(self, src):
        return [f for f, *_ in find_source(src)]

    def test_every_signal_zero_probe_is_found(self):
        src = ("import os, time\nclass T:\n"
               "    def test_a(self):\n        with self.assertRaises(ProcessLookupError):\n            os.kill(p, 0)\n"
               "    def test_b(self):\n        time.sleep(0.5)\n"
               "        with self.assertRaises(ProcessLookupError, msg='x'):\n            os.killpg(g, 0)\n"
               "    def test_c(self):\n        self.assertRaises(ProcessLookupError, os.kill, p, 0)\n"
               "    def test_d(self):\n        os.kill(p, 0)  # 'it still runs'\n"
               "def alive(p):\n    try:\n        os.kill(p, 0)\n    except OSError:\n        return False\n"
               "    return True\n")
        self.assertEqual(self.hits(src), ["test_a", "test_b", "test_c", "test_d", "alive"])

    def test_a_probe_inside_a_loop_is_found_too(self):
        # review of #4363 (F1): a loop with one pass, or none that sleeps, still checks once
        src = ("import os, time\nclass T:\n"
               "    def test_a(self):\n        with self.assertRaises(ProcessLookupError):\n"
               "            for _ in range(1):\n                os.kill(p, 0)\n"
               "    def test_b(self):\n        for _ in range(50):\n            try:\n                os.kill(p, 0)\n"
               "            except ProcessLookupError:\n                break\n            time.sleep(0.1)\n")
        self.assertEqual(self.hits(src), ["test_a", "test_b"])

    def test_every_way_to_reach_os_kill_is_resolved(self):
        # review of #41326 (F2): an import, an alias, a keyword or getattr hid a probe from the scanner
        src = ("import os, signal\nfrom os import kill\nfrom os import killpg as kpg\nimport os as o\n"
               "k = os.kill\nj = k\n"
               "def test_a():\n    kill(p, 0)\n"
               "def test_b():\n    os.kill(p, sig=0)\n"
               "def test_c():\n    k(p, 0)\n"
               "def test_d():\n    j(p, 0)\n"
               "def test_e():\n    kpg(g, 0)\n"
               "def test_f():\n    o.kill(p, 0)\n"
               "def test_g():\n    getattr(os, 'kill')(p, 0)\n")
        self.assertEqual(self.hits(src), ["test_a", "test_b", "test_c", "test_d", "test_e", "test_f", "test_g"])

    def test_a_signal_the_source_does_not_show_is_flagged_unresolved(self):
        # review of #41326 (F2) and #4379: a splat, a name or a reference that escapes is never skipped
        src = ("import os, signal\nfrom os import kill\n"
               "def test_a():\n    os.kill(*(p, 0))\n"
               "def test_b(args):\n    os.kill(*args)\n"
               "def test_c(sig):\n    os.kill(p, sig)\n"
               "def test_d(kw):\n    os.kill(p, **kw)\n"
               "def test_e():\n    return kill\n"
               "def test_f():\n    os.kill(p, signal.SIGTERM)\n    kill(p, 9)\n    os.killpg(g, signal.SIGKILL)\n"
               "    self.addCleanup(os.kill, p, signal.SIGKILL)\n    threading.Timer(1, os.kill, (p, signal.SIGINT))\n"
               "    os.kill(p, signal.Signals.SIGTERM)\n"
               "def test_g():\n    threading.Timer(1, os.kill, (p, 0))\n")
        self.assertEqual(self.hits(src), ["test_a", "test_b", "test_c", "test_d", "test_e", "test_g"])
        self.assertEqual([k for *_, k in find_source(src)], ["unresolved"] * 5 + ["signal 0"])

    def test_an_alias_in_one_function_does_not_hide_another_functions_probe(self):
        # review of #4398 (F1): one dict for every scope let `import signal as os` in test_a rebind os for test_b
        src = ("import os, signal\nfrom os import kill\n"
               "def test_a():\n    import signal as os\n    os.kill(p, os.SIGTERM)\n"
               "def test_b():\n    os.kill(p, 0)\n"
               "def test_c():\n    from signal import SIGTERM as kill\n    print(kill)\n"
               "def test_d():\n    kill(p, 0)\n"
               "def test_e():\n    global k\n    k = os.kill\n"
               "def test_f():\n    k(p, 0)\n")
        # test_c's local kill meets the module's os.kill: the kill reading wins, so the reference is unresolved
        self.assertEqual(self.hits(src), ["test_b", "test_c", "test_d", "test_f"])

    def test_a_kill_binding_wins_where_scopes_meet(self):
        # review of #4398 (F1): a name bound to os.kill in any scope a read can see keeps the reading that finds it
        src = ("import os, signal\nk = os.kill\n"
               "def test_a():\n    if x:\n        k = signal.SIGTERM\n    k(p, 0)\n"
               "def test_b():\n    import signal as os\n    def inner():\n        os.kill(p, 0)\n")
        self.assertEqual(self.hits(src), ["test_a", "test_b"])

    def test_a_global_or_nonlocal_declared_after_the_binding_still_applies(self):
        # review of #4404 (F1): an import bound before a later `global os` stayed local, so the module's os was never
        # bound and test_b's probe passed. A declaration covers its whole scope, wherever it sits.
        rows = [
            ("global", "def setup():\n    import os\n    global os\ndef test_b():\n    os.kill(p, 0)\n", ["test_b"]),
            ("nonlocal", "def outer():\n    os = None\n    def setup():\n        from os import kill as os\n"
                         "        nonlocal os\n    def test_b():\n        os(p, 0)\n", ["outer"]),
        ]
        for label, src, want in rows:
            with self.subTest(label):
                self.assertEqual(self.hits(src), want)

    def test_a_kill_reference_that_escapes_is_flagged_unresolved(self):
        # review of #4398 (F2): a returned getattr(os, "kill") or one stored on an attribute or a class went unseen
        src = ("import os\n"
               "def test_a():\n    return getattr(os, 'kill')\n"
               "def test_b(self):\n    self.probe = os.kill\n    self.probe(p, 0)\n"
               "class T:\n    probe = os.kill\n    def test_c(self):\n        self.probe(p, 0)\n"
               "def test_d():\n    run(probe=getattr(os, 'kill'))\n"
               "def test_e():\n    os.kill.__call__(p, 0)\n"
               "def test_f():\n    run(os.kill)\n")
        self.assertEqual(self.hits(src), ["test_a", "test_b", "<module>", "test_d", "test_e", "test_f"])
        self.assertEqual({k for *_, k in find_source(src)}, {"unresolved"})

    def test_a_kill_or_a_signal_the_source_picks_at_run_time_is_unresolved(self):
        # review of hq#9418 (F2, F3): `from os import *`, getattr(os, name) and obj.SIGTERM of an unknown obj passed
        src = ("import os, signal\n"
               "def test_a():\n    from os import *\n    kill(p, 0)\n"
               "def test_b(name):\n    getattr(os, name)(p, 0)\n"
               "def test_c(name):\n    return getattr(os, name)\n"
               "def test_d():\n    os.kill(p, mod.signal.SIGTERM)\n"
               "def test_e(obj):\n    os.kill(p, obj.SIGKILL)\n"
               "def test_f():\n    from signal import *\n    os.kill(p, SIGTERM)\n    __import__('os').kill(p, 0)\n"
               "def test_g():\n    os.kill(p, __import__('signal').SIGTERM)\n    os.kill(p, os.SIGTERM)\n")
        self.assertEqual([(f, k) for f, _, k in find_source(src)],
                         [("test_a", "signal 0"), ("test_b", "signal 0"), ("test_c", "unresolved"),
                          ("test_d", "unresolved"), ("test_e", "unresolved"), ("test_f", "signal 0")])

    def test_every_alias_form_is_a_row_the_lint_finds(self):
        # one row per form a review found slipping past a copy of this lint: (finding, source, function it is in)
        rows = [
            ("hq#9397 F2", "from os import kill\ndef test_a():\n    kill(p, 0)\n", "test_a"),
            ("hq#9397 F2", "import os as posix\ndef test_a():\n    posix.kill(p, 0)\n", "test_a"),
            ("cmux#41365 F1", "import os.path\ndef test_a():\n    os.kill(p, 0)\n", "test_a"),
            ("hq#9418 F2", "def test_a():\n    from os import *\n    kill(p, 0)\n", "test_a"),
            ("hq#9418 F2", "import os\ndef test_a(name):\n    getattr(os, name)(p, 0)\n", "test_a"),
            ("hq#9418 F3", "import os\ndef test_a(obj):\n    os.kill(p, obj.SIGTERM)\n", "test_a"),
        ]
        for finding, src, func in rows:
            with self.subTest(finding=finding, src=src):
                self.assertEqual(self.hits(src), [func])

    def test_a_signal_that_may_be_zero_is_a_probe(self):
        # review of cmux#41326 (F3): os.kill(*(pid, 0)), signal.SIG_DFL (whose value is 0) and aliases of it passed.
        # Each row: (source of one kill call's module, what the lint calls it)
        rows = [
            ("import os\nos.kill(*(p, 0))\n", "unresolved"),
            ("import os, signal\nos.kill(p, signal.SIG_DFL)\n", "signal 0"),
            ("import os, signal\nos.kill(p, signal.Handlers.SIG_DFL)\n", "signal 0"),
            ("import os\nfrom signal import SIG_DFL as D\nos.kill(p, D)\n", "signal 0"),
            ("import os\nZ = 0\nos.kill(p, Z)\n", "signal 0"),
            ("import os\nos.kill(p, 1 - 1)\n", "signal 0"),
            ("import os\nos.kill(p, False)\n", "signal 0"),
            ("import os, signal\nos.kill(p, signal.SIGTERM if c else 0)\n", "signal 0"),
            ("import os\ndef f(sig=0):\n    os.kill(p, sig)\n", "unresolved"),
            ("import os\nZ = 0\nZ = 9\nos.kill(p, Z)\n", "unresolved"),
            ("import os\nos.kill(p, pick())\n", "unresolved"),
            ("import os\nN = 9\nos.kill(p, N)\n", None),
            ("import os, signal\nos.kill(p, signal.SIGTERM)\n", None),
        ]
        for src, want in rows:
            with self.subTest(src=src):
                self.assertEqual([k for *_, k in find_source(src)], [want] if want else [])

    def test_import_os_path_binds_os(self):
        # review of cmux#41365 (F1): `import os.path` binds os, but only `import os` was read, so os.kill passed
        src = ("import os.path\n"
               "def test_a():\n    os.kill(p, 0)\n"
               "def test_b():\n    import os.path as osp\n    osp.join('a', 'b')\n")
        self.assertEqual([(f, k) for f, _, k in find_source(src)], [("test_a", "signal 0")])

    def test_a_real_signal_and_the_helpers_are_not_flagged(self):
        src = ("import os, signal\nclass T:\n"
               "    def test_a(self):\n        os.kill(p, 9)\n        os.killpg(g, signal.SIGKILL)\n"
               "        self.assertTrue(died(p))\n        self.assertTrue(running(q))\n")
        self.assertEqual(self.hits(src), [])


def zombie_child():
    """A SIGKILLed child of this process that nothing has reaped: a zombie until proc.wait()."""
    proc = subprocess.Popen(["sleep", "60"])
    os.kill(proc.pid, signal.SIGKILL)
    return proc


def zombie_not_ours():
    """(holder, pid): a zombie whose parent, HOLDER, never reaps it; not this process's child."""
    holder = subprocess.Popen([sys.executable, "-c",
                               "import os, signal, sys, time\npid = os.fork()\n"
                               "if pid == 0:\n    time.sleep(60)\n    os._exit(0)\n"
                               "os.kill(pid, signal.SIGKILL)\nprint(pid, flush=True)\ntime.sleep(60)\n"],
                              stdout=subprocess.PIPE, text=True)
    return holder, int(holder.stdout.readline())



def zombie_group():
    """(holder, pgid): a process group whose one member is a zombie its parent, HOLDER, never reaps."""
    holder = subprocess.Popen([sys.executable, "-c",
                               "import os, signal, sys, time\npid = os.fork()\n"
                               "if pid == 0:\n    os.setpgid(0, 0)\n    time.sleep(60)\n    os._exit(0)\n"
                               "try:\n    os.setpgid(pid, pid)\nexcept OSError:\n    pass\n"
                               "while os.getpgid(pid) != pid:\n    time.sleep(0.01)\n"
                               "os.kill(pid, signal.SIGKILL)\nprint(pid, flush=True)\ntime.sleep(60)\n"],
                              stdout=subprocess.PIPE, text=True)
    return holder, int(holder.stdout.readline())


class RefusesGroupSignalZero:
    """Signal 0 to a process group that exists is refused with EPERM, as macOS does for a group of zombies only. On
    macOS itself the kernel's own answer is used."""

    def __enter__(self):
        if sys.platform == "darwin":
            self.patch = None
            return self
        real = os.killpg

        def killpg(pgid, sig):
            real(pgid, sig)
            if sig == 0:
                raise PermissionError(1, "Operation not permitted")
        self.patch = mock.patch.object(process_gone.os, "killpg", killpg)
        self.patch.start()
        return self

    def __exit__(self, *exc):
        if self.patch:
            self.patch.stop()


class AsOnMacOS:
    """No pidfd and no /proc, as on macOS: died() has to tell a zombie by other means (ps, through
    process_identity)."""

    def __enter__(self):
        real_open = builtins.open
        real_isdir = os.path.isdir
        base = type(Path())

        def no_proc(path, *args, **kwargs):
            if str(path).startswith("/proc/"):
                raise FileNotFoundError(2, "No such file or directory", str(path))
            return real_open(path, *args, **kwargs)

        class NoProcPath(base):
            def exists(self, *args, **kwargs):
                return False if str(self).startswith("/proc") else super().exists(*args, **kwargs)

            def read_text(self, *args, **kwargs):
                if str(self).startswith("/proc"):
                    raise FileNotFoundError(2, "No such file or directory", str(self))
                return super().read_text(*args, **kwargs)
        self.patches = [mock.patch.object(process_gone.os, "pidfd_open", side_effect=AttributeError, create=True),
                        mock.patch("builtins.open", no_proc),
                        mock.patch.object(process_gone.os.path, "isdir",
                                          lambda p: False if str(p).startswith("/proc") else real_isdir(p))]
        identity = sys.modules.get("process_identity")
        if identity is not None and hasattr(identity, "Path"):
            self.patches.append(mock.patch.object(identity, "Path", NoProcPath))
        for p in self.patches:
            p.start()
        return self

    def __exit__(self, *exc):
        for p in reversed(self.patches):
            p.stop()


class FakePs:
    """A `ps` first on PATH that runs BODY (shell) instead: one that fails, prints nothing, or hangs."""

    def __init__(self, body):
        self.body = body

    def __enter__(self):
        self.dir = tempfile.TemporaryDirectory()
        path = os.path.join(self.dir.name, "ps")
        with open(path, "w") as f:
            f.write("#!/bin/sh\n%s\n" % self.body)
        os.chmod(path, 0o755)
        self.patch = mock.patch.dict(os.environ, {"PATH": self.dir.name + os.pathsep + os.environ.get("PATH", "")})
        self.patch.start()
        return self

    def __exit__(self, *exc):
        self.patch.stop()
        self.dir.cleanup()


class TheHelpers(unittest.TestCase):
    def test_a_killed_child_not_reaped_yet_counts_as_died_and_a_live_one_does_not(self):
        live = subprocess.Popen(["sleep", "60"])
        proc = zombie_child()
        try:
            self.assertFalse(died(live.pid, within=0.3))
            self.assertTrue(running(live.pid))
            self.assertTrue(died(proc.pid))  # a zombie until the wait below reaps it
            self.assertFalse(running(proc.pid))
            self.assertIsNone(os.kill(proc.pid, 0))  # where the raw probe was wrong: signal 0 still reaches it
        finally:
            for p in (live, proc):
                p.kill()
                p.wait()
        self.assertTrue(died(proc.pid))  # reaped: gone

    def test_without_a_pidfd_or_proc_a_zombie_still_counts_as_died(self):
        # review of #4363 (F2): on macOS died() polled signal 0, which a zombie answers, for the whole 10 s
        live = subprocess.Popen(["sleep", "60"])
        proc = zombie_child()
        holder, orphan = zombie_not_ours()
        try:
            with AsOnMacOS():
                # Nothing reaps either zombie during these waits (this test, and HOLDER, never wait on them), so
                # True can only come from seeing the zombie; the old poll answered False at the deadline.
                self.assertTrue(died(proc.pid, within=5), "our own unreaped child")
                self.assertTrue(died(orphan, within=5), "another process's unreaped child")
                self.assertIsNone(holder.poll(), "HOLDER ended, which would have reaped its child")
                self.assertFalse(died(live.pid, within=0.3))
                self.assertTrue(running(live.pid))
                self.assertFalse(running(orphan))
        finally:
            for p in (live, proc, holder):
                p.kill()
                p.wait()
            holder.stdout.close()

    def test_a_pidfd_past_fd_setsize_is_still_waited_on(self):
        # review of #41326 (F1): select.select() refused a pidfd at or above FD_SETSIZE (1024) with ValueError
        if not hasattr(os, "pidfd_open"):
            self.skipTest("no pidfd here: died() polls the state instead")
        import resource
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        if soft < 1300:
            if hard != resource.RLIM_INFINITY and hard < 1300:
                self.skipTest("this host allows %d open files" % hard)
            resource.setrlimit(resource.RLIMIT_NOFILE, (1300, hard))
            self.addCleanup(resource.setrlimit, resource.RLIMIT_NOFILE, (soft, hard))
        fds = [os.open(os.devnull, os.O_RDONLY) for _ in range(1100)]
        live = subprocess.Popen(["sleep", "60"])
        proc = zombie_child()
        try:
            self.assertFalse(died(live.pid, within=0.3))
            self.assertTrue(died(proc.pid))
        finally:
            for fd in fds:
                os.close(fd)
            for p in (live, proc):
                p.kill()
                p.wait()

    def test_a_pidfd_at_1024_or_higher_is_still_waited_on(self):
        # review of hq#9397 (F1): select.select() raises ValueError for an fd at or above FD_SETSIZE (1024), so
        # died() crashed in a process with many descriptors. The real pidfd is dup2-ed to 1024+ and waited on there.
        if not hasattr(os, "pidfd_open"):
            self.skipTest("no pidfd here: died() polls the state instead")
        import resource
        high = 1500
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        if soft <= high:
            if hard != resource.RLIM_INFINITY and hard <= high:
                self.skipTest("this host allows %d open files" % hard)
            resource.setrlimit(resource.RLIMIT_NOFILE, (high + 1, hard))
            self.addCleanup(resource.setrlimit, resource.RLIMIT_NOFILE, (soft, hard))
        real, used = os.pidfd_open, []

        def pidfd_open(pid, *args):
            fd = real(pid, *args)
            try:
                os.dup2(fd, high)
            finally:
                os.close(fd)
            used.append(high)
            return high
        live = subprocess.Popen(["sleep", "60"])
        proc = zombie_child()
        try:
            with mock.patch.object(process_gone.os, "pidfd_open", pidfd_open):
                self.assertFalse(died(live.pid, within=0.3))
                self.assertTrue(running(live.pid))
                self.assertTrue(died(proc.pid))
            self.assertEqual(used[:1], [high], "died() did not wait on a pidfd")
        finally:
            for p in (live, proc):
                p.kill()
                p.wait()

    def test_a_group_of_zombies_that_refuses_signal_zero_counts_as_died(self):
        # review of #41326 (F3): macOS answers EPERM for a group that holds only zombies; died() is True for them
        holder, pgid = zombie_group()
        live = subprocess.Popen(["sleep", "60"], start_new_session=True)
        try:
            with RefusesGroupSignalZero():
                # HOLDER never reaps its child during the wait, so True can only come from reading the members.
                self.assertTrue(group_died(pgid, within=5), "a group of zombies only")
                self.assertIsNone(holder.poll(), "HOLDER ended, which would have reaped its child")
                self.assertFalse(group_died(live.pid, within=0.3), "a live group that refuses signal 0")
        finally:
            for p in (live, holder):
                p.kill()
                p.wait()
            holder.stdout.close()

    def test_a_ps_that_answers_nothing_is_unknown_never_gone(self):
        # review of leo-workspace#4379 (F1): ps that failed with empty stdout read as "no such pid", so a live
        # process counted as gone
        live = subprocess.Popen(["sleep", "60"])
        try:
            for body in ("exit 1", "exit 0", "echo 'ps: oops' >&2; exit 2"):
                with self.subTest(ps=body), FakePs(body), AsOnMacOS():
                    self.assertFalse(died(live.pid, within=0.3), "a live process counted as gone")
                    self.assertEqual(process_gone.probe(live.pid), process_gone.UNKNOWN)
                    self.assertFalse(running(live.pid), "UNKNOWN is not ALIVE either")
        finally:
            live.kill()
            live.wait()

    def test_a_group_ps_lists_no_member_of_is_not_gone(self):
        # review of hq#9418 (F1): all([]) is True, so a group that refused signal 0 and that ps listed no member of
        # counted as zombies only, and gone
        # (and cmux 0d3b4b7e's _live_group_members, where signal 0 reaches the group: no line listed read as no live
        # member, so gone)
        import contextlib
        live = subprocess.Popen(["sleep", "60"], start_new_session=True)
        try:
            # cmux#41326 (F2): EPERM, or a ps that fails, says nothing: never a definite "gone"
            for refuses in (True, False):
                for ps in ("exit 0", "exit 1", "echo 'ps: oops' >&2; exit 2"):
                    with self.subTest(eperm=refuses, ps=ps), FakePs(ps), \
                            (RefusesGroupSignalZero() if refuses else contextlib.nullcontext()):
                        self.assertFalse(group_died(live.pid, within=0.3), "a live group counted as gone")
        finally:
            live.kill()
            live.wait()

    def test_a_hung_ps_is_bounded_by_the_time_the_wait_has_left(self):
        # review of cmux#41365 (F3): each ps had a fixed 5 s timeout, so a wait of WITHIN ran 5 s past it
        live = subprocess.Popen(["sleep", "60"], start_new_session=True)
        bound = 0.5 + process_gone.PS_FLOOR + 1.0  # the wait, one ps past it at its floor, and slack for a busy host
        try:
            with FakePs("exec sleep 30"):
                with RefusesGroupSignalZero():
                    start = time.monotonic()
                    self.assertFalse(group_died(live.pid, within=0.5))
                    self.assertLess(time.monotonic() - start, bound, "group_died() waited out ps past its deadline")
                with AsOnMacOS():
                    start = time.monotonic()
                    self.assertFalse(died(live.pid, within=0.5))
                    self.assertLess(time.monotonic() - start, bound, "died() waited out ps past its deadline")
        finally:
            live.kill()
            live.wait()

    def test_probe_says_alive_dead_or_unknown(self):
        live = subprocess.Popen(["sleep", "60"])
        proc = zombie_child()
        try:
            self.assertEqual(process_gone.probe(live.pid), process_gone.ALIVE)
            self.assertTrue(died(proc.pid))
            self.assertEqual(process_gone.probe(proc.pid), process_gone.DEAD)
            with AsOnMacOS():
                self.assertEqual(process_gone.probe(live.pid), process_gone.ALIVE)
                self.assertEqual(process_gone.probe(proc.pid), process_gone.DEAD)
        finally:
            for p in (live, proc):
                p.kill()
                p.wait()

    def test_a_group_of_zombies_counts_as_died_where_signal_zero_still_reaches_it(self):
        # cmux#41316: a member SIGKILLed with its parent gone stays a zombie until init reaps it, and signal 0 still
        # finds its group ("process group outlived the gate" with nothing left running). On Linux nothing refuses
        # signal 0 here, so True can only come from judging the members.
        holder, pgid = zombie_group()
        try:
            self.assertTrue(group_died(pgid, within=5), "a group of zombies only")
            self.assertIsNone(holder.poll(), "HOLDER ended, which would have reaped its child")
        finally:
            holder.kill()
            holder.wait()
            holder.stdout.close()

    def test_a_group_with_a_member_unknown_is_not_gone(self):
        # a member process_identity cannot tell (UNKNOWN) is never counted as DEAD, so the group is not gone
        holder, pgid = zombie_group()
        try:
            with mock.patch.object(process_gone.process_identity, "status", lambda pid, timeout=None: "unknown"):
                self.assertFalse(group_died(pgid, within=0.3))
        finally:
            holder.kill()
            holder.wait()
            holder.stdout.close()

    def test_a_group_is_gone_once_its_members_are_reaped(self):
        proc = subprocess.Popen(["sleep", "60"], start_new_session=True)
        try:
            self.assertFalse(group_died(proc.pid, within=0.3))
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
            self.assertTrue(group_died(proc.pid))
        finally:
            proc.kill()
            proc.wait()
