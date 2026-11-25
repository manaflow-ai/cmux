#!/usr/bin/env python3
"""cmd-n-paint-e2e.py --screen: the look of the measured window, and what the app itself says of its settings.

The screen mode's launch starts its app with an empty config, so its app is at the schema's defaults: a number of
it is a number of that app, not of an app with other settings. `--window-look` gives the launch other settings. Its
words, its config keys, its reads of the app and its report lines are scripts/cmux-next/window_look.py's, the one
look option of the measure tools; this file is only this tool's use of that module:

  asked    the option's type. This tool makes no panel behind its window: `behind` is `desktop` or not named.
  write    the driver's launch calls it with the launch's own environment before the app starts: the look's keys
           go into the launch's app config file and its terminal lines into the terminal config file, and both
           files are read again. With no look both files stay as the driver made them.
  shown    the screen mode calls it one time, before it makes its session. It asks the app for its settings, for
           the speed of its motion and for what its first window shows, and gives the report's first lines: each
           key that the launch wrote with the app's own answer, each other setting that the app holds, the
           motion's speed, the window's backdrop and its theme, and with a look the CLI's answer for each key.
           `problem` is why the app does not show the look (None with no look): the mode then ends its run before
           the session, so no key goes into an app with another look.
  cli_try  the CLI of the launched bundle, asked one time for each key of the look. A try: its fault is a line.

The app is read again for 10 s when it does not show the look yet (a picture loads, a tint blends). The time is this
tool's own count of its pauses, so a run has at most 22 reads of the backdrop.

`new_surface_look.py --check WORDS` is the entry's check before its build: exit 2 with the reason for words that
the option refuses.

Tests: scripts/cmux-next/tests/test_screen_window_look.py
"""
import argparse
import json
import os
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))  # window_look, also under `python3 -I`
import window_look as looks  # noqa: E402

THEME_FACTS = ("spec", "effective_spec", "source", "window_background", "is_dark")
CLI_S = 10


def asked(words):
    """The option's value: None for `opaque`, else the look (window_look.window_look)."""
    try:
        look = looks.window_look(words)
    except ValueError as refused:
        raise argparse.ArgumentTypeError(str(refused)) from None
    if look and look.get("behind", "desktop") != "desktop":
        raise argparse.ArgumentTypeError(f"--window-look behind={look['behind']}: this tool makes no panel behind its window "
                                         "(behind=desktop, or no `behind`)")
    return look


def write(look, env):
    """Writes the look into the 2 config files of the launch's environment `env`, and reads them again. Returns why
    the launch did not get the look (None when it did, and with no look, which writes nothing)."""
    if not look:
        return None
    try:
        with open(env["CMUX_NEXT_CONFIG_FILE"], "w", encoding="utf-8") as handle:
            handle.write(json.dumps(looks.look_config({}, look)) + "\n")
        with open(env["CMUX_NEXT_GHOSTTY_CONFIG"], "w", encoding="utf-8") as handle:
            handle.write("".join(line + "\n" for line in looks.look_terminal_lines(look)))
    except (KeyError, OSError) as error:
        return f"the launch's config files were not written: {error!r}"
    return looks.look_problem(look, env)


def cli_try(launched, paths, run=subprocess.run):
    """One line for each settings path of `paths`: what the launched bundle's CLI answers for it (`config get`, then
    `settings get` when the first word is refused), in the launch's environment, in `CLI_S` s at most for a call.
    `launched` is the driver's word about its launch (`cli`, `env`); None when the driver launched no app."""
    if not launched:
        return ["the CLI: not asked (the driver did not launch this app)"]
    lines = []
    for path in paths:
        said = "not asked"
        for word in ("config", "settings"):
            try:
                done = run([launched["cli"], word, "get", path, "--json"], env=launched["env"], capture_output=True, text=True,
                           timeout=CLI_S, check=False)
                said = f"exit {done.returncode}: {' '.join((done.stdout or done.stderr or '').split())[:300]}"
                if done.returncode == 0:
                    break
            except subprocess.TimeoutExpired:
                said = f"no answer in {CLI_S} s"
            except OSError as error:
                said = f"not run ({error!r})"
        lines.append(f"the CLI, `{word} get {path}`: {said}")
    return lines


def shown(rpc, look, sleep, launched=None, run=subprocess.run):
    """What the app says of its settings and of its first window, for the report: `look` (the look's name part,
    None with no look), `lines` (the report's first lines), `resolved` and `backdrop` (window_look.shown_look's
    facts), `theme` (the first window's own theme facts), `problem`. `rpc(method, params, timeout)` is the driver's
    call, which gives `{"error": ...}` and does not raise; `sleep` is the mode's pause."""
    waited = [0.0]

    def pause(seconds):
        waited[0] += seconds
        # sleep-ok: the poll step of window_look.shown_look's deadline loop (it re-reads until the look shows and its tint
        # stops blending); this wrapper only counts the waited seconds as that loop's clock.
        sleep(seconds)

    def ask(method, params=None):
        return rpc(method, params, 10)

    facts, problem = looks.shown_look(ask, look, monotonic=lambda: waited[0], sleep=pause)
    resolved = facts.get("resolved") or {}
    lines = looks.look_head(look, facts)
    lines.append("the first window shows, by the app: " + (
        "NOT READ" if not isinstance(facts.get("backdrop_shown"), dict) else
        f"{'the picture ' + repr(resolved['picture']) if resolved.get('picture') else 'no picture'}, "
        f"opacity {resolved.get('opacity')}, kind {facts.get('kind')}"))
    themes = ask("debug.themes")
    windows = themes.get("windows") if isinstance(themes, dict) else None
    window = windows[0] if isinstance(windows, list) and windows and isinstance(windows[0], dict) else None
    theme = None if window is None else {name: window.get(name) for name in THEME_FACTS}
    lines.append("the first window's theme, by the app: " + ("NOT READ" if theme is None else json.dumps(theme)))
    if look:
        lines += cli_try(launched, list(looks.look_paths(look)), run)
    return {"look": looks.look_tag(look) or None, "lines": lines, "resolved": resolved, "backdrop": facts.get("backdrop_shown"),
            "theme": theme, "seconds_read_again": waited[0], "problem": problem}


def main(arguments):
    if len(arguments) != 2 or arguments[0] != "--check":
        sys.exit("use: new_surface_look.py --check WORDS (the option itself: cmd-n-paint-e2e.py --screen --window-look WORDS)")
    try:
        look = asked(arguments[1])
    except argparse.ArgumentTypeError as refused:
        print(refused, file=sys.stderr)
        sys.exit(2)
    if not look:
        print("window look: opaque (the launch writes no key)")
        return
    print(f"window look {looks.look_tag(look)}: {len(looks.look_paths(look))} settings keys, {len(looks.look_terminal_lines(look))} terminal line")


if __name__ == "__main__":
    main(sys.argv[1:])
