"""Which engine a measured page ran in (decision 2026-11-16: each measure says its engine).

The app shows a page (a New Tab page, a chat) in Chromium by default, and in WebKit when the build has no Chromium
or the engine is not at hand for that page. A tagged build embeds Chromium only when the engine's artifact is at
hand (scripts/cmux-next/embed-cef.sh); with none it warned in a build log that no measure step prints. So a time
of a page in WebKit read as a time of the default engine. A bench that times a page:

  - reads the page's engine from the app after the timed press (`debug.agent_pane {action: engine}`: `cef`, or
    `webkit:<reason>`) and keeps it in the row as `page_engine` (`page_engine`); a row of a command that opens a
    browser page or a viewer's page names the engine of the focused pane's browser tab itself (`engine`: `cef`,
    `webkit`, or `none` with no browser tab there), and that word is its `page_engine` (`judge_created`);
  - with an asked engine, takes a page row whose engine is not named (`none`) as an error of the row too: its
    page is in one of the two engines, and the row does not say which;
  - with an asked engine (`cef` or `webkit`), takes a row of another engine as an error of the row: its times and
    its frames move to `other_engine`, so each summary counts the row as a missed run and no percentile holds its
    numbers (`judge`);
  - with `cef` asked, can stop at its first launch when the app says that it has no Chromium (`no_chromium`);
  - prints the app's own word on Chromium at each launch (`chromium_line`) and the count of rows for each engine
    at its end (`counts_line`).

`any` judges no row: the field and the lines are the whole of it.
"""

WANTED = ("any", "cef", "webkit")
# The times of a row that a summary reads: what moves to `other_engine` in a row of another engine. `frames` is
# the row's frame times (a summary reads its `first_tick_ms`).
TIMES = ("key_ms", "visible_ms", "confirmed_ms", "committed_ms", "page_ms", "ready_ms", "chrome_ms", "frames_to_visible",
         "frames")


def page_engine(reply):
    """The engine's name in the app's answer to `debug.agent_pane {action: engine}`; `unknown: <why>` when the
    answer names none (no page in the focused pane, no answer)."""
    if isinstance(reply, dict):
        name = reply.get("engine")
        if isinstance(name, str) and name:
            return name
        if reply.get("error"):
            return f"unknown: {str(reply['error'])[:160]}"
    return "unknown: the app named no engine"


def family(name):
    """`cef` or `webkit` for an engine name, None for any other text (`unknown: ...`, `native`, no name)."""
    if name == "cef":
        return "cef"
    if isinstance(name, str) and (name == "webkit" or name.startswith("webkit:")):
        return "webkit"
    return None


def fault(row, wanted, page=False):
    """Why `row` is no number for the asked engine, or None. A row with no `page_engine` (a command that opens no
    page, a press that failed before the read) and a native page are not judged. A page whose engine was not read
    is no number when the app said that the page was ready, or when the row's command always opens a page
    (`page`); else the row has no page time to refuse."""
    name = row.get("page_engine")
    if wanted == "any" or name is None or name == "native":
        return None
    kind = family(name)
    if kind == wanted:
        return None
    if kind is None:
        return f"page engine not read ({name}), asked: {wanted}" if page or row.get("ready_ms") is not None else None
    return f"page engine {name}, asked: {wanted}"


def judge(row, wanted, page=False):
    """`row`, and when it is no number for the asked engine (`fault`): its times moved to `other_engine` and the
    reason in `error`, after an error that the row had."""
    why = fault(row, wanted, page)
    if why is None:
        return row
    row["other_engine"] = {name: row.pop(name) for name in TIMES if name in row}
    row["error"] = f"{row['error']}; {why}" if row.get("error") else why
    return row


def judge_created(row, wanted, opens, read):
    """The Cmd-T bench's rule for one row: its `page_engine`, then `judge`. `opens` is what the row's command opens:

      `tab`        Cmd-T: always a New Tab page. `read()` gives its engine after the row's times. An engine that
                   was not read is no number, also when the page was not ready.
      `workspace`  Cmd-N: a New Tab page or a terminal. `read()` as for `tab`; with no ready page and no engine
                   the row is left as it is (a terminal has no page).
      `page`       a browser page (a link, a browser split, a browser workspace) or a viewer's page (a diff, the
                   GitHub page). The app's row names the engine of the focused pane's browser tab itself
                   (`engine`: `cef`, `webkit`, or `none` when that pane shows no browser tab: a viewer's page
                   always, or a browser in a pane with no focus). `none` is kept as the row's `page_engine`. With
                   an asked engine it is no number: that page is a page view in one of the two engines, and the
                   row does not say which. A measure of a viewer's page asks for `any`.
      None         no page: nothing is read and nothing is judged.

    A `tab` or `workspace` row that showed nothing, and a `page` row with no page time, get no `page_engine`."""
    if opens in ("tab", "workspace"):
        if row.get("visible_ms") is None:
            return row
        row["page_engine"] = read()
        return judge(row, wanted, page=opens == "tab")
    if opens == "page":
        if row.get("page_ms") is None and row.get("chrome_ms") is None:
            return row
        name = row.get("engine")
        row["page_engine"] = name if isinstance(name, str) and name else "unknown: the row named no engine"
        return judge(row, wanted, page=True)
    return row


def unavailable_word(value):
    """The app's `unavailable` word of `debug.cef` as text: its code, and its detail when it has one. The app
    sends null (None here: Chromium is not unavailable) or an object with `code` and `detail`."""
    if not value:
        return None
    if isinstance(value, dict):
        code, detail = value.get("code") or "no code", value.get("detail")
        return f"{code}: {detail}"[:200] if detail else str(code)
    return str(value)[:200]


def chromium_word(reply):
    """The app's own word on Chromium from `debug.cef`: the engine's state, why it is unavailable (`unavailable_word`;
    None when it is not), and the browser tabs' default engine (a setting; the engine of a measured page is the
    row's `page_engine`). `{"error": ...}` when the app gave no answer."""
    if not isinstance(reply, dict):
        return {"error": "no reply"}
    if reply.get("error") and "state" not in reply:
        return {"error": str(reply["error"])[:160]}
    return {"state": reply.get("state"), "unavailable": unavailable_word(reply.get("unavailable")),
            "browser_default_engine": reply.get("default_engine")}


def chromium_line(bench, word):
    """One line for the step's log, from `chromium_word`."""
    if "error" in word:
        return f"CHROMIUM {bench}: the app gave no word ({word['error']})"
    return (f"CHROMIUM {bench}: the app says state={word.get('state')} unavailable={word.get('unavailable') or 'no'} "
            f"browser_default_engine={word.get('browser_default_engine')}")


def no_chromium(word):
    """For a bench that was asked for `cef`: one line that says why it stops, when the app's own word
    (`chromium_word`) is that Chromium is unavailable. None when the app has the engine, and when it gave no word
    (no answer is no claim)."""
    if "error" in word or not word.get("unavailable"):
        return None
    return (f"the app has no Chromium engine (unavailable={word['unavailable']}) and --page-engine=cef was asked, so "
            "no open can be in the asked engine. For a measure of WebKit pass --allow-no-chromium to the entry "
            "(with cmux-ci: --arg=--allow-no-chromium), or --page-engine=webkit to the bench.")


def counts(rows):
    """{engine name: rows} of the rows that have a `page_engine`."""
    out = {}
    for row in rows:
        name = row.get("page_engine")
        if name is not None:
            out[name] = out.get(name, 0) + 1
    return out


def counts_line(bench, rows, wanted):
    """One line for the step's log: the rows of each engine, the asked engine, and how many rows were refused."""
    found = counts(rows)
    if not found:
        return f"PAGE-ENGINE {bench}: no row with a page (asked: {wanted})"
    refused = sum(1 for row in rows if "other_engine" in row)
    tail = (f"; {refused} row{'' if refused == 1 else 's'} in another engine, counted as missed, "
            f"{'its' if refused == 1 else 'their'} times under other_engine") if refused else ""
    return f"PAGE-ENGINE {bench}: " + ", ".join(f"{name} {n}" for name, n in sorted(found.items())) + f" (asked: {wanted}{tail})"
