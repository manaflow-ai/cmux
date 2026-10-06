#!/usr/bin/env python3
"""Build a small, local-first frontend for cmux UI-test artifacts.

The E2E lane already exports screenshots, accessibility trees, socket replies,
and step logs. This turns that directory into an interactive mirror that can
be opened with a browser without a server or a JavaScript dependency.

    python3 scripts/ci/ui-mirror.py "$TMPDIR/cmux-ui-frames/123"

The generated ``index.html`` is deliberately static: it can be uploaded as a
CI artifact, copied to another machine, or opened with ``open``. It references
the images and text attachments next to it instead of embedding or uploading
their contents anywhere.
"""

from __future__ import annotations

import argparse
import html
import json
import re
from pathlib import Path
from typing import Any


STEP = re.compile(
    r"^(?P<number>\d+)\. (?P<title>.*?)  \(frames/(?P<frame>[^)]+)\)"
    r"(?P<failed>  <- failed here)?$"
)


def relative(path: Path, root: Path) -> str:
    """Return a browser-safe path for a file beneath ``root``."""
    try:
        return path.resolve().relative_to(root.resolve()).as_posix()
    except ValueError as error:
        raise ValueError(f"artifact path escapes mirror root: {path}") from error


def read_test(test_dir: Path, root: Path) -> dict[str, Any]:
    steps_file = test_dir / "steps.md"
    lines = steps_file.read_text(encoding="utf-8", errors="replace").splitlines()
    heading = lines[0] if lines else test_dir.name
    identifier, separator, result = heading[2:].rpartition(": ")
    if not separator:
        identifier, result = heading, "Unknown"

    failures = [line.removeprefix("Failure: ") for line in lines if line.startswith("Failure: ")]
    steps: list[dict[str, Any]] = []
    for line in lines:
        match = STEP.match(line)
        if not match:
            continue
        frame = test_dir / "frames" / match.group("frame")
        if not frame.is_file():
            continue
        steps.append(
            {
                "number": int(match.group("number")),
                "title": match.group("title"),
                "frame": relative(frame, root),
                "failed": bool(match.group("failed")),
            }
        )

    attachments: list[dict[str, str]] = []
    attachment_dir = test_dir / "attachments"
    if attachment_dir.is_dir():
        for path in sorted(p for p in attachment_dir.rglob("*") if p.is_file()):
            attachment: dict[str, str] = {
                "name": path.relative_to(attachment_dir).as_posix(),
                "path": relative(path, root),
            }
            if path.suffix.lower() in {".txt", ".log", ".json", ".md"}:
                # Keep the mirror usable from file://, where fetch() is often
                # blocked by the browser's local-file origin policy.
                attachment["text"] = path.read_text(
                    encoding="utf-8", errors="replace"
                )[:200_000]
            attachments.append(attachment)

    sheets = [
        relative(path, root)
        for path in sorted(test_dir.glob("sheet-*.jpg"))
        if path.is_file()
    ]
    return {
        "id": identifier,
        "result": result,
        "failures": failures,
        "steps": steps,
        "attachments": attachments,
        "sheets": sheets,
    }


def collect(root: Path) -> list[dict[str, Any]]:
    tests = []
    for steps_file in sorted(root.rglob("steps.md")):
        tests.append(read_test(steps_file.parent, root))
    return tests


def write_mirror(root: Path, tests: list[dict[str, Any]]) -> Path:
    payload = json.dumps(
        {"version": 1, "root": root.name, "tests": tests},
        ensure_ascii=False,
        separators=(",", ":"),
    ).replace("<", "\\u003c")
    title = html.escape(root.name)
    document = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>cmux UI mirror · {title}</title>
<style>
:root {{ color-scheme: dark; font: 14px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", sans-serif; background: #111318; color: #e9edf5; }}
* {{ box-sizing: border-box; }}
body {{ margin: 0; min-height: 100vh; display: grid; grid-template-columns: 310px minmax(0, 1fr); background: #111318; }}
aside {{ border-right: 1px solid #2a2f3b; background: #171a21; min-height: 100vh; overflow: auto; }}
header {{ padding: 20px 18px 14px; position: sticky; top: 0; background: #171a21ee; backdrop-filter: blur(12px); z-index: 1; }}
h1 {{ font-size: 18px; margin: 0 0 4px; letter-spacing: -.01em; }}
.subtle {{ color: #929aaa; font-size: 12px; }}
input {{ width: 100%; margin-top: 14px; border: 1px solid #343b4a; border-radius: 8px; background: #101218; color: inherit; padding: 8px 10px; }}
nav {{ padding: 0 10px 18px; }}
.test {{ border: 1px solid transparent; border-radius: 9px; margin: 5px 0; overflow: hidden; }}
.test.selected {{ border-color: #5e8cff; background: #20283a; }}
.test button, .step {{ display: block; width: 100%; text-align: left; border: 0; color: inherit; background: transparent; cursor: pointer; }}
.test button {{ padding: 10px 10px 7px; }}
.test button:hover, .step:hover {{ background: #252c3b; }}
.test-name {{ font-weight: 600; overflow-wrap: anywhere; }}
.status {{ float: right; color: #78d99b; font-size: 11px; }}
.status.failed {{ color: #ff8e8e; }}
.step-list {{ padding: 0 7px 8px; }}
.step {{ border-radius: 6px; padding: 6px 7px; color: #aeb6c7; font-size: 12px; }}
.step.current {{ color: #fff; background: #303c58; }}
.step.failed {{ color: #ffb0b0; }}
.step-number {{ display: inline-block; width: 26px; color: #74809a; }}
main {{ min-width: 0; padding: 24px clamp(18px, 4vw, 56px) 44px; }}
.toolbar {{ display: flex; gap: 10px; align-items: baseline; flex-wrap: wrap; margin-bottom: 16px; }}
.toolbar h2 {{ margin: 0; font-size: 16px; overflow-wrap: anywhere; }}
.toolbar button, .attachment {{ border: 1px solid #3b4455; background: #1c2230; color: #e9edf5; border-radius: 7px; padding: 6px 9px; cursor: pointer; text-decoration: none; }}
.toolbar button:hover, .attachment:hover {{ background: #2b3549; }}
.stage {{ min-height: min(70vh, 760px); display: grid; place-items: center; border: 1px solid #303746; border-radius: 12px; padding: 18px; background: repeating-conic-gradient(#1b1f27 0 25%, #171a21 0 50%) 50% / 24px 24px; }}
.stage img {{ max-width: 100%; max-height: min(70vh, 720px); object-fit: contain; border-radius: 4px; box-shadow: 0 14px 40px #0008; }}
.empty {{ color: #8f99ac; text-align: center; padding: 80px 20px; }}
.caption {{ margin-top: 11px; color: #cbd2e0; font-size: 13px; }}
.panels {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(260px, 1fr)); gap: 12px; margin-top: 16px; }}
details {{ border: 1px solid #303746; border-radius: 9px; background: #171a21; }}
summary {{ cursor: pointer; padding: 10px 12px; color: #cbd2e0; }}
pre {{ margin: 0; padding: 0 12px 12px; max-height: 340px; overflow: auto; white-space: pre-wrap; color: #aeb6c7; font: 12px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace; }}
.sheets {{ display: flex; gap: 8px; overflow-x: auto; margin-top: 14px; }}
.sheets img {{ width: 180px; height: 135px; object-fit: cover; border-radius: 5px; border: 1px solid #303746; cursor: pointer; }}
.clips {{ display: grid; gap: 10px; margin-top: 14px; }}
.clips video, .clips img {{ max-width: 100%; max-height: 360px; border-radius: 7px; border: 1px solid #303746; background: #0d0f14; }}
@media (max-width: 760px) {{ body {{ display: block; }} aside {{ min-height: auto; max-height: 42vh; border-right: 0; border-bottom: 1px solid #2a2f3b; }} header {{ position: relative; }} main {{ padding: 18px 12px 32px; }} }}
</style>
</head>
<body>
<aside>
<header><h1>cmux UI mirror</h1><div class="subtle">Screenshots and interaction evidence · {title}</div><input id="filter" type="search" placeholder="Filter tests or steps…" autocomplete="off"></header>
<nav id="tests" aria-label="Tests"></nav>
</aside>
<main>
<div class="toolbar"><h2 id="heading">Select a test</h2><span class="subtle" id="result"></span><span style="flex:1"></span><button id="prev" type="button">← Previous</button><button id="next" type="button">Next →</button></div>
<div class="stage" id="stage"><div class="empty">Choose a test and step to inspect the UI.</div></div>
<div class="caption" id="caption"></div>
<div class="sheets" id="sheets"></div>
<div class="clips" id="clips"></div>
<div class="panels"><details id="failures-panel"><summary>Failures</summary><pre id="failures"></pre></details><details><summary>Attachments</summary><div id="attachments" style="padding:0 12px 12px;display:flex;gap:7px;flex-wrap:wrap"></div></details></div>
</main>
<script id="mirror-data" type="application/json">{payload}</script>
<script>
const data = JSON.parse(document.getElementById('mirror-data').textContent);
const testNav = document.getElementById('tests'), filter = document.getElementById('filter');
const heading = document.getElementById('heading'), result = document.getElementById('result');
const stage = document.getElementById('stage'), caption = document.getElementById('caption');
const sheets = document.getElementById('sheets'), failures = document.getElementById('failures');
const clips = document.getElementById('clips');
const attachments = document.getElementById('attachments');
let selectedTest = 0, selectedStep = 0;
function visibleTests() {{ const q = filter.value.trim().toLowerCase(); return data.tests.map((test, i) => ({{test, i}})).filter(x => !q || JSON.stringify(x.test).toLowerCase().includes(q)); }}
function renderNav() {{
  testNav.replaceChildren();
  visibleTests().forEach(x => {{
    const box = document.createElement('section'); box.className = 'test' + (x.i === selectedTest ? ' selected' : '');
    const button = document.createElement('button'); button.type = 'button';
    const name = document.createElement('span'); name.className = 'test-name'; name.textContent = x.test.id || 'UI test';
    const status = document.createElement('span'); status.className = 'status' + (x.test.result !== 'Passed' ? ' failed' : ''); status.textContent = x.test.result;
    button.append(name, status); button.onclick = () => {{ selectedTest = x.i; selectedStep = 0; render(); }}; box.append(button);
    const list = document.createElement('div'); list.className = 'step-list';
    x.test.steps.forEach((step, i) => {{ const item = document.createElement('button'); item.type = 'button'; item.className = 'step' + (x.i === selectedTest && i === selectedStep ? ' current' : '') + (step.failed ? ' failed' : ''); item.innerHTML = '<span class="step-number">' + String(step.number).padStart(2, '0') + '</span>'; const label = document.createElement('span'); label.textContent = step.title; item.append(label); item.onclick = () => {{ selectedTest = x.i; selectedStep = i; render(); }}; list.append(item); }});
    box.append(list); testNav.append(box);
  }});
}}
function showText(text, name) {{ const d = document.createElement('details'); const s = document.createElement('summary'); s.textContent = name; const p = document.createElement('pre'); p.textContent = text; d.append(s, p); attachments.append(d); }}
function render() {{
  renderNav(); const test = data.tests[selectedTest]; if (!test) return;
  heading.textContent = test.id || 'UI test'; result.textContent = test.result;
  failures.textContent = test.failures.join('\\n') || 'No failures recorded.';
  document.getElementById('failures-panel').open = test.failures.length > 0;
  attachments.replaceChildren(); clips.replaceChildren(); test.attachments.forEach(a => {{ const link = document.createElement('a'); link.className = 'attachment'; link.href = a.path; link.target = '_blank'; link.textContent = a.name; attachments.append(link); if (a.text !== undefined) showText(a.text, a.name); const suffix = a.name.toLowerCase(); if (/\\.(mp4|mov|webm)$/.test(suffix)) {{ const video = document.createElement('video'); video.controls = true; video.preload = 'metadata'; video.src = a.path; video.title = a.name; clips.append(video); }} else if (/\\.gif$/.test(suffix)) {{ const gif = document.createElement('img'); gif.src = a.path; gif.alt = a.name; clips.append(gif); }} }});
  sheets.replaceChildren(); test.sheets.forEach(path => {{ const image = document.createElement('img'); image.src = path; image.alt = 'Contact sheet'; image.onclick = () => window.open(path, '_blank'); sheets.append(image); }});
  const step = test.steps[selectedStep]; if (!step) {{ stage.innerHTML = '<div class="empty">This test has no captured screenshots.</div>'; caption.textContent = ''; return; }}
  stage.replaceChildren(); const image = document.createElement('img'); image.src = step.frame; image.alt = step.title; image.onclick = () => window.open(step.frame, '_blank'); stage.append(image); caption.textContent = String(step.number).padStart(2, '0') + ' · ' + step.title + (step.failed ? ' · failed here' : '');
}}
function move(delta) {{ const test = data.tests[selectedTest]; if (!test || !test.steps.length) return; selectedStep = Math.max(0, Math.min(test.steps.length - 1, selectedStep + delta)); render(); }}
filter.oninput = renderNav; document.getElementById('prev').onclick = () => move(-1); document.getElementById('next').onclick = () => move(1); document.onkeydown = event => {{ if (event.target === filter) return; if (event.key === 'ArrowLeft') move(-1); if (event.key === 'ArrowRight') move(1); }}; render();
</script>
</body>
</html>
"""
    output = root / "index.html"
    output.write_text(document, encoding="utf-8")
    (root / "mirror.json").write_text(
        json.dumps({"version": 1, "root": root.name, "tests": tests}, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    return output


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=Path, help="a ui-frames artifact or extracted e2e-frames directory")
    args = parser.parse_args()
    root = args.artifact.resolve()
    if not root.is_dir():
        parser.error(f"artifact directory does not exist: {root}")
    tests = collect(root)
    output = write_mirror(root, tests)
    print(f"cmux UI mirror: {output}")
    print(f"tests: {len(tests)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
