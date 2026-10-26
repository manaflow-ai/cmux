#!/usr/bin/env python3
"""Incremental build timing for the generated wire targets (p05-ipc-194).

Run through scripts/cmux-next/build-timing.sh on a fleet Mac. It times, on a
warm build:

- a leaf edit: the body of a private function appended to DaemonRequest.swift
  (CmuxNextDaemonWire after p05-ipc-025, CmuxNextDaemon before), which changes
  no module interface;
- a schema edit: one optional request field added to one command of
  cmux-tui/spec/sdk-schema.json (a `clients: macos` command when the schema
  says which, else `ping`), which the build-time generator (p05-ipc-027)
  turns into a changed generated type.

Each edit is a different one per sample, so every sample is a real rebuild.
The rebuilt targets come from SwiftPM's `Compiling <module>` and
`Emitting module <module>` lines (cargo's `Compiling <crate>` lines with
--rust), and "generator ran" from a build line that names the generator. All
edited files get their original bytes back, also when a build fails or the
step is stopped.

Output keys (artifacts/build-timing/<sha>.json):
  task, date, host, macos, cores, jobs, swift, sha, dirty, layout, label,
  full_build_s, noop_build_s, max_leaf_seconds,
  rows[]: edit (leaf|schema), tool (swift|cargo), file, command (schema rows),
          samples[]: {seconds, targets, steps, generator_ran},
          p50_s, max_s, target_count, targets, generator_ran,
  verdict: {leaf_under_budget, leaf_reran_generator, passed}.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import re
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional, Sequence

TASK = "p05-ipc-194"
PACKAGE = Path("Packages/macOS/CmuxNext")
LEAF_CANDIDATES = (
    PACKAGE / "Sources/CmuxNextDaemonWire/DaemonRequest.swift",
    PACKAGE / "Sources/CmuxNextDaemon/Requests/DaemonRequest.swift",
)
WIRE_TARGET_DIR = PACKAGE / "Sources/CmuxNextDaemonWire"
PLUGIN_DIR = PACKAGE / "Plugins/CmuxNextWireGenPlugin"
DEFAULT_SCHEMA = Path("cmux-tui/spec/sdk-schema.json")
CARGO_MANIFEST = Path("cmux-tui/Cargo.toml")
PROBE_FIELD = "build_timing_probe"
DEFAULT_GENERATOR_PATTERN = r"WireGen"
RUST_GENERATOR_CRATE = "cmux-ipc"

SWIFT_STEP = re.compile(r"^\[(\d+)/(\d+)\]\s+(.*)$")
# Steps that build code; a generator match on any other step means it ran.
BUILD_ONLY_ACTIONS = ("Compiling ", "Emitting module ", "Linking ", "Write ", "Applying ", "Planning ")
SWIFT_MODULE = re.compile(r"^(?:Compiling|Emitting module)\s+(?!plugin\s)([A-Za-z_][A-Za-z0-9_]*)\b")
CARGO_CRATE = re.compile(r"^\s*Compiling\s+([A-Za-z0-9_-]+)\s+v")

EXIT_BUDGET = 1
EXIT_USAGE = 2
EXIT_BUILD = 3


class UsageError(Exception):
    """A bad option or a repository that does not have the files to edit."""


class BuildFailed(Exception):
    """A build exited non-zero; the message carries the log path and its tail."""


class Stopped(Exception):
    """SIGTERM or SIGHUP: unwind so every edited file is put back."""

    def __init__(self, signum: int) -> None:
        super().__init__(f"stopped by signal {signum}")
        self.signum = signum


# --- build log parsing -------------------------------------------------------


def parse_swift_log(text: str, generator_pattern: str) -> Dict[str, object]:
    generator = re.compile(generator_pattern)
    steps = 0
    targets = set()
    generator_ran = False
    for line in text.splitlines():
        step = SWIFT_STEP.match(line.strip())
        if not step:
            continue
        steps = max(steps, int(step.group(2)))
        action = step.group(3)
        if action.startswith(BUILD_ONLY_ACTIONS):
            module = SWIFT_MODULE.match(action)
            if module:
                targets.add(module.group(1))
        elif generator.search(action):
            generator_ran = True
    return {"targets": sorted(targets), "steps": steps, "generator_ran": generator_ran}


def parse_cargo_log(text: str) -> Dict[str, object]:
    crates = sorted({m.group(1) for m in map(CARGO_CRATE.match, text.splitlines()) if m})
    return {"targets": crates, "steps": len(crates), "generator_ran": RUST_GENERATOR_CRATE in crates}


# --- edits -------------------------------------------------------------------


def leaf_edit(original: bytes, nonce: int) -> bytes:
    """A private function whose body changes with the nonce: no interface change."""
    text = original.decode("utf-8")
    if not text.endswith("\n"):
        text += "\n"
    return (
        text
        + "\n// p05-ipc-194 build-timing probe; build-timing.sh puts this file back.\n"
        + f"private func buildTimingProbe() -> Int {{ {nonce} }}\n"
    ).encode("utf-8")


def _json_indent(original: str) -> int:
    for line in original.splitlines()[1:]:
        stripped = line.lstrip(" ")
        if stripped:
            return max(1, len(line) - len(stripped))
    return 1


def _object_fields(container: object) -> Optional[dict]:
    if isinstance(container, dict) and isinstance(container.get("fields"), dict):
        return container["fields"]
    return None


def _sdk_request_fields(spec: object) -> Optional[dict]:
    if not isinstance(spec, dict):
        return None
    request = spec.get("request")
    if isinstance(request, dict) and request.get("kind") == "object":
        return _object_fields(request)
    return None


def _v2_param_fields(spec: object) -> Optional[dict]:
    return _object_fields(spec.get("params")) if isinstance(spec, dict) else None


def _schema_table(doc: dict):
    """(methods table, fields getter, new field) for sdk-schema or resource-operations-v2."""
    if isinstance(doc.get("commands"), dict):
        field = {"type": {"kind": "scalar", "name": "string"}, "presence": "optional", "nullable": True, "default": None}
        return doc["commands"], _sdk_request_fields, field
    if isinstance(doc.get("operations"), dict):
        field = {"required": False, "type": {"kind": "primitive", "name": "string"}}
        return doc["operations"], _v2_param_fields, field
    raise UsageError("the schema has neither a `commands` nor an `operations` table")


def pick_schema_command(doc: dict, requested: Optional[str]) -> str:
    table, fields_of, _ = _schema_table(doc)
    if requested is not None:
        if requested not in table:
            raise UsageError(f"--schema-command {requested}: not in the schema")
        if fields_of(table[requested]) is None:
            raise UsageError(f"--schema-command {requested}: its request is not an object with fields")
        return requested
    editable = [name for name, spec in table.items() if fields_of(spec) is not None]
    for name in editable:
        clients = table[name].get("clients")
        if isinstance(clients, list) and "macos" in clients:
            return name
    if "ping" in editable:
        return "ping"
    if editable:
        return editable[0]
    raise UsageError("the schema has no command with an object request")


def schema_edit(original: bytes, command: str, nonce: int) -> bytes:
    """The schema with one more optional field on `command`'s request."""
    text = original.decode("utf-8")
    doc = json.loads(text)
    table, fields_of, field = _schema_table(doc)
    fields = fields_of(table[command])
    if fields is None:
        raise UsageError(f"{command}: its request is not an object with fields")
    fields[f"{PROBE_FIELD}_{nonce}"] = field
    return (json.dumps(doc, indent=_json_indent(text), ensure_ascii=False) + "\n").encode("utf-8")


class EditedFiles:
    """Keeps each file's original bytes and writes them back on exit."""

    def __init__(self) -> None:
        self._originals: Dict[Path, bytes] = {}

    def original(self, path: Path) -> bytes:
        if path not in self._originals:
            self._originals[path] = path.read_bytes()
        return self._originals[path]

    def write(self, path: Path, content: bytes) -> None:
        self.original(path)
        path.write_bytes(content)

    def restore(self, path: Path) -> None:
        if path in self._originals:
            path.write_bytes(self._originals[path])

    def __enter__(self) -> "EditedFiles":
        return self

    def __exit__(self, *_exc: object) -> None:
        for path, content in self._originals.items():
            path.write_bytes(content)


# --- builds ------------------------------------------------------------------


class Builder:
    def __init__(self, root: Path, args: argparse.Namespace, jobs: int, logs: Path) -> None:
        self.root = root
        self.args = args
        self.jobs = jobs
        self.logs = logs
        self.count = 0

    def _run(self, name: str, cmd: Sequence[str]) -> "tuple[float, str]":
        self.count += 1
        log = self.logs / f"{self.count:02d}-{name}.log"
        started = time.monotonic()
        with log.open("wb") as out:
            status = subprocess.call(list(cmd), cwd=self.root, stdin=subprocess.DEVNULL, stdout=out, stderr=subprocess.STDOUT)
        seconds = time.monotonic() - started
        text = log.read_text(encoding="utf-8", errors="replace")
        if status != 0:
            tail = "\n".join(text.splitlines()[-40:])
            raise BuildFailed(f"{name}: `{' '.join(cmd)}` exited {status}; log {log}\n{tail}")
        return seconds, text

    def swift(self, name: str) -> "tuple[float, Dict[str, object]]":
        cmd = ["swift", "build", "--package-path", str(PACKAGE), "--target", self.args.target, "--jobs", str(self.jobs)]
        if self.args.scratch_path:
            cmd += ["--scratch-path", self.args.scratch_path]
        seconds, text = self._run(f"swift-{name}", cmd)
        return seconds, parse_swift_log(text, self.args.generator_pattern)

    def cargo(self, name: str) -> "tuple[float, Dict[str, object]]":
        cmd = ["cargo", "build", "--manifest-path", str(CARGO_MANIFEST), "-p", "cmux-tui", "--jobs", str(self.jobs)]
        seconds, text = self._run(f"cargo-{name}", cmd)
        return seconds, parse_cargo_log(text)


def summarize(edit: str, tool: str, file: Path, samples: List[Dict[str, object]], command: Optional[str]) -> Dict[str, object]:
    seconds = [float(s["seconds"]) for s in samples]
    names = sorted({name for s in samples for name in s["targets"]})  # type: ignore[union-attr]
    row: Dict[str, object] = {
        "edit": edit,
        "tool": tool,
        "file": str(file),
        "samples": samples,
        "p50_s": round(statistics.median(seconds), 3),
        "max_s": round(max(seconds), 3),
        "target_count": max(len(s["targets"]) for s in samples),  # type: ignore[arg-type]
        "targets": names,
        "generator_ran": any(bool(s["generator_ran"]) for s in samples),
    }
    if command is not None:
        row["command"] = command
    return row


def sample(seconds: float, parsed: Dict[str, object]) -> Dict[str, object]:
    return {"seconds": round(seconds, 3), **parsed}


# --- environment -------------------------------------------------------------


def _output(cmd: Sequence[str], cwd: Optional[Path] = None) -> str:
    if shutil.which(cmd[0]) is None:
        return ""
    try:
        return subprocess.run(list(cmd), cwd=cwd, capture_output=True, text=True, check=False).stdout.strip()
    except OSError:
        return ""


def build_jobs() -> int:
    budget = os.environ.get("CMUX_CI_CPU_BUDGET", "")
    if budget.isdigit() and int(budget) > 0:
        return int(budget)
    return os.cpu_count() or 1


def layout_of(root: Path) -> str:
    wire = (root / WIRE_TARGET_DIR).is_dir()
    plugin = (root / PLUGIN_DIR).is_dir()
    if wire and plugin:
        return "after-025/027"
    if not wire and not plugin:
        return "before-025/027"
    return "partial: " + ("025" if wire else "027")


def leaf_file(root: Path, requested: Optional[str]) -> Path:
    if requested:
        path = Path(requested)
        if not (root / path).is_file():
            raise UsageError(f"--leaf-file {requested}: no such file")
        return path
    for candidate in LEAF_CANDIDATES:
        if (root / candidate).is_file():
            return candidate
    raise UsageError("no DaemonRequest.swift in CmuxNextDaemonWire or CmuxNextDaemon; pass --leaf-file")


def markdown_row(report: Dict[str, object], row: Dict[str, object]) -> str:
    targets = list(row["targets"])  # type: ignore[arg-type]
    shown = ", ".join(targets[:5]) + (", ..." if len(targets) > 5 else "")
    edit = f"{row['edit']} ({row['tool']})"
    if row.get("command"):
        edit += f" `{row['command']}`"
    host = f"{report['host']} / {report['cores']} cores, jobs {report['jobs']} / macOS {report['macos'] or '?'}"
    sha = str(report["sha"])[:12] + (" dirty" if report["dirty"] else "")
    samples = len(row["samples"])  # type: ignore[arg-type]
    return (
        f"| {report['date']} | {edit} | {report['layout']} | {host} | {sha} | "
        f"{row['p50_s']} / {row['max_s']} (n={samples}) | {row['target_count']}: {shown or '-'} | "
        f"{'yes' if row['generator_ran'] else 'no'} | {report['label'] or ''} |"
    )


# --- main --------------------------------------------------------------------


def parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--leaf-edit", action="store_true", help="time a rebuild after a leaf Swift edit")
    parser.add_argument("--schema-edit", action="store_true", help="time a rebuild after a one-field schema edit")
    parser.add_argument("--rust", action="store_true", help="also time `cargo build -p cmux-tui` after the schema edit")
    parser.add_argument("--repeat", type=int, default=3, help="samples per edit (default 3)")
    parser.add_argument("--target", default="CmuxNextApp", help="SwiftPM target to build (default CmuxNextApp)")
    parser.add_argument("--leaf-file", help="Swift file for the leaf edit, relative to the repo")
    parser.add_argument("--schema-file", default=str(DEFAULT_SCHEMA), help="schema for the one-field edit")
    parser.add_argument("--schema-command", help="command (or v2 operation) that gets the field")
    parser.add_argument("--scratch-path", help="SwiftPM --scratch-path")
    parser.add_argument("--generator-pattern", default=DEFAULT_GENERATOR_PATTERN, help="regex for a build line that runs the generator")
    parser.add_argument("--max-leaf-seconds", type=float, default=30.0, help="leaf-edit budget (default 30)")
    parser.add_argument("--label", default="", help="free text for the Note column, e.g. 'before 025/027'")
    parser.add_argument("--out", help="JSON output (default artifacts/build-timing/<sha>.json)")
    args = parser.parse_args(argv)
    if not (args.leaf_edit or args.schema_edit):
        parser.error("pass --leaf-edit, --schema-edit or both")
    if args.rust and not args.schema_edit:
        parser.error("--rust times the schema edit; pass --schema-edit too")
    if args.repeat < 1:
        parser.error("--repeat must be at least 1")
    try:
        re.compile(args.generator_pattern)
    except re.error as error:
        parser.error(f"--generator-pattern: {error}")
    return args


def _stop(signum: int, _frame: object) -> None:
    raise Stopped(signum)


def run(args: argparse.Namespace) -> int:
    root = Path(args.repo_root).resolve()
    if not os.environ.get("CMUX_CI_STEP_KEY"):
        raise UsageError(
            "build-timing.sh builds the app: run it as a fleet step "
            "(cmux-ci run --class isolated --ref SHA --script 'scripts/cmux-next/build-timing.sh ...'), "
            "never on a person's Mac"
        )
    leaf = leaf_file(root, args.leaf_file) if args.leaf_edit else None
    schema = Path(args.schema_file) if args.schema_edit else None
    if schema is not None and not (root / schema).is_file():
        raise UsageError(f"--schema-file {schema}: no such file")

    sha = os.environ.get("CMUX_CI_SHA") or _output(["git", "rev-parse", "HEAD"], root) or "unknown"
    dirty = bool(_output(["git", "status", "--porcelain", "--untracked-files=no"], root))
    jobs = build_jobs()
    out = Path(args.out) if args.out else root / "artifacts/build-timing" / f"{sha[:12]}.json"
    logs = out.parent / f"{out.stem}-logs"
    logs.mkdir(parents=True, exist_ok=True)
    builder = Builder(root, args, jobs, logs)

    report: Dict[str, object] = {
        "task": TASK,
        "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"),
        "host": socket.gethostname().split(".")[0],
        "macos": _output(["sw_vers", "-productVersion"]),
        "cores": os.cpu_count(),
        "jobs": jobs,
        "swift": (_output(["swift", "--version"]).splitlines() or [""])[0],
        "sha": sha,
        "dirty": dirty,
        "layout": layout_of(root),
        "label": args.label,
        "max_leaf_seconds": args.max_leaf_seconds,
    }
    rows: List[Dict[str, object]] = []

    with EditedFiles() as edits:
        full_s, _ = builder.swift("warm")
        noop_s, _ = builder.swift("noop")
        report["full_build_s"] = round(full_s, 3)
        report["noop_build_s"] = round(noop_s, 3)
        if args.rust:
            builder.cargo("warm")

        if leaf is not None:
            path = root / leaf
            original = edits.original(path)
            samples = []
            for nonce in range(1, args.repeat + 1):
                edits.write(path, leaf_edit(original, nonce))
                samples.append(sample(*builder.swift(f"leaf-{nonce}")))
            edits.restore(path)
            builder.swift("leaf-restore")
            rows.append(summarize("leaf", "swift", leaf, samples, None))

        if schema is not None:
            path = root / schema
            original = edits.original(path)
            command = pick_schema_command(json.loads(original.decode("utf-8")), args.schema_command)
            swift_samples, cargo_samples = [], []
            for nonce in range(1, args.repeat + 1):
                edits.write(path, schema_edit(original, command, nonce))
                swift_samples.append(sample(*builder.swift(f"schema-{nonce}")))
                if args.rust:
                    cargo_samples.append(sample(*builder.cargo(f"schema-{nonce}")))
            edits.restore(path)
            builder.swift("schema-restore")
            rows.append(summarize("schema", "swift", schema, swift_samples, command))
            if args.rust:
                builder.cargo("schema-restore")
                rows.append(summarize("schema", "cargo", schema, cargo_samples, command))

    leaf_rows = [row for row in rows if row["edit"] == "leaf"]
    under_budget = all(float(row["max_s"]) < args.max_leaf_seconds for row in leaf_rows)  # type: ignore[arg-type]
    reran = any(bool(row["generator_ran"]) for row in leaf_rows)
    report["rows"] = rows
    report["verdict"] = {
        "leaf_under_budget": under_budget if leaf_rows else None,
        "leaf_reran_generator": reran if leaf_rows else None,
        "passed": under_budget and not reran,
    }
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")

    print(f"build-timing: {report['layout']} at {sha[:12]} on {report['host']}; full {report['full_build_s']} s, no-op {report['noop_build_s']} s")
    print("| Date | Edit | Layout | Host / cores / macOS | sha | Seconds p50 / max | Targets rebuilt | Generator ran | Note |")
    print("|---|---|---|---|---|---|---|---|---|")
    for row in rows:
        print(markdown_row(report, row))
    print(f"build-timing: wrote {out} (build logs in {logs})")
    for row in leaf_rows:
        if float(row["max_s"]) >= args.max_leaf_seconds:  # type: ignore[arg-type]
            print(f"build-timing: FAIL leaf edit max {row['max_s']} s is not under {args.max_leaf_seconds} s", file=sys.stderr)
        if row["generator_ran"]:
            print("build-timing: FAIL the leaf edit reran the wire generator", file=sys.stderr)
    return 0 if report["verdict"]["passed"] else EXIT_BUDGET  # type: ignore[index]


def main(argv: Sequence[str]) -> int:
    args = parse_args(argv)
    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGHUP, _stop)
    try:
        return run(args)
    except UsageError as error:
        print(f"build-timing: {error}", file=sys.stderr)
        return EXIT_USAGE
    except BuildFailed as error:
        print(f"build-timing: build failed: {error}", file=sys.stderr)
        return EXIT_BUILD
    except Stopped as error:
        print(f"build-timing: {error}; edited files put back", file=sys.stderr)
        return 128 + error.signum


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
