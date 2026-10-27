#!/usr/bin/env python3
"""Story launch-restore (p12-perf-process.md 3.8, task p12-perf-process-121): a session of 60 workspaces restored at
launch, cold and warm, timed to the first live terminal frame and the live sidebar rows.

    python3 -I scripts/perf-lab/corpus/launch_restore.py write   # perf-corpus/launch-restore{.json,/layout.json}
    python3 -I scripts/perf-lab/corpus/launch_restore.py check   # both files are what `write` makes

The story has no input track: what it measures is a launch, so its runner is the launch bench, not play.py.

    scripts/cmux-next/bench-startup.py --corpus perf-corpus/launch-restore.json --mode cold --purge --app APP --out DIR
    scripts/cmux-next/bench-startup.py --corpus perf-corpus/launch-restore.json --mode warm --app APP --out DIR

Every launch of the story, seeding and measured, gets one window and config (`launch_env`, `launch_config`): the
bench window size on the main display and the bench minimum pane size, which session_io.import_layout uses.
Seeding (once per layout digest, `seed`): a fresh bench launch (bench_launch.BenchApp, the bench environment play.py
uses) imports the layout snapshot through the action pipeline (session_io.import_layout), its settled `debug.focus`
and `debug.surfaces` digests are read (the state at quit), and the app quits as a person's Quit that keeps sessions.
Each measured launch then restores that session; before it quits, its window goes where seeding left it
(`place_window`) and its settled digests are read again. A launch whose restored digests differ from the story's
`restored` checkpoint (the recorded digests, else the state at quit) did not restore the session it was given:
bench-startup counts it in `<root>.<mode>.checkpoint_mismatch_runs` and fails.
Chrome checks its session restore the same way: the restored browser must hold the tabs and the selection that were
saved (chrome/browser/sessions/session_restore_browsertest.cc), and its startup benchmark restores a recorded
session before it times the launch (tools/perf/benchmarks/startup_mobile.py, `--restore-session`).

The digests are play.py's (task 115): `read_checkpoint`, `focus_digest` and `surfaces_digest`, so `play.py --verify
launch-restore` (the layout imported, the checkpoint compared at t 0) and every restored launch judge one state.
`--capture` (bench-startup) writes the digests into the manifest, which becomes `recorded`, only when the state at
quit and every restored launch agree.

The layout is terminals only, so the first live terminal frame is a terminal of the shown workspace and no Chromium
or agent process is part of the launch: the shown workspace (the last one, as STRESS shows its last) is a 2 x 2 grid
of panes with two terminal tabs each, 20 other workspaces have two terminals side by side, and the other 39 have
one pane of one or two terminal tabs (106 terminals). Every value is generated here, so the files hold no user data.

Stdlib only; runs under python3 -I. Tests: python3 -m unittest scripts/perf-lab/tests/test_corpus_launch_restore.py
"""
from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import sys
import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
LAB = HERE.parent
REPO_ROOT = LAB.parents[1]

STORY_ID = "launch-restore"
MANIFEST_PATH = f"perf-corpus/{STORY_ID}.json"
LAYOUT_PATH = f"perf-corpus/{STORY_ID}/layout.json"
WORKSPACES = 60
SPLIT_WORKSPACES = 20       # side-by-side pairs of terminals, besides the shown workspace
CHECKPOINT = "restored"
CHECKPOINT_SETTLE_S = 5.0   # play.py's settle: how long a launch may take to reach the checkpoint's state
CHECKPOINT_POLL_S = 0.25
MARKS = ("first_terminal_frame", "sidebar_rows_shown")  # the launch waits for both
WINDOW_SCREEN = "0"         # CMUX_NEXT_TEST_WINDOW_SCREEN: the main display, where import_layout places the window


class LaunchRestoreError(RuntimeError):
    """The manifest is not a launch story, a module it needs is missing, or seeding failed."""


def _load(name: str, path: Path):
    """The module at `path` as `name`, once per process (play.py and bench-startup share these names)."""
    if name in sys.modules:
        return sys.modules[name]
    if not path.is_file():
        raise LaunchRestoreError(f"{path.relative_to(REPO_ROOT)} is missing")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module  # before exec: dataclasses resolve their module through sys.modules
    try:
        spec.loader.exec_module(module)
    except BaseException:
        del sys.modules[name]
        raise
    return module


def corpus_manifest():
    return _load("perf_lab_corpus_manifest", HERE / "manifest.py")


def session_io():
    return _load("perf_lab_corpus_session_io", HERE / "session_io.py")


def player():
    """play.py (task 115): the checkpoint digests are its functions, so a replay and a restore judge one state."""
    try:
        return _load("perf_lab_corpus_play", HERE / "play.py")
    except LaunchRestoreError as error:
        raise LaunchRestoreError(f"{error} (task 115): the checkpoint digests are its focus_digest and "
                                 "surfaces_digest") from error


def bench_launch():
    return _load("bench_launch", REPO_ROOT / "scripts" / "cmux-next" / "bench_launch.py")


# ---------------------------------------------------------------- the generated files

def _pane(tabs: int, selected: int = 0) -> dict[str, Any]:
    return {"tabs": ["terminal"] * tabs, "selected": selected}


def layout_snapshot() -> dict[str, Any]:
    """The 60-workspace layout (module docstring), at the bench window size session_io.import_layout needs."""
    workspaces = []
    for index in range(WORKSPACES - 1):
        if index < SPLIT_WORKSPACES:
            tree = {"split": "right", "children": [_pane(1), _pane(1)]}
        else:
            tabs = 2 if index % 2 else 1
            tree = _pane(tabs, selected=tabs - 1)  # a second tab is the selected one: the restore keeps it
        workspaces.append({"even": True, "tree": tree})
    grid = {"split": "right", "children": [{"split": "down", "children": [_pane(2), _pane(2, selected=1)]},
                                           {"split": "down", "children": [_pane(2, selected=1), _pane(2)]}]}
    workspaces.append({"even": True, "tree": grid})
    window = list(session_io().load_stress().WINDOW_SIZE)
    return session_io().check({"schema": session_io().SCHEMA, "window": window, "workspaces": workspaces,
                               "shown": WORKSPACES - 1, "focused_pane": 0, "busy": []})


def _metric_root(story_id: str) -> str:
    return "corpus." + story_id.replace("-", "_")


def build_manifest(layout_ref: Mapping[str, Any], checkpoint: Mapping[str, Any] | None = None) -> dict[str, Any]:
    """The manifest for the layout file `layout_ref` ({path, sha256, bytes}); recorded when `checkpoint` has both
    digests, planned otherwise."""
    focus = (checkpoint or {}).get("focus")
    surfaces = (checkpoint or {}).get("surfaces")
    recorded = focus is not None and surfaces is not None
    root = _metric_root(STORY_ID).replace(".", "\\.")
    doc: dict[str, Any] = {"schema": "cmux-perf-corpus-story/v1", "id": STORY_ID, "tier": "T1",
                           "status": "recorded" if recorded else "planned"}
    if not recorded:
        doc["planned"] = ("Generated by scripts/perf-lab/corpus/launch_restore.py (task 121). `bench-startup.py "
                          "--corpus perf-corpus/launch-restore.json --capture` on a lab host adds the restored "
                          "checkpoint's digests once the state at quit and every restored launch agree.")
    doc.update({
        "description": ("Restore 60 workspaces of terminals (106 terminals, a 2 x 2 grid shown) at launch, cold and "
                        "warm, to the first live terminal frame and the live sidebar rows; no input. Its runner is "
                        "scripts/cmux-next/bench-startup.py --corpus."),
        "owner": "PL-perf-lab",
        "duration_ms": 1,
        "layout": {"snapshot": dict(layout_ref), "workspaces": WORKSPACES},
        "input": {"events": []},
        "pty": [],
        "web_archive": None,
        "agents": [],
        "checkpoints": [{"t_ms": 0, "name": CHECKPOINT, "focus": focus, "surfaces": surfaces}],
        "metrics": [
            {"name": f"{root}\\.(cold|warm)\\.(first_window_frame_committed|first_terminal_frame|"
                     "did_finish_launching_end|sidebar_rows_shown)", "unit": "ms", "better": "lower"},
            {"name": f"{root}\\.(cold|warm)\\.[a-z_]+\\.missing_runs", "unit": "count", "better": "lower"},
            {"name": f"{root}\\.(cold|warm)\\.checkpoint_mismatch_runs", "unit": "count", "better": "lower"},
            {"name": f"{root}\\.cold\\.not_cold_runs", "unit": "count", "better": "lower"},
        ],
    })
    return doc


def manifest_bytes(doc: Mapping[str, Any]) -> bytes:
    return (json.dumps(doc, indent=2) + "\n").encode()


def generated_files(root: Path = REPO_ROOT) -> dict[str, bytes]:
    """{repository path: bytes} of the layout and the manifest. A recorded checkpoint of the manifest in `root` is
    kept while the layout it was recorded on is unchanged."""
    layout = session_io().canonical_bytes(layout_snapshot())
    ref = corpus_manifest().blob_ref(layout)
    ref = {"path": LAYOUT_PATH, "sha256": ref["sha256"], "bytes": ref["bytes"]}
    checkpoint = None
    try:
        existing = json.loads((root / MANIFEST_PATH).read_text(encoding="utf-8"))
        if (existing.get("layout") or {}).get("snapshot") == ref:
            checkpoint = next((c for c in existing.get("checkpoints") or [] if c.get("name") == CHECKPOINT), None)
    except (OSError, ValueError):
        pass
    return {LAYOUT_PATH: layout, MANIFEST_PATH: manifest_bytes(build_manifest(ref, checkpoint))}


def stale_files(root: Path = REPO_ROOT) -> list[str]:
    """The generated files whose committed bytes differ from what `write` makes."""
    stale = []
    for path, data in generated_files(root).items():
        try:
            current = (root / path).read_bytes()
        except OSError:
            current = None
        if current != data:
            stale.append(path)
    return stale


def write_files(root: Path = REPO_ROOT) -> list[str]:
    written = []
    for path, data in generated_files(root).items():
        (root / path).parent.mkdir(parents=True, exist_ok=True)
        (root / path).write_bytes(data)
        written.append(path)
    return written


# ---------------------------------------------------------------- the launch story at run time

@dataclass(frozen=True)
class Story:
    """A loaded launch story: its manifest, the layout snapshot and the `restored` checkpoint's recorded digests."""
    path: Path
    manifest: dict[str, Any]
    snapshot: dict[str, Any]

    @property
    def id(self) -> str:
        return self.manifest["id"]

    @property
    def session(self) -> str:
        return f"corpus:{self.id}"

    @property
    def metric_root(self) -> str:
        return _metric_root(self.id)

    @property
    def layout_sha(self) -> str:
        return self.manifest["layout"]["snapshot"]["sha256"]

    @property
    def recorded(self) -> dict[str, str] | None:
        """The `restored` checkpoint's digests when the story is recorded, else None."""
        checkpoint = next(c for c in self.manifest["checkpoints"] if c["name"] == CHECKPOINT)
        if checkpoint["focus"] is None or checkpoint["surfaces"] is None:
            return None
        return {"focus": checkpoint["focus"], "surfaces": checkpoint["surfaces"]}


def load(path: str | Path, root: Path = REPO_ROOT) -> Story:
    """The launch story at `path`: a valid manifest (manifest.py) with nothing to replay while the app launches (no
    input, PTY, agent or web tracks), one `restored` checkpoint, and a layout snapshot in the repository."""
    path = Path(path)
    corpus = corpus_manifest()
    try:
        doc = json.loads((path if path.is_absolute() else root / path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise LaunchRestoreError(f"{path}: {error}") from error
    # The schema and vocabulary are this checkout's; the sources are under `root`.
    errors = corpus.validation_errors(doc, root=root, schema=corpus.load_schema(), vocabulary=corpus.load_vocabulary())
    if errors:
        raise LaunchRestoreError(f"{path}: " + "; ".join(errors[:6]))
    if doc["input"] != {"events": []} or doc["pty"] or doc["agents"] or doc["web_archive"] is not None:
        raise LaunchRestoreError(f"{path}: a launch story replays nothing while the app launches (no input, PTY, "
                                 "agent or web tracks)")
    if [c["name"] for c in doc["checkpoints"]] != [CHECKPOINT]:
        raise LaunchRestoreError(f"{path}: a launch story has one checkpoint, {CHECKPOINT!r}")
    ref = doc["layout"]["snapshot"]
    if ref is None or "path" not in ref:
        raise LaunchRestoreError(f"{path}: the layout snapshot is a repository file")
    io = session_io()
    try:
        snapshot = io.read(root / ref["path"])  # its digest is checked against the manifest by validation_errors
    except (OSError, ValueError, io.LayoutSnapshotError) as error:
        raise LaunchRestoreError(f"{ref['path']}: {error}") from error
    if len(snapshot["workspaces"]) != doc["layout"]["workspaces"]:
        raise LaunchRestoreError(f"{ref['path']}: {len(snapshot['workspaces'])} workspaces, the manifest says "
                                 f"{doc['layout']['workspaces']}")
    problems = io.importable(snapshot)
    if problems:
        raise LaunchRestoreError(f"{ref['path']}: " + "; ".join(problems[:4]))
    return Story(path, doc, snapshot)


def read_digests(read: Callable[[str], Any], play: Any = None) -> dict[str, str]:
    """{focus, surfaces}: play.py's checkpoint digests of the app behind `read` (one request by method name)."""
    play = play or player()
    try:
        focus, surfaces, order = play.read_checkpoint(read)
    except play.PlayError as error:
        raise LaunchRestoreError(f"checkpoint read: {error}") from error
    return {"focus": play.focus_digest(focus, order), "surfaces": play.surfaces_digest(surfaces)}


def settled_digests(read: Callable[[str], Any], want: Mapping[str, str] | None = None, *,
                    settle_s: float = CHECKPOINT_SETTLE_S, digests: Callable[[Callable[[str], Any]], dict] = read_digests,
                    now: Callable[[], float] = time.monotonic, sleep: Callable[[float], None] = time.sleep
                    ) -> dict[str, str]:
    """The digests once the app's state settles, as play.py's checkpoint reads them: with `want`, the first read equal
    to it, else the last read when `settle_s` passed; without, the first read equal to the one before it (a state
    that held for one poll), else the last read."""
    deadline = now() + settle_s
    previous = None
    while True:
        got = digests(read)
        if (want is not None and got == dict(want)) or (want is None and got == previous):
            return got
        if now() >= deadline:
            return got
        previous = got
        sleep(CHECKPOINT_POLL_S)  # the app reaches the state on its own turns; play.py polls the same way


# ---------------------------------------------------------------- one window and config for every launch

def launch_window() -> tuple[int, int, int, int]:
    """CMUX_NEXT_TEST_WINDOW_FRAME of every launch of the story (x, y, w, h from the top-left of the visible frame):
    the bench window size (perf-stress-session.py WINDOW_SIZE) that session_io.import_layout gives the window."""
    width, height = session_io().load_stress().WINDOW_SIZE
    return 0, 0, width, height


def launch_env() -> dict[str, str]:
    """The window variables of every launch of the story, seeding and measured: the launch window on the main
    display (WINDOW_SCREEN), where import_layout places it. An isolated launch with no frame would open 1100x720 on
    the last screen (TestWindowPlacement.defaultSize) and ignore the saved frame, so no pane would have its size at
    quit."""
    return {"CMUX_NEXT_TEST_WINDOW_FRAME": ",".join(str(value) for value in launch_window()),
            "CMUX_NEXT_TEST_WINDOW_SCREEN": WINDOW_SCREEN}


def launch_config() -> dict[str, Any]:
    """The cmux-next.json of every launch of the story: the bench minimum pane size (perf-stress-session.py
    MINIMUM_PANE) that import_layout sets in the seeding app, nested as the config file holds it."""
    config: dict[str, Any] = {}
    for key, value in session_io().load_stress().MINIMUM_PANE.items():
        *parents, leaf = key.split(".")
        node = config
        for part in parents:
            node = node.setdefault(part, {})
        node[leaf] = value
    return config


def place_window(rpc: Callable[..., Any]) -> dict[str, Any]:
    """Puts a restored launch's window where seeding left it (perf-stress-session.py place_window, the call
    import_layout makes), so its checkpoint is read at the seeding's window frame: a display whose visible frame is
    under WINDOW_SIZE clamps an isolated launch's frame, and place_window does not. Returns the debug.window_frame
    reply; LaunchRestoreError when the display cannot hold the window."""
    reply, problem = session_io().load_stress().place_window(rpc)
    if problem:
        raise LaunchRestoreError(f"window: {problem}")
    return reply


def seeding_bench(app: str, out: Path):
    """The seeding launch: a bench launch (bench_launch.BenchApp) with the story's window and config, which every
    measured launch gets too (launch_env, launch_config). It keeps the tag's daemons when it stops."""
    return bench_launch().BenchApp(app, out=str(out), teardown=False, log_name="app-seed.log", window=launch_window(),
                                   screen=WINDOW_SCREEN, config=launch_config())


def seed(story: Story, app: str, out: str | Path, *, bench_factory: Callable[..., Any] | None = None,
         importer: Callable[[Callable[..., Any], Mapping[str, Any]], Any] | None = None,
         digests: Callable[[Callable[[str], Any]], dict] = read_digests) -> dict[str, str]:
    """Imports the story's layout into a fresh bench launch of `app` and quits it keeping its sessions (the daemon,
    its terminals and the saved session stay). Returns the settled digests of the state at quit. The caller has
    emptied the tag's state; the bench's own launch refuses a tag that still runs."""
    bench = (bench_factory or seeding_bench)(app, Path(out))
    builder = None
    try:
        bench.launch(validate_host=False)  # bench_launch.LaunchError when the app does not come up
        io = session_io()
        try:
            builder = (importer or io.import_layout)(bench.rpc, story.snapshot)
        except io.LayoutSnapshotError as error:
            raise LaunchRestoreError(f"layout import: {error}") from error
        at_quit = settled_digests(lambda method: bench.rpc(method), digests=digests)
        quit_state = bench.quit_keep_sessions()
        if not quit_state.get("quit"):
            raise LaunchRestoreError(f"the seeding launch did not quit: {quit_state.get('error')}")
        return at_quit
    finally:
        if builder is not None and callable(getattr(builder, "close", None)):
            builder.close()
        bench.stop()  # nothing when it already quit; never the daemons (teardown=False)


def capture(story: Story, digests: Mapping[str, str]) -> Path:
    """Writes `digests` as the story's `restored` checkpoint: the manifest becomes recorded. Refuses a story that is
    recorded already with other digests (a changed restore is a regression to look at, never a new recording)."""
    recorded = story.recorded
    if recorded is not None and recorded != dict(digests):
        raise LaunchRestoreError(f"{story.path}: recorded with other digests; a different restore is not recorded "
                                 "over them")
    doc = copy.deepcopy(story.manifest)
    doc.pop("planned", None)
    doc["status"] = "recorded"
    for checkpoint in doc["checkpoints"]:
        if checkpoint["name"] == CHECKPOINT:
            checkpoint.update(focus=digests["focus"], surfaces=digests["surfaces"])
    errors = corpus_manifest().validation_errors(doc, root=REPO_ROOT)
    if errors:
        raise LaunchRestoreError("the recorded manifest is invalid: " + "; ".join(errors[:4]))
    target = story.path if story.path.is_absolute() else REPO_ROOT / story.path
    target.write_bytes(manifest_bytes(doc))
    return target


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("command", choices=["write", "check"])
    opts = parser.parse_args(argv)
    if opts.command == "write":
        for path in write_files():
            print(f"wrote {path}")
        return 0
    stale = stale_files()
    for path in stale:
        print(f"{path}: not what `launch_restore.py write` makes; run it and commit the result", file=sys.stderr)
    if not stale:
        print(f"ok: {MANIFEST_PATH} and {LAYOUT_PATH}")
    return 1 if stale else 0


if __name__ == "__main__":
    sys.exit(main())
