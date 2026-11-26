"""The look of a measured window: from an option's words to what the running app says that its window shows.

A measure tool that launches a bench app takes `--window-look`: `opaque` (the default: the launch, its config and each
name stay as they were), or KEY=VALUE parts with a comma between them. No key has a default, and a key that the option
does not name is not written:

  background=NAME        `appearance.background` of the app config: a built-in picture's name, `none`, `daily`, `desktop`
  opacity=0..1           `appearance.backgroundOpacity`
  blur=KIND              `appearance.backgroundBlur`: frosted, glass, glass-clear or none
  terminal-opacity=0..1  the terminal config file's `background-opacity`
  terminal-blur=RADIUS   the terminal config file's `background-blur`
  behind=WHAT            what the window is over: `desktop`, or the app's own `checker` or `stripes` panel (the tool
                         makes the panel; a tool that makes none refuses the word)

The tool then asks the app itself, not a file: `settings.get` for the `appearance` keys and `debug.themes` for the
window's backdrop (the id of the picture that the window shows, and the alpha of the tint over it: the opacity that
the app resolved). `shown_look` waits for a picture's load and a tint's blend, and gives the fault of a window that
does not show the look. The debug read has no field for the blur: `resolved.blur` is the app's settings answer.

No app and no socket in this file: the caller gives its own `rpc`. Tests: scripts/measure/tests/window-look.test.py
"""
import json
import time


def window_look(value):
    """None for `opaque` (and for no option), or the keys that the option names (a `-` of a key is a `_` here).
    Another word, a key two times, or no config key at all, raises ValueError."""
    if value is None or value == "opaque":
        return None
    refused = ValueError("--window-look takes opaque or KEY=VALUE[,KEY=VALUE...] with background=NAME, opacity=0..1, "
                         "blur=frosted|glass|glass-clear|none, terminal-opacity=0..1, terminal-blur=RADIUS and "
                         f"behind=desktop|checker|stripes (one config key at least), not {value!r}")
    look = {}
    for part in value.split(","):
        key, equals, text = (piece.strip() for piece in part.partition("="))
        key = key.replace("-", "_")
        if not equals or key in look:
            raise refused
        try:
            if key == "background":
                found = text if text and not text.strip("abcdefghijklmnopqrstuvwxyz0123456789-") else None
            elif key == "blur":
                found = text if text in ("frosted", "glass", "glass-clear", "none") else None
            elif key == "behind":
                found = text if text in ("desktop", "checker", "stripes") else None
            elif key == "terminal_blur":
                found = int(text) if int(text) >= 0 else None
            elif key in ("opacity", "terminal_opacity"):
                found = float(text) if 0 <= float(text) <= 1 else None
            else:
                found = None
        except ValueError:
            found = None
        if found is None:
            raise refused
        look[key] = found
    if not set(look) - {"behind"}:
        raise refused
    return look


def look_tag(look):
    """The part a look adds to a row's or a film's name: each named key and its value in the option's order, then
    what the window is over when that is not the desktop. An opaque window adds nothing."""
    if not look:
        return ""
    parts = [f"{key.replace('_', '-')}-{format(value, 'g') if isinstance(value, float) else value}"
             for key, value in look.items() if key != "behind"]
    over = "" if look.get("behind", "desktop") == "desktop" else f"-over-{look['behind']}"
    return "look-" + "-".join(parts) + over


def look_config(config, look):
    """The app config with the look's named keys of `appearance`: `background`, `backgroundOpacity` and
    `backgroundBlur` (a copy; the other keys stay, and a key that the look does not name is not written). An opaque
    window gets `config` itself."""
    if not look:
        return config
    appearance = dict(config.get("appearance") or {})
    for key, name in (("background", "background"), ("opacity", "backgroundOpacity"), ("blur", "backgroundBlur")):
        if key in look:
            appearance[name] = look[key]
    return {**config, "appearance": appearance} if appearance else dict(config)


def look_terminal_lines(look):
    """The look's lines of the terminal config file: an opacity and a blur radius, each only when the look names it.
    No line for an opaque window."""
    lines = []
    if look and "terminal_opacity" in look:
        lines.append(f"background-opacity = {look['terminal_opacity']:g}")
    if look and "terminal_blur" in look:
        lines.append(f"background-blur = {look['terminal_blur']}")
    return lines


def look_problem(look, env, read=None):
    """Why the launched app did not get the look (None when it did, and for an opaque window): the app config of
    the launch's own environment must hold each named key, and its terminal config file each named line (a look
    with no terminal line does not read that file)."""
    if not look:
        return None
    read = read or (lambda path: open(path).read())
    try:
        terminal = read(env["CMUX_NEXT_GHOSTTY_CONFIG"]).splitlines() if look_terminal_lines(look) else []
        appearance = json.loads(read(env["CMUX_NEXT_CONFIG_FILE"])).get("appearance") or {}
    except (KeyError, OSError, ValueError) as error:
        return f"the launch's config files were not read: {error!r}"
    missing = [line for line in look_terminal_lines(look) if line not in terminal]
    wanted = look_config({}, look).get("appearance") or {}
    missing += [f"appearance.{key}" for key, value in wanted.items() if appearance.get(key) != value]
    return f"not in the launch's config: {missing}" if missing else None


def look_resolved(look, backdrop, settings):
    """What the running app says that its window shows, and why that is not the look: (resolved, problem), problem
    None when it is the look, and for an opaque window (which is read and never fails). `backdrop` is `debug.themes`'
    `windows[0].backdrop`: `picture` is the id of the picture that the window shows (empty with none); the alpha of
    `tint` (`#RRGGBBAA`: the theme tint over the picture or the desktop) is the opacity the app resolved, Liquid
    Glass carries that tint itself (`glassTint`), and an opaque window paints its `sheet` and shows no tint.
    `settings` is the app's own answer (`settings.get`) for each `appearance` key. `resolved` holds the background's
    kind (`picture` or `none`), the picture's id, the opacity, `glass`, and `blur`: the app's settings answer. The
    look fails when a named settings key has another value in the app, when `background` names a picture that the
    window does not show, or when the shown opacity is not the named `opacity` (to 1.5 steps of the alpha's 255)."""
    backdrop = backdrop if isinstance(backdrop, dict) else {}
    settings = settings if isinstance(settings, dict) else {}

    def alpha(name):
        text = backdrop.get(name) or ""
        try:
            return int(text[7:9], 16) / 255 if isinstance(text, str) and len(text) == 9 and text[0] == "#" else None
        except ValueError:
            return None

    picture = backdrop.get("picture") or ""
    tint, glass = alpha("tint"), alpha("glassTint")
    opacity = tint if tint is not None else glass if glass is not None else 1.0 if backdrop.get("sheet") else None
    resolved = {"background": "picture" if picture else "none", "picture": picture,
                "opacity": None if opacity is None else round(opacity, 3), "glass": tint is None and glass is not None,
                "blur": settings.get("backgroundBlur"), "settings": settings}
    if not look:
        return resolved, None

    def same(seen, value):
        number = isinstance(value, float) and isinstance(seen, (int, float)) and not isinstance(seen, bool)
        return abs(seen - value) <= 1e-9 if number else seen == value

    wanted = look_config({}, look).get("appearance") or {}
    faults = [f"appearance.{key} is {settings.get(key)!r} in the app's settings, not {value!r}"
              for key, value in wanted.items() if not same(settings.get(key), value)]
    name = look.get("background")
    if name == "none" and picture:
        faults.append(f"the window shows the picture {picture!r}, not none")
    elif name in ("daily", "desktop") and not picture:
        faults.append(f"the window shows no picture, not the {name} one")
    elif name not in (None, "none", "daily", "desktop") and picture != name:
        faults.append(f"the window shows the picture {picture!r}, not {name!r}")
    if "opacity" in look and (opacity is None or abs(opacity - look["opacity"]) > 1.5 / 255):
        faults.append(f"the window's opacity is {resolved['opacity']!r}, not {look['opacity']!r}")
    return resolved, "; ".join(faults) or None


def look_kind(resolved):
    """One word for what the app shows (`resolved` of `look_resolved`), for a name: `picture` (the window shows a
    picture, under a tint or under glass), `glass` (no picture; the glass carries the tint), `seethrough` (no picture
    and no glass; the tint's opacity is below 1) or `opaque`. None when the app's backdrop gave no opacity and no
    picture (it was not read). The word has no value of the look and no picture's name."""
    if not isinstance(resolved, dict):
        return None
    if resolved.get("picture"):
        return "picture"
    opacity = resolved.get("opacity")
    if opacity is None:
        return None
    if resolved.get("glass"):
        return "glass"
    return "seethrough" if opacity < 1 else "opaque"


def shown_look(rpc, look, monotonic=time.monotonic, sleep=time.sleep, seconds=10.0, step=0.5):
    """Asks the running app what its first window shows: (facts, problem). `rpc(method, params=None)` is the caller's
    socket call. The settings answer is read one time; the backdrop is read until it is the look and its tint blends
    no more, for `seconds` at most (a picture loads and a tint blends after the launch). An opaque window is read one
    time and has no problem. `facts` holds `resolved` (`look_resolved`), `kind` (`look_kind`), `backdrop_shown` (the
    backdrop as the app gave it) and `terminal_background` (the terminal's own background color, as the app says it)."""
    answer = rpc("settings.get", {"path": "appearance"})
    settings = answer.get("value") if isinstance(answer, dict) and isinstance(answer.get("value"), dict) else {"not read": answer}
    deadline = monotonic() + seconds
    while True:
        themes = rpc("debug.themes")
        windows = themes.get("windows") if isinstance(themes, dict) else None
        shown = windows[0].get("backdrop") if isinstance(windows, list) and windows and isinstance(windows[0], dict) else None
        resolved, problem = look_resolved(look, shown, settings)
        blending = isinstance(shown, dict) and shown.get("blending") == "true"
        if not look or not (problem or blending) or monotonic() > deadline:
            break
        sleep(step)  # test harness: the picture's load and the tint's blend, between 2 reads of the app
    facts = {"resolved": resolved, "kind": look_kind(resolved), "backdrop_shown": shown,
             "terminal_background": themes.get("ghostty_background") if isinstance(themes, dict) else None}
    return facts, problem
