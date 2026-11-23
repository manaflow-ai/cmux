#!/usr/bin/env python3
"""Bundle every installable look in the gallery into a profile file the demo previews.

Each folder with a cmux-setup.json under examples/looks (at any depth) and examples/gallery
becomes gallery/<path-with-dashes>.json: what `cmux setup install` would apply, as one file
`cmux customize use` takes. It reads the folder the way cmux-customize's setup.rs (read_dir,
repo_files) does: the manifest's settings and files (a {"$file": ...} entry read from the folder),
plus keybindings.json, <surface>/theme.css, themes/*.json and customize/**. A folder with only a
profile.json (a profile, no setup) is copied as it is. Starters from examples/gallery are named
starter-<name>.json.

A preview carries settings and files only: a setup's cmux-next.json `actions` and the extensions it
lists come with `cmux setup install`, not with a preview. The bundle keeps them under
"x-setup" so the demo can say so; `cmux customize use` ignores unknown top-level keys.

A look that sets a setting this cmux's schema does not have yet waits in WAITING, with the PR
that adds it: it has no bundle until schemas/settings/settings-schema.json has the key, and then
`--check` fails until it is bundled, so it joins the demo the day its PR lands.

`--check` exits 1 while a bundle is stale or a look has no bundle.
"""
import json
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
EXAMPLES = HERE.parent.parent
STYLE_SURFACES = ("agent-pane", "markdown", "diff", "picker", "fileViewer")
SCHEMA = EXAMPLES.parent / "schemas" / "settings" / "settings-schema.json"
# Bundle name -> (the PR that adds the setting, the setting).
WAITING = {
    "starter-thinking-dots.json": ("cmux#47525", "agentPane.display.thinking.glyph"),
    # The schema row is agent_settable: false (a setting only the person changes), so `customize use`
    # refuses the profile; it joins once that row lets a profile set it.
    "claude-code-open-in-editor.json": ("a profile-settable openCitationsInEditor row",
                                        "agentPane.links.openCitationsInEditor"),
}


def waiting() -> dict[str, tuple[str, str]]:
    """The WAITING looks whose setting this checkout's schema still lacks, or keeps to the person
    (agent_settable: false), so a profile cannot set it."""
    rows = {}
    if SCHEMA.is_file():
        rows = {row.get("key"): row for row in json.loads(SCHEMA.read_text()).get("rows", [])}
    return {name: why for name, why in WAITING.items()
            if why[1] not in rows or rows[why[1]].get("agent_settable") is False}


def strip_jsonc(text: str) -> str:
    """JSONC to JSON: drop // and /* */ comments outside strings, then trailing commas."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                j += 2 if text[j] == "\\" else 1
            out.append(text[i:j + 1])
            i = j + 1
        elif text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
        elif text.startswith("/*", i):
            end = text.find("*/", i + 2)
            i = n if end < 0 else end + 2
        else:
            out.append(c)
            i += 1
    return re.sub(r",(\s*[}\]])", r"\1", "".join(out))


def walk(folder: pathlib.Path, logical: str) -> list[tuple[str, pathlib.Path]]:
    if not folder.is_dir():
        return []
    found = []
    for entry in sorted(folder.iterdir(), key=lambda p: p.name):
        if entry.name.startswith(".") or entry.name.endswith("~") or entry.name == "node_modules":
            continue
        child = f"{logical}/{entry.name}"
        if entry.is_dir():
            found += walk(entry, child)
        elif entry.is_file():
            found.append((child, entry))
    return found


def repo_files(folder: pathlib.Path) -> dict[str, str]:
    files = {}
    if (folder / "keybindings.json").is_file():
        files["keybindings.json"] = (folder / "keybindings.json").read_text()
    for surface in STYLE_SURFACES:
        css = folder / surface / "theme.css"
        if css.is_file():
            files[f"{surface}/theme.css"] = css.read_text()
    for part in ("themes", "customize"):
        for logical, path in walk(folder / part, part):
            if part == "themes" and not logical.endswith(".json"):
                continue
            files[logical] = path.read_text()
    return files


def profile_name(setup_id: str) -> str:
    name = "".join(c.lower() if c.isascii() and c.isalnum() else "-" for c in f"setup-{setup_id}")
    return name[:64].rstrip("-")


def bundle_setup(folder: pathlib.Path) -> str:
    manifest = json.loads(strip_jsonc((folder / "cmux-setup.json").read_text()))
    files = {}
    for logical, entry in manifest.get("files", {}).items():
        files[logical] = entry if isinstance(entry, str) else (folder / entry["$file"]).read_text()
    for logical, text in repo_files(folder).items():
        if logical in files:
            raise SystemExit(f"{folder}: {logical} is both in cmux-setup.json's files and in the folder")
        files[logical] = text
    profile = {
        "cmuxProfile": manifest.get("cmuxProfile", 1),
        "name": profile_name(manifest["id"]),
        "description": manifest.get("description") or manifest.get("tagline") or manifest["name"],
        "created_ms": 0,
        "settings": manifest.get("settings", {}),
        "files": dict(sorted(files.items())),
    }
    setup = {"id": manifest["id"], "name": manifest["name"],
             "source": folder.relative_to(EXAMPLES).as_posix()}
    if manifest.get("actions"):
        setup["actions"] = sorted(manifest["actions"])
    if manifest.get("extensions"):
        setup["extensions"] = manifest["extensions"]
    profile["x-setup"] = setup
    return json.dumps(profile, indent=2, ensure_ascii=False) + "\n"


def bundle_profile(folder: pathlib.Path) -> str:
    profile = json.loads((folder / "profile.json").read_text())
    profile.setdefault("created_ms", 0)
    profile.setdefault("files", {})
    profile["x-setup"] = {"name": profile["name"], "source": folder.relative_to(EXAMPLES).as_posix()}
    return json.dumps(profile, indent=2, ensure_ascii=False) + "\n"


def sources() -> dict[str, pathlib.Path]:
    """Bundle name -> source folder, for every installable look."""
    out = {}
    looks = EXAMPLES / "looks"
    for setup in sorted(looks.rglob("cmux-setup.json")):
        out["-".join(setup.parent.relative_to(looks).parts) + ".json"] = setup.parent
    for profile in sorted(looks.rglob("profile.json")):
        if not (profile.parent / "cmux-setup.json").is_file():
            out["-".join(profile.parent.relative_to(looks).parts) + ".json"] = profile.parent
    for setup in sorted((EXAMPLES / "gallery").glob("*/cmux-setup.json")):
        out[f"starter-{setup.parent.name}.json"] = setup.parent
    for name in waiting():
        out.pop(name, None)
    return out


def bundle(folder: pathlib.Path) -> str:
    return bundle_setup(folder) if (folder / "cmux-setup.json").is_file() else bundle_profile(folder)


def main() -> int:
    check = "--check" in sys.argv[1:]
    stale = []
    wanted = sources()
    for name, folder in wanted.items():
        out = HERE / name
        text = bundle(folder)
        if check:
            if not out.is_file() or out.read_text() != text:
                stale.append(name)
        else:
            out.write_text(text)
    extra = sorted(p.name for p in HERE.glob("*.json") if p.name not in wanted)
    if extra:
        print("no source look for: " + ", ".join(extra), file=sys.stderr)
        return 1
    if stale:
        print("stale: " + ", ".join(stale) + "; run examples/customize-demo/gallery/bundle.py", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
