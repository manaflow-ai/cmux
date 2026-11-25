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
  SETTINGS.PATH=VALUE    any other key of the app config, by its path (a key with a dot: `ui.animationSpeed=off`,
                         `appearance.metrics.titlebarHeight=40`): a number, `true` or `false` is that value, each
                         other text is a text (letters, digits, `.`, `_`, `-` and spaces between its words; a `+`
                         between 2 words is a space, for an argument that can have no space)
  name=WORD              the look's name (small letters, digits, `-`): then each row's or film's name has the name
                         and no value of the look

The tool then asks the app itself, not a file: `settings.get` for the `appearance` keys and for the app's whole
settings, `debug.motion` for the speed that the motion runs at, and `debug.themes` for the window's backdrop (the id
of the picture that the window shows, and the alpha of the tint over it: the opacity that the app resolved).
`shown_look` waits for a picture's load and a tint's blend, and gives the fault of a window that does not show the
look, or of an app that holds another value for a key of the look. The debug read has no field for the blur:
`resolved.blur` is the app's settings answer. `look_head` gives a report's first lines: each key that the launch wrote
with the app's answer beside it, and each other setting that the app holds.

A look that names a theme (`appearance.theme=NAME`): the app's answer has no name of the theme that it resolved, so
`shown_look` checks the theme by the ground (`look_theme`): the window's ground is the ground of the file with that
name in the theme folder of the app's own bundle. It proves that and no more. Its line says how many of the bundle's
theme files have that ground: with more than one, the name is not proved. A theme of the user's own folder is not
in the bundle: such a look fails the check.

No app and no socket in this file: the caller gives its own `rpc`. Tests: scripts/measure/tests/window-look.test.py
"""
import json
import os
import time

SHORT = {"background": "appearance.background", "opacity": "appearance.backgroundOpacity", "blur": "appearance.backgroundBlur"}
LETTERS, DIGITS = "abcdefghijklmnopqrstuvwxyz", "0123456789"


def window_look(value):
    """None for `opaque` (and for no option), or the keys that the option names (a `-` of a short key is a `_` here;
    a settings path stays as it is, with its value as the settings file has it). Another word, a key two times (a
    short key and its own path, or a path under another path, are one key), or no config key at all, raises
    ValueError."""
    if value is None or value == "opaque":
        return None
    refused = ValueError("--window-look takes opaque or KEY=VALUE[,KEY=VALUE...] with background=NAME, opacity=0..1, "
                         "blur=frosted|glass|glass-clear|none, terminal-opacity=0..1, terminal-blur=RADIUS, "
                         "behind=desktop|checker|stripes, SETTINGS.PATH=VALUE and name=WORD (one config key at least, "
                         f"no settings key two times), not {value!r}")
    look = {}
    for part in value.split(","):
        key, equals, text = (piece.strip() for piece in part.partition("="))
        if "." in key:  # a path of the app's settings
            words = key.split(".")
            if "+" in text:  # a `+` between 2 words of a value is a space (an argument that can have no space)
                pieces = text.split("+")
                if any(not piece or piece != piece.strip() for piece in pieces):
                    raise refused
                text = " ".join(pieces)
            if not equals or key in look or not text or text.strip(LETTERS + LETTERS.upper() + DIGITS + "._- ") or ".." in text:
                raise refused
            if any(not word or not word[0].isalpha() or word.strip(LETTERS + LETTERS.upper() + DIGITS) for word in words):
                raise refused
            look[key] = text
            if text in ("true", "false"):
                look[key] = text == "true"
            elif not text.strip(DIGITS + ".-"):  # digits, a point, a minus: a number or nothing
                try:
                    look[key] = float(text) if "." in text else int(text)
                except ValueError:
                    raise refused from None
            continue
        key = key.replace("-", "_")
        if not equals or key in look:
            raise refused
        try:
            if key == "name":
                found = text if text and not text.strip(LETTERS + DIGITS + "-") else None
            elif key == "background":
                found = text if text and not text.strip(LETTERS + DIGITS + "-") else None
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
    if not set(look) - {"behind", "name"}:
        raise refused
    paths = list(look_paths(look))
    if any(other.startswith(one + ".") for one in paths for other in paths) or len(paths) != len([key for key in look if key in SHORT or "." in key]):
        raise refused
    return look


def look_tag(look):
    """The part a look adds to a row's or a film's name: `look-` and the look's `name` when it has one (then no value
    is in the name), else each named key and its value in the option's order (a settings path by its last word, a
    value's space as a `-`); then what the window is over when that is not the desktop. An opaque window adds
    nothing."""
    if not look:
        return ""
    parts = [f"{key.replace('_', '-').rpartition('.')[2]}-{format(value, 'g') if isinstance(value, float) else value}".replace(" ", "-")
             for key, value in look.items() if key not in ("behind", "name")]
    over = "" if look.get("behind", "desktop") == "desktop" else f"-over-{look['behind']}"
    return "look-" + (look["name"] if "name" in look else "-".join(parts)) + over


def look_paths(look):
    """Each settings path that the look writes to the app config, and its value, in the option's order: `background`,
    `opacity` and `blur` as `appearance.background`, `appearance.backgroundOpacity` and `appearance.backgroundBlur`,
    and each key with a dot as it is. No terminal key, no `behind`, no `name`."""
    return {SHORT.get(key, key): value for key, value in (look or {}).items() if key in SHORT or "." in key}


def look_value(config, path):
    """The value of the settings `path` (words with dots) in `config`, None when it is not there."""
    for word in path.split("."):
        config = config.get(word) if isinstance(config, dict) else None
    return config


def look_config(config, look):
    """The app config with each settings path of the look (`look_paths`: a copy; the other keys stay, and a key that
    the look does not name is not written). An opaque window gets `config` itself."""
    if not look:
        return config
    made = dict(config)
    for path, value in look_paths(look).items():
        *groups, last = path.split(".")
        group = made
        for word in groups:
            group[word] = dict(group[word]) if isinstance(group.get(word), dict) else {}
            group = group[word]
        group[last] = value
    return made


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
    the launch's own environment must hold each settings path of the look, and its terminal config file each named
    line (a look with no terminal line does not read that file)."""
    if not look:
        return None
    read = read or (lambda path: open(path).read())
    try:
        terminal = read(env["CMUX_NEXT_GHOSTTY_CONFIG"]).splitlines() if look_terminal_lines(look) else []
        held = json.loads(read(env["CMUX_NEXT_CONFIG_FILE"]))
    except (KeyError, OSError, ValueError) as error:
        return f"the launch's config files were not read: {error!r}"
    missing = [line for line in look_terminal_lines(look) if line not in terminal]
    missing += [path for path, value in look_paths(look).items() if look_value(held, path) != value]
    return f"not in the launch's config: {missing}" if missing else None


def same_value(seen, value):
    """If the app's answer `seen` is the look's `value`: a number is the same whole or with a point (to 1e-9), and
    true is not 1."""
    if isinstance(seen, bool) != isinstance(value, bool):
        return False
    number = isinstance(value, float) and isinstance(seen, (int, float)) and not isinstance(seen, bool)
    return abs(seen - value) <= 1e-9 if number else seen == value


def look_resolved(look, backdrop, settings, root=None, motion=None):
    """What the running app says that its window shows, and why that is not the look: (resolved, problem), problem
    None when it is the look, and for an opaque window (which is read and never fails). `backdrop` is `debug.themes`'
    `windows[0].backdrop`: `picture` is the id of the picture that the window shows (empty with none); the alpha of
    `tint` (`#RRGGBBAA`: the theme tint over the picture or the desktop) is the opacity the app resolved, Liquid
    Glass carries that tint itself (`glassTint`), and an opaque window paints its `sheet` and shows no tint.
    `settings` is the app's own answer (`settings.get`) for each `appearance` key. `resolved` holds the background's
    kind (`picture` or `none`), the picture's id, the opacity, `glass`, and `blur`: the app's settings answer.
    `root` is the app's answer for its whole settings (`settings.get` with no path: what the app holds of its
    settings file, so a setting that is not there is at the app's default); `resolved` has it as `app_settings`,
    each path with its value, None when it was not read. `motion` is `debug.motion`'s answer; `resolved` has the
    speed that the motion runs at as `motion_speed`. The look fails when a named settings key has another value in
    the app (a short key in `settings`, a path in `root`), when `ui.animationSpeed` is named and the motion runs at
    another speed, when `background` names a picture that the window does not show, or when the shown opacity is
    not the named `opacity` (to 1.5 steps of the alpha's 255)."""
    backdrop = backdrop if isinstance(backdrop, dict) else {}
    settings = settings if isinstance(settings, dict) else {}

    def alpha(name):
        text = backdrop.get(name) or ""
        try:
            return int(text[7:9], 16) / 255 if isinstance(text, str) and len(text) == 9 and text[0] == "#" else None
        except ValueError:
            return None

    def leaves(group, before=""):
        return {path: value for key, inner in group.items()
                for path, value in (leaves(inner, f"{before}{key}.") if isinstance(inner, dict) and inner else {f"{before}{key}": inner}).items()}

    picture = backdrop.get("picture") or ""
    tint, glass = alpha("tint"), alpha("glassTint")
    opacity = tint if tint is not None else glass if glass is not None else 1.0 if backdrop.get("sheet") else None
    speed = motion.get("speed") if isinstance(motion, dict) else None
    resolved = {"background": "picture" if picture else "none", "picture": picture,
                "opacity": None if opacity is None else round(opacity, 3), "glass": tint is None and glass is not None,
                "blur": settings.get("backgroundBlur"), "settings": settings,
                "app_settings": leaves(root) if isinstance(root, dict) else None, "motion_speed": speed}
    if not look:
        return resolved, None
    names = {key: path.rpartition(".")[2] for key, path in SHORT.items()}  # a short key's name in `appearance`
    faults = [f"appearance.{name} is {settings.get(name)!r} in the app's settings, not {look[key]!r}"
              for key, name in names.items() if key in look and not same_value(settings.get(name), look[key])]
    faults += [f"{path} is {look_value(root, path)!r} in the app's settings, not {value!r}"
               for path, value in look.items() if "." in path and not same_value(look_value(root, path), value)]
    if "ui.animationSpeed" in look and speed != look["ui.animationSpeed"]:
        faults.append(f"the app's motion speed is {speed!r}, not {look['ui.animationSpeed']!r}")
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


def theme_ground(text):
    """The ground of a theme file's `text`: the color of its `background` line as 6 hex digits in small letters. None
    when the file has no such line, or the line holds no such color."""
    for line in text.splitlines() if isinstance(text, str) else []:
        key, equals, value = line.partition("=")
        if equals and key.strip() == "background":
            color = value.strip().removeprefix("#").lower()
            return color if len(color) == 6 and not color.strip(DIGITS + "abcdef") else None
    return None


def theme_grounds(folder, read=None, names=None):
    """Each theme file of `folder` (the theme folder that the app names in its own bundle) with its ground
    (`theme_ground`; None for a file that was not read or has none). None when there is no folder or its list was
    not read. `read(path)` gives a file's text and `names(folder)` the folder's file names."""
    read = read or (lambda path: open(path, encoding="utf-8", errors="replace").read())
    try:
        found = sorted((names or os.listdir)(folder)) if isinstance(folder, str) and folder else None
    except OSError:
        found = None
    if found is None:
        return None
    grounds = {}
    for name in found:
        try:
            grounds[name] = theme_ground(read(f"{folder.rstrip('/')}/{name}"))
        except OSError:
            grounds[name] = None
    return grounds


def look_theme(look, themes, grounds):
    """The check of the look's theme (the settings path `appearance.theme`): (line, problem), problem None when the
    check passed, and (None, None) for a look that names no theme. `themes` is `debug.themes`' answer and `grounds`
    is `theme_grounds` of the app's bundle. The app's answer has no name of the theme that it resolved, so the check
    is by the ground, and it proves this and no more: the window's ground (`windows[0].window_background`) is the
    ground of the file with the theme's name in the app's bundle. The line has the count of the bundle's files with
    that ground: with more than one, the name is not proved. An answer with no `window_background`, a bundle with
    files that were not read, no file of the theme, or a file with no `background` line fails: none of them passes."""
    name = (look or {}).get("appearance.theme")
    if not isinstance(name, str):
        return None, None

    def failed(text):
        return f"theme check: {text}", f"theme check: {text}"

    windows = themes.get("windows") if isinstance(themes, dict) else None
    window = windows[0] if isinstance(windows, list) and windows and isinstance(windows[0], dict) else {}
    shown = theme_ground(f"background = {window.get('window_background')}") if isinstance(window.get("window_background"), str) else None
    if shown is None:
        return failed("the app's answer has no window_background: the window's ground was not read")
    if not isinstance(grounds, dict):
        return failed("the theme files of the app's bundle were not read: the theme is not proved")
    if name not in grounds:
        return failed("the app's bundle has no file of the look's theme: the theme is not proved")
    if grounds[name] is None:
        return failed("the theme's file in the app's bundle has no background line: the theme is not proved")
    if shown != grounds[name]:
        return failed(f"the window's ground is #{shown}, not #{grounds[name]}, the ground of the theme's file in the app's bundle")
    same = sum(1 for ground in grounds.values() if ground == shown)
    return (f"theme check: the window's ground = the ground of the theme's file in the app's bundle; {same} of the {len(grounds)} "
            f"theme files of the bundle {'has' if same == 1 else 'have'} that ground" + (": the name is not proved" if same > 1 else ""), None)


def look_head(look, facts):
    """A report's first lines about the app's settings, from `shown_look`'s `facts`: each settings path of the look
    with what the launch wrote and the app's own answer for it (`NOT THE LOOK` when they differ), each other setting
    that the app holds, and the speed that the motion runs at. `NOT READ` where the app gave no answer: no line says
    a default as a fact of the app then. The last line is the theme check's (`look_theme`) for a look with a theme."""
    resolved = facts.get("resolved") or {}
    held, speed = resolved.get("app_settings"), resolved.get("motion_speed")
    wrote = look_paths(look)
    named = f"window look {look['name']}" if look and "name" in look else "window look"
    lines = []
    for path, value in wrote.items():
        answer = "NOT READ" if held is None else repr(held.get(path)) + ("" if same_value(held.get(path), value) else " (NOT THE LOOK)")
        lines.append(f"{named}: {path}: the launch wrote {value!r}, the app answers {answer}")
    lines += [f"app setting, not of the look: {path} = {value!r}" for path, value in (held or {}).items() if path not in wrote]
    lines.append("each other setting: NOT READ" if held is None else "each other setting: not in the app's settings (the app's default)")
    lines.append(f"the app's motion speed: {'NOT READ' if speed is None else repr(speed)}")
    if facts.get("theme"):  # the line of `look_theme`: what the theme's check proves, and its count
        lines.append(facts["theme"])
    return lines


def shown_look(rpc, look, monotonic=time.monotonic, sleep=time.sleep, seconds=10.0, step=0.5, read=None, names=None):
    """Asks the running app what its first window shows: (facts, problem). `rpc(method, params=None)` is the caller's
    socket call. The settings answers (the `appearance` keys, then the whole settings) and the motion's answer are
    read one time: a read of the whole settings or of the motion that raises, or that is no such answer, is not
    read (None in `resolved`). The backdrop is read until it is the look and its tint blends no more, for `seconds`
    at most (a picture loads and a tint blends after the launch). An opaque window is read one time and has no
    problem. `facts` holds `resolved` (`look_resolved`), `kind` (`look_kind`), `backdrop_shown` (the backdrop as the
    app gave it), `terminal_background` (the terminal's own background color, as the app says it) and `theme` (the
    line of `look_theme`, None for a look that names no theme).
    A look that names a theme (`appearance.theme`) is checked by the ground, in this one place for each tool: the
    app says where the theme folder of its own bundle is (`debug.appearance` with no mode, which changes nothing),
    the folder's files are read one time (`read` and `names` as `theme_grounds` takes them), and the window's ground
    is in the same answer as the backdrop, so the wait is for the theme too. A theme that fails is in `problem`."""
    answer = rpc("settings.get", {"path": "appearance"})
    settings = answer.get("value") if isinstance(answer, dict) and isinstance(answer.get("value"), dict) else {"not read": answer}

    def ask(method, params):
        try:
            return rpc(method, params)
        except Exception:  # noqa: BLE001  a read for the report's head: the look's own rows say what a look needs
            return None

    whole = ask("settings.get", {})
    root = whole.get("value") if isinstance(whole, dict) and isinstance(whole.get("value"), dict) else None
    motion = ask("debug.motion", {"action": "read"})
    grounds = None
    if isinstance((look or {}).get("appearance.theme"), str):  # the bundle's theme files: one read, before the wait
        bundle = ask("debug.appearance", {})
        grounds = theme_grounds(bundle.get("themes") if isinstance(bundle, dict) else None, read, names)
    deadline = monotonic() + seconds
    while True:
        themes = rpc("debug.themes")
        windows = themes.get("windows") if isinstance(themes, dict) else None
        shown = windows[0].get("backdrop") if isinstance(windows, list) and windows and isinstance(windows[0], dict) else None
        resolved, problem = look_resolved(look, shown, settings, root, motion)
        theme, theme_problem = look_theme(look, themes, grounds)
        problem = "; ".join(part for part in (problem, theme_problem) if part) or None
        blending = isinstance(shown, dict) and shown.get("blending") == "true"
        if not look or not (problem or blending) or monotonic() > deadline:
            break
        sleep(step)  # test harness: the picture's load and the tint's blend, between 2 reads of the app
    facts = {"resolved": resolved, "kind": look_kind(resolved), "backdrop_shown": shown,
             "terminal_background": themes.get("ghostty_background") if isinstance(themes, dict) else None, "theme": theme}
    return facts, problem
