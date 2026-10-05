#!/usr/bin/env python3
"""Build a small side-by-side HTML receipt for two scene manifests.

The comparison stays artifact-local: it never trusts a scene name or path from
an unverified manifest and it records the exact base/head refs supplied by CI.
"""
from __future__ import annotations

import base64
import hashlib
import html
import json
import pathlib
import sys


def load(path: pathlib.Path) -> dict:
    value = json.loads(path.read_text())
    if value.get("schema_version") != 1 or not isinstance(value.get("scenes"), list):
        raise SystemExit(f"invalid scene manifest: {path}")
    return value


def image_data(path: pathlib.Path) -> str:
    if not path.is_file() or path.stat().st_size == 0:
        raise SystemExit(f"missing scene image: {path}")
    encoded = base64.b64encode(path.read_bytes()).decode("ascii")
    return f"data:image/png;base64,{encoded}"


def main() -> int:
    if len(sys.argv) != 5:
        raise SystemExit("usage: compare-scenes.py BASE.json HEAD.json OUT.html BASE_REF HEAD_REF")
    base_path, head_path, out_path, base_ref, head_ref = map(pathlib.Path, sys.argv[1:])
    # The refs are passed as path-like values only for this compact CLI; CI
    # supplies them as plain SHA strings and escapes them in the document.
    base_ref = str(base_ref)
    head_ref = str(head_ref)
    base = load(base_path)
    head = load(head_path)
    base_items = {item.get("scene"): item for item in base["scenes"] if isinstance(item, dict)}
    head_items = {item.get("scene"): item for item in head["scenes"] if isinstance(item, dict)}
    names = sorted(set(base_items) | set(head_items))
    rows = []
    for name in names:
        left = base_items.get(name, {})
        right = head_items.get(name, {})
        left_path = pathlib.Path(left.get("path", "")) if left.get("path") else None
        right_path = pathlib.Path(right.get("path", "")) if right.get("path") else None
        if left_path is None or right_path is None:
            status = "added" if right_path else "removed"
            left_image = right_image = ""
        else:
            left_bytes = left_path.read_bytes() if left_path.is_file() else b""
            right_bytes = right_path.read_bytes() if right_path.is_file() else b""
            status = "same" if left_bytes == right_bytes else "changed"
            left_image = image_data(left_path)
            right_image = image_data(right_path)
        rows.append(
            f"<article><h2>{html.escape(str(name))} <small>{status}</small></h2>"
            f"<div><figure><figcaption>base {html.escape(base_ref)}</figcaption>"
            f"{('<img src=' + repr(left_image) + '>') if left_image else '<p>missing</p>'}</figure>"
            f"<figure><figcaption>head {html.escape(head_ref)}</figcaption>"
            f"{('<img src=' + repr(right_image) + '>') if right_image else '<p>missing</p>'}</figure></div></article>"
        )
    out = """<!doctype html><meta charset=utf-8><title>cmux-next scene comparison</title>
<style>body{font:14px system-ui;background:#202124;color:#eee}article{margin:2rem 0}article>div{display:flex;gap:1rem}figure{margin:0;flex:1}img{max-width:100%;background:#111}small{font-size:.7em;color:#9ad}</style>
""" + "\n".join(rows)
    pathlib.Path(out_path).write_text(out)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
