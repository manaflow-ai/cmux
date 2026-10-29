"""The app's invariant ledger for journeys and the fuzz (plans/cmux-next/invariants-DESIGN.md section 5.2).

The app checks every declared invariant after each action and each committed turn (Debug builds, and bench
builds launched with CMUX_NEXT_INVARIANTS=1) and appends each new violation to an append-only ledger with a
sequence number. A harness keeps a `Cursor` and reads `debug.invariants {since: cursor}` after every step, so it
sees every violation of every frame in that step with no per-frame poll. A violation fails the step; a ledger
that dropped entries before the read fails it too; an app that does not check (`armed: false`: a Release or
unarmed bench build) is "not run", never a pass.

Standard library only (driver.py runs on the stock /usr/bin/python3 3.9). It does not import driver.py: the
caller passes its rpc and the errors to raise.
"""


class NotArmed(Exception):
    """The app does not check its invariants (`armed: false`), or does not serve `debug.invariants`."""


class Cursor:
    """Where a harness is in one app process's ledger. `rpc(method, params)` returns the method's result; `pid()`
    returns the app's process id (a relaunch starts a new ledger, so the cursor goes back to 0)."""

    def __init__(self, rpc, pid, from_start=False):
        self.rpc, self.pid = rpc, pid
        self.seq, self.owner, self.mode = 0, pid(), None
        reply = self.read({})
        # A fresh app's first journey owns the violations of its launch; a later journey starts where the app is.
        self.seq = 0 if from_start else int(reply.get("seq") or 0)

    def read(self, params):
        try:
            reply = self.rpc("debug.invariants", params) or {}
        except Exception as error:  # noqa: BLE001 (any rpc error: the method is missing or the app is gone)
            raise NotArmed(f"debug.invariants: {error}") from error
        if not reply.get("armed"):
            raise NotArmed(f"the app does not check its invariants (mode {reply.get('mode')!r})")
        self.mode = reply.get("mode")
        return reply

    def new(self, check=False, ipc=False):
        """The violations since the last read, and whether the ledger dropped some before this read."""
        pid = self.pid()
        if pid != self.owner:
            # A relaunched app has a new ledger, which starts at 1.
            self.seq, self.owner = 0, pid
        params = {"since": self.seq}
        if check:
            params["check"] = True
        if ipc:
            params["ipc"] = True
        reply = self.read(params)
        violations = reply.get("violations") or []
        self.seq = max([self.seq, int(reply.get("seq") or 0)] + [int(v.get("seq") or 0) for v in violations])
        return violations, bool(reply.get("dropped"))


def describe(violation):
    """One violation in one line: the rule, its subject, what is wrong, what ran, and where its report is."""
    trigger = violation.get("trigger") or {}
    subject = violation.get("subject") or {}
    where = ", ".join(f"{k} {v}" for k, v in subject.items()) or "app"
    ran = ", ".join(f"{a.get('id')} ({a.get('origin')}) #{a.get('index')}" for a in trigger.get("actions") or [])
    parts = [f"{violation.get('id')} [{violation.get('host', 'app')}] {where}: {violation.get('detail')}",
             f"trigger {trigger.get('kind')}" + (f" after {ran}" if ran else "") + f", turn {trigger.get('turn')}"
             + (f", frame {trigger['frame_seq']}" if trigger.get("frame_seq") is not None else "")]
    if trigger.get("file"):
        parts.append(f"at {trigger['file']}:{trigger.get('line')}")
    if violation.get("report"):
        parts.append(f"report {violation['report']}")
    return "; ".join(parts)


def assert_clean(cursor, step, error, check=False, ipc=False):
    """Raises `error` naming every violation since the last read (and the step), a dropped ledger, or an app that
    stopped checking."""
    try:
        violations, dropped = cursor.new(check=check, ipc=ipc)
    except NotArmed as missing:
        raise error(f"invariants after {step}: {missing}") from missing
    problems = [describe(v) for v in violations]
    if dropped:
        problems.insert(0, "the invariant ledger dropped violations before this read (more than its ring holds)")
    if problems:
        raise error(f"invariants broken after {step}: " + " | ".join(problems))
