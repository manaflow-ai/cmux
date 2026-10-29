#!/usr/bin/env python3
"""Capture release-note media for one changelog feature on a fleet Mac.

    scripts/release-media/release_media.py scenes/0.64.25/light-mode-terminals.json \\
        --host <capture-mac> [--allow-1x] [--keep-app] [--dry-run]

Reads a scene file, runs host_agent.py on the capture host over SSH (it
installs the latest nightly there, sets up the scene with the cmux CLI and
captures the window), copies the raw capture back, encodes it to the
changelog media convention, writes it under web/public/changelog/<version>/,
and points the feature's entry in changelog-media.ts at it.

See README.md for the scene format and host requirements.
"""
import argparse
import base64
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
MEDIA_TS = os.path.join(REPO, "web", "app", "[locale]", "(landing)", "docs", "changelog", "changelog-media.ts")
PUBLIC = os.path.join(REPO, "web", "public")

CLIP_BUDGET_BYTES = 2 * 1024 * 1024
CLIP_FPS = 30
DEFAULT_WIDTH = 1600
DEFAULT_MATTE = "#fafafa"

HIDPI_ASK = """\
  HiDPI: attach a 4K HDMI dummy plug and set it to "looks like 1920x1080",
  or create a headless HiDPI virtual display (BetterDisplay)."""

SCREEN_RECORDING_ASK = """\
  Screen Recording: over Screen Sharing, approve CuaSshScreenCapture under
  System Settings > Privacy & Security > Screen & System Audio Recording
  (`cua-ssh permission-request <host> --screen-recording` installs it and
  raises the prompt), or approve sshd-keygen-wrapper for direct SSH captures."""

HOST_ASK = """\
{host} cannot capture release media yet: {reason}.
Operator step on {host} (needs Screen Sharing):

{step}

Keep the host out of other GUI work while capturing.
"""

SCENE_KEYS = {"version", "feature", "slug", "window", "capture", "tryIt", "settings", "setup", "zshrc", "output", "notes"}


class SceneError(ValueError):
    pass


# Scenes ---------------------------------------------------------------------


def load_scene(path):
    with open(path) as handle:
        scene = json.load(handle)
    validate_scene(scene)
    return scene


def validate_scene(scene):
    unknown = set(scene) - SCENE_KEYS
    if unknown:
        raise SceneError("unknown scene keys: " + ", ".join(sorted(unknown)))
    for key in ("version", "feature", "slug", "window", "capture"):
        if key not in scene:
            raise SceneError("scene is missing " + key)
    if not re.fullmatch(r"\d+\.\d+\.\d+", scene["version"]):
        raise SceneError("version must look like 0.64.25")
    if not re.fullmatch(r"[a-z0-9]+(-[a-z0-9]+)*", scene["slug"]):
        raise SceneError("slug must be lowercase words joined by hyphens")
    window = scene["window"]
    if not all(isinstance(window.get(k), (int, float)) and window[k] > 0 for k in ("width", "height")):
        raise SceneError("window needs positive width and height in points")
    capture = scene["capture"]
    if capture.get("type") == "screenshot":
        pass
    elif capture.get("type") == "clip":
        seconds = capture.get("seconds")
        if not isinstance(seconds, (int, float)) or not 5 <= seconds <= 10:
            raise SceneError("clips run 5-10 s")
        poster_at = capture.get("posterAt", seconds / 2)
        if not 0 <= poster_at < seconds:
            raise SceneError("posterAt must fall inside the clip")
        for step in capture.get("during", []):
            if not 0 <= float(step.get("at", -1)) < seconds:
                raise SceneError("every during step needs an `at` inside the clip")
            validate_step(step)
    else:
        raise SceneError('capture.type is "screenshot" or "clip"')
    for step in scene.get("setup", []):
        validate_step(step)
    if "matte" in scene.get("output", {}) and not re.fullmatch(r"#[0-9a-fA-F]{6}", scene["output"]["matte"]):
        raise SceneError("output.matte is a #rrggbb color")


def validate_step(step):
    kinds = [k for k in ("cmux", "sleep", "settings") if k in step]
    if len(kinds) != 1:
        raise SceneError("each step has exactly one of cmux, sleep, settings: {!r}".format(step))
    if "cmux" in step and not (isinstance(step["cmux"], list) and step["cmux"]):
        raise SceneError("cmux steps are argument lists: {!r}".format(step))


# Host agent -----------------------------------------------------------------


def run_agent(host, scene, allow_1x, keep_app):
    with open(os.path.join(HERE, "window_probe.swift")) as handle:
        probe_source = handle.read()
    payload = {
        "scene": scene,
        "options": {"allow1x": allow_1x, "keepApp": keep_app},
        "probeSource": probe_source,
    }
    encoded = base64.b64encode(json.dumps(payload).encode()).decode()
    with open(os.path.join(HERE, "host_agent.py"), "rb") as agent:
        proc = subprocess.run(
            ["ssh", "-o", "BatchMode=yes", host, "python3 - " + encoded],
            stdin=agent,
            stdout=subprocess.PIPE,
            universal_newlines=True,
        )
    lines = [line for line in proc.stdout.splitlines() if line.startswith("RESULT ")]
    if not lines:
        raise SystemExit("host agent on {} exited {} without a result".format(host, proc.returncode))
    return json.loads(lines[-1][len("RESULT "):])


def explain_failure(host, result):
    code = result["error"]
    print("error: {} ({})".format(result["message"], code), file=sys.stderr)
    for line in result.get("details", {}).get("processes", []):
        print("  " + line, file=sys.stderr)
    step = {"not-hidpi": HIDPI_ASK, "no-screen-recording": SCREEN_RECORDING_ASK}.get(code)
    if step:
        print("", file=sys.stderr)
        print(HOST_ASK.format(host=host, reason=result["message"], step=step.replace("<host>", host)), file=sys.stderr)
    if code == "not-hidpi":
        print("Pass --allow-1x to capture at 1x anyway (half the resolution the site expects).", file=sys.stderr)
    return 2


def fetch(host, remote_path, local_dir):
    subprocess.run(["scp", "-q", "-r", "{}:{}".format(host, remote_path), local_dir], check=True)
    return os.path.join(local_dir, os.path.basename(remote_path))


# Encoding -------------------------------------------------------------------


def ffmpeg(*args):
    # Encoding runs on the operator's Mac: stay at low priority behind other work.
    subprocess.run(["nice", "-n", "10", "ffmpeg", "-hide_banner", "-loglevel", "error", "-y"] + list(args), check=True)


def probe_size(path):
    out = subprocess.run(
        ["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
         "-of", "json", path],
        stdout=subprocess.PIPE, check=True, universal_newlines=True,
    ).stdout
    stream = json.loads(out)["streams"][0]
    return stream["width"], stream["height"]


def fit_filter(source_width, out_width):
    """Scale down to out_width only when needed, then trim to even dimensions.

    Rounding the height up with scale=W:-2 would stretch a 1x capture by a row.
    """
    scale = "scale={}:-1:flags=lanczos,".format(out_width) if out_width < source_width else ""
    return scale + "crop=trunc(iw/2)*2:trunc(ih/2)*2:0:0"


def encode_still(src, out, target_width):
    width, _ = probe_size(src)
    if width <= target_width:
        shutil.copyfile(src, out)
    else:
        ffmpeg("-i", src, "-vf", "scale={}:-1:flags=lanczos".format(target_width), out)


def concat_list(frames, frames_dir, seconds):
    """ffconcat for timestamped frames: each frame lasts until the next one."""
    lines = ["ffconcat version 1.0"]
    for index, frame in enumerate(frames):
        end = frames[index + 1]["t"] if index + 1 < len(frames) else seconds
        lines.append("file '{}'".format(os.path.join(frames_dir, frame["file"])))
        lines.append("duration {:.3f}".format(max(end - frame["t"], 0.001)))
    # The concat demuxer ignores the last duration unless the file repeats.
    lines.append("file '{}'".format(os.path.join(frames_dir, frames[-1]["file"])))
    return "\n".join(lines) + "\n"


def flatten_clip(capture, workdir, width, matte, crop):
    """One lossless 30 fps master with the window's transparent corners on `matte`."""
    master = os.path.join(workdir, "master.mkv")
    if capture["kind"] == "frames":
        listing = os.path.join(workdir, "frames.ffconcat")
        with open(listing, "w") as handle:
            handle.write(concat_list(capture["frames"], capture["local"], capture["seconds"]))
        source = ["-f", "concat", "-safe", "0", "-i", listing]
        src_w, src_h = probe_size(os.path.join(capture["local"], capture["frames"][0]["file"]))
    else:
        source = ["-i", capture["local"]]
        src_w, src_h = probe_size(capture["local"])
    pre = ""
    if crop and (src_w, src_h) != (crop["w"], crop["h"]):
        # screencapture recorded the whole display: cut the window out. Any
        # other size (a window plus its shadow, say) has no known offset.
        if (src_w, src_h) != (crop["displayW"], crop["displayH"]):
            raise SystemExit("clip is {}x{}, neither the window ({}x{}) nor the display".format(
                src_w, src_h, crop["w"], crop["h"]))
        pre = "crop={w}:{h}:{x}:{y},".format(**crop)
        src_w, src_h = crop["w"], crop["h"]
    graph = (
        "color=c={matte}:s={w}x{h}:r={fps}[bg];"
        "[0:v]{pre}format=rgba[fg];"
        "[bg][fg]overlay=shortest=1:format=auto,fps={fps},{fit}"
    ).format(matte=matte, w=src_w, h=src_h, fps=CLIP_FPS, pre=pre, fit=fit_filter(src_w, min(src_w, width)))
    ffmpeg(*source, "-filter_complex", graph, "-c:v", "ffv1", "-an", master)
    return master


def encode_under_budget(master, out, codec_args, crf_values):
    for crf in crf_values:
        ffmpeg("-i", master, *codec_args(crf), "-an", out)
        if os.path.getsize(out) <= CLIP_BUDGET_BYTES:
            return crf
    raise SystemExit("{} stays over {} bytes at every quality step".format(out, CLIP_BUDGET_BYTES))


def encode_clip(master, stem, poster_at):
    mp4, webm, poster = stem + ".mp4", stem + ".webm", stem + "-poster.png"
    mp4_crf = encode_under_budget(
        master, mp4,
        lambda crf: ["-c:v", "libx264", "-preset", "medium", "-crf", str(crf), "-pix_fmt", "yuv420p",
                     "-profile:v", "high", "-movflags", "+faststart"],
        range(20, 40, 3),
    )
    webm_crf = encode_under_budget(
        master, webm,
        lambda crf: ["-c:v", "libvpx-vp9", "-b:v", "0", "-crf", str(crf), "-deadline", "good", "-cpu-used", "4",
                     "-row-mt", "1", "-pix_fmt", "yuv420p"],
        range(30, 52, 4),
    )
    ffmpeg("-ss", "{:.3f}".format(poster_at), "-i", master, "-frames:v", "1", poster)
    return {"mp4": mp4, "webm": webm, "poster": poster, "mp4Crf": mp4_crf, "webmCrf": webm_crf}


# changelog-media.ts ---------------------------------------------------------


def matching_brace(text, start):
    """Index of the brace closing text[start], skipping strings and comments."""
    pairs = {"{": "}", "[": "]"}
    stack = []
    i = start
    while i < len(text):
        c = text[i]
        if c in "\"'`":
            i += 1
            while text[i] != c:
                i += 2 if text[i] == "\\" else 1
        elif text.startswith("//", i):
            i = text.index("\n", i)
        elif text.startswith("/*", i):
            i = text.index("*/", i) + 1
        elif c in pairs:
            stack.append(pairs[c])
        elif c in "}]":
            if not stack or stack.pop() != c:
                raise ValueError("unbalanced {} at {}".format(c, i))
            if not stack:
                return i
        i += 1
    raise ValueError("no closing brace for index {}".format(start))


def top_level_objects(text, open_index):
    """(start, end) of each `{...}` directly inside the array opened at open_index."""
    close = matching_brace(text, open_index)
    objects, i = [], open_index + 1
    while i < close:
        if text[i] == "{":
            end = matching_brace(text, i)
            objects.append((i, end))
            i = end
        i += 1
    return objects


def remove_property(body, name):
    """Drop `name: <value>,` (one line, or a braced multi-line value) from an object body."""
    match = re.search(r"\n[ \t]*" + name + r":[ \t]*", body)
    if not match:
        return body
    value_start = match.end()
    if body[value_start] == "{":
        value_end = matching_brace(body, value_start) + 1
    else:
        value_end = body.index("\n", value_start)
        # A long string may sit on the next line under `name:`.
        if body[match.end():value_end].strip() == "":
            value_end = body.index("\n", value_end + 1)
    if body[value_end:value_end + 1] == ",":
        value_end += 1
    return body[:match.start()] + body[value_end:]


def patch_media_ts(text, version, feature, media, try_it=None):
    """Point one feature at `media` ({"image": path} or {"video": {...}})."""
    anchor = text.index("export const changelogMedia")
    key = re.compile(r'\n  "' + re.escape(version) + r'": \{').search(text, anchor)
    if not key:
        raise SystemExit("changelog-media.ts has no {} entry; write its recap first".format(version))
    block_start = key.end() - 1
    block_end = matching_brace(text, block_start)
    features = re.compile(r"\n    features: \[").search(text, block_start, block_end)
    if not features:
        raise SystemExit("{} has no features list".format(version))
    title = "title: " + json.dumps(feature, ensure_ascii=False) + ","
    for start, end in top_level_objects(text, features.end() - 1):
        body = text[start:end]
        if title not in body:
            continue
        body = remove_property(remove_property(body, "image"), "video")
        indent = " " * 8
        lines = []
        if "image" in media:
            lines.append("{}image: {},".format(indent, json.dumps(media["image"])))
        else:
            lines.append(indent + "video: {")
            for field in ("src", "webm", "poster"):
                lines.append("{}  {}: {},".format(indent, field, json.dumps(media["video"][field])))
            lines.append(indent + "},")
        if try_it and not re.search(r"\n[ \t]*tryIt:", body):
            lines.append("{}tryIt: {},".format(indent, json.dumps(try_it, ensure_ascii=False)))
        body = body.rstrip(" \n") + "\n" + "\n".join(lines) + "\n      "
        return text[:start] + body + text[end:]
    raise SystemExit("{} has no feature titled {!r}".format(version, feature))


# Main -----------------------------------------------------------------------


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("scene", help="scene JSON file")
    parser.add_argument("--host", required=True, help="capture host (ssh name)")
    parser.add_argument("--allow-1x", action="store_true", help="capture on a 1x display anyway")
    parser.add_argument("--keep-app", action="store_true", help="leave the nightly running afterwards")
    parser.add_argument("--dry-run", action="store_true", help="capture and encode, but write nothing into web/")
    parser.add_argument("--workdir", help="keep raw and encoded files here (default: a temp dir)")
    args = parser.parse_args(argv)

    scene = load_scene(args.scene)
    workdir = args.workdir or tempfile.mkdtemp(prefix="release-media-")
    os.makedirs(workdir, exist_ok=True)

    result = run_agent(args.host, scene, args.allow_1x, args.keep_app)
    if "error" in result:
        return explain_failure(args.host, result)
    for warning in result["warnings"]:
        print("warning: " + warning, file=sys.stderr)

    output = scene.get("output", {})
    width = output.get("width", DEFAULT_WIDTH)
    stem = os.path.join(workdir, scene["slug"])
    capture = result["capture"]
    if capture["kind"] == "still":
        encode_still(fetch(args.host, capture["path"], workdir), stem + ".png", width)
        produced = {"image": stem + ".png"}
    else:
        remote = capture["dir"] if capture["kind"] == "frames" else capture["path"]
        capture["local"] = fetch(args.host, remote, workdir)
        window, scale = result["window"], result["display"]["scale"]
        crop = {k: int(round(window[v] * scale)) for k, v in (("x", "x"), ("y", "y"), ("w", "width"), ("h", "height"))}
        crop["displayW"], crop["displayH"] = result["display"]["pixelsWide"], result["display"]["pixelsHigh"]
        master = flatten_clip(capture, workdir, width, output.get("matte", DEFAULT_MATTE), crop)
        seconds = float(scene["capture"]["seconds"])
        produced = encode_clip(master, stem, float(scene["capture"].get("posterAt", seconds / 2)))

    # Everything the host produced is in the workdir now.
    subprocess.run(["ssh", "-o", "BatchMode=yes", args.host, "rm -rf " + shlex.quote(result["rundir"])], check=False)

    receipt = {
        "host": args.host,
        "nightly": result["nightly"],
        "backend": result["backend"],
        "display": result["display"],
        "warnings": result["warnings"],
        "files": {},
    }
    web_dir = "/changelog/{}/".format(scene["version"])
    dest_dir = os.path.join(PUBLIC, "changelog", scene["version"])
    for kind in ("image", "mp4", "webm", "poster"):
        if kind not in produced:
            continue
        path = produced[kind]
        w, h = probe_size(path)
        receipt["files"][web_dir + os.path.basename(path)] = {"bytes": os.path.getsize(path), "width": w, "height": h}
        if not args.dry_run:
            os.makedirs(dest_dir, exist_ok=True)
            shutil.copyfile(path, os.path.join(dest_dir, os.path.basename(path)))
    if "image" in produced:
        media = {"image": web_dir + scene["slug"] + ".png"}
    else:
        media = {"video": {
            "src": web_dir + scene["slug"] + ".mp4",
            "webm": web_dir + scene["slug"] + ".webm",
            "poster": web_dir + scene["slug"] + "-poster.png",
        }}
    if not args.dry_run:
        with open(MEDIA_TS) as handle:
            text = handle.read()
        with open(MEDIA_TS, "w") as handle:
            handle.write(patch_media_ts(text, scene["version"], scene["feature"], media, scene.get("tryIt")))
    receipt["media"] = media
    with open(os.path.join(workdir, "receipt.json"), "w") as handle:
        json.dump(receipt, handle, indent=2)
    print(json.dumps(receipt, indent=2))
    print("raw and encoded files: " + workdir, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
