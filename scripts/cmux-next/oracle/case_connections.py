#!/usr/bin/env python3
"""The case connections of the daemon driver: one SDK connection per case-v1 `args.connection`, the streams
its steps open, the calls they leave in flight, and the session event logs that invariant I8 folds.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md section 3D (suite streams) and task 204. Stdlib plus the repo's
Python SDK (cmux-tui/bindings/python); safe under `python3 -I`. driver_daemon.py (task 023) owns the daemon and
the steps; this file owns what a connection-scoped step leaves open between steps.

- `CaseConnection` is the SDK's ProtocolConnection with one addition: `send_in_flight` sends a request, returns
  its wire id once it is on the wire and keeps waiting for the reply in a thread. `request.cancel` names that id
  (case-v1 `args.inFlight`: "send, go on, reply {request_id}").
- `CaseStreams` holds the streams of one case: a `session.events` stream is an event_log.EventLog (I8's input),
  any other stream (terminal.attach, browser.attach, sidebar_view.attach, session.journal.subscribe,
  conversation.events) a plain ResourceStream whose items the driver drains so the SDK's bounded queue never
  overflows into a gap. At each checkpoint the driver reads every open log up to the daemon facet's
  `session.cursor`; after the daemon's connections close it reads each log to its end; at teardown it stops the
  in-flight calls, cancels the streams and closes the logs (event_log.ORACLE_TEARDOWN).

Chrome reference (chromium/src): mojo/public/cpp/bindings/tests/receiver_set_unittest.cc and
connection_group_unittest.cc hold several pipes of one test open at once and close each pipe's pending calls
when the pipe goes away; the sync integration tests' StatusChangeChecker (chrome/browser/sync/test/integration/
status_change_checker.h) waits for a client to reach a server's state before comparing, as `read_logs_to` does.

Usage:
  case_connections.py --selftest
"""

from __future__ import annotations

import sys
import threading
import unittest
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Mapping, Optional

HERE = Path(__file__).resolve().parent
SDK = HERE.parents[2] / "cmux-tui" / "bindings" / "python"
for _path in (str(HERE), str(SDK)):
    if _path not in sys.path:
        sys.path.insert(0, _path)

import event_log  # noqa: E402 - sibling of this file
from cmux._protocol import ProtocolConnection  # noqa: E402
from cmux.errors import CmuxError  # noqa: E402
from cmux.errors import TimeoutError as SdkTimeout  # noqa: E402

MAIN = "main"
# The longest a drain reads one stream at a checkpoint (the SDK queue holds 256 items).
DRAIN_ITEMS = 256
DRAIN_WAIT_S = 0.001


class _RequestIds(dict):
    """The SDK's table of pending requests, keyed by wire id; it remembers the id it registered last."""

    last: Optional[str] = None

    def __setitem__(self, key: str, value: Any) -> None:
        super().__setitem__(key, value)
        self.last = key


@dataclass
class InFlight:
    """A request sent by `send_in_flight`: its wire id and the thread that waits for its reply."""

    step: str
    connection: str
    request_id: str
    cancel: threading.Event
    thread: threading.Thread
    done: Dict[str, Any] = field(default_factory=dict)

    def stop(self, timeout: float) -> None:
        """Stop waiting. A wait the daemon has not answered is canceled by the SDK's own request.cancel."""
        self.cancel.set()
        self.thread.join(timeout)


class CaseConnection(ProtocolConnection):
    """A ProtocolConnection that can leave a request in flight and name it by its wire id."""

    def __init__(self, socket_path: str, timeout: float):
        super().__init__(socket_path, timeout)
        # The SDK makes the wire id inside `request`; request.cancel needs it, so the table records it.
        with self._lock:
            self._pending = _RequestIds(self._pending)

    def send_in_flight(self, step: str, connection: str, operation: str, params: Mapping[str, Any],
                       timeout: float) -> InFlight:
        """Send `operation` and return once it is on the wire; a thread keeps waiting up to `timeout` seconds."""
        sent = threading.Event()
        cancel = threading.Event()
        ids: Dict[str, str] = {}
        done: Dict[str, Any] = {}

        def dispatched() -> None:
            last = self._pending.last
            if last is not None:
                ids["id"] = last
            sent.set()

        def call() -> None:
            try:
                done["reply"] = self.request(operation, params, timeout=timeout, cancel_event=cancel,
                                             _on_dispatched=dispatched)
            except CmuxError as error:
                done["error"] = error
            finally:
                sent.set()

        thread = threading.Thread(target=call, name=f"oracle-in-flight-{step}", daemon=True)
        thread.start()
        sent.wait(timeout)
        if "id" not in ids:
            cancel.set()
            thread.join(timeout)
            error = done.get("error")
            raise error if isinstance(error, CmuxError) else SdkTimeout(f"{operation} was not sent in {timeout:.0f} s")
        return InFlight(step, connection, ids["id"], cancel, thread, done)

    def forget(self, request_id: str) -> None:
        """A request the daemon canceled sends no reply (request.cancel's contract): stop routing one to it."""
        with self._lock:
            self._pending.pop(request_id, None)


class CaseStreams:
    """What the steps of one case left open: event logs, other streams and in-flight calls."""

    def __init__(self) -> None:
        self.logs: List[event_log.EventLog] = []
        self.streams: Dict[str, Any] = {}
        self.in_flight: List[InFlight] = []

    def open(self, conn: Any, step: str, connection: str, operation: str, params: Mapping[str, Any],
             timeout: float) -> Dict[str, Any]:
        """Open a stream_open operation through the SDK; its reply as the daemon sent it (StreamOpened or
        ViewAttachmentStreamOpened, without the cursor the SDK checks and keeps)."""
        if operation == event_log.STREAM:
            log = event_log.EventLog(conn, step, connection, params, timeout, opened_at=step)
            self.logs.append(log)
            stream = log.stream
        else:
            stream = conn.open_stream(operation, dict(params), _raw, timeout=timeout)
            self.streams[step] = stream
        reply: Dict[str, Any] = {"stream_id": str(stream.id)}
        if stream.attachment_lease is not None:
            reply["attachment_lease"] = stream.attachment_lease
        return reply

    def send_in_flight(self, conn: CaseConnection, step: str, connection: str, operation: str,
                       params: Mapping[str, Any], timeout: float) -> Dict[str, str]:
        entry = conn.send_in_flight(step, connection, operation, params, timeout)
        self.in_flight.append(entry)
        return {"request_id": entry.request_id}

    def canceled(self, conn: Any, connection: str, request_id: Any, reply: Any, timeout: float) -> None:
        """After a request.cancel reply: a call it canceled (canceled true) gets no reply, so stop waiting."""
        if not (isinstance(reply, Mapping) and reply.get("canceled") is True):
            return
        for entry in self.in_flight:
            if entry.connection == connection and entry.request_id == request_id:
                if isinstance(conn, CaseConnection):
                    conn.forget(request_id)
                entry.stop(timeout)

    def read_logs(self, step: str, checkpoint: str) -> None:
        """At a checkpoint with no session cursor: read what each open log holds, an end included."""
        for log in self.logs:
            if log.end is None:
                log.read_queued()
                _note_end(log, step, checkpoint)

    def read_logs_to(self, generation: str, revision: int, timeout: float, step: str, checkpoint: str) -> None:
        """At a checkpoint: read each open log until it carries the cursor (generation, revision), then what it
        already holds; I8 judges a log that never gets there. An end read here comes before this checkpoint."""
        for log in self.logs:
            if log.end is None:
                log.read_until(generation, revision, timeout)
                _note_end(log, step, checkpoint)

    def drain(self) -> None:
        """Read the queued items of the streams that are not event logs (nothing compares them yet)."""
        for stream in self.streams.values():
            for _ in range(DRAIN_ITEMS):
                try:
                    stream.next(DRAIN_WAIT_S)
                except (StopIteration, CmuxError):
                    break

    def disconnected(self, timeout: float, step: str) -> None:
        """The daemon's connections closed during `step` (a kill, a restart, a stop): each log reads to the end the
        SDK gave it."""
        for log in self.logs:
            if log.end is None:
                log.read_to_end(timeout)
                _note_end(log, step, None)

    def close(self, timeout: float) -> None:
        """Teardown, before the daemon stops: the in-flight calls, the streams, then the logs."""
        for entry in self.in_flight:
            entry.stop(timeout)
        for stream in self.streams.values():
            try:
                stream.cancel()
            except CmuxError:
                pass  # its connection is gone
        for log in self.logs:
            log.close()

    def records(self, rename: Callable[[Any], None]) -> List[Dict[str, Any]]:
        """The trace's `eventLogs`. `rename` gives each session object the name the daemon facet shows."""
        out = []
        for log in self.logs:
            record = log.record()
            for entry in record["items"]:
                item = entry.get("item")
                if not isinstance(item, Mapping):
                    continue
                if item.get("kind") == "snapshot":
                    rename(item.get("snapshot"))
                for change in item.get("changes") or ():
                    if isinstance(change, dict) and change.get("resource") == "session":
                        rename({"session": change.get("value")})
            out.append(record)
        return out


def _raw(item: Any) -> Any:
    return item


def _note_end(log: event_log.EventLog, step: str, checkpoint: Optional[str]) -> None:
    if log.end is not None and log.ended_at is None:
        log.ended_at = {"step": step, **({"checkpoint": checkpoint} if checkpoint else {})}


# ---------------------------------------------------------------------------------------------- self test


@dataclass
class _Item:
    sequence: str
    item: Any


class _FakeStream:
    def __init__(self, ident: str, items: List[Any], lease: Optional[str] = None):
        self.id = ident
        self.attachment_lease = lease
        self.items = list(items)
        self.canceled = False
        self.end: Any = None

    def next(self, timeout: Optional[float] = None) -> Any:
        if not self.items:
            raise SdkTimeout("quiet")
        return self.items.pop(0)

    def cancel(self) -> None:
        self.canceled = True


class _FakeConnection:
    def __init__(self) -> None:
        self.opened: List[Any] = []

    def open_stream(self, operation: str, params: Mapping[str, Any], decode: Callable[[Any], Any],
                    timeout: Optional[float] = None) -> _FakeStream:
        stream = _FakeStream(f"stream_{len(self.opened):032x}", [_Item(str(n), {}) for n in range(3)],
                             "lease-1" if operation.endswith(".attach") else None)
        self.opened.append((operation, dict(params), stream))
        return stream


class CaseConnectionsSelfTest(unittest.TestCase):
    def test_streams_open_drain_and_close(self) -> None:
        conn = _FakeConnection()
        streams = CaseStreams()
        reply = streams.open(conn, "attach", "viewer", "terminal.attach", {"machine": "current"}, 1.0)
        self.assertEqual(reply, {"stream_id": f"stream_{0:032x}", "attachment_lease": "lease-1"})
        events = streams.open(conn, "open", "watch", event_log.STREAM, {"machine": "current", "session": "current"}, 1.0)
        self.assertEqual(events, {"stream_id": f"stream_{1:032x}"})
        self.assertEqual([log.case_connection for log in streams.logs], ["watch"])
        streams.drain()
        self.assertEqual(conn.opened[0][2].items, [], "the drain reads what the attach queued")
        streams.close(1.0)
        self.assertTrue(conn.opened[0][2].canceled)
        self.assertTrue(conn.opened[1][2].canceled)
        self.assertEqual(streams.logs[0].record()["end"], {"reason": event_log.ORACLE_TEARDOWN})

    def test_an_end_is_placed_at_the_checkpoint_that_read_it(self) -> None:
        conn = _FakeConnection()
        streams = CaseStreams()
        streams.open(conn, "open", "watch", event_log.STREAM, {"machine": "current", "session": "current"}, 1.0)
        stream = conn.opened[0][2]
        stream.items = []
        streams.read_logs("call", "before")
        self.assertIsNone(streams.logs[0].ended_at, "a quiet open stream has no end")

        def ended(timeout: Optional[float] = None) -> Any:
            stream.end = type("End", (), {"reason": "closed", "cursor": None})()
            raise StopIteration

        stream.next = ended
        streams.read_logs("call", "settled")
        self.assertEqual(streams.logs[0].record()["end"], {"reason": "closed"})
        self.assertEqual(streams.logs[0].record()["endedAt"], {"step": "call", "checkpoint": "settled"})
        streams.disconnected(1.0, "later")
        self.assertEqual(streams.logs[0].ended_at, {"step": "call", "checkpoint": "settled"}, "the first sighting stays")

    def test_records_rename_the_session_in_snapshots_and_upserts(self) -> None:
        streams = CaseStreams()
        log = event_log.EventLog(_FakeConnection(), "open", "watch")
        log.items = [{"sequence": "0", "item": {"kind": "snapshot", "snapshot": {"session": {"name": "oracle-x"}}}},
                     {"sequence": "1", "item": {"kind": "delta", "changes": [
                         {"kind": "upsert", "resource": "session", "id": "s", "value": {"name": "oracle-x"}},
                         {"kind": "upsert", "resource": "tab", "id": "t", "value": {"name": "oracle-x"}}]}}]
        streams.logs.append(log)

        def rename(snapshot: Any) -> None:
            info = snapshot.get("session") if isinstance(snapshot, dict) else None
            if isinstance(info, dict) and info.get("name") == "oracle-x":
                info["name"] = "oracle"

        record = streams.records(rename)[0]
        self.assertEqual(record["items"][0]["item"]["snapshot"]["session"]["name"], "oracle")
        changes = record["items"][1]["item"]["changes"]
        self.assertEqual([c["value"]["name"] for c in changes], ["oracle", "oracle-x"])

    def test_a_canceled_call_stops_waiting_and_an_uncanceled_one_waits(self) -> None:
        streams = CaseStreams()
        release = threading.Event()
        thread = threading.Thread(target=release.wait, daemon=True)
        thread.start()
        entry = InFlight("wait", "waiter", "request-1", release, thread)
        streams.in_flight.append(entry)
        streams.canceled(object(), "waiter", "request-1", {"canceled": False}, 1.0)
        self.assertFalse(release.is_set(), "canceled false: the reply is still coming")
        streams.canceled(object(), "other", "request-1", {"canceled": True}, 1.0)
        self.assertFalse(release.is_set(), "a cancel on another connection is not this call's")
        streams.canceled(object(), "waiter", "request-1", {"canceled": True}, 1.0)
        self.assertTrue(release.is_set())
        self.assertFalse(thread.is_alive())

    def test_the_request_table_remembers_the_last_id(self) -> None:
        table = _RequestIds({"request-a": 1})
        table["request-b"] = 2
        self.assertEqual(table.last, "request-b")
        self.assertEqual(set(table), {"request-a", "request-b"})


def main(argv: Optional[List[str]] = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if argv == ["--selftest"]:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(CaseConnectionsSelfTest)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    print(__doc__.strip().splitlines()[-1], file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
