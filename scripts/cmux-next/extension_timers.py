"""Which timers wake an extension's background page while nothing happens (p14-energy-108).

Attaches to the extension's DevTools target (an MV2 background page or an MV3 service worker) and sets the
instrumentation breakpoints DevTools' "Event Listener Breakpoints > Timer" uses (EventBreakpoints
.setInstrumentationBreakpoint; Chromium third_party/blink/renderer/core/inspector/inspector_event_breakpoints_agent.cc,
the names of probe::BreakableLocation in core/probe/core_probes.pidl): each `<timer>.callback` pause is one JS wake
of the page, named by the callback's frame; each `<timer>` pause is one arm, named by the stack that armed it (the
owner, OWNER_DEPTH frames). chrome.alarms fire outside the timer probes, so a console marker listener counts them,
and the alarm list is read at the start. Every pause is resumed at once.

The pauses and the CDP traffic wake the extension process too, so this names owners; the rate the budget judges
is idle-budget.py's cef-extension row, measured without a debugger attached.
"""
import time

TIMERS = ("setTimeout", "setInterval", "requestIdleCallback", "requestAnimationFrame")
CALLBACK_SUFFIX = ".callback"
INSTRUMENTATION_PREFIX = "instrumentation:"
OWNER_DEPTH = 3
ALARM_MARK = "cmux-idle-probe-alarm"
ALARM_HOOK = ("(() => { if (!(globalThis.chrome && chrome.alarms)) return false;"
              f" globalThis.__cmuxIdleProbeAlarm = a => console.debug({ALARM_MARK!r}, a.name);"
              " chrome.alarms.onAlarm.addListener(globalThis.__cmuxIdleProbeAlarm); return true; })()")
ALARM_UNHOOK = ("(() => { if (globalThis.__cmuxIdleProbeAlarm) {"
                " chrome.alarms.onAlarm.removeListener(globalThis.__cmuxIdleProbeAlarm);"
                " delete globalThis.__cmuxIdleProbeAlarm; } return true; })()")
ALARM_LIST = ("(globalThis.chrome && chrome.alarms) ? new Promise(done => chrome.alarms.getAll(all => done(all.map(a => ({"
              "name: a.name, period_min: a.periodInMinutes ?? null,"
              " due_s: Math.round((a.scheduledTime - Date.now()) / 1000)}))))) : null")


def background_target(targets, extension_id):
    """The extension's background target in a /json/list: its MV2 background page, else its MV3 service worker."""
    origin = f"chrome-extension://{extension_id}/"
    mine = [t for t in targets if (t.get("url") or "").startswith(origin)]
    for kind in ("background_page", "service_worker"):
        for target in mine:
            if target.get("type") == kind:
                return target
    return None


def frame_where(frame, scripts, extension_id):
    """`path:line function` of a call frame, the path relative to the extension's root."""
    url = scripts.get(frame.get("location", {}).get("scriptId")) or frame.get("url") or "?"
    url = url.removeprefix(f"chrome-extension://{extension_id}/")
    line = frame.get("location", {}).get("lineNumber", -1) + 1
    return f"{url}:{line} {frame.get('functionName') or '(anonymous)'}"


class ExtensionTimerProfile:
    """One extension target's timer fires, arms and alarms over a window. `session` is an ext_e2e.cdp.Session on
    the target; start() before the window, run_until() for it, stop() after."""

    def __init__(self, session, extension_id, clock=time.monotonic):
        self.session, self.extension_id, self.clock = session, extension_id, clock
        self.scripts, self.counts, self.alarms, self.domains = {}, {}, None, {}

    def handle(self, message):
        """Counts one CDP event; a pause is resumed at once."""
        method, params = message.get("method"), message.get("params") or {}
        if method == "Debugger.scriptParsed":
            self.scripts[params.get("scriptId")] = params.get("url") or ""
        elif method == "Debugger.paused":
            event = (params.get("data") or {}).get("eventName", "").removeprefix(INSTRUMENTATION_PREFIX)
            frames = params.get("callFrames") or []
            if event and frames:
                if event.endswith(CALLBACK_SUFFIX):
                    self.add("fire", event.removesuffix(CALLBACK_SUFFIX), self.where(frames[:1]))
                else:
                    self.add("arm", event, self.where(frames[:OWNER_DEPTH]))
            self.session.send("Debugger.resume")
        elif method == "Runtime.consoleAPICalled":
            args = params.get("args") or []
            if len(args) >= 2 and args[0].get("value") == ALARM_MARK:
                self.add("fire", "alarm", str(args[1].get("value")))

    def where(self, frames):
        return " < ".join(frame_where(frame, self.scripts, self.extension_id) for frame in frames)

    def add(self, kind, event, where):
        key = (kind, event, where)
        self.counts[key] = self.counts.get(key, 0) + 1

    def call(self, method, params=None, timeout=15):
        """A command whose events in flight are handled, not dropped (scriptParsed arrives inside Debugger.enable)."""
        request_id = self.session.send(method, params)
        deadline = self.clock() + timeout
        while (left := deadline - self.clock()) > 0:
            message = self.session.receive(left)
            if message is None:
                break
            if message.get("id") == request_id:
                if "error" in message:
                    raise RuntimeError(f"{method}: {message['error'].get('message')}")
                return message.get("result", {})
            self.handle(message)
        raise TimeoutError(f"{method}: no answer in {timeout:g} s")

    def evaluate(self, expression):
        result = self.call("Runtime.evaluate", {"expression": expression, "awaitPromise": True, "returnByValue": True})
        return result.get("result", {}).get("value")

    def breakpoint_names(self):
        return [name + suffix for name in TIMERS for suffix in ("", CALLBACK_SUFFIX)]

    def start(self):
        self.call("Runtime.enable")
        self.call("Debugger.enable")
        for name in self.breakpoint_names():
            # EventBreakpoints works in pages and workers; older builds have only DOMDebugger's (pages).
            for domain in ("EventBreakpoints", "DOMDebugger"):
                try:
                    self.call(f"{domain}.setInstrumentationBreakpoint", {"eventName": name})
                    self.domains[name] = domain
                    break
                except RuntimeError:
                    continue
        self.alarms = self.evaluate(ALARM_LIST)
        self.evaluate(ALARM_HOOK)
        self.counts.clear()  # the start's own evaluations armed nothing of the page's

    def run_until(self, deadline):
        while (left := deadline - self.clock()) > 0:
            message = self.session.receive(left)
            if message is not None:
                self.handle(message)

    def stop(self):
        try:
            self.evaluate(ALARM_UNHOOK)
            for name, domain in self.domains.items():
                self.call(f"{domain}.removeInstrumentationBreakpoint", {"eventName": name})
            self.call("Debugger.disable")
        finally:
            self.session.close()

    def report(self, seconds):
        """Rows highest per_s first, and the totals: fires_per_s (JS wakes: timer callbacks and alarms) and
        arms_per_s."""
        rows = [{"kind": kind, "event": event, "where": where, "count": count, "per_s": round(count / seconds, 4)}
                for (kind, event, where), count in self.counts.items()]
        rows.sort(key=lambda row: (-row["count"], row["kind"], row["event"], row["where"]))
        total = lambda kind: round(sum(r["count"] for r in rows if r["kind"] == kind) / seconds, 4)  # noqa: E731
        missing = [name for name in self.breakpoint_names() if name not in self.domains]
        return {"extension": self.extension_id, "seconds": round(seconds, 2), "fires_per_s": total("fire"),
                "arms_per_s": total("arm"), "alarms": self.alarms, "unwatched": missing, "rows": rows}
