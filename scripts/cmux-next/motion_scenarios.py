"""The timed motion scenarios of the rendering program's done checks DC2t and DC3
(plans/cmux-next/chrome-parity/p03-rendering.md, section 5), for motion-hitches.py. Each scenario name and step
name is a scenario row of the counting bench (motion-main-work.py; its self-test checks it), so the count report
and the time report join by name.

A scenario is a pair of steps that leaves the session as it found it (Cmd-D then Cmd-W, hide then show), with an
untimed `prepare` before the pair, an untimed `check` after it (what the pair must leave: the band closed, the card
hidden) and an untimed `cleanup` last. A step is one input and nothing else: a key chord through `debug.key` (the
person's key path, for the Ghostty-default chords), an action through `action.run`, or a synthesized pointer move
through `debug.mouse`. TIMED_METHODS names those three; a timed pass sends nothing else, so no probe
(`debug.frames`, `debug.window_record`, `debug.wakeups`, RenderStats) runs in the app while it is timed.

Each step has `settle_s`, the time its pass waits before the next step (the spring lands inside it), and
`motion_s`, the length of the motion it starts (the spring's nominal time to rest): a timing bench reads frames
in [input, input + motion_s] and hitches in [input, input + settle_s].

Load by path (the benches run under `python3 -I`):

    spec = importlib.util.spec_from_file_location("motion_scenarios", os.path.join(HERE, "motion_scenarios.py"))
    scenarios = importlib.util.module_from_spec(spec); spec.loader.exec_module(scenarios)
    for scenario in scenarios.select(names): ...
"""
import dataclasses
import time

# The only methods a timed pass sends: the inputs themselves.
TIMED_METHODS = frozenset({"debug.key", "action.run", "debug.mouse"})

SPRING_MOTION_S = 0.6  # MotionSpring tokens rest in under 0.6 s (anim-perf-terminal.py)
SPRING_SETTLE_S = 1.0
HOVER_CARD_SETTLE_S = 1.8  # the hover card's open delay, then its fade
BAND_SETTLE_S = 1.2  # CollapsedBandReveal.closeDelay (300 ms) and the band's spring
PREPARE_SETTLE_S = 0.6  # an untimed prepare's change lands before a recording starts
BAND_POINT = (90.0, 12.0)  # window point (top-left) over the collapsed band's corner: motion-main-work.py --band-point


class ScenarioError(RuntimeError):
    """A scenario cannot run in this session (no Chromium tab, no second workspace, no tab strip geometry)."""


@dataclasses.dataclass(frozen=True)
class Step:
    name: str
    method: str
    params: object  # callable(Context) -> dict
    settle_s: float = SPRING_SETTLE_S
    motion_s: float = SPRING_MOTION_S

    def request(self, context, now_s):
        """(method, params) to send at `now_s` (CLOCK_UPTIME_RAW seconds). A key carries its send time as the event's
        timestamp, so the action signposts carry an input age (trace.py's Typist does the same)."""
        params = dict(self.params(context))
        if self.method == "debug.key":
            params["timestamp"] = now_s
        return self.method, params


@dataclasses.dataclass(frozen=True)
class Scenario:
    name: str
    steps: tuple
    prepare: object = None  # callable(Context), untimed, before the pair
    check: object = None  # callable(Context) -> error or None, untimed, after the pair
    cleanup: object = None  # callable(Context), untimed, last


class Context:
    """What the steps aim at in one session: the measured workspace and its first pane, the tab it shows by default,
    a Chromium tab of that pane, another workspace, and the points `prepare` reads (`points`).

    `rpc(method, params=None, timeout=...)` returns the reply's result or {"error": ...}; `sleep` is injected so a
    test runs without waiting."""

    def __init__(self, rpc, workspace, pane, default_tab=None, chromium_tab=None, other_workspace=None, sleep=time.sleep):
        self.rpc, self.sleep = rpc, sleep
        self.workspace, self.pane = workspace, pane
        self.default_tab, self.chromium_tab, self.other_workspace = default_tab, chromium_tab, other_workspace
        self.points = {}

    def action(self, name, args=None, target=None):
        params = {"action": name, "args": dict(args or {}), "focus": True}
        if target:
            params["target"] = target
        reply = self.rpc("action.run", params, timeout=60)
        if isinstance(reply, dict) and reply.get("error"):
            raise ScenarioError(f"{name}: {str(reply['error'])[:200]}")
        return reply

    def settle(self, seconds=PREPARE_SETTLE_S):
        self.sleep(seconds)  # bench harness: an untimed change lands before the recording starts

    def home(self):
        """The measured workspace shown, its first pane focused, showing its default tab: every pair starts here."""
        self.action("goToWorkspace", {"workspace": self.workspace})
        self.action("pane.focus", target=f"pane:{self.pane}")
        if self.default_tab:
            self.action("tab.focus", target=f"tab:{self.default_tab}")
        self.settle()

    def windows(self):
        """`debug.pane_chrome`'s windows: each pane's tab strip and tab slots (window points, top-left), the
        window controls (`band_presence`) and the title bar buttons (`pointer_inside`)."""
        reply = self.rpc("debug.pane_chrome", None, timeout=30)
        return (reply.get("windows") or []) if isinstance(reply, dict) else []

    def pane_geometry(self):
        """The first pane's entry in `windows()`; raises ScenarioError without a tab strip and tab slots."""
        pane = next((p for w in self.windows() for p in w.get("panes") or [] if p.get("pane") == self.pane), None)
        if not pane or not pane.get("strip") or not pane.get("tab_slots"):
            raise ScenarioError(f"no tab strip geometry for pane {self.pane}")
        return pane


def key(name, key_name, modifiers, **timing):
    return Step(name, "debug.key", lambda _context: {"key": key_name, "modifiers": list(modifiers)}, **timing)


def action(name, action_id, args=None, **timing):
    def params(context):
        resolved = args(context) if callable(args) else dict(args or {})
        return {"action": action_id, "args": resolved, "focus": True}
    return Step(name, "action.run", params, **timing)


def pointer(name, point, **timing):
    """A synthesized pointer move to `context.points[point]` (`debug.mouse move`): tracking-area owners get their
    enter and exit (DebugHover) and the hover cards hear the move, as from a real pointer. `leave` is never used:
    it only clears the layout's pointer, so a card or the band would stay up."""
    return Step(name, "debug.mouse", lambda context: {"action": "move", **context.points[point]}, **timing)


def _away(context):
    """The measured pane's content centre, off every hover target (motion-main-work.py's `away`)."""
    return {"pane": context.pane}


def _home(context):
    context.home()


def _chromium(context):
    context.home()
    if not context.chromium_tab:
        raise ScenarioError("the session has no Chromium tab in the measured pane")
    context.action("tab.focus", target=f"tab:{context.chromium_tab}")
    context.settle()


def _other_workspace(context):
    context.home()
    if not context.other_workspace:
        raise ScenarioError("the session has no second workspace")


def _band(context):
    context.home()
    context.action("toggleSidebar")
    context.settle()
    context.points["band"] = {"x": BAND_POINT[0], "y": BAND_POINT[1]}
    context.points["away"] = _away(context)


def _band_closed(context):
    windows = context.windows()
    presence = next(((w.get("window_controls") or {}).get("band_presence") for w in windows
                     if "band_presence" in (w.get("window_controls") or {})), None)
    if presence != 0 or any((w.get("titlebar_buttons") or {}).get("pointer_inside") for w in windows):
        return f"the band did not close when the pointer moved away: presence {presence}"
    return None


def _band_cleanup(context):
    context.action("toggleSidebar")
    context.settle()


def _hover_card(context):
    context.home()
    pane = context.pane_geometry()
    sx, sy, _sw, sh = pane["strip"]
    slot = pane["tab_slots"][-1]
    context.points["tab"] = {"x": sx + slot[0] + slot[1] / 2, "y": sy + sh / 2}
    context.points["away"] = _away(context)


def _card_hidden(context):
    reply = context.rpc("debug.hover_cards", None, timeout=15)
    showing = isinstance(reply, dict) and reply.get("card_showing") == "true"
    return "the hover card still shows after the pointer moved away" if showing else None


SCENARIOS = (
    # Ghostty-default chords through the person's key path.
    Scenario("cmd-d", (key("cmd-d", "d", ["cmd"]), key("cmd-w", "w", ["cmd"])), prepare=_home),
    Scenario("cmd-shift-d", (key("cmd-shift-d", "d", ["cmd", "shift"]), key("cmd-w", "w", ["cmd"])), prepare=_home),
    Scenario("zoom", (action("zoom", "toggleSplitZoom"), action("unzoom", "toggleSplitZoom")), prepare=_home),
    Scenario("new-column", (action("new-column", "newColumn"), action("close-last-column", "closePane")), prepare=_home),
    Scenario("workspace-switch", (action("workspace-switch", "goToWorkspace", lambda c: {"workspace": c.other_workspace}),
                                  action("switch-back", "goToWorkspace", lambda c: {"workspace": c.workspace})),
             prepare=_other_workspace),
    Scenario("sidebar-toggle", (action("sidebar-hide", "toggleSidebar"), action("sidebar-show", "toggleSidebar")),
             prepare=_home),
    Scenario("toggle-omnibar", (action("omnibar-hide", "palette.browserToggleOmnibar"),
                                action("omnibar-show", "palette.browserToggleOmnibar")),
             prepare=_chromium, cleanup=_home),
    Scenario("band-reveal", (pointer("band-open", "band", settle_s=BAND_SETTLE_S),
                             pointer("band-close", "away", settle_s=BAND_SETTLE_S, motion_s=0.3 + SPRING_MOTION_S)),
             prepare=_band, check=_band_closed, cleanup=_band_cleanup),
    Scenario("window-zoom", (action("window-zoom", "zoomWindow"), action("window-unzoom", "zoomWindow")), prepare=_home),
    Scenario("hover-card", (pointer("card-open", "tab", settle_s=HOVER_CARD_SETTLE_S, motion_s=HOVER_CARD_SETTLE_S),
                            pointer("card-close", "away")),
             prepare=_hover_card, check=_card_hidden),
    Scenario("sidebar-reorder", (action("move-up", "moveWorkspaceUp"), action("move-down", "moveWorkspaceDown")),
             prepare=_home),
)


def names():
    return [scenario.name for scenario in SCENARIOS]


def select(wanted=None):
    """The scenarios named in `wanted` (a list, or a comma string), in SCENARIOS order; all when empty. Raises
    ValueError for an unknown name."""
    if isinstance(wanted, str):
        wanted = [name.strip() for name in wanted.split(",") if name.strip()]
    if not wanted:
        return list(SCENARIOS)
    unknown = sorted(set(wanted) - set(names()))
    if unknown:
        raise ValueError(f"unknown scenarios {unknown}; known: {', '.join(names())}")
    return [scenario for scenario in SCENARIOS if scenario.name in wanted]
