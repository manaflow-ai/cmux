#!/usr/bin/env python3
"""A `process_present` check binds a process of the journey's own terminal, no fleet, no app.

    python3 scripts/journeys/test_process_scope.py

One terminal host runs the shells of every terminal of the app (one tty each). The ctrl-d journey binds
"the second tab's shell" with process_present (foreground zsh|bash) and then waits for process_gone after
Ctrl+D. Bound by host alone, the check took the lowest pid of all shells under the host: the shell of
another, older terminal (gates v2.2.5-opt to v2.2.7-opt: bound ttys001 or ttys003; the daemon reported
the second terminal exited, code 0, and its tab closed). The bound shell never ended, so the journey
failed although the product was right.
"""
import re
import shlex
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parent / "cmux-next")]
import driver as D  # noqa: E402

HOST = 500


def row(pid, tty, command, ppid=HOST, stat="Ss+"):
    return {"pid": pid, "ppid": ppid, "pgid": pid, "tpgid": pid, "tty": tty, "stat": stat, "command": command}


class Host:
    """One terminal host with a shell per terminal; `term_b` is the journey's second tab."""

    def __init__(self, write_tty=True, late_probe=False):
        # late_probe: the shell runs the probe only when the next line arrives (a slow host).
        self.write_tty, self.late_probe, self.pending = write_tty, late_probe, None
        self.ttys = {"term_old": "ttys001", "term_a": "ttys004", "term_b": "ttys005"}
        self.table = {HOST: row(HOST, "??", "/Applications/cmux NEXT.app/Contents/MacOS/cmux-host", ppid=1, stat="S")}
        self.table[101] = row(101, "ttys001", "/bin/zsh")  # an older terminal of the app (its default tab)
        self.table[190] = row(190, "ttys004", "/bin/zsh")  # the journey's first tab
        self.table[230] = row(230, "ttys005", "/bin/zsh")  # the journey's second tab
        self.writes = []

    def cmux(self, *args, timeout=30):
        assert args[0] == "terminal" and args[2] == "write", args
        term, text = args[1], args[4]
        self.writes.append((term, text))
        # The shell runs the line: a `tty >| FILE` in it writes this terminal's device.
        match = re.search(r"tty >\| ('[^']*'|[^\s;]+)", text)
        if match and self.late_probe:
            self.pending = (term, match)
            return {}
        if self.pending:
            term, match, self.pending = *self.pending, None
        if match and self.write_tty:
            Path(shlex.split(match.group(1))[0]).write_text(f"/dev/{self.ttys[term]}\n")
        return {}

    def screen(self, term):
        return {"text": D.PROMPT}

    def processes(self):
        return {pid: dict(r) for pid, r in self.table.items()}

    def roots(self, table, host_pid):
        return D.App.roots(self, table, host_pid)


def journey(host, out):
    j = D.Journey.__new__(D.Journey)
    j.app, j.out, j.binds, j.host_pid, j.pane = host, Path(out) / "ctrl-d", {}, HOST, "pane_1"
    j.out.mkdir(exist_ok=True)
    j.ttys, j.tty_probes, j.nonce = {}, 0, "234567"
    return j


SHELL = {"match": "(^|[ /-])(zsh|bash)( |$)", "bind": "shell", "foreground": True}


class ProcessPresentBindsTheJourneysTerminal(unittest.TestCase):
    def setUp(self):
        self.out = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.out.cleanup()

    def test_the_second_tabs_shell_is_bound_not_an_older_terminals(self):
        host = Host()
        j = journey(host, self.out.name)
        for term in ("term_a", "term_b"):  # each tab gets the neutral prompt, as the ctrl-d journey does
            j.term = term
            j.step_neutral_prompt({})
        holds, detail = j.evaluate("process_present", SHELL, {})
        self.assertTrue(holds, detail)
        self.assertEqual(j.binds["shell"]["pid"], 230, detail)
        # The tty goes on its own line first; the neutral prompt line itself is written unchanged after it.
        self.assertEqual([text for _, text in host.writes][1::2], [D.NEUTRAL_PROMPT, D.NEUTRAL_PROMPT])
        self.assertTrue(all(text.startswith(f"tty >| {self.out.name}/.tty-") for _, text in host.writes[0::2]), host.writes)
        self.assertEqual(list(Path(self.out.name).rglob("*tty-*")), [])
        # Ctrl+D ends the second tab's shell: process_gone holds.
        del host.table[230]
        holds, detail = j.evaluate("process_gone", "shell", {})
        self.assertTrue(holds, detail)

    def test_the_first_tabs_shell_after_use(self):
        host = Host()
        j = journey(host, self.out.name)
        for term in ("term_a", "term_b"):
            j.term = term
            j.step_neutral_prompt({})
        j.term = "term_a"
        holds, detail = j.evaluate("process_present", SHELL, {})
        self.assertTrue(holds, detail)
        self.assertEqual(j.binds["shell"]["pid"], 190, detail)

    def test_a_probe_that_runs_late_is_still_read_after_the_prompt(self):
        host = Host(late_probe=True)
        j = journey(host, self.out.name)
        j.term = "term_b"
        self.assertEqual(j.step_neutral_prompt({"tty_timeout": 0.1})["tty"], "ttys005")
        self.assertEqual(j.ttys, {"term_b": "ttys005"})
        self.assertEqual(list(Path(self.out.name).rglob("*tty-*")), [])

    def test_the_probe_line_never_wraps_the_terminal(self):
        # A capture slot's out dir and the longest journey ids: "$ " + the probe line stays within 110 columns.
        for slot in ("1", "17"):
            for journey_id in ("ctrl-d", "spam-cmd-shift-close-bracket", "mw-move-workspace-between-windows" + "-x" * 10):
                j = journey(Host(), self.out.name)
                j.out = Path(f"/Users/Shared/cmux-capture/slots/{slot}/lease-606f73db6233/journeys/out/{journey_id}")
                line = "$ " + D.TTY_PROBE.format(tty_file=shlex.quote(str(j.tty_probe_path()))).rstrip("\r")
                self.assertLessEqual(len(line), 100, line)

    def test_a_terminal_with_an_unknown_tty_never_binds_a_guess(self):
        host = Host(write_tty=False)
        j = journey(host, self.out.name)
        j.term = "term_b"
        try:
            j.step_neutral_prompt({"tty_timeout": 0.2})
        except D.StepError:
            pass
        holds, detail = j.evaluate("process_present", SHELL, {})
        self.assertFalse(holds, detail)
        self.assertNotIn("shell", j.binds)

    def test_one_match_under_the_host_still_binds_without_a_tty(self):
        host = Host(write_tty=False)
        j = journey(host, self.out.name)
        j.term = "term_b"
        host.table[231] = row(231, "ttys005", "sleep 100", ppid=230, stat="S+")
        holds, detail = j.evaluate("process_present", {"match": "^sleep 100$", "bind": "sleep", "foreground": True}, {})
        self.assertTrue(holds, detail)
        self.assertEqual(j.binds["sleep"]["pid"], 231)


if __name__ == "__main__":
    unittest.main()
