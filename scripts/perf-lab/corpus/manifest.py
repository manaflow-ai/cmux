#!/usr/bin/env python3
"""Corpus story manifests (cmux-perf-corpus-story/v1) and their blobs (p12-perf-process.md 3.8, task 110).

    python3 -I scripts/perf-lab/corpus/manifest.py --validate perf-corpus/*.json [--fetch]
    python3 -I scripts/perf-lab/corpus/manifest.py --add-blob FILE      # into the cache; prints its blob ref
    python3 -I scripts/perf-lab/corpus/manifest.py --upload perf-corpus/*.json

A manifest (schemas/perf/corpus-story-v1.schema.json, one file per story in perf-corpus/) names its large data
by sha256, and the data lives in R2 at perf-lab/corpus/sha256/<hex>, with a local cache that is checked against
the digest on every read. Chromium does the same for its recorded stories: git has the archive's .sha1 and
tools/perf/page_sets/data/<story set>.json, cloud storage has the .wprgo, and py_utils/cloud_storage.py
GetIfHashChanged downloads only when the local copy's hash differs (third_party/catapult/common/py_utils).

The validator checks the schema with a small evaluator of the schema file itself (so the two never drift),
then what the schema cannot say:
  - no text payloads: an input event never carries a text key, a CLI text word or flag, or the key code of a
    typing key (the input journal's rule, InputJournalEntry.Key); every string is a token (no spaces)
  - a recorded story has every source and checkpoint digest; a planned one says why it is not recorded
  - event and checkpoint times are ordered and within duration_ms; checkpoint names are unique
  - repository sources exist, match their digest and size, and no perf-corpus file is over 256 KB
  - metric names compile as regexes; the owner is an OWNERS.md owner; compose names known stories

R2 (fetch, upload): CMUX_PERF_LAB_R2_PUBLIC_URL is the read base; upload uses trace_quest.R2BlobStore and its
CMUX_PERF_LAB_R2_* credentials from the environment. The cache is $CMUX_PERF_CORPUS_CACHE, else
$XDG_CACHE_HOME/cmux/perf-corpus, else ~/.cache/cmux/perf-corpus.

Stdlib only; runs under python3 -I. Tests: python3 -m unittest scripts/perf-lab/tests/test_corpus_manifest.py
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import sys
import tempfile
import urllib.request
from collections.abc import Callable, Iterable, Mapping
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
LAB = HERE.parent
REPO_ROOT = LAB.parents[1]
SCHEMA_PATH = "schemas/perf/corpus-story-v1.schema.json"
CORPUS_DIR = "perf-corpus"
SCHEMA_ID = "cmux-perf-corpus-story/v1"
MAX_GIT_BYTES = 256 * 1024
R2_PREFIX = "perf-lab/corpus/sha256/"

# Keys that carry text wherever they appear in an event payload.
TEXT_KEYS = frozenset({"text", "characters", "chars", "string", "input", "content", "body", "message", "title",
                       "name", "label", "query", "prompt", "command", "url", "path", "cwd", "paste"})
# CLI words and flags whose argument is text (the recorder synthesizes text from a fixed corpus instead).
TEXT_CLI_WORDS = frozenset({"send", "send-text", "send-key", "paste", "type", "notify", "rename", "set-title",
                            "prompt", "message"})
TEXT_CLI_FLAGS = frozenset(f"--{key}" for key in TEXT_KEYS)
TYPING_CLASSES = frozenset({"letter", "digit", "punctuation", "space", "other"})
SHORTCUT_MODIFIERS = frozenset({"cmd", "ctrl"})


class CorpusError(RuntimeError):
    pass


def _load_sibling(name: str):
    module_name = f"perf_lab_{name}"
    if module_name not in sys.modules:
        spec = importlib.util.spec_from_file_location(module_name, LAB / f"{name}.py")
        module = importlib.util.module_from_spec(spec)
        sys.modules[module_name] = module  # before exec: dataclasses resolve their module through sys.modules
        spec.loader.exec_module(module)
    return sys.modules[module_name]


# ---------------------------------------------------------------- schema evaluator

def schema_errors(instance: Any, node: Mapping[str, Any], root: Mapping[str, Any], where: str = "$") -> list[str]:
    """JSON Schema 2020-12 for the keywords corpus-story-v1 uses; an unknown keyword raises, so none is skipped."""
    unknown = set(node) - {"$schema", "$id", "$defs", "$ref", "title", "description", "type", "const", "enum",
                           "required", "properties", "additionalProperties", "propertyNames", "items", "minItems",
                           "minLength", "pattern", "minimum", "maximum", "exclusiveMinimum", "oneOf"}
    if unknown:
        raise CorpusError(f"schema evaluator does not support {sorted(unknown)}")
    if "$ref" in node:
        target: Any = root
        for part in node["$ref"].removeprefix("#/").split("/"):
            target = target[part]
        return schema_errors(instance, target, root, where)
    if "oneOf" in node:
        branches = [schema_errors(instance, sub, root, where) for sub in node["oneOf"]]
        passing = sum(1 for errors in branches if not errors)
        if passing == 0:
            return min(branches, key=len)  # the closest branch says what is wrong
        if passing > 1:
            return [f"{where}: matches {passing} oneOf branches"]
    if "type" in node:
        types = node["type"] if isinstance(node["type"], list) else [node["type"]]
        if not any(_is_type(instance, kind) for kind in types):
            return [f"{where}: not {' or '.join(types)}"]
    errors = []
    if "const" in node and instance != node["const"]:
        errors.append(f"{where}: not {node['const']!r}")
    if "enum" in node and not any(type(instance) is type(v) and instance == v for v in node["enum"]):
        errors.append(f"{where}: {instance!r} not one of {node['enum']}")
    if isinstance(instance, str):
        if len(instance) < node.get("minLength", 0):
            errors.append(f"{where}: empty")
        if "pattern" in node and re.search(node["pattern"].replace("$", r"\Z"), instance) is None:
            errors.append(f"{where}: {instance!r} does not match {node['pattern']}")
    if _is_type(instance, "number"):
        if "minimum" in node and instance < node["minimum"]:
            errors.append(f"{where}: below {node['minimum']}")
        if "maximum" in node and instance > node["maximum"]:
            errors.append(f"{where}: above {node['maximum']}")
        if "exclusiveMinimum" in node and instance <= node["exclusiveMinimum"]:
            errors.append(f"{where}: not above {node['exclusiveMinimum']}")
    if isinstance(instance, list):
        if len(instance) < node.get("minItems", 0):
            errors.append(f"{where}: fewer than {node['minItems']} items")
        for index, item in enumerate(instance if "items" in node else ()):
            errors += schema_errors(item, node["items"], root, f"{where}[{index}]")
    if isinstance(instance, dict):
        errors += [f"{where}: missing {key}" for key in node.get("required", ()) if key not in instance]
        properties, extra = node.get("properties", {}), node.get("additionalProperties")
        for key, value in instance.items():
            if "propertyNames" in node:
                errors += schema_errors(key, node["propertyNames"], root, f"{where}.<{key}>")
            if key in properties:
                errors += schema_errors(value, properties[key], root, f"{where}.{key}")
            elif extra is False:
                errors.append(f"{where}: unknown key {key}")
            elif isinstance(extra, dict):
                errors += schema_errors(value, extra, root, f"{where}.{key}")
    return errors


def _is_type(value: Any, kind: str) -> bool:
    if kind == "integer":
        return not isinstance(value, bool) and (isinstance(value, int) or (isinstance(value, float) and value.is_integer()))
    if kind == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    return isinstance(value, {"null": type(None), "string": str, "boolean": bool, "object": dict, "array": list}[kind])


def load_schema(root: Path = REPO_ROOT) -> dict[str, Any]:
    return json.loads((root / SCHEMA_PATH).read_text(encoding="utf-8"))


# ---------------------------------------------------------------- the rules the schema cannot say

def text_errors(where: str, event: Mapping[str, Any]) -> list[str]:
    """Why EVENT carries text, if it does. Runs on schema-valid events and on events read back from a blob."""
    payload = event.get("payload")
    if not isinstance(payload, dict):
        return []
    errors = [f"{where}.payload: text key {key!r}" for key in _keys(payload) if key.lower() in TEXT_KEYS]
    kind = event.get("kind")
    if kind == "key" and payload.get("class") in TYPING_CLASSES and "key_code" in payload \
            and not SHORTCUT_MODIFIERS & set(payload.get("modifiers") or ()):
        errors.append(f"{where}.payload: key_code on a {payload['class']} key without cmd or ctrl is typed text")
    if kind == "cli":
        for token in payload.get("argv") or ():
            word = str(token).split("=", 1)[0]
            if word in TEXT_CLI_WORDS or word in TEXT_CLI_FLAGS:
                errors.append(f"{where}.payload.argv: {word!r} carries text")
    return errors


def _keys(value: Any) -> Iterable[str]:
    if isinstance(value, dict):
        for key, child in value.items():
            yield str(key)
            yield from _keys(child)
    elif isinstance(value, list):
        for child in value:
            yield from _keys(child)


def event_errors(events: list[Any], duration_ms: Any, schema: Mapping[str, Any], where: str = "$.input.events") -> list[str]:
    errors, previous = [], 0.0
    for index, event in enumerate(events):
        here = f"{where}[{index}]"
        found = schema_errors(event, schema["$defs"]["event"], schema, here)
        if found:
            errors += found
            continue
        errors += text_errors(here, event)
        if event["t_ms"] < previous:
            errors.append(f"{here}.t_ms: before the previous event")
        if _is_type(duration_ms, "integer") and event["t_ms"] > duration_ms:
            errors.append(f"{here}.t_ms: after duration_ms")
        previous = event["t_ms"]
    return errors


def _sources(manifest: Mapping[str, Any]) -> Iterable[tuple[str, Any]]:
    """(where, ref or None) of every blob or file the manifest names."""
    yield "$.layout.snapshot", manifest["layout"]["snapshot"]
    if "blob" in manifest["input"]:
        yield "$.input.blob", manifest["input"]["blob"]
    for index, track in enumerate(manifest["pty"]):
        yield f"$.pty[{index}].source", track["source"]
    if manifest["web_archive"] is not None:
        yield "$.web_archive.wprgo", manifest["web_archive"]["wprgo"]
    for index, agent in enumerate(manifest["agents"]):
        yield f"$.agents[{index}].transcript", agent["transcript"]


def validation_errors(manifest: Any, *, root: Path = REPO_ROOT, schema: Mapping[str, Any] | None = None,
                      owners: frozenset[str] | None = None, stories: frozenset[str] | None = None) -> list[str]:
    """One "where: reason" line per problem of MANIFEST (empty if valid). `owners` and `stories` are optional
    allowlists for the owner and for compose; repository sources are checked under `root`."""
    schema = schema if schema is not None else load_schema(root)
    events: list[Any] = []
    if isinstance(manifest, dict) and isinstance(manifest.get("input"), dict) \
            and isinstance(manifest["input"].get("events"), list):
        # Events are checked one by one, so each error names its event instead of the input's oneOf.
        events = manifest["input"]["events"]
        manifest = {**manifest, "input": {**manifest["input"], "events": []}}
    errors = schema_errors(manifest, schema, schema)
    if errors:
        return errors
    errors = event_errors(events, manifest["duration_ms"], schema)
    recorded = manifest["status"] == "recorded"
    if recorded and "planned" in manifest:
        errors.append("$.planned: only a planned story says why it is not recorded")
    if not recorded and "planned" not in manifest:
        errors.append("$.planned: a planned story says what records it")
    for where, ref in _sources(manifest):
        if ref is None:
            if recorded:
                errors.append(f"{where}: a recorded story needs it")
        elif "path" in ref:
            errors += _file_errors(where, ref, root)
    if recorded and manifest["web_archive"] is not None and manifest["web_archive"]["spki"] is None:
        errors.append("$.web_archive.spki: a recorded story needs it")
    names, previous = set(), 0
    for index, checkpoint in enumerate(manifest["checkpoints"]):
        here = f"$.checkpoints[{index}]"
        if checkpoint["name"] in names:
            errors.append(f"{here}.name: {checkpoint['name']!r} twice")
        names.add(checkpoint["name"])
        if checkpoint["t_ms"] < previous or checkpoint["t_ms"] > manifest["duration_ms"]:
            errors.append(f"{here}.t_ms: out of order or after duration_ms")
        previous = checkpoint["t_ms"]
        if recorded and (checkpoint["focus"] is None or checkpoint["surfaces"] is None):
            errors.append(f"{here}: a recorded story needs both digests")
    for index, metric in enumerate(manifest["metrics"]):
        try:
            re.compile(metric["name"])
        except re.error as error:
            errors.append(f"$.metrics[{index}].name: {error}")
    if owners is not None and manifest["owner"] not in owners:
        errors.append(f"$.owner: {manifest['owner']!r} is not an owner in plans/cmux-next/OWNERS.md")
    if "compose" in manifest:
        for name in manifest["compose"]["stories"]:
            if name == manifest["id"] or (stories is not None and name not in stories):
                errors.append(f"$.compose.stories: {name!r} is not another corpus story")
    return errors


def _file_errors(where: str, ref: Mapping[str, Any], root: Path) -> list[str]:
    path = root / ref["path"]
    if not path.is_file():
        return [f"{where}.path: {ref['path']} does not exist"]
    data = path.read_bytes()
    if len(data) > MAX_GIT_BYTES:
        return [f"{where}.path: {ref['path']} is {len(data)} bytes; over {MAX_GIT_BYTES} it goes to R2 as a blob"]
    if len(data) != ref["bytes"] or hashlib.sha256(data).hexdigest() != ref["sha256"]:
        return [f"{where}: {ref['path']} does not match its sha256 and bytes"]
    return []


def oversized_files(root: Path = REPO_ROOT) -> list[str]:
    """Every perf-corpus file over 256 KB: large data is a blob in R2, never in git."""
    corpus = root / CORPUS_DIR
    return sorted(f"{path.relative_to(root)}: {path.stat().st_size} bytes, over {MAX_GIT_BYTES}"
                  for path in corpus.rglob("*") if path.is_file() and path.stat().st_size > MAX_GIT_BYTES)


# ---------------------------------------------------------------- blobs

def blob_ref(data: bytes) -> dict[str, Any]:
    return {"sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}


def default_cache_dir(env: Mapping[str, str] = os.environ) -> Path:
    if env.get("CMUX_PERF_CORPUS_CACHE"):
        return Path(env["CMUX_PERF_CORPUS_CACHE"])
    base = Path(env["XDG_CACHE_HOME"]) if env.get("XDG_CACHE_HOME") else Path.home() / ".cache"
    return base / "cmux" / "perf-corpus"


def http_fetcher(env: Mapping[str, str] = os.environ, timeout_s: float = 120) -> Callable[[str], bytes]:
    """Reads a blob by its hex digest from CMUX_PERF_LAB_R2_PUBLIC_URL (the corpus has no user data)."""
    base = (env.get("CMUX_PERF_LAB_R2_PUBLIC_URL") or "").rstrip("/")

    def fetch(hex_digest: str) -> bytes:
        if not base:
            raise CorpusError(f"blob {hex_digest} is not cached and CMUX_PERF_LAB_R2_PUBLIC_URL is not set")
        try:
            with urllib.request.urlopen(f"{base}/{R2_PREFIX}{hex_digest}", timeout=timeout_s) as response:
                return response.read()
        except OSError as error:
            raise CorpusError(f"blob {hex_digest}: {error}") from error

    return fetch


class BlobCache:
    """Content-addressed local copies of R2 blobs; every read is checked against the digest."""

    def __init__(self, directory: Path, fetch: Callable[[str], bytes]):
        self.directory, self._fetch = Path(directory), fetch

    def path(self, ref: Mapping[str, Any]) -> Path:
        return self.directory / ref["sha256"]

    def get(self, ref: Mapping[str, Any]) -> bytes:
        path = self.path(ref)
        if path.is_file():
            data = path.read_bytes()
            if blob_ref(data) == {"sha256": ref["sha256"], "bytes": ref["bytes"]}:
                return data
        data = self._fetch(ref["sha256"])
        if blob_ref(data) != {"sha256": ref["sha256"], "bytes": ref["bytes"]}:
            raise CorpusError(f"blob {ref['sha256']}: the fetched bytes do not match the digest and size")
        self._write(path, data)
        return data

    def add(self, data: bytes) -> dict[str, Any]:
        ref = blob_ref(data)
        self._write(self.path(ref), data)
        return ref

    def _write(self, path: Path, data: bytes) -> None:
        self.directory.mkdir(parents=True, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(dir=self.directory, prefix=f".{path.name}.")
        try:
            with os.fdopen(descriptor, "wb") as handle:
                handle.write(data)
            os.replace(temporary, path)
        except BaseException:
            Path(temporary).unlink(missing_ok=True)
            raise


def blob_input_errors(manifest: Mapping[str, Any], cache: BlobCache, schema: Mapping[str, Any]) -> list[str]:
    """The text and order checks for an input track kept in a blob (NDJSON, one event per line)."""
    ref = manifest["input"].get("blob")
    if ref is None:
        return []
    try:
        events = [json.loads(line) for line in cache.get(ref).decode("utf-8").splitlines() if line.strip()]
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        return [f"$.input.blob: not NDJSON events: {error}"]
    return event_errors(events, manifest["duration_ms"], schema, "$.input.blob")


def upload(manifests: Iterable[Mapping[str, Any]], cache: BlobCache, store: Any) -> list[str]:
    """Puts every cached blob of MANIFESTS into R2 once (write-once: an existing key is left alone)."""
    done = []
    for manifest in manifests:
        for where, ref in _sources(manifest):
            if ref is None or "path" in ref:
                continue
            key = f"{R2_PREFIX}{ref['sha256']}"
            if store.size(key) is None:
                store.put(key, cache.get(ref), "application/octet-stream")
                done.append(f"{manifest['id']} {where}: uploaded {key}")
    return done


# ---------------------------------------------------------------- CLI

def _read_manifest(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise CorpusError(f"{path}: {error}") from error


def validate_paths(paths: list[Path], root: Path, cache: BlobCache | None = None) -> list[str]:
    schema = load_schema(root)
    catalog = _load_sibling("catalog")
    owners_md = root / catalog.OWNERS_PATH
    owners = catalog.owner_lanes(owners_md.read_text(encoding="utf-8")) if owners_md.is_file() else None
    corpus = root / CORPUS_DIR
    known = frozenset(path.stem for path in corpus.glob("*.json")) | frozenset(path.stem for path in paths)
    problems = list(oversized_files(root))
    for path in paths:
        if path.stat().st_size > MAX_GIT_BYTES:
            problems.append(f"{path}: over {MAX_GIT_BYTES} bytes; move its events into an input blob")
            continue
        manifest = _read_manifest(path)
        errors = validation_errors(manifest, root=root, schema=schema, owners=owners, stories=known)
        if not errors and manifest["id"] != path.stem:
            errors.append(f"$.id: {manifest['id']!r} is not the file name {path.stem!r}")
        if not errors and cache is not None:
            errors += blob_input_errors(manifest, cache, schema)
        problems += [f"{path}: {error}" for error in errors]
    return problems


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--validate", nargs="+", type=Path, metavar="MANIFEST")
    mode.add_argument("--add-blob", type=Path, metavar="FILE")
    mode.add_argument("--upload", nargs="+", type=Path, metavar="MANIFEST")
    parser.add_argument("--fetch", action="store_true", help="with --validate: fetch input blobs and check them too")
    parser.add_argument("--root", type=Path, default=REPO_ROOT)
    parser.add_argument("--cache", type=Path, default=None)
    args = parser.parse_args(argv)
    cache = BlobCache(args.cache or default_cache_dir(), http_fetcher())
    try:
        if args.add_blob:
            print(json.dumps(cache.add(args.add_blob.read_bytes())))
            return 0
        if args.upload:
            problems = validate_paths(args.upload, args.root)
            if not problems:
                trace_quest = _load_sibling("trace_quest")
                try:
                    store = trace_quest.R2BlobStore.from_env()
                    done = upload([_read_manifest(path) for path in args.upload], cache, store)
                except trace_quest.TraceQuestError as error:
                    raise CorpusError(str(error)) from error
                print("\n".join(done) or "nothing to upload")
        else:
            problems = validate_paths(args.validate, args.root, cache if args.fetch else None)
            if not problems:
                print(f"ok: {len(args.validate)} corpus stories")
    except (CorpusError, OSError) as error:
        problems = [str(error)]
    for problem in problems:
        print(problem, file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
