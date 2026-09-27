#!/usr/bin/env python3
"""Versioned, complete app-host product layers; legacy archives remain independent."""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import stat
import subprocess
import tempfile

SCHEMA = "cmux.app-host-layers"
LAYERS = ("app-cli", "runtime", "tests", "diagnostics")
ROOT = "Build/Products"
MANIFEST = "app-host-layers.json"
METADATA_POLICY = {"version": 1, "platform_local_xattrs": ["com.apple.provenance"]}


def digest(path):
    with Path(path).open("rb") as stream:
        checksum = hashlib.sha256()
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(block)
        return checksum.hexdigest()


def publish(source, destination):
    # Darwin's exclusive rename closes the check/rename race and cannot replace
    # another job's empty directory or dangling symlink.
    libc = ctypes.CDLL(None, use_errno=True)
    libc.renamex_np.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
    libc.renamex_np.restype = ctypes.c_int
    if libc.renamex_np(os.fsencode(source), os.fsencode(destination), 0x4):
        raise OSError(ctypes.get_errno(), f"cannot exclusively publish products: {destination}")


def valid_path(value):
    if not isinstance(value, str) or not value.startswith(ROOT + "/") and value != ROOT:
        raise ValueError(f"unscoped product path: {value!r}")
    if any(ord(c) < 32 for c in value) or str(PurePosixPath(value)) != value or ".." in PurePosixPath(value).parts:
        raise ValueError(f"non-canonical product path: {value!r}")
    return value


def identity(value):
    if not isinstance(value, dict) or set(value) != {"source_sha", "workflow_run_id", "workflow_run_attempt", "toolchain"}:
        raise ValueError("identity must pin source_sha, workflow_run_id, workflow_run_attempt, toolchain")
    if not isinstance(value["source_sha"], str) or not re.fullmatch(r"[0-9a-f]{40}", value["source_sha"]):
        raise ValueError("source_sha must be a full commit SHA")
    for key in ("workflow_run_id", "workflow_run_attempt"):
        if not isinstance(value[key], str) or not re.fullmatch(r"[1-9][0-9]*", value[key]):
            raise ValueError(f"{key} must be a positive decimal string")
    if not isinstance(value["toolchain"], dict) or not value["toolchain"] or any(
        not isinstance(k, str) or not isinstance(v, str) or not v for k, v in value["toolchain"].items()
    ):
        raise ValueError("toolchain must be a nonempty string map")
    return value


def owner(path):
    parts = PurePosixPath(path).parts[2:]
    if path.endswith(".xctestrun") or any(p.endswith((".xctest", ".xctestbundle")) for p in parts):
        return "tests"
    if len(parts) > 3 and parts[1].endswith(".app") and parts[2] == "Contents" and parts[3] in {"Frameworks", "Resources", "PlugIns"}:
        return "runtime"
    if len(parts) > 1 and (parts[1] == "PackageFrameworks" or parts[1].endswith((".framework", ".bundle", ".plugin"))):
        return "runtime"
    if len(parts) > 1 and parts[1].endswith((".dSYM", ".swiftmodule")) or len(parts) == 2 and parts[-1].endswith((".a", ".o")):
        return "diagnostics"
    return "app-cli"  # Unknown products are retained, never guessed away.


def attributes(path):
    # Python exposes os.*xattr only on Linux; use Darwin's no-follow API so
    # resource forks and signature-related metadata are verified on macOS.
    libc = ctypes.CDLL(None, use_errno=True)
    libc.listxattr.argtypes = (ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_int)
    libc.listxattr.restype = ctypes.c_ssize_t
    libc.getxattr.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int)
    libc.getxattr.restype = ctypes.c_ssize_t
    encoded = os.fsencode(path)
    def read(function, *args):
        size = function(*args, None, 0)
        if size < 0:
            raise OSError(ctypes.get_errno(), f"cannot read product extended attributes: {path}")
        buffer = ctypes.create_string_buffer(size)
        actual = function(*args, buffer, size)
        if actual != size:
            raise OSError(f"product extended attributes changed while reading: {path}")
        return buffer.raw
    names = read(lambda path, buf, size: libc.listxattr(path, buf, size, 1), encoded)
    result = {}
    for name in sorted(names.rstrip(b"\0").split(b"\0")) if names else []:
        value = read(lambda path, name, buf, size: libc.getxattr(path, name, buf, size, 0, 1), encoded, name)
        result[os.fsdecode(name)] = hashlib.sha256(value).hexdigest()
    return result


def inventory(derived):
    root = derived / ROOT
    if not root.is_dir() or root.is_symlink():
        raise ValueError("products must be a real directory")
    directories, entries = [], []
    paths = [root]
    for base, dirs, files in os.walk(root, followlinks=False):
        paths.extend(Path(base) / name for name in dirs + files)
    for path in sorted(paths):
        info = path.lstat()
        entry = {"path": valid_path(path.relative_to(derived).as_posix()),
                 "mode": stat.S_IMODE(info.st_mode), "xattrs": attributes(path)}
        if stat.S_ISDIR(info.st_mode):
            directories.append(entry)
        elif stat.S_ISLNK(info.st_mode):
            entries.append({**entry, "type": "symlink", "target": os.readlink(path)})
        elif stat.S_ISREG(info.st_mode):
            entries.append({**entry, "type": "file", "size": info.st_size, "sha256": digest(path)})
        else:
            raise ValueError(f"unsupported product type: {path}")
    validate_tree(directories, entries)
    # Canonical manifest ordering is POSIX path text, not Path's component-wise
    # ordering (which differs for siblings such as prefix.ext and prefix/child).
    return sorted(directories, key=lambda e: e["path"]), sorted(entries, key=lambda e: e["path"])


def validate_tree(directories, entries):
    table = {}
    for entry in directories + entries:
        path = valid_path(entry["path"])
        if path in table:
            raise ValueError(f"overlapping product ownership: {path}")
        if type(entry.get("mode")) is not int or not 0 <= entry["mode"] <= 0o7777:
            raise ValueError(f"invalid product mode: {path}")
        if not isinstance(entry.get("xattrs"), dict):
            raise ValueError(f"missing extended-attribute inventory: {path}")
        table[path] = entry
    if ROOT not in table or "type" in table[ROOT]:
        raise ValueError("missing product root directory")
    for path, entry in table.items():
        if path != ROOT and (str(PurePosixPath(path).parent) not in table or "type" in table[str(PurePosixPath(path).parent)]):
            raise ValueError(f"non-directory product ancestor: {path}")
        if entry.get("type") == "symlink":
            pending = list(PurePosixPath(path).parent.parts) + entry["target"].split("/")
            if not entry["target"] or entry["target"].startswith("/"):
                raise ValueError(f"absolute/empty product link: {path}")
            resolved, visited = [], set()
            while pending:
                part = pending.pop(0)
                if part in ("", "."):
                    continue
                if part == "..":
                    if len(resolved) <= 2:
                        raise ValueError(f"escaping product link: {path}")
                    resolved.pop()
                    continue
                resolved.append(part)
                current = "/".join(resolved)
                target = table.get(current, {}).get("target")
                if target is not None:
                    if current in visited or len(visited) >= 40 or target.startswith("/"):
                        raise ValueError(f"cyclic/absolute product link: {path}")
                    visited.add(current)
                    resolved.pop()
                    pending = target.split("/") + pending
            valid_path("/".join(resolved))
        elif "type" in entry and entry["type"] != "file":
            raise ValueError(f"unsupported manifest entry: {path}")


def portable_metadata(entries):
    # Darwin assigns creator-local provenance when files are created/written.
    # Keep its original hash in the manifest, but do not require another
    # creator's tag on restored files. No other metadata is exempt or rewritten.
    return sorted(({**entry, "xattrs": {name: value for name, value in entry["xattrs"].items()
                                       if name != "com.apple.provenance"}}
                   for entry in entries), key=lambda entry: entry["path"])


def exclusions(directories, entries, layer):
    children = {entry["path"]: [] for entry in directories}
    ownership = {entry["path"]: {owner(entry["path"])} for entry in entries}
    for path in sorted(list(children) + list(ownership), key=lambda p: len(PurePosixPath(p).parts), reverse=True):
        if path in children:
            ownership[path] = set().union(*(ownership[p] for p in children[path])) if children[path] else set()
        parent = str(PurePosixPath(path).parent)
        if parent in children:
            children[parent].append(path)
    excluded = []
    def visit(path):
        if ownership[path] and layer not in ownership[path]:
            excluded.append(path)
        else:
            for child in children.get(path, []):
                visit(child)
    visit(ROOT)
    escape = lambda s: re.sub(r"([.\\+*?\[\]^$(){}|])", r"\\\1", s)
    expression = "^(" + "|".join(map(escape, excluded)) + ")(/.*)?$" if excluded else "^$"
    if len(expression.encode()) > 60000:
        raise ValueError("layer selection exceeds safe command argument size; use legacy aggregate")
    return expression


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=600).stdout


def pack(derived, output, current):
    current = identity(current)
    if output.exists() or output.is_symlink():
        raise ValueError("layer output must not already exist")
    if output.resolve().is_relative_to((derived / ROOT).resolve()):
        raise ValueError("layer output cannot be inside producer products")
    directories, entries = inventory(derived)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".app-host-layers-", dir=output.parent) as temporary:
        staging = Path(temporary) / "layers"
        staging.mkdir()
        layers = []
        for name in LAYERS:
            archive = staging / f"{name}.aar"
            run("aa", "archive", "-d", str(derived), "-subdir", ROOT, "-o", str(archive), "-a", "lzfse",
                "-exclude-field", "uid,gid", "-include-field", "sh2", "-exclude-regex", exclusions(directories, entries, name))
            layers.append({"name": name, "archive": archive.name, "sha256": digest(archive), "size": archive.stat().st_size,
                           "entries": [entry for entry in entries if owner(entry["path"]) == name]})
        manifest = {"schema": SCHEMA, "version": 1, "profile": "app-host-full", "required_layers": list(LAYERS),
                    "identity": current, "metadata_policy": METADATA_POLICY, "directories": directories, "layers": layers}
        (staging / MANIFEST).write_text(json.dumps(manifest, sort_keys=True, indent=2) + "\n")
        # Do not publish a selection inconsistent with the source inventory.
        verify_manifest(manifest, staging, current)
        publish(staging, output)


def normalize_selected_layers(value):
    requested = tuple(value)
    if not requested or len(set(requested)) != len(requested) or any(name not in LAYERS for name in requested):
        raise ValueError("invalid requested layer set")
    canonical = tuple(name for name in LAYERS if name in requested)
    if requested != canonical:
        raise ValueError("requested layers must use canonical order")
    return canonical


def verify_manifest(manifest, directory, expected, required_layers=LAYERS):
    selected = normalize_selected_layers(required_layers)
    if type(manifest.get("version")) is not int or (manifest.get("schema"), manifest.get("version"), manifest.get("profile")) != (SCHEMA, 1, "app-host-full"):
        raise ValueError("unsupported layered product format/profile")
    if manifest.get("identity") != identity(expected):
        raise ValueError("layered product identity mismatch")
    if manifest.get("metadata_policy") != METADATA_POLICY or type(manifest["metadata_policy"]["version"]) is not int:
        raise ValueError("unsupported product metadata portability policy")
    if manifest.get("required_layers") != list(LAYERS) or [x.get("name") for x in manifest.get("layers", [])] != list(LAYERS):
        raise ValueError("canonical product manifest requires all four layers in order")
    directories = manifest["directories"]
    all_entries = [entry for layer in manifest["layers"] for entry in layer["entries"]]
    validate_tree(directories, all_entries)
    directory_table = {x["path"]: x for x in directories}
    layers = {layer["name"]: layer for layer in manifest["layers"]}
    for layer in manifest["layers"]:
        if layer["archive"] != layer["name"] + ".aar":
            raise ValueError("invalid layer archive name")
        if any(owner(entry["path"]) != layer["name"] for entry in layer["entries"]):
            raise ValueError(f"incorrect semantic layer ownership: {layer['name']}")
    for name in selected:
        layer = layers[name]
        archive = directory / layer["archive"]
        if archive.is_symlink() or not archive.is_file() or archive.stat().st_size != layer["size"] or digest(archive) != layer["sha256"]:
            raise ValueError(f"layer archive digest/size mismatch: {name}")
        wanted = {x["path"]: x for x in layer["entries"]}
        seen = set()
        listing = json.loads(run("aa", "list", "-i", str(archive), "-list-format", "json"))
        for actual in listing:
            path = valid_path(actual["PAT"])
            if path in seen:
                raise ValueError(f"duplicate archive entry: {path}")
            seen.add(path)
            entry = directory_table.get(path) if actual["TYP"] == "D" else wanted.get(path)
            if entry is None or actual["TYP"] != {None: "D", "file": "F", "symlink": "L"}[entry.get("type")]:
                raise ValueError(f"unexpected archive ownership/type: {path}")
            if actual.get("MOD") != entry["mode"] or actual.get("LNK") != entry.get("target"):
                raise ValueError(f"archive mode/link mismatch: {path}")
            if entry.get("type") == "file" and actual.get("DAT", 0) != entry["size"]:
                raise ValueError(f"archive file size mismatch: {path}")
            if entry.get("type") == "file" and actual.get("SH2") != entry["sha256"]:
                raise ValueError(f"archive file digest mismatch: {path}")
        if not wanted.keys() <= seen:
            raise ValueError(f"missing archive entries: {name}")
    selected_entries = [
        entry for layer in manifest["layers"] if layer["name"] in selected for entry in layer["entries"]
    ]
    return directories, selected_entries


def validate_restored_subset(canonical_directories, expected_entries, actual_directories, actual_entries):
    if portable_metadata(expected_entries) != portable_metadata(actual_entries):
        raise ValueError("reconstructed selected product content/metadata mismatch")
    canonical = {entry["path"]: portable_metadata([entry])[0] for entry in canonical_directories}
    actual = {entry["path"]: portable_metadata([entry])[0] for entry in actual_directories}
    for path, entry in actual.items():
        if canonical.get(path) != entry:
            raise ValueError(f"unexpected reconstructed directory metadata: {path}")
    required = {ROOT}
    canonical_paths = set(canonical)
    for entry in expected_entries:
        parent = PurePosixPath(entry["path"]).parent
        while str(parent) in canonical_paths:
            required.add(str(parent))
            if str(parent) == ROOT:
                break
            parent = parent.parent
    if not required <= set(actual):
        raise ValueError("selected product is missing required directories")


def restore(manifest_path, destination, expected, required_layers=LAYERS):
    selected = normalize_selected_layers(required_layers)
    if destination.exists() or destination.is_symlink():
        raise ValueError("restore destination must not already exist")
    manifest = json.loads(manifest_path.read_text())
    directories, entries = verify_manifest(manifest, manifest_path.parent, expected, selected)
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".app-host-restore-", dir=destination.parent) as temporary:
        staging = Path(temporary) / "derived"
        staging.mkdir()
        layers = {layer["name"]: layer for layer in manifest["layers"]}
        for name in selected:
            layer = layers[name]
            run("aa", "extract", "-d", str(staging), "-i", str(manifest_path.parent / layer["archive"]))
        actual_directories, actual_entries = inventory(staging)
        validate_restored_subset(directories, entries, actual_directories, actual_entries)
        publish(staging, destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("pack", "restore"))
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--identity", type=Path, required=True)
    parser.add_argument("--layers", default=",".join(LAYERS))
    args = parser.parse_args()
    try:
        if args.command == "pack":
            pack(args.source.resolve(), args.destination.absolute(), json.loads(args.identity.read_text()))
        else:
            restore(
                args.source.resolve(),
                args.destination.absolute(),
                json.loads(args.identity.read_text()),
                tuple(name for name in args.layers.split(",") if name),
            )
    except (ValueError, OSError, KeyError, TypeError, subprocess.SubprocessError) as error:
        parser.exit(1, f"app-host layers: {error}\n")


if __name__ == "__main__":
    main()
