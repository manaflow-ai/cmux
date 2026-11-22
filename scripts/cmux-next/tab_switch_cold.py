#!/usr/bin/env python3
"""Cold Chromium loads, reloads and same-tab navigations: each one's visual stages counted from the frames.

Leo, 2026-11-22 12:41Z: "loading chrome tabs. it has the transparent background. then it draws some asinine bullshit
idk opaque layer for a nasty-ass flicker. THEN loads the web page. in our app. nah. we can't have that. dont have
stupid multi stage loading. this necessarily collaborates a bit with the morphing tabs thing, but this is moreso for
completely cold loads. but similar situations may apply." Measured on his NIGHTLY (dark theme): glass ground, ONE
flat frame of the theme's opaque page color at the document commit, the glass again, then the page: 4 stages.

Scenarios (tab_switch_frames.py --scenarios):
  chromium-cold      from the measured pane's terminal, a NEW Chromium tab opened straight to a page this session never
                     loaded (openBrowser.chromium, a fresh query on a fixture URL of the harness's own HTTP server,
                     no-store), PAGES_PER_ROUND pages a round, light and dark fixtures alternating (default set)
  chromium-reload    that tab reloaded (location.reload through browser.page.eval)                (scenarios=all)
  chromium-navigate  that tab navigated to the next fixture, the other theme (browser.page.navigate) (scenarios=all)
Each is recorded COLD_RECORD_S after its action; the tab is closed after its round's reload and navigation.

Per load, beside tab_switch_judge.judge_switch's fields (against the settled frame) and the settle fields:
  load_stages      the visual stages from the action's commit to the settled page (load_stages.py): 2 is the
                   ground, then the page
  first_paint_ms   when the page's first stage started, from the mark
  stages           the stage list (start_ms, end_ms, kind, mean_rgb, frames)
  cold_load        true: the frame budgets of a switch (content within one display frame, 0 blank, 0 wrong ...) are
                   not this action's; its budget is load_stages <= 2 (tab_switch_judge.budget_fails, tab_switch_gate.py)
"""
from __future__ import annotations

import os
import time
import uuid

import load_stages
import tab_switch_foreign as foreign
import tab_switch_restored as restored

SCENARIOS = ("chromium-cold",)
MORE_SCENARIOS = ("chromium-reload", "chromium-navigate")
ALL = SCENARIOS + MORE_SCENARIOS
PAGES_PER_ROUND = 2
COLD_RECORD_S = 3.0


def fixture_order():
    """The fixture names, light and dark alternating, so consecutive loads are of opposite themes."""
    light = [f[0] for f in restored.FIXTURES if f[0].startswith("light")]
    dark = [f[0] for f in restored.FIXTURES if f[0].startswith("dark")]
    out = []
    for i in range(max(len(light), len(dark))):
        out += ([light[i]] if i < len(light) else []) + ([dark[i]] if i < len(dark) else [])
    return out


def stage_fields(h, window, mark, before, end):
    """load_stages, first_paint_ms and the stage list of one action's window, on the harness's content rect."""
    return load_stages.measure(window, h.rec.w, rect=h.content, mark=mark, before=before, frame_ms=h.rec.frame_ms,
                               end=end)


class Cold:
    """The chromium-cold, chromium-reload and chromium-navigate rounds on a tab_switch_frames.Harness `h`."""

    def __init__(self, h, say, scenarios):
        self.h, self.say = h, say
        self.scenarios = [s for s in ALL if s in scenarios]
        self.server = restored.FixtureServer()
        self.order = fixture_order()
        self.next = 0
        self.clips = not getattr(h.args, "no_clips", False)

    def url(self, name):
        return self.server.url(f"/p/{name}?cold={uuid.uuid4().hex[:12]}")

    def fixture(self):
        name = self.order[self.next % len(self.order)]
        self.next += 1
        return name

    def round(self, load, r):
        """One round: PAGES_PER_ROUND cold opens, each followed by its reload and navigation when asked. Returns the
        items to judge [(scenario, item)] and the tabs to close."""
        h = self.h
        items = []
        for k in range(PAGES_PER_ROUND):
            name = self.fixture()
            h.select("terminal")
            time.sleep(h.args.settle)  # test script: the terminal shows
            before = {t.get("id") for t in h.pane_tabs()[0]}
            label = f"chromium-cold/{load} round {r} page {k + 1}"
            h.flip3(label)
            reply = h.c.action("openBrowser.chromium", url=self.url(name))
            time.sleep(COLD_RECORD_S)  # test script: the cold load, recorded
            h.rec.flip(f"{label}:end")
            error = f"openBrowser.chromium: {reply['error']}" if reply.get("error") else None
            items.append(("chromium-cold", {"label": label, "page": name, "error": error}))
            made = [] if error else h.new_tabs(before, 1)
            tab = made[0] if made else None
            if tab is None:
                continue
            if "chromium-reload" in self.scenarios:
                label = f"chromium-reload/{load} round {r} page {k + 1}"
                h.flip3(label)
                reply = h.c.call("browser.page.eval", {"tab": tab, "script": "location.reload(), 1"}, timeout=8)
                time.sleep(COLD_RECORD_S)  # test script: the reload, recorded
                h.rec.flip(f"{label}:end")
                bad = isinstance(reply, dict) and reply.get("error")
                items.append(("chromium-reload", {"label": label, "page": name,
                                                  "error": f"browser.page.eval: {reply['error']}" if bad else None}))
            if "chromium-navigate" in self.scenarios:
                other = self.fixture()
                label = f"chromium-navigate/{load} round {r} page {k + 1}"
                h.flip3(label)
                reply = h.c.call("browser.page.navigate", {"tab": tab, "url": self.url(other)}, timeout=8)
                if isinstance(reply, dict) and reply.get("error"):
                    reply = h.c.call("browser.page.eval",
                                     {"tab": tab, "script": f"location.href = {self.url(other)!r}, 1"}, timeout=8)
                time.sleep(COLD_RECORD_S)  # test script: the navigation, recorded
                h.rec.flip(f"{label}:end")
                bad = isinstance(reply, dict) and reply.get("error")
                items.append(("chromium-navigate", {"label": label, "page": other,
                                                    "error": f"navigate: {reply['error']}" if bad else None}))
            h.c.action("closeTab", focus=False, target=f"tab:{tab}")
            time.sleep(0.8)  # test script: the tab closes
        return items

    def judge(self, item, frames, flips):
        h = self.h
        label = item["label"]
        if item.get("error"):
            return {"label": label, "error": item["error"], "page": item.get("page"), "cold_load": True}
        leave, mark, end = (flips[f"{label}:{k}"] for k in ("leave", "mark", "end"))
        covered = h.foreign_over(label)
        if covered:
            return {"label": label, "foreign_window": "+".join(foreign.owners(covered)), "windows": covered}
        window = h.between(frames, leave, end)
        switch = h.judge(window, mark)
        switch.update(stage_fields(h, window, mark, h.at(frames, leave), end))
        switch.update({"label": label, "page": item.get("page"), "cold_load": True})
        h.add_settle(switch, frames, window, leave, mark, end, None, label)
        h.keep_sheet(switch, window, mark, label)
        return switch

    def run(self, loads, enter, leave):
        """{(scenario, load): switches} and {(scenario, load): note}; `enter(load)` starts a load and returns its
        notes, `leave(load)` ends it."""
        h = self.h
        rows, notes = {}, {}
        for load in loads:
            try:
                setup = enter(load)
                for r in range(1, h.args.rounds + 1):
                    keep = self.clips and r == 1 and load in ("idle", "L0")
                    if keep:
                        h.rec.keep_next = os.path.join(h.args.out, "clips", f"chromium-cold-{load}")
                    h.rec.begin()
                    try:
                        items = self.round(load, r)
                    finally:
                        frames, flips = h.rec.end()
                    if keep and getattr(h.rec, "kept", None):
                        self.say(f"cold: clip kept at {h.rec.kept}")
                    for name, item in items:
                        switch = self.judge(item, frames, flips)
                        if setup:
                            switch["load_setup"] = setup
                        if switch.get("load_stages") is not None:
                            self.say(f"  {item['label']}: {switch['load_stages']} stages, first paint "
                                     f"{switch.get('first_paint_ms')} ms: {switch.get('stages_summary')}")
                        rows.setdefault((name, load), []).append(switch)
            except Exception as error:  # noqa: BLE001 - this load's rows say why; the next still runs
                for name in self.scenarios:
                    notes.setdefault((name, load), f"{type(error).__name__}: {error}"[:600])
                try:
                    h.rec.end()
                except Exception:  # noqa: BLE001 - no block was open
                    pass
            finally:
                leave(load)
        return rows, notes

    def close(self):
        self.server.close()
