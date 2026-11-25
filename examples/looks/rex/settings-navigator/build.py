#!/usr/bin/env python3
"""Regenerate this pack from mapping.json: the MAP block of customize/main.js, the
inlined files of profile.json, and the tables of README.md. Checks that there are 85
actions and that every cmux key is a visible row of schemas/settings/settings-schema.json.

    python3 examples/looks/rex/settings-navigator/build.py [--check]
"""
import json
import re
import sys
from collections import Counter
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
EXPECTED = 85


def main() -> int:
    check = "--check" in sys.argv[1:]
    mapping = json.loads((HERE / "mapping.json").read_text())
    actions = mapping["actions"]
    rows = {r["key"]: r for r in json.loads((ROOT / "schemas/settings/settings-schema.json").read_text())["rows"]}
    problems = []
    if len(actions) != EXPECTED:
        problems.append(f"{len(actions)} actions, expected {EXPECTED}")
    if len({a[0] for a in actions}) != len(actions):
        problems.append("duplicate action ids")
    for aid, _title, status, key, note in actions:
        if status not in mapping["statuses"]:
            problems.append(f"{aid}: unknown status {status}")
        if (status == "unavailable") != (key is None):
            problems.append(f"{aid}: {status} must {'not ' if status == 'unavailable' else ''}name a cmux key")
        if key and (key not in rows or rows[key].get("page_hidden")):
            problems.append(f"{aid}: {key} is not a visible Settings row")
        if status != "exact" and not note:
            problems.append(f"{aid}: {status} needs a note")

    outputs = {}
    js_path = HERE / "customize/main.js"
    js = js_path.read_text()
    block = "const MAP = [\n" + ",\n".join("  " + json.dumps(a, ensure_ascii=False) for a in actions) + "\n]"
    outputs[js_path] = re.sub(r"(// BEGIN MAP\n).*?(\n// END MAP)", lambda m: m[1] + block + m[2], js, flags=re.S)

    setup = json.loads((HERE / "cmux-setup.json").read_text())
    profile = {"cmuxProfile": 1, "name": "rex-settings-navigator", "description": setup["description"],
               "settings": setup["settings"],
               "files": {f"customize/{n}": (HERE / "customize" / n).read_text() if n != "main.js" else outputs[js_path]
                         for n in ("cmux-app.json", "main.js")}}
    outputs[HERE / "profile.json"] = json.dumps(profile, indent=2, ensure_ascii=False) + "\n"

    readme_path = HERE / "README.md"
    readme = readme_path.read_text()
    tally = Counter(a[2] for a in actions)
    def table(status):
        lines = ["| Rex action | Title | cmux setting | Difference |" if status != "unavailable" else
                 "| Rex action | Title | Where it lives instead |", "| --- | --- | --- | --- |" if status != "unavailable"
                 else "| --- | --- | --- |"]
        for aid, title, s, key, note in actions:
            if s != status:
                continue
            lines.append(f"| `{aid}` | {title} | `{key}` | {note or 'Same behavior.'} |" if key
                         else f"| `{aid}` | {title} | {note} |")
        return "\n".join(lines)
    body = (f"**{len(actions)} actions: {tally['exact']} exact, {tally['related']} related, "
            f"{tally['unavailable']} unavailable.**\n\n### Exact\n\n{table('exact')}\n\n### Related\n\n"
            f"{table('related')}\n\n### Not expressible in cmux Settings\n\n{table('unavailable')}")
    outputs[readme_path] = re.sub(r"(<!-- BEGIN TABLES -->\n).*?(\n<!-- END TABLES -->)",
                                  lambda m: m[1] + body + m[2], readme, flags=re.S)

    stale = [p for p, text in outputs.items() if not p.exists() or p.read_text() != text]
    if check:
        problems += [f"{p.relative_to(ROOT)} is stale: run build.py" for p in stale]
    else:
        for p in stale:
            p.write_text(outputs[p])
    for p in problems:
        print(f"build.py: {p}", file=sys.stderr)
    print(f"{len(actions)} actions: {dict(tally)}; {'stale' if check and stale else 'written' if stale else 'current'}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
