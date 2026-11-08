#!/usr/bin/env python3
"""Record each What's New item's clip: the feature in use, cropped to where it happens.

    whats-new-clips.py record ID [--sha SHA | --job JOB] [--out FILE]   capture on the fleet, then render
    whats-new-clips.py render ID --capture DIR [--out FILE]             a capture folder to the clip
    whats-new-clips.py publish ID FILE                                  upload it and point the item at it
    whats-new-clips.py check                                            every spec and clip line is valid
    whats-new-clips.py plan --base SHA --head SHA --out PLAN --tours DIR  what the nightly tour records
    whats-new-clips.py tours --plan PLAN --role ROLE --dir DIR          the planned tours of one role
    whats-new-clips.py publish-auto --plan PLAN --results DIR           render those, upload them

Leo, 2026-10-24: "I also think the What's New video is kind of, uh, it's like you're not even
showing anything properly off. It's just sort of weird." The nightly reel (reel.py) strings whole
windows of each pull request's tour together; this gives each What's New item (a highlight,
release-notes/next/highlights/ID.md) its own short loop that shows that one feature being used.

A clip's spec is release-notes/next/clips/ID.json:

    {
      "caption": "Right-click a workspace and archive it: it moves to the end of its group.",
      "frameInterval": 0.25,
      "settings": {...}, "launch_args": [...],
      "steps": [{"title": "Three workspaces", "rpc": {...}, "wait": 1},
                {"title": "Archive one", "cmux": [...], "wait": 1.5, "clip": true}],
      "crop": [0, 0, 0.32, 0.62]
    }

- `caption` says what you can now do; it is the clip's alt text and the panel shows it under the
  clip (the highlight's title stays the item's title).
- `settings`, `launch_args`, `frameInterval` and `steps` are a `cmux-ci capture` state (tour.py's
  step format). Steps without `"clip": true` set the scene up and are not in the clip; the clip runs
  from the first clip step's first frame to the frame the step after the last clip step starts at
  (or the stills), plus the frame before, so the clip opens on the state before the feature acts.
- `crop` is the part of the window that matters, as fractions of its width and height
  (x, y, w, h). Never the whole window: the panel shows a clip a few hundred points wide.
- `hold` (default HOLD seconds) keeps the last frame up before the loop starts over, and `lead`
  (default LEAD) the first one, so the eye finds the starting state.

`record` runs `cmux-ci capture SHA --state SPEC --video` (the fleet builds the DEV app for SHA,
drives it on a capture mini, and its text recognition reads every frame for private names; nothing
builds or runs on this Mac), then `render`. `render` crops the clip's frames, plays them at their
own pace, and writes an animated WebP that loops (the app shows WebP and no video in the panel,
ReleaseMediaStore). A clip must last MIN_SECONDS to MAX_SECONDS, fit MAX_BYTES, and change: a
clip whose frames are all alike is refused, since an idle window shows nothing. `publish` puts it
on the pr-media branch at whats-new/ID/<sha12>.webp (scripts/pr-media.py's privacy check reads
every frame first) and writes `clip: URL | SHA256` into the highlight, which release-notes.py
carries into the signed notes.

With no person: cmux-next-media.yml's nightly tour (a push to nightly-next) builds the previous
nightly tip and the new one. `plan` lists the New and Improved highlights the new tip adds that
have a spec and no `clip:` line, at most PLAN_LIMIT, and writes each spec as a tour.py tour; the
tour job runs them on the new tip's app (the clip) and, for an improvement, on the previous tip's
(its before). `publish-auto` renders each from the tour's capture.mov (or its stills), checks it
and puts it at whats-new/ID/clip-auto-ROLE.webp, where release-notes.py finds it with no write back
to the highlight. Those publish after the nightly is cut, so the highlight rides along with the
next one (release-notes.py late_pictures).

Encoding needs ffmpeg and img2webp (Homebrew `webp`, apt `webp`).
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from typing import Any

ROOT = Path(__file__).resolve().parents[3]
HIGHLIGHTS = ROOT / "release-notes/next/highlights"
SPECS = ROOT / "release-notes/next/clips"
# pr-capture's last line: "stills: DIR/light.png DIR/dark.png [video: ...]".
STILLS = re.compile(r"stills: (?P<dir>/\S+)/light\.png ")
REPO = "manaflow-ai/cmux"
BRANCH = "pr-media"
URL_PREFIX = f"https://raw.githubusercontent.com/{REPO}/{BRANCH}/whats-new/"
CLIP_LINE = re.compile(r"^clip:\s*(?P<url>\S+)\s*\|\s*(?P<sha256>[0-9a-f]{64})\s*$", re.M)
ID = re.compile(r"[a-z0-9][a-z0-9-]{0,79}")
SPEC_KEYS = {"caption", "frameInterval", "settings", "launch_args", "steps", "crop", "hold", "lead"}
MIN_SECONDS, MAX_SECONDS = 3.0, 8.0
HOLD, LEAD = 1.2, 0.6
# ReleaseMediaStore.maxImageBytes: the app drops a larger picture.
MAX_BYTES = 4 << 20
# Wider than the panel ever shows a clip; a crop narrower than this keeps its own width (never scaled up).
MAX_WIDTH = 960
# Two frames this alike (mean absolute difference of a small gray copy, 0 to 255) count as the same.
SAME = 0.6
QUALITIES = (80, 70, 60, 50)
# At most this many highlights a nightly tour records (each twice for an improvement); the rest wait.
PLAN_LIMIT = 4
AUTO_ROLES = ("after", "before")
# Spec step keys only `cmux-ci capture` reads: `clip` marks the clip's steps, `record` where its video starts.
CAPTURE_ONLY_STEP_KEYS = {"clip", "record"}


class ClipError(Exception):
    pass


def run(argv: list[str], **kw: Any) -> subprocess.CompletedProcess:
    done = subprocess.run(argv, capture_output=True, **kw)
    if done.returncode != 0:
        said = done.stderr if isinstance(done.stderr, str) else done.stderr.decode(errors="replace")
        raise ClipError(f"{Path(argv[0]).name} exited {done.returncode}: {said.strip()[-600:]}")
    return done


def load_spec(clip_id: str, specs: Path = SPECS) -> dict:
    if not ID.fullmatch(clip_id):
        raise ClipError(f"{clip_id!r} is not a highlight id")
    path = specs / f"{clip_id}.json"
    if not path.is_file():
        raise ClipError(f"no spec {path.relative_to(ROOT) if path.is_relative_to(ROOT) else path}")
    spec = json.loads(path.read_text())
    problems = spec_problems(spec)
    if problems:
        raise ClipError(f"{path.name}: " + "; ".join(problems))
    return spec


def spec_problems(spec: Any) -> list[str]:
    if not isinstance(spec, dict):
        return ["a spec is a JSON object"]
    out = [f"unknown key {key!r}" for key in sorted(set(spec) - SPEC_KEYS)]
    caption = spec.get("caption")
    if not isinstance(caption, str) or not caption.strip() or len(caption) > 140:
        out.append("caption: one sentence of what you can now do, at most 140 characters")
    steps = spec.get("steps")
    if not isinstance(steps, list) or not steps or not all(isinstance(s, dict) for s in steps):
        out.append("steps: a list of capture steps")
    elif not any(s.get("clip") is True for s in steps):
        out.append('steps: mark the steps that perform the feature with "clip": true')
    crop = spec.get("crop")
    if not (isinstance(crop, list) and len(crop) == 4 and all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in crop)):
        out.append("crop: [x, y, w, h] as fractions of the window")
    else:
        x, y, w, h = crop
        if not (0 <= x < 1 and 0 <= y < 1 and 0 < w <= 1 and 0 < h <= 1 and x + w <= 1.0001 and y + h <= 1.0001):
            out.append("crop: inside the window, as fractions from 0 to 1")
        elif w * h > 0.75:
            out.append("crop: the part of the window that matters, not the whole window")
    interval = spec.get("frameInterval", 1.0)
    if isinstance(interval, bool) or not isinstance(interval, (int, float)) or not 0.25 <= interval <= 1:
        out.append("frameInterval: 0.25 to 1 seconds")
    for key, default in (("hold", HOLD), ("lead", LEAD)):
        value = spec.get(key, default)
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not 0 <= value <= 3:
            out.append(f"{key}: 0 to 3 seconds")
    return out


def capture_state(spec: dict) -> dict:
    """The `cmux-ci capture` steps file: the spec without what only this tool reads."""
    state = {"steps": [{k: v for k, v in step.items() if k != "clip"} for step in spec["steps"]],
             "frameInterval": spec.get("frameInterval", 1.0)}
    for key in ("settings", "launch_args"):
        if key in spec:
            state[key] = spec[key]
    return state


def clip_frames(spec: dict, result: dict, frames: list[Path]) -> list[Path]:
    """The frames of the clip steps, from result.json's step frames (pr-capture's driver)."""
    steps = result.get("steps") or []
    if len(steps) != len(spec["steps"]) or any("frame" not in s for s in steps):
        raise ClipError("result.json has no frame per step: record with a cmux-ci capture that writes them (HQ#4314)")
    marked = [i for i, step in enumerate(spec["steps"]) if step.get("clip") is True]
    # An optional step the mini could not run reports "unavailable" and the capture still passes:
    # fine for setting the scene, never for a step the clip shows.
    failed = [s["title"] for i, s in enumerate(steps)
              if s.get("status") == "failed" or (i in marked and s.get("status") != "ok")]
    if failed:
        raise ClipError(f"steps failed: {', '.join(failed)}")
    # A step's frame is the first one taken after its command started, which a quick command has
    # already changed: the frame before it is the state the clip starts from.
    start = max(0, steps[marked[0]]["frame"] - 1)
    after = marked[-1] + 1
    end = steps[after]["frame"] if after < len(steps) else result.get("stillsFrame", len(frames))
    picked = [f for f in frames if start <= frame_number(f) < end]
    if len(picked) < 2:
        raise ClipError(f"the clip steps span {len(picked)} frame(s); give them a longer wait")
    return picked


def frame_number(path: Path) -> int:
    return int(path.stem.rsplit("-", 1)[1])


def size_of(path: Path) -> tuple[int, int]:
    out = run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
               "-of", "csv=p=0", str(path)], text=True).stdout.strip()
    width, height = out.split(",")[:2]
    return int(width), int(height)


def crop_filter(crop: list[float], size: tuple[int, int], width: int | None = None) -> str:
    """ffmpeg's crop (even pixels) and, past MAX_WIDTH or a given width, a scale down."""
    fw, fh = size
    x, y, w, h = crop
    cw, ch = max(2, int(fw * w) // 2 * 2), max(2, int(fh * h) // 2 * 2)
    cx, cy = min(int(fw * x), fw - cw), min(int(fh * y), fh - ch)
    target = min(cw, width or MAX_WIDTH)
    scale = f",scale={target}:-2:flags=lanczos" if target < cw else ""
    return f"crop={cw}:{ch}:{cx}:{cy}{scale}"


def gray(path: Path, crop: str) -> bytes:
    return run(["ffmpeg", "-v", "error", "-i", str(path), "-vf", f"{crop},scale=96:-2,format=gray",
                "-f", "rawvideo", "-"]).stdout


def difference(a: bytes, b: bytes) -> float:
    if len(a) != len(b) or not a:
        return 255.0
    return sum(abs(x - y) for x, y in zip(a, b)) / len(a)


def timeline(spec: dict, frames: list[Path], crop: str) -> list[tuple[Path, float]]:
    """(frame, seconds) at the capture's own pace: runs of alike frames merged, the first frame held
    `lead` and the last `hold`, the whole between MIN_SECONDS and MAX_SECONDS."""
    interval = float(spec.get("frameInterval", 1.0))
    runs: list[list[Any]] = []
    previous = None
    for frame in frames:
        pixels = gray(frame, crop)
        if previous is not None and difference(previous, pixels) <= SAME:
            runs[-1][1] += interval
        else:
            runs.append([frame, interval])
            previous = pixels
    # A one-frame run between two others is a frame caught mid-animation (a ghosted composer, a dot
    # halfway): its time goes to the settled state after it.
    settled = [runs[0]]
    for index, run_ in enumerate(runs[1:], 1):
        if index < len(runs) - 1 and run_[1] <= interval:
            runs[index + 1][1] += run_[1]
        else:
            settled.append(run_)
    runs = settled
    if len(runs) < 2:
        raise ClipError("every frame of the clip is alike: it shows no change (an idle window); script the feature")
    runs[0][1] = max(runs[0][1], float(spec.get("lead", LEAD)))
    runs[-1][1] = max(runs[-1][1], float(spec.get("hold", HOLD)))
    total = sum(seconds for _, seconds in runs)
    if total > MAX_SECONDS:
        raise ClipError(f"the clip lasts {total:.1f} s; at most {MAX_SECONDS:g} (shorter waits or fewer clip steps)")
    if total < MIN_SECONDS:
        runs[-1][1] += MIN_SECONDS - total
    return [(frame, round(seconds, 3)) for frame, seconds in runs]


def encode(spec: dict, frames: list[Path], out: Path) -> dict:
    size = size_of(frames[0])
    crop = crop_filter(spec["crop"], size)
    plan = timeline(spec, frames, crop)
    for width in (MAX_WIDTH, 720, 560):
        with tempfile.TemporaryDirectory(prefix="whats-new-clip-") as tmp:
            argv = ["img2webp", "-loop", "0", "-min_size", "-mixed"]
            for index, (frame, seconds) in enumerate(plan):
                cropped = Path(tmp) / f"{index:04d}.png"
                run(["ffmpeg", "-v", "error", "-y", "-i", str(frame), "-vf", crop_filter(spec["crop"], size, width),
                     str(cropped)])
                argv += ["-d", str(int(seconds * 1000)), str(cropped)]
            for quality in QUALITIES:
                run([*argv[:5], "-q", str(quality), *argv[5:], "-o", str(out)])
                if out.stat().st_size <= MAX_BYTES:
                    return {"frames": len(plan), "seconds": round(sum(s for _, s in plan), 2),
                            "bytes": out.stat().st_size, "size": list(size_of(cropped)), "quality": quality}
    raise ClipError(f"the clip does not fit {MAX_BYTES} bytes even at {QUALITIES[-1]} quality and 560 px")


def render(clip_id: str, capture: Path, out: Path) -> dict:
    spec = load_spec(clip_id)
    result = json.loads((capture / "result.json").read_text())
    if result.get("privacy"):
        raise ClipError("the capture's text check found a private name; record again with a clean scene")
    read = set(result.get("text") or {})
    frames = sorted(f for f in (capture / "frames").glob("frame-*.png") if f"frames/{f.name}" in read)
    if not frames:
        raise ClipError(f"{capture} has no frames the capture read (record with --video)")
    report = encode(spec, clip_frames(spec, result, frames), out)
    print(json.dumps({"id": clip_id, "out": str(out), **report}))
    return report


def record(clip_id: str, sha: str | None, job: str | None, out: Path) -> dict:
    spec = load_spec(clip_id)
    if not os.environ.get("CMUX_HQ"):
        raise ClipError("set CMUX_HQ to a manaflow-ai/cmuxterm-hq checkout (cmux-ci capture needs it)")
    with tempfile.TemporaryDirectory(prefix="whats-new-clip-") as tmp:
        state = Path(tmp) / "state.json"
        state.write_text(json.dumps(capture_state(spec), indent=2))
        argv = ["cmux-ci", "capture", "--state", str(state), "--video"]
        argv += ["--job", job] if job else []
        argv += [sha or run(["git", "-C", str(ROOT), "rev-parse", "HEAD"], text=True).stdout.strip()]
        done = subprocess.run(argv, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    sys.stderr.write(done.stdout)
    # pr-capture names the folder it wrote (~/.cache/pr-capture/SHA8/steps-HASH) on its stills line.
    found = STILLS.search(done.stdout)
    if done.returncode != 0 or not found:
        raise ClipError(f"cmux-ci capture exited {done.returncode} without stills (its log is above)")
    return render(clip_id, Path(found["dir"]), out)


def set_clip_line(text: str, line: str) -> str:
    head, sep, body = text.partition("\n\n")
    kept = [l for l in head.splitlines() if not l.lower().startswith("clip:")]
    return "\n".join([*kept, line]) + sep + body


def publish(clip_id: str, local: Path, highlights: Path = HIGHLIGHTS) -> str:
    load_spec(clip_id)
    highlight = highlights / f"{clip_id}.md"
    if not highlight.is_file():
        raise ClipError(f"no highlight {clip_id}.md")
    data = local.read_bytes()
    # The .webp name too: the privacy check reads a file as media (every frame) by its suffix.
    webp = data[:4] == b"RIFF" and data[8:12] == b"WEBP"
    if local.suffix.lower() != ".webp" or not webp or len(data) > MAX_BYTES:
        raise ClipError(f"{local} is not a .webp of at most {MAX_BYTES} bytes")
    digest = hashlib.sha256(data).hexdigest()
    path = f"whats-new/{clip_id}/{digest[:12]}.webp"
    spec = importlib.util.spec_from_file_location("pr_media_tool", ROOT / "scripts/pr-media.py")
    pr_media = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = pr_media
    spec.loader.exec_module(pr_media)
    # The shared privacy check (pr_media_privacy.py) reads every frame first; a refusal uploads nothing.
    # Without OCR it would pass a clip unread, so publish wants it (a Mac with Xcode).
    if pr_media.privacy_module().ocr_binary() is None:
        raise ClipError("publish reads every frame with Apple Vision first: run it on a Mac with Xcode")
    pr_media.check_privacy([(path, local)], REPO)
    pr_media.put_file(REPO, BRANCH, path, local, f"What's New clip: {clip_id}", checked=True)
    url = URL_PREFIX + f"{clip_id}/{digest[:12]}.webp"
    highlight.write_text(set_clip_line(highlight.read_text(), f"clip: {url} | {digest}"))
    print(url)
    return url


def auto_url(clip_id: str, role: str) -> str:
    """Where publish-auto puts a clip the nightly tour recorded (release-notes.py clip_auto_url)."""
    return f"{URL_PREFIX}{clip_id}/clip-auto-{role}.webp"


def published(url: str) -> bool:
    import urllib.error
    import urllib.request
    request = urllib.request.Request(url, method="HEAD", headers={"User-Agent": "cmux-whats-new-clips/1"})
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            return response.status == 200
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return False
        raise


def tour_module():
    spec = importlib.util.spec_from_file_location("media_tour", Path(__file__).with_name("tour.py"))
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def tour_from_spec(spec: dict, title: str) -> dict:
    """The spec as a tour.py tour: the same steps in the same order, with no step shots (a shot stops the
    window for a moment the clip would show), so its manifest's steps line up with the spec's."""
    steps = [{**{k: v for k, v in step.items() if k not in CAPTURE_ONLY_STEP_KEYS}, "shot": False}
             for step in spec["steps"]]
    tour = {"title": title, "steps": steps}
    for key in ("settings", "launch_args"):
        if key in spec:
            tour[key] = spec[key]
    return tour


def front_matter(text: str) -> dict:
    meta = {}
    for line in text.partition("\n\n")[0].splitlines():
        key, sep, value = line.partition(":")
        if sep:
            meta[key.strip().lower()] = value.strip()
    return meta


def plan(base: str, head: str, tours: Path, limit: int = PLAN_LIMIT, exists=published,
         root: Path = ROOT) -> list[dict]:
    """The highlights base..head adds that the tour records: New or Improved, a valid spec, no `clip:`
    line, and a role whose clip is not on pr-media yet. Writes each one's tour to TOURS/ID.json."""
    git = lambda *a: run(["git", "-C", str(root), *a], text=True).stdout
    added = git("diff", "--diff-filter=A", "--name-only", base, head, "--", "release-notes/next/highlights").split()
    validate = tour_module().load_tour
    rows = []
    for path in sorted(added):
        clip_id = Path(path).stem
        if not path.endswith(".md") or not ID.fullmatch(clip_id):
            continue
        meta = front_matter(git("show", f"{head}:{path}"))
        category = meta.get("category", "new").lower() or "new"
        if category not in {"new", "improved"} or "clip" in meta:
            continue
        try:
            spec = load_spec(clip_id, root / "release-notes/next/clips")
            roles = [role for role in AUTO_ROLES[:2 if category == "improved" else 1]
                     if not exists(auto_url(clip_id, role))]
            if not roles:
                continue
            tours.mkdir(parents=True, exist_ok=True)
            tour = tours / f"{clip_id}.json"
            tour.write_text(json.dumps(tour_from_spec(spec, meta.get("title") or clip_id), indent=2) + "\n")
            validate(tour)
        except ClipError as error:
            if "no spec" not in str(error):
                print(f"::warning title=What's New clip::{clip_id}: {error}")
            continue
        except Exception as error:  # tour.py's TourError: the spec has a step tour.py cannot run
            (tours / f"{clip_id}.json").unlink(missing_ok=True)
            print(f"::warning title=What's New clip::{clip_id}: not a tour: {error}")
            continue
        rows.append({"id": clip_id, "category": category, "roles": roles})
    if len(rows) > limit:
        print(f"::notice title=What's New clip::{len(rows) - limit} more wait for the next nightly")
    return rows[:limit]


def tour_frames(spec: dict, manifest: dict, tour_dir: Path, scratch: Path) -> list[Path]:
    """The clip steps' frames out of a tour folder: from capture.mov at the spec's frame interval, cut at
    the steps' `at` times, else from the still frames tagged with their step."""
    steps = manifest.get("steps") or []
    if manifest.get("error") or len(steps) != len(spec["steps"]):
        raise ClipError(f"the tour did not run every step: {manifest.get('error') or len(steps)}")
    marked = [i for i, step in enumerate(spec["steps"]) if step.get("clip") is True]
    failed = [s["title"] for i, s in enumerate(steps)
              if s.get("status") == "failed" or (i in marked and s.get("status") != "ok")]
    if failed:
        raise ClipError(f"steps failed: {', '.join(failed)}")
    interval = float(spec.get("frameInterval", 1.0))
    after = marked[-1] + 1
    if manifest.get("video"):
        if any("at" not in step for step in steps):
            raise ClipError("the tour's steps have no times (a tour.py from before step times)")
        # The frame before the first clip step is the state the clip starts from.
        start = max(0.0, steps[marked[0]]["at"] - interval)
        argv = ["ffmpeg", "-v", "error", "-y", "-ss", f"{start:.3f}", "-i", str(tour_dir / manifest["video"])]
        if after < len(steps):
            argv += ["-t", f"{steps[after]['at'] - start:.3f}"]
        run([*argv, "-vf", f"fps=1/{interval}", str(scratch / "frame-%05d.png")])
        picked = sorted(scratch.glob("frame-*.png"))
    else:
        # Still frames carry the 1-based step they were taken in.
        first, last = marked[0] + 1, marked[-1] + 1
        frames = manifest.get("frames") or []
        inside = [i for i, f in enumerate(frames) if first <= f.get("step", 0) <= last]
        if inside and inside[0] > 0:
            inside.insert(0, inside[0] - 1)
        picked, previous = [], None
        for index in inside:
            frame = frames[index]
            if previous is None or frame.get("time", 0) - previous >= interval:
                picked.append(tour_dir / frame["file"])
                previous = frame.get("time", 0)
    if len(picked) < 2:
        raise ClipError(f"the clip steps span {len(picked)} frame(s); give them a longer wait")
    return picked


def render_tour(clip_id: str, tour_dir: Path, out: Path) -> dict:
    spec = load_spec(clip_id)
    manifest = json.loads((tour_dir / "manifest.json").read_text())
    with tempfile.TemporaryDirectory(prefix="whats-new-clip-") as tmp:
        report = encode(spec, tour_frames(spec, manifest, tour_dir, Path(tmp)), out)
    print(json.dumps({"id": clip_id, "out": str(out), **report}))
    return report


def publish_auto(rows: list[dict], results: Path, scratch: Path) -> list[str]:
    """Renders each planned clip from RESULTS/ROLE/ID (the tour's folders), then checks them all and puts
    them at auto_url. A clip that does not render is left out with a warning; a refusal uploads nothing."""
    files, problems = [], []
    # tour.py names a tour's folder by the slug of its file's name (40 characters at most).
    folder = tour_module().slug
    for row in rows:
        for role in row["roles"]:
            local = scratch / f"{row['id']}-{role}.webp"
            try:
                render_tour(row["id"], results / role / folder(row["id"]), local)
            except (ClipError, OSError, ValueError) as error:
                problems.append(f"{row['id']} {role}: {error}")
                continue
            files.append((f"whats-new/{row['id']}/clip-auto-{role}.webp", local, row["id"], role))
    if not files:
        return problems
    spec = importlib.util.spec_from_file_location("pr_media_tool", ROOT / "scripts/pr-media.py")
    pr_media = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = pr_media
    spec.loader.exec_module(pr_media)
    if pr_media.privacy_module().ocr_binary() is None:
        raise ClipError("publish-auto reads every frame first, and no OCR is set up")
    # One check for all of them: a refusal names paths and kinds only, and uploads nothing.
    pr_media.check_privacy([(path, local) for path, local, _, _ in files], REPO)
    for path, local, clip_id, role in files:
        pr_media.put_file(REPO, BRANCH, path, local, f"What's New clip: {clip_id} ({role}, nightly tour)",
                          checked=True)
        print(auto_url(clip_id, role))
    return problems


def check(specs: Path = SPECS, highlights: Path = HIGHLIGHTS) -> list[str]:
    problems = []
    for path in sorted(specs.glob("*.json")) if specs.is_dir() else []:
        if not (highlights / f"{path.stem}.md").is_file():
            problems.append(f"{path.name}: no highlight {path.stem}.md")
        try:
            problems += [f"{path.name}: {p}" for p in spec_problems(json.loads(path.read_text()))]
        except json.JSONDecodeError as error:
            problems.append(f"{path.name}: {error}")
    for path in sorted(highlights.glob("*.md")):
        head = path.read_text().partition("\n\n")[0]
        lines = [l for l in head.splitlines() if l.lower().startswith("clip:")]
        if not lines:
            continue
        match = CLIP_LINE.match(lines[0])
        if len(lines) > 1 or not match:
            problems.append(f"{path.name}: one line 'clip: URL | SHA256'")
        elif not re.fullmatch(re.escape(f"{URL_PREFIX}{path.stem}/") + r"[0-9a-f]{12}\.webp", match["url"]):
            problems.append(f"{path.name}: the clip lives at {URL_PREFIX}{path.stem}/SHA12.webp")
        if not (specs / f"{path.stem}.json").is_file():
            problems.append(f"{path.name}: a clip needs its spec, clips/{path.stem}.json, so the next one is recorded the same way")
    return problems


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="command", required=True)
    r = sub.add_parser("record")
    r.add_argument("id")
    r.add_argument("--sha")
    r.add_argument("--job")
    r.add_argument("--out", type=Path)
    d = sub.add_parser("render")
    d.add_argument("id")
    d.add_argument("--capture", type=Path, required=True)
    d.add_argument("--out", type=Path)
    p = sub.add_parser("publish")
    p.add_argument("id")
    p.add_argument("file", type=Path)
    sub.add_parser("check")
    n = sub.add_parser("plan")
    n.add_argument("--base", required=True)
    n.add_argument("--head", required=True)
    n.add_argument("--out", type=Path, required=True)
    n.add_argument("--tours", type=Path, required=True)
    n.add_argument("--limit", type=int, default=PLAN_LIMIT)
    o = sub.add_parser("tours")
    o.add_argument("--plan", type=Path, required=True)
    o.add_argument("--role", choices=AUTO_ROLES, required=True)
    o.add_argument("--dir", type=Path, required=True)
    u = sub.add_parser("publish-auto")
    u.add_argument("--plan", type=Path, required=True)
    u.add_argument("--results", type=Path, required=True)
    a = ap.parse_args(argv)
    try:
        if a.command == "plan":
            rows = plan(a.base, a.head, a.tours, a.limit)
            a.out.write_text(json.dumps(rows, indent=2) + "\n")
            print(len(rows))
            return 0
        if a.command == "tours":
            for row in json.loads(a.plan.read_text()):
                if a.role in row["roles"]:
                    print(a.dir / f"{row['id']}.json")
            return 0
        if a.command == "publish-auto":
            with tempfile.TemporaryDirectory(prefix="whats-new-clips-") as tmp:
                for problem in publish_auto(json.loads(a.plan.read_text()), a.results, Path(tmp)):
                    print(f"::warning title=What's New clip::{problem}")
            return 0
        if a.command == "check":
            problems = check()
            for problem in problems:
                print(problem, file=sys.stderr)
            return 1 if problems else 0
        if a.command == "publish":
            publish(a.id, a.file)
            return 0
        out = a.out or Path(f"{a.id}.webp")
        if a.command == "record":
            record(a.id, a.sha, a.job, out)
        else:
            render(a.id, a.capture, out)
        return 0
    except (ClipError, subprocess.CalledProcessError) as error:
        print(f"whats-new-clips: {error}", file=sys.stderr)
        return 1
    except Exception as error:  # pr-media.py's PrivacyError: the message names paths and kinds only
        if type(error).__name__ != "PrivacyError":
            raise
        print(f"whats-new-clips: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
