"""The R3 resize invariant after the layout settles (group resize-r3, journeys/r3/*.json).

cmux-ad P0 2026-10-31 (Lawrence on v2.2.11-opt: "resizing terminals is broken (doesn't actually resize
properly)"; his capture: grid 297x87, drawn 297x87, but fit_grid 126x87 in a 2088x1233 pt view). After each
resize the shown terminal must have one size everywhere: the app's grid == the grid its view's frame fits ==
Ghostty's drawn grid == the PTY (`stty size`) == the daemon's screen == the topology, and a long line wraps at
that width. ext_smoke's `smoke_r3` reads all of them; this group adds the "settled" part.

Condition (inside `expect.all`):
  r3_settled  {pane, pty_tag?, long_tag?, vs?, cols?}     app
              ext_smoke's smoke_r3 (same fields), but NEGATIVE: read again on every poll, it must hold at the
              end together with the positive conditions and through the expect's `settle` seconds. A size that
              is right for one poll and then drifts (a late layout, a held spring size, a deferred set_size)
              fails; a size that is wrong for good fails with every size in the detail.

  r3_replay_matches {pane, chars?}   app
              the app's viewport text and the daemon's screen show the same characters at the end (default the last
              800): rows joined, single spaces dropped and longer space runs kept as one mark, because the app's text (Ghostty's
              selection read) joins soft-wrapped rows while the daemon's screen read gives physical rows. A row drawn
              at another column (fuzzer e2) still differs: its leading spaces stay. NEGATIVE.

Steps:
  r3_long_line {tag, after?, timeout?} ext_smoke's smoke_long_line (a line 15 cells longer than any grid,
                                 fitted grid or view width now, or any remembered grid),
                                 but it waits for either neutral prompt (`J>` after neutral_prompt, `$` of the
                                 capture home) before its keys
Other steps come from ext_window (window_drag, divider_drag, remember, use_pane), ext_smoke (smoke_adopt_line)
and the driver (key, type, new_terminal).
"""
import re
import time
D = None


def install(driver):
    global D
    D = driver


def cond_r3_settled(j, want, cache):
    import ext_smoke  # the driver loaded it (load_extensions imports every ext_*.py by its stem)
    return ext_smoke.cond_smoke_r3(j, want, cache)


def step_r3_long_line(j, step):
    import ext_smoke
    t0, last = D.now(), None
    timeout = float(step.get("timeout", 15))
    # `after`: a regex a whole screen line above the prompt must match first (the line the step before
    # printed, such as `echo TAG $(stty size)`'s output). Without it the old bare prompt, still the last line
    # before the shell echoes the typed command, ends the wait, and the long line is typed into the command
    # before its output comes: the output then starts mid-line and pty_size cannot read it (a false red).
    after = re.compile(j.sub(step["after"])) if step.get("after") else None
    while D.now() - t0 < timeout:
        lines = [l for l in ext_smoke._lines(j.app.screen(j.need_term())["text"]) if l]
        last = lines[-1] if lines else None
        if last in ("$", D.PROMPT.strip()) and (after is None or any(after.fullmatch(l.strip()) for l in lines[:-1])):
            break
        time.sleep(0.1)
    else:
        raise D.StepError(f"r3_long_line: the prompt did not come back within {timeout} s"
                          f"{' after a line matching ' + repr(step['after']) if after else ''} (last line {last!r})")
    waited = round(D.now() - t0, 2)
    # smoke_long_line waits for `$` only: the prompt is back now, so its own wait ends at once for `$`; for `J>`
    # it is skipped (timeout 0 would raise), so build the same line here.
    # Longer than every width the line could wrap at: each remembered grid, and every pane's grid, fitted grid and
    # view-frame width now (a stale grid must not make the line too short to wrap at the real width).
    widths = [k["grid"][0] for k in getattr(j, "ext_remembered", {}).values() if k.get("grid")]
    for p in j.app.panes():
        surface, info = p.get("surface") or {}, p.get("grid") or {}
        for g in (ext_smoke._grid(surface.get("grid")), ext_smoke._grid(surface.get("fit_grid"))):
            if g:
                widths.append(g[0])
        if info.get("cell_width") and info.get("frame_width"):
            widths.append(int(info["frame_width"] // info["cell_width"]))
    widest = max(widths or [0])
    if widest <= 0:
        raise D.StepError("r3_long_line: no grid width to exceed")
    tag = j.sub(step["tag"])
    length = widest + 15
    text = f"printf '%s' {tag}; printf 'x%.0s' $(seq 1 {length - len(tag)}); echo"
    replies = [j.key(char, [], j.key_window) for char in text] + [j.key("return", [], j.key_window)]
    if not hasattr(j, "smoke_long"):
        j.smoke_long = {}
    j.smoke_long[tag] = length
    return {"tag": tag, "length": length, "widest_before": widest, "keys": len(replies), "prompt_wait_s": waited}


def _stream(text):
    """The characters both sides agree on: rows joined (the app joins soft-wrapped rows, the daemon's read drops the
    space a soft wrap falls on), single spaces dropped, and each run of two or more spaces kept as one mark, so a row
    drawn at another column (its leading spaces) still differs."""
    import re
    return re.sub(r" ", "", re.sub(r" {2,}", "\u2423", "".join(row.rstrip() for row in (text or "").split("\n"))))


def cond_r3_replay_matches(j, want, cache):
    import ext_smoke
    rec = ext_smoke._named(j, want["pane"])
    row = next((p for p in ext_smoke._surfaces(j, cache) if p.get("pane") == rec["pane"]), None)
    app, daemon = _stream((row or {}).get("text")), _stream(j.app.screen(rec["term"])["text"])
    n = int(want.get("chars", 800))
    n = min(n, len(app), len(daemon))
    a, d = app[len(app) - n:], daemon[len(daemon) - n:]
    first = next((i for i, (x, y) in enumerate(zip(a, d)) if x != y), None if len(a) == len(d) else min(len(a), len(d)))
    detail = {"pane": rec["pane"], "app_chars": len(app), "daemon_chars": len(daemon), "first_difference": first}
    if first is not None:
        detail.update(app_around=a[max(0, first - 40):first + 40], daemon_around=d[max(0, first - 40):first + 40])
    return row is not None and first is None and len(a) > 0, detail


STEPS = {"r3_long_line": step_r3_long_line}
CONDITIONS = {"r3_settled": ("app", cond_r3_settled), "r3_replay_matches": ("app", cond_r3_replay_matches)}
NEGATIVE = ("r3_settled", "r3_replay_matches")
