#!/usr/bin/env python3
"""Writes the resize-videos gallery: index.html in ROOT and in each build folder (handoff resize-videos/KIT.md).

  video-gallery.py [ROOT]   (default /Users/lawrence/fun/wt/handoff/resize-videos)

A build folder is ROOT/<build-label>-<vdisplay>/ with <case>.mov and its side files; <case>.judge.json (the judge's
report) adds its summary and findings. Cases with the same name in several builds are shown side by side on the
root page. Standard library only; the files stay read-only (the page links them, it never copies them).
"""
import html
import json
import sys
from pathlib import Path


def load(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


# cmux-ad 02:55Z (STATUS 4657): before #31671 (spin pacing) the gradient TUI drew in bursts (about 25 Hz of real
# updates). A film whose round ran it cannot show content cadence: geometry and blank-frame findings stay valid.
BURST_GRADIENT_NOTE = "burst gradient: content cadence not judged"
SPIN_PACING_SINCE = 1793588400  # 2026-11-02T03:00:00Z: films before this with the gradient TUI used the burst kit


def burst_gradient(folder, case):
    """True when the round of CASE ran the gradient TUI (its result names it) and was filmed before the spin kit."""
    meta = load(folder / f"{case}.meta.json") or {}
    own = folder / f"{case}.result.json"
    texts = [own.read_text(errors="replace")] if own.exists() else [p.read_text(errors="replace") for p in folder.glob("*.result.json")]
    uses = any("gradient" in t and ("--pace spin" not in t) for t in texts)
    filmed = (folder / f"{case}.mov").stat().st_mtime if (folder / f"{case}.mov").exists() else 0
    return uses and filmed < SPIN_PACING_SINCE and meta.get("smoke_env") is not True


def case_facts(folder, case):
    meta = load(folder / f"{case}.meta.json") or {}
    judge = load(folder / f"{case}.judge.json") or {}
    counts = meta.get("counts") or {}
    refresh = meta.get("refresh_ms")
    facts = ([BURST_GRADIENT_NOTE] if burst_gradient(folder, case) else []) + [
             f"refresh {refresh:.2f} ms ({1000 / refresh:.0f} Hz)" if refresh else "refresh unknown",
             f"{counts.get('complete', '?')} frames, {counts.get('idle', '?')} idle, encoder drops {counts.get('encoder_not_ready', '?')}"]
    if judge:
        iv = judge.get("intervals_ms") or {}
        facts.append(f"motion p50/p95/max {iv.get('p50', '?')}/{iv.get('p95', '?')}/{iv.get('max', '?')} ms, dropped {judge.get('dropped', '?')}")
        defects = [f for f in judge.get("findings") or [] if f.get("severity") == "defect"]
        facts.append(f"{len(defects)} defect finding(s)")
    return facts, judge


def video_block(folder, case, rel):
    facts, judge = case_facts(folder, case)
    rows = "".join(f"<li>{html.escape(f['check'])} at {html.escape(str(f.get('t')))} s, frames {html.escape(str(f.get('frames')))}: "
                   f"{html.escape(f.get('detail', ''))}</li>" for f in (judge.get("findings") or [])[:40]
                   if f.get("severity") == "defect")
    links = " ".join(f'<a href="{rel}{case}{s}">{s.lstrip(".")}</a>' for s in
                     (".mov", ".trace.json", ".mov.frames.json", ".events.json", ".meta.json", ".judge.json")
                     if (folder / f"{case}{s}").exists())
    return (f'<div class="case"><h3>{html.escape(folder.name)} / {html.escape(case)}</h3>'
            f'<video controls preload="metadata" src="{rel}{case}.mov"></video>'
            f'<p>{" | ".join(html.escape(f) for f in facts)}</p><p>{links}</p><ul>{rows}</ul></div>')


STYLE = ("<style>body{font:14px -apple-system,sans-serif;margin:16px}video{width:100%;max-width:960px;background:#111}"
         ".row{display:flex;gap:16px;flex-wrap:wrap}.case{flex:1;min-width:420px}h3{margin:8px 0}</style>")


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "/Users/lawrence/fun/wt/handoff/resize-videos")
    folders = sorted(p for p in root.iterdir() if p.is_dir() and any(p.glob("*.mov")))
    cases = {}
    for folder in folders:
        for movie in sorted(folder.glob("*.mov")):
            cases.setdefault(movie.stem, []).append(folder)
        body = "".join(video_block(folder, m.stem, "") for m in sorted(folder.glob("*.mov")))
        display = load(folder / "display.json")
        head = f"<p>display: {html.escape(json.dumps({k: display.get(k) for k in ('mode', 'pixels', 'refresh', 'main_interval_ms')}))}</p>" if display else ""
        (folder / "index.html").write_text(f"<!doctype html><meta charset=utf-8><title>{folder.name}</title>{STYLE}"
                                           f"<h1>{html.escape(folder.name)}</h1>{head}{body}")
    parts = [f"<!doctype html><meta charset=utf-8><title>RESIZE VIDEOS</title>{STYLE}<h1>RESIZE VIDEOS</h1>",
             '<p>Real app, every frame the window server composited (ScreenCaptureKit at the display rate), real HID '
             'input. Findings: <a href="FINDINGS.md">FINDINGS.md</a>. Kit: <a href="KIT.md">KIT.md</a>.</p>',
             "<p>Builds: " + " | ".join(f'<a href="{f.name}/">{html.escape(f.name)}</a>' for f in folders) + "</p>"]
    for case, where in sorted(cases.items()):
        parts.append(f"<h2>{html.escape(case)}</h2><div class='row'>"
                     + "".join(video_block(f, case, f"{f.name}/") for f in where) + "</div>")
    reopen = sorted((root / "reopen").rglob("*.mp4")) if (root / "reopen").is_dir() else []
    if reopen:
        parts.append("<h2>REOPEN VIDEO films (CuaDriver display recorder, up to 30 fps)</h2><div class='row'>")
        for film in reopen[:60]:
            rel = film.relative_to(root).as_posix()
            parts.append(f'<div class="case"><h3>{html.escape(rel)}</h3><video controls preload="metadata" src="{rel}"></video></div>')
        parts.append("</div>")
    (root / "index.html").write_text("".join(parts))
    print(f"gallery: {len(folders)} build folders, {len(cases)} cases")


if __name__ == "__main__":
    main()
