#!/usr/bin/env python3
# Copyright 2026 Manaflow, Inc.
# SPDX-License-Identifier: GPL-3.0-or-later
"""First-party license declarations are GPL-3.0-or-later (Lawrence, 2026-10-06:
"keep everything GPL, we do not want any MIT in cmux").

  check_first_party_licenses.py [--root DIR]

Reads every tracked file (git ls-files) and fails when first-party code
declares another license:
  - package.json "license" (a package without one must be "private": true);
  - Cargo.toml [package] license, with `license.workspace = true` resolved from
    the nearest [workspace] root (a crate without one must not be published),
    and [workspace.package] license;
  - pyproject.toml [project] license and its "License ::" classifiers (a
    Python package must declare one);
  - cmux-app.json / cmux-app.v2.json "license";
  - LICENSE and COPYING files: they must name GPL-3.0-or-later and hold no
    other license grant;
  - SPDX-License-Identifier lines in the first five lines of a source file.

Not first-party, so not checked here:
  - BUSL_DIRS, the server directories that the root LICENSE puts under the
    Business Source License 1.1 (a declaration there must be BUSL-1.1);
  - THIRD_PARTY, code we vendor or copy and stored license texts: they keep
    their own licenses.
MIXED names the first-party packages that also contain adapted third-party
code: their declaration is exactly the given SPDX expression, and their
third-party license texts are listed in THIRD_PARTY_LICENSE_FILES.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys
import tomllib

GPL = "GPL-3.0-or-later"
BUSL = "BUSL-1.1"
GPL_CLASSIFIER = "License :: OSI Approved :: GNU General Public License v3 or later (GPLv3+)"

# Root LICENSE, "The cmux server software is not licensed under the GPL".
BUSL_DIRS = (
    "web/",
    "workers/ci-artifacts/",
    "workers/iroh-v2/",
    "workers/presence/",
    "services/iroh-relay-minter/",
    "cmux-tui/relays/cloudflare-do/",
    "backend/",
)

# Third-party code and stored third-party license texts (prefix -> reason).
THIRD_PARTY = {
    "ghostty/": "Ghostty submodule (MIT)",
    "ghostty-next/": "Ghostty submodule (MIT)",
    "homebrew-cmux/": "submodule",
    "vendor/": "vendored third-party packages",
    "cmux-tui/vendor/": "vendored crossterm and terminput-crossterm",
    "daemon/remote/third-party/": "vendored Go sources",
    "cmux-tui/build-support/notices/": "stored third-party license texts and notice data",
    "cmux-tui/dist/notices/": "stored third-party license texts",
    "scripts/cmux-next/cef-license/": "CEF license text",
    "scripts/cmux-next/notices/": "third-party notice inputs and the notice tools' fixtures",
    "cmux-tui/crates/cmux-app-host/schema/fixtures/": "manifest fixtures of a hypothetical third-party app",
    "Packages/macOS/CmuxNext/Sources/CmuxNextApps/Resources/AppPlatform/schema/fixtures/": "copy of the fixtures above",
    "webviews/test/fixtures/": "test fixtures copied from other files",
}

# First-party packages that contain adapted third-party code: exact declaration.
MIXED = {
    "libs/integrations-core/": f"{GPL} AND MIT",  # executor (MIT), see NOTICE
    "first-party-apps/integrations/": f"{GPL} AND MIT",  # bundles libs/integrations-core
    "cmux-tui/bindings/examples/rust-agent-screen-detection/": f"{GPL} AND Apache-2.0",  # herdr
}

# Third-party license texts that sit inside first-party packages.
THIRD_PARTY_LICENSE_FILES = {
    "libs/integrations-core/LICENSE-executor": "executor MIT License",
    "first-party-apps/integrations/LICENSE-executor": "executor MIT License (the app's notice)",
    "cmux-tui/bindings/examples/rust-agent-screen-detection/manifests/LICENSE": "herdr Apache-2.0",
}

LICENSE_FILE = re.compile(r"^(LICEN[CS]E|COPYING)([-._].*)?$", re.I)
SPDX = re.compile(r"SPDX-License-Identifier:\s*(.+?)\s*(\*/|-->)?\s*$")
GPL_NAMES = ("GPL-3.0-or-later", "GNU General Public License v3.0 or later")
GPL_TEXT = ("GNU GENERAL PUBLIC LICENSE", "Version 3, 29 June 2007")
OTHER_GRANTS = {
    "MIT": "Permission is hereby granted, free of charge",
    "BSD": "Redistribution and use in source and binary forms",
    "Apache-2.0": "TERMS AND CONDITIONS FOR USE, REPRODUCTION, AND DISTRIBUTION",
    "MPL-2.0": "Mozilla Public License Version 2.0",
    "BUSL-1.1": "Business Source License 1.1\n\nParameters",
}
SOURCE_SUFFIXES = {
    ".c", ".cc", ".cpp", ".h", ".hpp", ".m", ".mm", ".swift", ".rs", ".go", ".zig", ".py", ".sh",
    ".bash", ".js", ".mjs", ".cjs", ".ts", ".tsx", ".jsx", ".css", ".java", ".kt", ".rb", ".lua",
}


def under(path: str, prefixes) -> str | None:
    return next((p for p in prefixes if path.startswith(p)), None)


def expected_for(path: str) -> str:
    mixed = under(path, MIXED)
    return MIXED[mixed] if mixed else GPL


def classify(path: str) -> str:
    if under(path, BUSL_DIRS):
        return "busl"
    if under(path, THIRD_PARTY):
        return "third-party"
    return "first-party"


def _declared(problems: list[str], path: str, value, what: str) -> None:
    kind = classify(path)
    if kind == "third-party" or value is None:
        return
    if kind == "busl":
        if value != BUSL:
            problems.append(f"{path}: {what} is {value!r}; the root LICENSE puts this directory under {BUSL}")
        return
    want = expected_for(path)
    if value != want:
        problems.append(f"{path}: {what} is {value!r}; first-party code declares {want!r}")


def check_package_json(root: Path, path: str, problems: list[str]) -> None:
    data = json.loads((root / path).read_text())
    license_ = data.get("license")
    if license_ is None and classify(path) == "first-party" and data.get("private") is not True:
        problems.append(f"{path}: a published package (no \"private\": true) must declare \"license\": {expected_for(path)!r}")
    _declared(problems, path, license_, '"license"')


def _workspace_root(root: Path, path: str, tracked: set[str]) -> tuple[str, dict] | None:
    parent = PurePosixPath(path).parent
    while True:
        parent = parent.parent if parent != PurePosixPath(".") else None
        if parent is None:
            return None
        candidate = str(parent / "Cargo.toml") if str(parent) != "." else "Cargo.toml"
        if candidate in tracked:
            data = tomllib.loads((root / candidate).read_text())
            if "workspace" in data:
                return candidate, data["workspace"]
        if str(parent) == ".":
            return None


def check_cargo(root: Path, path: str, tracked: set[str], problems: list[str]) -> None:
    data = tomllib.loads((root / path).read_text())
    ws_package = data.get("workspace", {}).get("package", {})
    if "license" in ws_package:
        _declared(problems, path, ws_package["license"], "[workspace.package] license")
    package = data.get("package")
    if package is None:
        return
    own_ws = data.get("workspace")

    def inherited(key):
        value = package.get(key)
        if isinstance(value, dict) and value.get("workspace") is True:
            ws = own_ws if own_ws is not None else (_workspace_root(root, path, tracked) or (None, {}))[1]
            return (ws or {}).get("package", {}).get(key)
        return value

    license_ = inherited("license")
    if package.get("license-file") and license_ is None and classify(path) == "first-party":
        problems.append(f"{path}: license-file without license; first-party crates declare license = {expected_for(path)!r}")
        return
    publish = inherited("publish")
    if license_ is None and classify(path) == "first-party" and publish is not False:
        problems.append(f"{path}: a publishable crate must declare license = {expected_for(path)!r}")
    _declared(problems, path, license_, "license")


def check_pyproject(root: Path, path: str, problems: list[str]) -> None:
    data = tomllib.loads((root / path).read_text())
    project = data.get("project")
    if project is None:
        return
    license_ = project.get("license")
    if isinstance(license_, dict):
        license_ = license_.get("text") or (f"file:{license_['file']}" if "file" in license_ else None)
    if license_ is None and classify(path) == "first-party":
        problems.append(f"{path}: [project] must declare license = {expected_for(path)!r}")
    _declared(problems, path, license_, "[project] license")
    if classify(path) == "first-party":
        for classifier in project.get("classifiers", []):
            if classifier.startswith("License ::") and classifier != GPL_CLASSIFIER:
                problems.append(f"{path}: classifier {classifier!r}; first-party code uses {GPL_CLASSIFIER!r}")


def check_app_manifest(root: Path, path: str, problems: list[str]) -> None:
    data = json.loads((root / path).read_text())
    _declared(problems, path, data.get("license"), '"license"')


def check_license_file(root: Path, path: str, problems: list[str]) -> None:
    if classify(path) != "first-party" or path in THIRD_PARTY_LICENSE_FILES:
        return
    text = (root / path).read_text(errors="replace")
    names_gpl = any(name in text for name in GPL_NAMES) or (
        all(marker in text for marker in GPL_TEXT) and "any later version" in text
    )
    if not names_gpl:
        problems.append(f"{path}: a first-party license file must name {GPL} (or list it in THIRD_PARTY_LICENSE_FILES as a third-party text)")
    for name, marker in OTHER_GRANTS.items():
        if marker in text:
            problems.append(f"{path}: holds a {name} grant; first-party license files are {GPL} only")


def check_spdx(root: Path, path: str, problems: list[str]) -> None:
    if classify(path) != "first-party" or PurePosixPath(path).suffix not in SOURCE_SUFFIXES:
        return
    try:
        with (root / path).open(errors="replace") as handle:
            head = [next(handle, "") for _ in range(5)]
    except (IsADirectoryError, FileNotFoundError):
        return
    for line in head:
        match = SPDX.search(line)
        if match and match.group(1) != expected_for(path):
            problems.append(f"{path}: SPDX-License-Identifier {match.group(1)!r}; first-party code uses {expected_for(path)!r}")


def check(root: Path, files: list[str]) -> list[str]:
    tracked = set(files)
    problems: list[str] = []
    for path in sorted(files):
        name = PurePosixPath(path).name
        if not (root / path).is_file():
            continue  # submodule gitlinks
        if name == "package.json":
            check_package_json(root, path, problems)
        elif name == "Cargo.toml":
            check_cargo(root, path, tracked, problems)
        elif name == "pyproject.toml":
            check_pyproject(root, path, problems)
        elif name in ("cmux-app.json", "cmux-app.v2.json"):
            check_app_manifest(root, path, problems)
        elif LICENSE_FILE.match(name):
            check_license_file(root, path, problems)
        else:
            check_spdx(root, path, problems)
    return problems


def tracked_files(root: Path) -> list[str]:
    out = subprocess.run(["git", "-C", str(root), "ls-files", "-z"], check=True, capture_output=True).stdout
    return [p for p in out.decode().split("\0") if p]


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[3])
    args = parser.parse_args(argv)
    problems = check(args.root, tracked_files(args.root))
    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    if problems:
        print(f"{len(problems)} first-party license declaration(s) are not {GPL}", file=sys.stderr)
        return 1
    print(f"first-party license declarations: all {GPL} (BUSL directories and third-party paths excluded)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
