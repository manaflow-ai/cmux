"""The timed motion scenarios of the rendering program's done checks DC2t and DC3
(plans/cmux-next/chrome-parity/p03-rendering.md, section 5), for motion-hitches.py: the 13 DC2 scenarios.

Each scenario is a row of the counting bench (motion-main-work.py) with the same input and the same setup: the
same action, aimed the same way (`splitRight` at the base pane by id, `closeTab` at the one tab of a pane made for
it, `closePane` at the last of STRIP_COLUMNS columns of an overflowed strip), with `origin: script`. Each timed
step is named for its row's phase, `do` or `undo`, so (scenario, step) is the key of a row in both reports and the
count report and the time report join on it. motion-main-work.py's self-test checks that every (scenario, step)
here is a row there.

A scenario is one or two timed steps (`do`, and `undo` where the counting row counts one), with an untimed
`prepare` before them, an untimed `check` after them (what they must leave: the band closed, the card hidden,
the closed tab's pane gone) and an untimed `cleanup` last (the panes a split or a new column made close again).
A step is one input and nothing else: an action through `action.run`, or a synthesized pointer move through
`debug.mouse`. TIMED_METHODS names those two; a timed pass sends nothing else, so no probe (`debug.frames`,
`debug.window_record`, `debug.wakeups`, RenderStats) runs in the app while it is timed.

Each step has `delay`, the time from its input to the start of its motion (the hover card's open delay, the band's
close delay: nothing moves in it, so it is no dropped frame), `motion_s`, the length of the motion after the delay
(the spring's nominal time to rest), and `settle_s`, the time its pass waits before the next step: a timing bench
reads frames in [input + delay, input + delay + motion_s] and hitches in [input, input + settle_s].

Load by path (the benches run under `python3 -I`):

    spec = importlib.util.spec_from_file_location("motion_scenarios", os.path.join(HERE, "motion_scenarios.py"))
    scenarios = importlib.util.module_from_spec(spec); spec.loader.exec_module(scenarios)
    for scenario in scenarios.select(names): ...
"""
import dataclasses
import time

# The only methods a timed pass sends: the inputs themselves.
TIMED_METHODS = frozenset({"action.run", "debug.mouse"})

SPRING_MOTION_S = 0.6  # MotionSpring tokens rest in under 0.6 s (anim-perf-terminal.py)
SPRING_SETTLE_S = 1.0
BAND_CLOSE_DELAY_S = 0.3  # CollapsedBandReveal.closeDelay
HOVER_CARD_DELAY_S = 0.5  # DesignSettings.hoverCardDelay's default; `debug.hover_cards` delay_ms when it answers
PREPARE_SETTLE_S = 0.6  # an untimed prepare's change lands before a recording starts
COLUMN_SETTLE_S = 0.5  # each untimed new column's motion lands before the next (motion-main-work.py)
STRIP_COLUMNS = 3  # motion-main-work.py STRIP_COLUMNS (its self-test checks they agree)
BAND_POINT = (90.0, 12.0)  # window point (top-left) over the collapsed band's corner: motion-main-work.py --band-point
ORIGIN = "script"  # motion-main-work.py Session.act


class ScenarioError(RuntimeError):
    """A scenario cannot run in this session (no Chromium tab, no second workspace, no tab strip geometry), or an
    untimed step of it failed."""


@dataclasses.dataclass(frozen=True)
class Step:
    name: str  # the counting row's phase: "do" or "undo"
    method: str
    params: object  # callable(Context) -> dict
    settle_s: float = SPRING_SETTLE_S
    motion_s: float = SPRING_MOTION_S
    delay: object = 0.0  # seconds, or callable(Context) -> seconds

    def request(self, context):
        """(method, params) of the input."""
        return self.method, dict(self.params(context))

    def timing(self, context):
        """(delay_s, motion_s, settle_s): the settle covers the delay and the motion after it."""
        delay = float(self.delay(context) if callable(self.delay) else self.delay)
        return delay, self.motion_s, max(self.settle_s, delay + SPRING_SETTLE_S)


@dataclasses.dataclass(frozen=True)
class Scenario:
    name: str
    steps: tuple
    prepare: object = None  # callable(Context), untimed, before the steps
    check: object = None  # callable(Context) -> error or None, untimed, after the steps
    cleanup: object = None  # callable(Context), untimed, last


class Context:
    """What the steps aim at in one session: the measured workspace and its base pane, the tab it shows by default,
    a Chromium tab of that pane, the workspace a switch goes to (motion-main-work.py `neighbor`), the measured
    workspace's panes (`panes()`: the topology's pane dicts, with `id`, `column` and `tabs`), and what `prepare`
    finds for the steps (`state`).

    `rpc(method, params=None, timeout=...)` returns the reply's result or {"error": ...}; `sleep` is injected so a
    test runs without waiting."""

    def __init__(self, rpc, workspace, pane, default_tab=None, chromium_tab=None, other_workspace=None, panes=None,
                 sleep=time.sleep):
        self.rpc, self.sleep = rpc, sleep
        self.workspace, self.pane = workspace, pane
        self.default_tab, self.chromium_tab, self.other_workspace = default_tab, chromium_tab, other_workspace
        self.panes = panes or (lambda: [])
        self.state = {}

    def action(self, name, args=None, target=None):
        params = {"action": name, "args": dict(args or {}), "focus": True, "origin": ORIGIN}
        if target:
            params["target"] = target
        reply = self.rpc("action.run", params, timeout=60)
        if isinstance(reply, dict) and reply.get("error"):
            raise ScenarioError(f"{name}: {str(reply['error'])[:200]}")
        return reply

    def settle(self, seconds=PREPARE_SETTLE_S):
        self.sleep(seconds)  # bench harness: an untimed change lands before the recording starts

    def wait_for(self, predicate, seconds, step=0.05):
        """`predicate()`'s first true value, read every `step` s for at most `seconds` (counted in reads, so an
        injected sleep that does not wait still ends), else None."""
        for _ in range(int(seconds / step) + 1):
            value = predicate()
            if value:
                return value
            self.sleep(step)  # bench harness: the app applies an untimed change
        return None

    def pane_ids(self):
        return [p.get("id") for p in self.panes()]

    def home(self):
        """The measured workspace shown, its base pane focused, showing its default tab: every scenario starts here."""
        self.action("goToWorkspace", {"workspace": self.workspace})
        self.action("pane.focus", target=f"pane:{self.pane}")
        if self.default_tab:
            self.action("tab.focus", target=f"tab:{self.default_tab}")
        self.settle()

    def remember_panes(self):
        """The panes now: `close_new` closes every other one."""
        self.state["before"] = set(self.pane_ids())

    def made_pane(self, verb, target, settle=PREPARE_SETTLE_S):
        """`verb` on `target`, untimed; the new pane's id once its motion landed. Raises ScenarioError without one."""
        before = set(self.pane_ids())
        self.action(verb, target=target)
        made = self.wait_for(lambda: next((p for p in self.pane_ids() if p not in before), None), 15)
        if not made:
            raise ScenarioError(f"{verb} on {target} made no pane")
        self.settle(settle)
        return made

    def last_column_pane(self):
        """A pane of the strip's last column (the topology's highest `column`), or None."""
        panes = [p for p in self.panes() if isinstance(p.get("column"), int) and not isinstance(p.get("column"), bool)]
        if not panes:
            return None
        last = max(p["column"] for p in panes)
        return next(p["id"] for p in panes if p["column"] == last)

    def close_new(self):
        """Closes every pane `remember_panes` did not see, untimed."""
        before = self.state.get("before")
        if before is None:
            return
        for pane in [p for p in self.pane_ids() if p not in before]:
            self.action("closePane", target=f"pane:{pane}")
        self.settle()

    def windows(self):
        """`debug.pane_chrome`'s windows: each pane's tab strip and tab slots (window points, top-left), the
        window controls (`band_presence`) and the title bar buttons (`pointer_inside`)."""
        reply = self.rpc("debug.pane_chrome", None, timeout=30)
        return (reply.get("windows") or []) if isinstance(reply, dict) else []

    def pane_geometry(self):
        """The base pane's entry in `windows()`; raises ScenarioError without a tab strip and tab slots."""
        pane = next((p for w in self.windows() for p in w.get("panes") or [] if p.get("pane") == self.pane), None)
        if not pane or not pane.get("strip") or not pane.get("tab_slots"):
            raise ScenarioError(f"no tab strip geometry for pane {self.pane}")
        return pane


def action(name, action_id, args=None, target=None, **timing):
    """An `action.run` step; `args` and `target` are values or callables of the Context."""
    def params(context):
        resolved = args(context) if callable(args) else dict(args or {})
        request = {"action": action_id, "args": resolved, "focus": True, "origin": ORIGIN}
        aim = target(context) if callable(target) else target
        if aim:
            request["target"] = aim
        return request
    return Step(name, "action.run", params, **timing)


def pointer(name, point, **timing):
    """A synthesized pointer move to `context.state[point]` (`debug.mouse move`): tracking-area owners get their
    enter and exit (DebugHover) and the hover cards hear the move, as from a real pointer. `leave` is never used:
    it only clears the layout's pointer, so a card or the band would stay up."""
    return Step(name, "debug.mouse", lambda context: {"action": "move", **context.state[point]}, **timing)


def _base(context):
    return f"pane:{context.pane}"


def _away(context):
    """The base pane's content centre, off every hover target (motion-main-work.py's `away`)."""
    return {"pane": context.pane}


def _home(context):
    context.home()


def _home_and_remember(context):
    context.home()
    context.remember_panes()


def _close_new(context):
    context.close_new()


def _cmd_w(context):
    """A pane made for the step (motion-main-work.py `cmd_w`): its one tab is the one the step closes."""
    _home_and_remember(context)
    made = context.made_pane("splitRight", _base(context))
    tabs = next((p.get("tabs") or [] for p in context.panes() if p.get("id") == made), [])
    if len(tabs) != 1:
        raise ScenarioError(f"the new pane has {len(tabs)} tabs, not 1")
    context.state["made"], context.state["tab"] = made, tabs[0].get("id")


def _cmd_w_closed(context):
    made = context.state.get("made")
    gone = context.wait_for(lambda: made not in context.pane_ids(), 10)
    return None if gone else "closeTab left the pane"


def _columns(context):
    """STRIP_COLUMNS columns, each right of the strip's last column (motion-main-work.py `close_last_column`): the
    strip overflows and its camera sits at the end; the step closes the last one."""
    _home_and_remember(context)
    for index in range(STRIP_COLUMNS):
        last = context.last_column_pane()
        if not last:
            raise ScenarioError("the topology names no pane column")
        context.state["last"] = context.made_pane("newColumn", f"pane:{last}", settle=COLUMN_SETTLE_S)
    if context.last_column_pane() != context.state["last"]:
        raise ScenarioError(f"the newest column {context.state['last']} is not the strip's last one "
                            f"({context.last_column_pane()})")
    context.settle(SPRING_SETTLE_S)  # the camera lands at the strip's end


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
    context.state["band"] = {"x": BAND_POINT[0], "y": BAND_POINT[1]}
    context.state["away"] = _away(context)


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
    context.state["tab"] = {"x": sx + slot[0] + slot[1] / 2, "y": sy + sh / 2}
    context.state["away"] = _away(context)
    reply = context.rpc("debug.hover_cards", None, timeout=15)
    try:
        context.state["card_delay_s"] = float((reply or {}).get("delay_ms")) / 1000
    except (TypeError, ValueError, AttributeError):
        context.state["card_delay_s"] = HOVER_CARD_DELAY_S


def _card_delay(context):
    return context.state.get("card_delay_s", HOVER_CARD_DELAY_S)


def _card_hidden(context):
    reply = context.rpc("debug.hover_cards", None, timeout=15)
    showing = isinstance(reply, dict) and reply.get("card_showing") == "true"
    return "the hover card still shows after the pointer moved away" if showing else None


SCENARIOS = (
    Scenario("cmd-d", (action("do", "splitRight", target=_base),), prepare=_home_and_remember, cleanup=_close_new),
    Scenario("cmd-shift-d", (action("do", "splitDown", target=_base),), prepare=_home_and_remember, cleanup=_close_new),
    Scenario("cmd-w", (action("do", "closeTab", target=lambda c: f"tab:{c.state['tab']}"),),
             prepare=_cmd_w, check=_cmd_w_closed, cleanup=_close_new),
    Scenario("zoom", (action("do", "toggleSplitZoom"), action("undo", "toggleSplitZoom")), prepare=_home),
    Scenario("new-column", (action("do", "newColumn"),), prepare=_home_and_remember, cleanup=_close_new),
    Scenario("close-last-column", (action("do", "closePane", target=lambda c: f"pane:{c.state['last']}"),),
             prepare=_columns, cleanup=_close_new),
    Scenario("workspace-switch", (action("do", "goToWorkspace", lambda c: {"workspace": c.other_workspace}),
                                  action("undo", "goToWorkspace", lambda c: {"workspace": c.workspace})),
             prepare=_other_workspace),
    Scenario("sidebar-toggle", (action("do", "toggleSidebar"), action("undo", "toggleSidebar")), prepare=_home),
    Scenario("toggle-omnibar", (action("do", "palette.browserToggleOmnibar"), action("undo", "palette.browserToggleOmnibar")),
             prepare=_chromium, cleanup=_home),
    # The band opens at once; it closes CollapsedBandReveal.closeDelay after the pointer leaves.
    Scenario("band-reveal", (pointer("do", "band"), pointer("undo", "away", delay=BAND_CLOSE_DELAY_S)),
             prepare=_band, check=_band_closed, cleanup=_band_cleanup),
    Scenario("window-zoom", (action("do", "zoomWindow"), action("undo", "zoomWindow")), prepare=_home),
    # The card fades in after its open delay; it fades out at once when the pointer leaves (HoverCardMachine: hide,
    # then the grace for a reshow).
    Scenario("hover-card", (pointer("do", "tab", delay=_card_delay), pointer("undo", "away")),
             prepare=_hover_card, check=_card_hidden),
    Scenario("sidebar-reorder", (action("do", "moveWorkspaceUp"), action("undo", "moveWorkspaceDown")), prepare=_home),
)


def names():
    return [scenario.name for scenario in SCENARIOS]


def rows():
    """[(scenario, step)]: the counting bench's (scenario, phase) row of each timed step."""
    return [(scenario.name, step.name) for scenario in SCENARIOS for step in scenario.steps]


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
