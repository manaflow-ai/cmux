#!/usr/bin/env python3
"""thread_wakes counts a thread's wakeups from an exported System Trace thread-state table (a change into
Running from a wait, not a run after a preemption), keeps other processes' threads out, resolves `ref`s, and
names an unnamed thread from a `sample` report by its thread id."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import thread_wakes  # noqa: E402

# The shape of `xctrace export --xpath ...table[@schema="thread-state"]`: a schema of columns, then rows
# whose repeated values are `ref`s to an earlier element's `id`.
TABLE = """<?xml version="1.0"?>
<trace-query-result>
<node xpath='//trace-toc[1]/run[1]/data[1]/table[9]'><schema name="thread-state">
<col><mnemonic>start</mnemonic></col><col><mnemonic>duration</mnemonic></col><col><mnemonic>thread</mnemonic></col>
<col><mnemonic>state</mnemonic></col></schema>
<row><start-time id="1" fmt="00:00.000">0</start-time><duration id="2" fmt="50 us">50000</duration>
 <thread id="3" fmt="0x4146258 (cmux DEV, pid: 42)"><tid id="4">4146258</tid><process id="5" fmt="cmux DEV (42)"><pid id="6">42</pid></process></thread>
 <thread-state id="7" fmt="Running">Running</thread-state></row>
<row><start-time fmt="00:00.001">1000</start-time><duration fmt="1 s">1000000000</duration><thread ref="3"/>
 <thread-state id="8" fmt="Blocked">Blocked</thread-state></row>
<row><start-time fmt="00:01.001">2000</start-time><duration fmt="30 us">30000</duration><thread ref="3"/><thread-state ref="7"/></row>
<row><start-time fmt="00:01.002">3000</start-time><duration fmt="5 us">5000</duration><thread ref="3"/>
 <thread-state id="9" fmt="Preempted">Preempted</thread-state></row>
<row><start-time fmt="00:01.003">4000</start-time><duration fmt="20 us">20000</duration><thread ref="3"/><thread-state ref="7"/></row>
<row><start-time fmt="00:00.000">0</start-time><duration fmt="1 ms">1000000</duration>
 <thread id="10" fmt="Main Thread 0x10 (cmux DEV, pid: 42)"><tid id="11">16</tid><process ref="5"/></thread><thread-state ref="7"/></row>
<row><start-time fmt="00:00.000">0</start-time><duration fmt="1 s">1000000000</duration>
 <thread id="20" fmt="0x309 (cmux DEV, pid: 42)"><tid id="21">777</tid><process ref="5"/></thread><thread-state ref="8"/></row>
<row><start-time fmt="00:01.000">1000</start-time><duration fmt="2 us">2000</duration><thread ref="20"/>
 <thread-state id="22" fmt="Runnable">Runnable</thread-state></row>
<row><start-time fmt="00:01.001">1001</start-time><duration fmt="10 us">10000</duration><thread ref="20"/><thread-state ref="7"/></row>
<row><start-time fmt="00:01.002">1002</start-time><duration fmt="1 s">1000000000</duration><thread ref="20"/><thread-state ref="8"/></row>
<row><start-time fmt="00:02.002">2002</start-time><duration fmt="2 us">2000</duration><thread ref="20"/><thread-state ref="22"/></row>
<row><start-time fmt="00:02.003">2003</start-time><duration fmt="10 us">10000</duration><thread ref="20"/><thread-state ref="7"/></row>
<row><start-time fmt="00:02.004">2004</start-time><duration fmt="5 us">5000</duration><thread ref="20"/><thread-state ref="9"/></row>
<row><start-time fmt="00:02.005">2005</start-time><duration fmt="2 us">2000</duration><thread ref="20"/><thread-state ref="22"/></row>
<row><start-time fmt="00:02.006">2006</start-time><duration fmt="10 us">10000</duration><thread ref="20"/><thread-state ref="7"/></row>
<row><start-time fmt="00:00.000">0</start-time><duration fmt="1 ms">1000000</duration>
 <thread id="12" fmt="0x99 (other, pid: 7)"><tid id="13">153</tid><process id="14" fmt="other (7)"><pid id="15">7</pid></process></thread><thread-state ref="7"/></row>
</node></trace-query-result>
"""

SAMPLE = """Call graph:
    2091 Thread_16   DispatchQueue_1: com.apple.main-thread  (serial)
    + 2091 start  (in dyld) + 6076  [0x1]
    +   2091 main  (in cmux DEV) + 10  [0x2]
    2091 Thread_4146258
    + 2091 start_wqthread  (in libsystem_pthread.dylib) + 8  [0x3]
    +   2091 _pthread_wqthread  (in libsystem_pthread.dylib) + 292  [0x4]
    +     2091 AppHealth.arm()  (in cmux DEV) + 40  [0x5]
    +     ! 2091 DemandTimer.fire()  (in cmux DEV) + 12  [0x6]
    +     1 other.sibling()  (in cmux DEV) + 1  [0x7]
    2091 Thread_4146259: tokio-runtime-worker
    + 2091 thread_start  (in libsystem_pthread.dylib) + 8  [0x8]

Total number in stack (recursive counted multiple times):
"""


class CountWakes(unittest.TestCase):
    def setUp(self):
        handle, self.path = tempfile.mkstemp(suffix=".xml")
        with os.fdopen(handle, "w") as out:
            out.write(TABLE)

    def tearDown(self):
        os.remove(self.path)

    def test_wake_is_a_run_after_a_wait(self):
        threads = thread_wakes.count_wakes(self.path, pid=42)
        worker = threads[4146258]
        # Running (opens the record), Blocked, Running (a wakeup), Preempted, Running (the same run).
        self.assertEqual(worker["wakes"], 2)
        self.assertEqual(worker["runs"], 3)
        self.assertEqual(worker["running_ns"], 100000)
        self.assertEqual(worker["name"], "")
        self.assertEqual(threads[16]["name"], "Main Thread")

    def test_wake_through_runnable(self):
        # Blocked, Runnable, Running (a wakeup), Blocked, Runnable, Running (a wakeup), Preempted,
        # Runnable, Running (the same run).
        worker = thread_wakes.count_wakes(self.path, pid=42)[777]
        self.assertEqual((worker["wakes"], worker["runs"]), (2, 3))

    def test_other_processes_are_left_out(self):
        self.assertNotIn(153, thread_wakes.count_wakes(self.path, pid=42))
        self.assertIn(153, thread_wakes.count_wakes(self.path))

    def test_summary_names_and_rates(self):
        threads = thread_wakes.count_wakes(self.path, pid=42)
        sampled = thread_wakes.sample_threads(SAMPLE)
        got = thread_wakes.summarize({"seconds": 2, "threads": threads}, sampled)
        self.assertEqual(got["total_wakes_per_s"], 2.5)
        # Most wakeups first, ties by thread id.
        self.assertEqual([(r["thread"], r["wakes_per_s"]) for r in got["threads"]], [(777, 1.0), (4146258, 1.0), (16, 0.5)])
        self.assertEqual(got["threads"][1]["label"], "~AppHealth.arm() > DemandTimer.fire()")


class SampleNames(unittest.TestCase):
    def test_header_and_heaviest_frames(self):
        sampled = thread_wakes.sample_threads(SAMPLE)
        self.assertEqual(sampled[16]["header"], "DispatchQueue_1: com.apple.main-thread  (serial)")
        self.assertEqual(sampled[4146258]["header"], "")
        # The thread-start frames are skipped, and a sibling (not deeper) is not on the heaviest path.
        self.assertEqual(sampled[4146258]["frames"], ["AppHealth.arm() (cmux DEV)", "DemandTimer.fire() (cmux DEV)"])
        self.assertEqual(sampled[4146259]["header"], "tokio-runtime-worker")

    def test_label_prefers_the_pthread_name(self):
        sampled = thread_wakes.sample_threads(SAMPLE)
        self.assertEqual(thread_wakes.label("CrBrowserMain", sampled[16]), "CrBrowserMain")
        self.assertEqual(thread_wakes.label("?", sampled[4146259]), "tokio-runtime-worker")
        self.assertEqual(thread_wakes.label("?", None), "?")


if __name__ == "__main__":
    unittest.main()
