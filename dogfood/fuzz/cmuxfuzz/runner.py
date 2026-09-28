"""Fuzz sessions: generate, run and check steps; on a failure, capture evidence and minimize."""

from __future__ import annotations

import json
import os
import random
import shutil
import signal
import subprocess
import time
from collections import deque
from dataclasses import dataclass, field
from pathlib import Path

from . import actions, oracles
from .app import AppSession, LaunchError
from .cua import CuaDriver, CuaError
from .minimize import ddmin
from .oracles import Failure
from .signature import Signature, crash_signature, hang_signature, memory_signature

SETTLE_S = 0.25
CONFIRM_S = 1.5  # a layout problem must still be there after this long
HEAVY_EVERY = 10  # counters, hang files, memory
FRAMES_KEPT = 8
MEMORY_WARMUP_STEPS = 60
MEMORY_LIMIT_MB = 3000


class Stop(Exception):
    """SIGTERM from the scheduler: a job wants this mini."""


# ------------------------------------------------------------------ pointer


class Pointer:
    """Window-local pointer input through cua-driver, fed AppKit window coordinates (origin bottom-left)."""

    def __init__(self, cua: CuaDriver, session: AppSession, shots: Path):
        self.cua = cua
        self.session = session
        self.shots = shots
        self.window_id: int | None = None
        self.height = 0.0
        self.scale = 1.0

    def refresh(self) -> None:
        win = self.cua.main_window(self.session.pid or 0)
        if not win:
            raise actions.Skip("no on-screen window for cua-driver")
        self.window_id = int(win["window_id"])
        self.height = float(win["bounds"]["height"])
        probe = self.shots / "_pointer_probe.png"
        meta = self.cua.window_shot(self.session.pid or 0, self.window_id, probe, max_dimension=4096)
        width = float(win["bounds"]["width"]) or 1.0
        shot_w = float(meta.get("screenshot_width") or width)
        self.scale = shot_w / width

    def _px(self, point: tuple[float, float]) -> tuple[float, float]:
        # Callers pass top-left window points (Context converts); cua wants screenshot pixels.
        return (round(point[0] * self.scale, 1), round(point[1] * self.scale, 1))

    def drag(self, start: tuple[float, float], end: tuple[float, float], *, ms: int) -> None:
        self.refresh()
        self.cua.call("drag", {
            "pid": self.session.pid, "window_id": self.window_id,
            "from_x": self._px(start)[0], "from_y": self._px(start)[1],
            "to_x": self._px(end)[0], "to_y": self._px(end)[1],
            "duration_ms": ms, "steps": max(6, ms // 25), "delivery_mode": "foreground",
        }, timeout=30)

    def click(self, point: tuple[float, float]) -> None:
        self.refresh()
        x, y = self._px(point)
        self.cua.call("click", {"pid": self.session.pid, "window_id": self.window_id, "x": x, "y": y,
                                "delivery_mode": "foreground"})


# ------------------------------------------------------------------ context


@dataclass
class Context:
    session: AppSession
    cua: CuaDriver | None
    out: Path
    _pointer: Pointer | None = None

    def pointer(self) -> Pointer:
        if self.cua is None:
            raise actions.Skip("pointer actions need cua-driver")
        if self._pointer is None:
            self._pointer = Pointer(self.cua, self.session, self.out)
        return self._pointer

    def _layout(self) -> dict:
        return oracles.debug_layout(self.session.sock)

    def _window_height(self) -> float:
        p = self.pointer()
        p.refresh()
        return p.height

    def pane_geometry(self) -> list[dict]:
        """Visible pane views in top-left window points, with their tab counts."""
        layout = self._layout()
        height = self._window_height()
        tabs = {str(p.get("paneId")): len(p.get("tabIds") or []) for p in (layout.get("layout") or {}).get("panes") or []}
        out = []
        for panel in layout.get("selectedPanels") or []:
            f = panel.get("viewFrame")
            if not f or panel.get("hidden") or not panel.get("inWindow"):
                continue
            out.append({"id": panel.get("paneId"), "x": f["x"], "y": height - (f["y"] + f["height"]),
                        "w": f["width"], "h": f["height"], "tabs": tabs.get(str(panel.get("paneId")), 1)})
        out.sort(key=lambda g: (round(g["y"]), round(g["x"])))
        return out

    @staticmethod
    def tab_point(g: dict, frac: float) -> tuple[float, float]:
        count = max(1, int(g.get("tabs") or 1))
        width = min(200.0, max(40.0, (g["w"] - 40) / count))
        index = min(int(frac * count), count - 1)
        return (g["x"] + 10 + width * (index + 0.5), g["y"] - 14)

    def dividers(self) -> list[dict]:
        layout = self._layout()
        height = self._window_height()
        seen, out = set(), []
        for panel in layout.get("selectedPanels") or []:
            for sv in panel.get("splitViews") or []:
                frame = sv.get("frame")
                arranged = sv.get("arrangedSubviewFrames") or []
                if not frame or len(arranged) < 2:
                    continue
                key = (round(frame["x"]), round(frame["y"]), round(frame["width"]), round(frame["height"]), sv.get("isVertical"))
                if key in seen:
                    continue
                seen.add(key)
                a, b = arranged[0], arranged[1]
                if sv.get("isVertical"):
                    left, right = (a, b) if a["x"] <= b["x"] else (b, a)
                    x = (left["x"] + left["width"] + right["x"]) / 2
                    mid_y = frame["y"] + frame["height"] / 2
                    out.append({"vertical": True, "x": x, "mid": height - mid_y, "extent": frame["width"]})
                else:
                    low, high = (a, b) if a["y"] <= b["y"] else (b, a)
                    y = (low["y"] + low["height"] + high["y"]) / 2
                    out.append({"vertical": False, "y": height - y, "mid": frame["x"] + frame["width"] / 2,
                                "extent": frame["height"]})
        out.sort(key=lambda d: (d["vertical"], round(d.get("x", 0)), round(d.get("y", 0))))
        return out


# ------------------------------------------------------------------ session


@dataclass
class StepRecord:
    index: int
    step: dict
    outcome: str
    note: str = ""
    seconds: float = 0.0


@dataclass
class SessionResult:
    steps: list[StepRecord] = field(default_factory=list)
    failure: Failure | None = None
    failed_step: int | None = None
    stopped: bool = False


class Checker:
    """Runs the oracles after a step. Keeps the state they compare against."""

    def __init__(self, session: AppSession, disabled: set[str] | None = None):
        self.session = session
        self.disabled = disabled if disabled is not None else set()
        self.counters: dict[str, int] = {}
        self.rss: list[float] = []
        self.check_started = time.time()

    def baseline(self) -> None:
        self.counters = oracles.counters(self.session.sock)
        self.check_started = time.time()
        # Oracles that already fail on a fresh app are wrong about this build; turn them off.
        try:
            for name, detail in oracles.check_layout(self.session.sock):
                self.disabled.add(name)
        except Exception:  # noqa: BLE001
            pass

    def after_step(self, index: int, since: float) -> Failure | None:
        s = self.session
        if not s.alive():
            return self.crash_failure(since)
        elapsed, why = oracles.heartbeat(s.sock)
        if elapsed is None:
            if not s.alive():
                return self.crash_failure(since)
            return self.hang_failure(why)
        log_fail = oracles.scan_log(s.new_log_lines())
        if log_fail and log_fail.signature.key not in self.disabled:
            return log_fail
        time.sleep(SETTLE_S)
        problems = [p for p in self._layout_problems() if p[0] not in self.disabled]
        if problems:
            time.sleep(CONFIRM_S)
            again = {name for name, _ in self._layout_problems()}
            problems = [p for p in problems if p[0] in again]
            failure = oracles.first_problem(problems)
            if failure:
                return failure
        if index % HEAVY_EVERY == 0:
            now = oracles.counters(s.sock)
            failure = oracles.counter_failure(self.counters, now)
            self.counters = now
            if failure and failure.signature.key not in self.disabled:
                return failure
            hangs = s.hang_samples_since(self.check_started)
            if hangs:
                return Failure(hang_signature(hangs[-1].read_text(errors="replace")),
                               f"the app's own hang watchdog captured {hangs[-1].name}",
                               {"sample": str(hangs[-1])})
            rss = s.rss_mb()
            if rss is not None:
                self.rss.append(rss)
                if (index > MEMORY_WARMUP_STEPS and rss > MEMORY_LIMIT_MB
                        and self.rss and rss > 3 * min(self.rss)):
                    return Failure(memory_signature(f"{min(self.rss):.0f} MB -> {rss:.0f} MB"),
                                   f"RSS {rss:.0f} MB after {index} steps")
        return None

    def _layout_problems(self) -> list[tuple[str, str]]:
        try:
            return oracles.check_layout(self.session.sock)
        except Exception as error:  # noqa: BLE001 - the heartbeat judges liveness, not this
            return [("layout-query-failed", f"{type(error).__name__}: {error}")] \
                if "layout-query-failed" not in self.disabled else []

    def crash_failure(self, since: float) -> Failure:
        report = self.session.wait_for_crash_report(since)
        if report is None:
            return Failure(Signature("crash", "exited-without-report", "The app exited without a crash report"),
                           "process gone, no .ips within 20 s")
        return Failure(crash_signature(report), report.name, {"crash_report": str(report)})

    def hang_failure(self, why: str) -> Failure:
        dest = self.session.workdir / f"hang-{int(time.time())}.sample.txt"
        path = self.session.sample(dest)
        text = path.read_text(errors="replace") if path else ""
        sig = hang_signature(text) if text else Signature("hang", "no-sample", "Main thread hang (no sample)")
        return Failure(sig, why, {"sample": str(path) if path else ""})


def run_steps(ctx: Context, steps: list[dict], *, checker: Checker, shots: deque | None = None,
              deadline: float | None = None, on_step=None, keep_all_frames: bool = False) -> SessionResult:
    """Run `steps` in order; stop at the first failure."""
    result = SessionResult()
    executor = actions.Executor(ctx)
    for index, step in enumerate(steps, start=1):
        if deadline is not None and time.monotonic() > deadline:
            break
        started = time.time()
        t0 = time.monotonic()
        outcome, note = "ok", ""
        try:
            note = executor.run(step)
        except actions.Skip as error:
            outcome, note = "skip", str(error)
        except actions.SocketError as error:
            outcome, note = "error", str(error)[:300]
        except actions.SocketTimeout as error:
            outcome, note = "timeout", str(error)
        except CuaError as error:
            outcome, note = "pointer-error", str(error)[:300]
        except OSError as error:
            outcome, note = "io-error", f"{type(error).__name__}: {error}"
        record = StepRecord(index, step, outcome, note, round(time.monotonic() - t0, 3))
        result.steps.append(record)
        if shots is not None:
            _shot(ctx, shots, index, keep_all=keep_all_frames)
        failure = checker.after_step(index, started)
        if on_step:
            on_step(record, failure)
        if failure:
            result.failure, result.failed_step = failure, index
            break
    return result


def _shot(ctx: Context, ring: deque, index: int, *, keep_all: bool = False) -> None:
    path = ctx.out / "frames" / f"step-{index:05d}.png"
    try:
        if ctx.cua is not None and ctx.session.pid:
            p = ctx.pointer()
            if p.window_id is None:
                p.refresh()
            ctx.cua.window_shot(ctx.session.pid, p.window_id, path, max_dimension=1280)
        else:
            reply = ctx.session.sock.call("debug.window.screenshot", {"label": f"step-{index}"}, timeout=8)
            if reply.get("path"):
                shutil.copyfile(reply["path"], path)
    except Exception:  # noqa: BLE001 - frames are evidence, never a failure
        return
    ring.append(path)
    while not keep_all and len(ring) > FRAMES_KEPT:
        old = ring.popleft()
        try:
            old.unlink()
        except OSError:
            pass


# ------------------------------------------------------------------ top level


class Fuzzer:
    def __init__(self, *, app: Path, out: Path, seed: int, area_weights: dict[str, float],
                 use_pointer: bool = True, tag: str = "fuzz", log=print):
        self.app = app
        self.out = out
        self.seed = seed
        self.weights = area_weights
        self.tag = tag
        self.log = log
        out.mkdir(parents=True, exist_ok=True)
        (out / "frames").mkdir(exist_ok=True)
        self.cua = CuaDriver() if use_pointer else None
        if self.cua is not None and not self.cua.available():
            self.log("cua-driver not found: pointer actions off")
            self.cua = None
        if self.cua is not None:
            try:
                self.cua.ensure_daemon()
            except (CuaError, OSError, subprocess.SubprocessError) as error:
                self.log(f"cua-driver daemon unavailable ({error}): pointer actions off")
                self.cua = None
        self.stopping = False
        signal.signal(signal.SIGTERM, self._on_term)
        signal.signal(signal.SIGINT, self._on_term)

    def _on_term(self, signum, frame):
        self.stopping = True
        raise Stop()

    def new_session(self, workdir: Path) -> tuple[AppSession, Context]:
        session = AppSession(self.app, tag=self.tag, workdir=workdir)
        session.launch()
        return session, Context(session, self.cua, workdir)

    def fuzz(self, minutes: float, *, steps_per_session: int = 400, max_findings: int = 5,
             minimize_minutes: float = 20.0) -> dict:
        """Fuzz until the time is up. Every failure is captured and minimized, then fuzzing goes on
        with the next session seed."""
        deadline = time.monotonic() + minutes * 60
        rng = random.Random(self.seed)
        summary = {"seed": self.seed, "sessions": 0, "steps": 0, "findings": [], "stopped": False}
        seen: set[str] = set()
        try:
            while time.monotonic() < deadline and len(summary["findings"]) < max_findings:
                session_seed = rng.randrange(1 << 31)
                srng = random.Random(session_seed)
                planned = [actions.generate(srng, self.weights, pointer=self.cua is not None)
                           for _ in range(steps_per_session)]
                workdir = self.out / f"session-{summary['sessions']:03d}"
                workdir.mkdir(exist_ok=True)
                (workdir / "frames").mkdir(exist_ok=True)
                summary["sessions"] += 1
                result = self._run_session(workdir, planned, deadline)
                summary["steps"] += len(result.steps)
                if result.failure is None:
                    continue
                sig = result.failure.signature
                self.log(f"failure at step {result.failed_step}: {sig.title} [{sig.digest}]")
                if sig.digest in seen:
                    continue
                seen.add(sig.digest)
                finding = self._capture(workdir, session_seed, planned, result, minimize_minutes)
                summary["findings"].append(finding["path"])
        except Stop:
            summary["stopped"] = True
        finally:
            self._cleanup()
        (self.out / "summary.json").write_text(json.dumps(summary, indent=1))
        return summary

    def _run_session(self, workdir: Path, steps: list[dict], deadline: float) -> SessionResult:
        try:
            session, ctx = self.new_session(workdir)
        except LaunchError as error:
            r = SessionResult()
            r.failure = Failure(Signature("launch", "launch-failed", "The app did not start"), str(error))
            r.failed_step = 0
            return r
        self._session = session
        checker = Checker(session)
        checker.baseline()
        ring: deque = deque()
        log_path = workdir / "steps.jsonl"
        result: SessionResult | None = None
        with open(log_path, "w") as log:
            def on_step(record: StepRecord, failure: Failure | None) -> None:
                log.write(json.dumps({"i": record.index, "step": record.step, "outcome": record.outcome,
                                      "note": record.note, "s": record.seconds,
                                      "failure": failure.signature.to_json() if failure else None}) + "\n")
                log.flush()
            try:
                result = run_steps(ctx, steps, checker=checker, shots=ring, deadline=deadline, on_step=on_step)
            finally:
                self._evidence(session, workdir, result)
                session.stop()
        (workdir / "disabled-oracles.json").write_text(json.dumps(sorted(checker.disabled)))
        return result

    def _evidence(self, session: AppSession, workdir: Path, result: SessionResult | None) -> None:
        if result is None or result.failure is None:
            return
        session.copy_debug_log_tail(workdir / "debug.log")
        if session.alive() and result.failure.signature.kind != "hang":
            session.sample(workdir / "sample.txt", seconds=2)
        report = result.failure.evidence.get("crash_report")
        if report and Path(report).exists():
            shutil.copyfile(report, workdir / Path(report).name)
        if self.cua is not None:
            try:
                self.cua.desktop_shot(workdir / "desktop.png")
            except Exception:  # noqa: BLE001
                pass

    def reproduces(self, steps: list[dict], want: Signature, workdir: Path) -> bool:
        workdir.mkdir(parents=True, exist_ok=True)
        (workdir / "frames").mkdir(exist_ok=True)
        try:
            session, ctx = self.new_session(workdir)
        except LaunchError:
            return want.kind == "launch"
        try:
            checker = Checker(session)
            checker.baseline()
            result = run_steps(ctx, steps, checker=checker)
            return result.failure is not None and want.same_bug(result.failure.signature)
        finally:
            session.stop()

    def _capture(self, workdir: Path, session_seed: int, planned: list[dict], result: SessionResult,
                 minimize_minutes: float) -> dict:
        sig = result.failure.signature
        prefix = planned[: result.failed_step]
        self.log(f"minimizing {len(prefix)} steps (budget {minimize_minutes:g} min)")
        attempts = workdir / "minimize"
        counter = {"n": 0}

        def check(candidate: list[dict]) -> bool:
            counter["n"] += 1
            return self.reproduces(candidate, sig, attempts / f"try-{counter['n']:03d}")

        # First: does the plain prefix reproduce at all? A flaky failure is kept unminimized.
        if check(prefix):
            mini = ddmin(prefix, check, max_replays=80, deadline=time.monotonic() + minimize_minutes * 60)
            steps, exhausted, reproducible = mini.steps, mini.exhausted, True
            (workdir / "minimize.log").write_text("\n".join(mini.log))
        else:
            steps, exhausted, reproducible = prefix, True, False
        shutil.rmtree(attempts, ignore_errors=True)
        replayed = self.record_repro(steps, sig, workdir / "repro") if reproducible else None
        finding = {
            "kind": "cmux-fuzz-finding",
            "version": 1,
            "signature": sig.to_json(),
            "detail": result.failure.detail,
            "seed": self.seed,
            "session_seed": session_seed,
            "failed_step": result.failed_step,
            "total_steps": len(result.steps),
            "reproducible": reproducible,
            "minimize_exhausted": exhausted,
            "repro_steps": steps,
            "repro_name": f"{sig.kind}-{sig.digest}",
            "repro_replayed": replayed,
            "path": str(workdir),
        }
        (workdir / "finding.json").write_text(json.dumps(finding, indent=1))
        repro = {"kind": "cmux-fuzz-repro", "version": 1, "signature": sig.to_json(), "steps": steps}
        (workdir / "repro.json").write_text(json.dumps(repro, indent=1))
        return finding

    def record_repro(self, steps: list[dict], want: Signature, workdir: Path) -> bool:
        """Replay the minimized repro once more with a frame before the first step and after every step
        (workdir/frames/step-00000.png ...), for the issue. True when it failed the same way again."""
        workdir.mkdir(parents=True, exist_ok=True)
        (workdir / "frames").mkdir(exist_ok=True)
        try:
            session, ctx = self.new_session(workdir)
        except LaunchError:
            return want.kind == "launch"
        try:
            checker = Checker(session)
            checker.baseline()
            ring: deque = deque()
            _shot(ctx, ring, 0, keep_all=True)
            result = run_steps(ctx, steps, checker=checker, shots=ring, keep_all_frames=True)
            (workdir / "steps.json").write_text(json.dumps(
                [{"i": r.index, "step": r.step, "outcome": r.outcome, "note": r.note} for r in result.steps], indent=1))
            return result.failure is not None and want.same_bug(result.failure.signature)
        finally:
            session.stop()

    def _cleanup(self) -> None:
        session = getattr(self, "_session", None)
        if session is not None:
            session.stop()


def replay(app: Path, repro: dict, out: Path, *, use_pointer: bool = True, tag: str = "fuzz") -> SessionResult:
    fz = Fuzzer(app=app, out=out, seed=0, area_weights={}, use_pointer=use_pointer, tag=tag)
    session, ctx = fz.new_session(out)
    try:
        checker = Checker(session)
        checker.baseline()
        ring: deque = deque()
        return run_steps(ctx, repro["steps"], checker=checker, shots=ring)
    finally:
        fz._evidence(session, out, None)
        session.stop()


def env_flag(name: str) -> bool:
    return os.environ.get(name, "") not in ("", "0", "false")
