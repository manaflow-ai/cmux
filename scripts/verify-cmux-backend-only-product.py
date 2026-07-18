#!/usr/bin/env python3
"""Prove that a SwiftPM frontend product and built host are backend-only."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys
from collections import deque
from dataclasses import dataclass
from pathlib import Path
from typing import Any


SCRIPT_PATH = Path(__file__).resolve()
REPOSITORY_ROOT = SCRIPT_PATH.parents[1]
MACHO_AUDITOR = REPOSITORY_ROOT / "scripts/audit-cmux-backend-only-linkage.sh"

FORBIDDEN_TARGETS = frozenset(
    {
        "CmuxTerminal",
        "CmuxTerminalCore",
        "CmuxGhosttyKit",
        "GhosttyKit",
        "GhosttyRuntimeTestStubs",
    }
)
SOURCE_POLICIES = {
    "CmuxTerminalDomain": frozenset({"Foundation"}),
    "CmuxTerminalFrontend": frozenset(
        {
            "AppKit",
            "CmuxTerminalBackend",
            "CmuxTerminalDomain",
            "CmuxTerminalRenderCompositor",
            "CmuxTerminalRenderProtocol",
            "CmuxTerminalRenderTransport",
            "CoreGraphics",
            "Foundation",
            "Observation",
            "QuartzCore",
            "UniformTypeIdentifiers",
        }
    ),
}
FORBIDDEN_SOURCE_PATTERNS = (
    (
        "legacy terminal runtime identity",
        re.compile(
            r"\b(?:GhosttyKit|GhosttyNSView|GhosttyApp|EmbeddedTerminalPanelFactory|"
            r"CmuxTerminalCore|CmuxTerminalLegacyRuntime)\b|\bghostty_[A-Za-z0-9_]+\b"
        ),
    ),
    (
        "dynamic-load escape hatch",
        re.compile(
            r"\b(?:dlopen|dlclose|dlsym|dladdr|dlerror|dlmopen|"
            r"NSCreateObjectFileImageFromFile|NSLinkModule|NSLookupSymbolInModule)\b|"
            r"\b(?:Bundle|NSBundle)(?:\s*\([^\n]*\)|\.[A-Za-z_][A-Za-z0-9_]*)?"
            r"\s*\.\s*(?:load|loadAndReturnError|preflightAndReturnError|unload)\b"
        ),
    ),
    (
        "PTY ownership constructor",
        re.compile(
            r"\b(?:forkpty|openpty|posix_openpt|grantpt|unlockpt|ptsname|"
            r"ptsname_r|login_tty)\b"
        ),
    ),
    ("C symbol escape hatch", re.compile(r"@_silgen_name\b|@_cdecl\b")),
)
FORBIDDEN_DYNAMIC_SYMBOLS = frozenset(
    {
        "_CFBundleLoadExecutable",
        "_CFBundleLoadExecutableAndReturnError",
        "_CFBundlePreflightExecutable",
        "_NSCreateObjectFileImageFromFile",
        "_NSLinkModule",
        "_NSLookupSymbolInModule",
        "_dladdr",
        "_dlclose",
        "_dlerror",
        "_dlmopen",
        "_dlopen",
        "_dlopen_preflight",
        "_dlsym",
    }
)
ALLOWED_EXTERNAL_LOAD_PREFIXES = (
    "/System/Library/",
    "/usr/lib/",
    "/Library/Apple/System/Library/",
)


class VerificationError(RuntimeError):
    """A deterministic backend-only invariant failed."""


@dataclass(frozen=True, order=True)
class TargetKey:
    """A target qualified by its package manifest path."""

    package_path: Path
    target: str


@dataclass
class PackageManifest:
    """The subset of `swift package dump-package` used for graph traversal."""

    path: Path
    raw: dict[str, Any]
    dependency_paths: dict[str, Path]

    @property
    def name(self) -> str:
        return str(self.raw["name"])

    @property
    def targets(self) -> dict[str, dict[str, Any]]:
        return {str(item["name"]): item for item in self.raw.get("targets", [])}

    @property
    def products(self) -> dict[str, dict[str, Any]]:
        return {str(item["name"]): item for item in self.raw.get("products", [])}


class PackageGraphLoader:
    """Loads local SwiftPM manifests and derives an exact product closure."""

    def __init__(self, swift_executable: str) -> None:
        self.swift_executable = swift_executable
        self.manifests: dict[Path, PackageManifest] = {}

    def load(self, package_path: Path) -> PackageManifest:
        resolved = package_path.resolve(strict=True)
        if resolved in self.manifests:
            return self.manifests[resolved]
        if not (resolved / "Package.swift").is_file():
            raise VerificationError(f"Swift package manifest is missing: {resolved}")
        process = subprocess.run(
            [self.swift_executable, "package", "dump-package", "--package-path", str(resolved)],
            text=True,
            capture_output=True,
            check=False,
        )
        if process.returncode != 0:
            raise VerificationError(
                f"swift package dump-package failed for {resolved}: {process.stderr.strip()}"
            )
        try:
            raw = json.loads(process.stdout)
        except json.JSONDecodeError as error:
            raise VerificationError(f"invalid dump-package JSON for {resolved}: {error}") from error

        dependency_paths: dict[str, Path] = {}
        for dependency in raw.get("dependencies", []):
            file_system = dependency.get("fileSystem")
            if not file_system:
                continue
            record = file_system[0]
            dependency_path = Path(record["path"]).resolve(strict=True)
            dependency_paths[str(record["identity"]).lower()] = dependency_path

        manifest = PackageManifest(
            path=resolved,
            raw=raw,
            dependency_paths=dependency_paths,
        )
        self.manifests[resolved] = manifest
        return manifest

    def product_targets(self, package_path: Path, product_name: str) -> list[TargetKey]:
        manifest = self.load(package_path)
        product = manifest.products.get(product_name)
        if product is None:
            raise VerificationError(
                f"product {product_name} is missing from package {manifest.name}"
            )
        return [TargetKey(manifest.path, str(target)) for target in product.get("targets", [])]

    def dependency_targets(
        self,
        manifest: PackageManifest,
        dependency: dict[str, Any],
    ) -> list[TargetKey]:
        if "byName" in dependency:
            name = str(dependency["byName"][0])
            if name in manifest.targets:
                return [TargetKey(manifest.path, name)]
            if name in manifest.products:
                return self.product_targets(manifest.path, name)
            raise VerificationError(
                f"unresolved by-name dependency {name} in package {manifest.name}"
            )
        if "target" in dependency:
            name = str(dependency["target"][0])
            if name not in manifest.targets:
                raise VerificationError(
                    f"unresolved target dependency {name} in package {manifest.name}"
                )
            return [TargetKey(manifest.path, name)]
        if "product" in dependency:
            record = dependency["product"]
            product_name = str(record[0])
            package_identity = str(record[1]).lower()
            dependency_path = manifest.dependency_paths.get(package_identity)
            if dependency_path is None:
                for candidate_path in manifest.dependency_paths.values():
                    candidate = self.load(candidate_path)
                    if candidate.name.lower() == package_identity:
                        dependency_path = candidate_path
                        break
            if dependency_path is None:
                raise VerificationError(
                    f"local package {record[1]} for product {product_name} is unresolved"
                )
            return self.product_targets(dependency_path, product_name)
        raise VerificationError(f"unsupported target dependency record: {dependency}")

    def closure(
        self,
        package_path: Path,
        product_name: str,
    ) -> tuple[list[TargetKey], list[tuple[TargetKey, TargetKey]]]:
        queue = deque(self.product_targets(package_path, product_name))
        visited: set[TargetKey] = set()
        edges: set[tuple[TargetKey, TargetKey]] = set()
        while queue:
            key = queue.popleft()
            if key in visited:
                continue
            visited.add(key)
            manifest = self.load(key.package_path)
            target = manifest.targets.get(key.target)
            if target is None:
                raise VerificationError(
                    f"target {key.target} is missing from package {manifest.name}"
                )
            for dependency in target.get("dependencies", []):
                for child in self.dependency_targets(manifest, dependency):
                    edges.add((key, child))
                    if child not in visited:
                        queue.append(child)
        return sorted(visited), sorted(edges)


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def package_label(loader: PackageGraphLoader, key: TargetKey) -> str:
    return loader.load(key.package_path).name


def target_source_root(manifest: PackageManifest, target: dict[str, Any]) -> Path:
    declared_path = target.get("path")
    if declared_path:
        candidate = manifest.path / str(declared_path)
    else:
        candidate = manifest.path / "Sources" / str(target["name"])
    if not candidate.exists():
        raise VerificationError(
            f"source root for {target['name']} is missing: {candidate}"
        )
    resolved = candidate.resolve(strict=True)
    try:
        resolved.relative_to(manifest.path)
    except ValueError as error:
        raise VerificationError(
            f"source root for {target['name']} escapes package: {candidate}"
        ) from error
    return resolved


def swift_imports(source: str) -> list[str]:
    pattern = re.compile(
        r"(?m)^\s*(?:@[_A-Za-z][_A-Za-z0-9]*(?:\([^\n]*\))?\s+)*"
        r"(?:(?:private|fileprivate|internal|package|public)\s+)?"
        r"import(?:\s+(?:typealias|struct|class|enum|protocol|let|var|func))?\s+"
        r"([A-Za-z_][A-Za-z0-9_]*)"
    )
    return pattern.findall(source)


def verify_source_roots(
    loader: PackageGraphLoader,
    nodes: list[TargetKey],
) -> list[dict[str, Any]]:
    reports: list[dict[str, Any]] = []
    for key in nodes:
        allowed_imports = SOURCE_POLICIES.get(key.target)
        if allowed_imports is None:
            continue
        manifest = loader.load(key.package_path)
        target = manifest.targets[key.target]
        source_root = target_source_root(manifest, target)
        files = sorted(source_root.rglob("*.swift"))
        if not files:
            raise VerificationError(f"source root for {key.target} contains no Swift files")
        file_reports: list[dict[str, str]] = []
        aggregate = hashlib.sha256()
        for source_path in files:
            if source_path.is_symlink():
                raise VerificationError(f"source file for {key.target} is a symlink: {source_path}")
            resolved = source_path.resolve(strict=True)
            try:
                relative = resolved.relative_to(source_root)
            except ValueError as error:
                raise VerificationError(
                    f"source file for {key.target} escapes source root: {source_path}"
                ) from error
            contents = resolved.read_text(encoding="utf-8")
            for imported_module in swift_imports(contents):
                if imported_module not in allowed_imports:
                    raise VerificationError(
                        f"{key.target}/{relative.as_posix()}: forbidden import {imported_module}"
                    )
            for description, pattern in FORBIDDEN_SOURCE_PATTERNS:
                if pattern.search(contents):
                    raise VerificationError(
                        f"{key.target}/{relative.as_posix()}: {description}"
                    )
            relative_text = relative.as_posix()
            content_hash = sha256_bytes(contents.encode("utf-8"))
            aggregate.update(relative_text.encode("utf-8"))
            aggregate.update(b"\0")
            aggregate.update(content_hash.encode("ascii"))
            aggregate.update(b"\0")
            file_reports.append({"path": relative_text, "sha256": content_hash})
        reports.append(
            {
                "package": manifest.name,
                "target": key.target,
                "sha256": aggregate.hexdigest(),
                "files": file_reports,
            }
        )
    required = set(SOURCE_POLICIES)
    observed = {report["target"] for report in reports}
    missing = required - observed
    if missing:
        raise VerificationError(
            f"backend-only product closure is missing required targets: {', '.join(sorted(missing))}"
        )
    return sorted(reports, key=lambda item: (item["package"], item["target"]))


def graph_report(
    loader: PackageGraphLoader,
    package_path: Path,
    product_name: str,
) -> dict[str, Any]:
    nodes, edges = loader.closure(package_path, product_name)
    for node in nodes:
        if node.target in FORBIDDEN_TARGETS:
            raise VerificationError(
                f"backend-only product closure contains forbidden target {node.target}"
            )
    node_records = [
        {"package": package_label(loader, node), "target": node.target}
        for node in nodes
    ]
    edge_records = [
        {
            "from": f"{package_label(loader, parent)}:{parent.target}",
            "to": f"{package_label(loader, child)}:{child.target}",
        }
        for parent, child in edges
    ]
    sources = verify_source_roots(loader, nodes)
    root_manifest = loader.load(package_path)
    graph = {
        "root_product": {"package": root_manifest.name, "product": product_name},
        "product_closure": {
            "nodes": sorted(node_records, key=lambda item: (item["package"], item["target"])),
            "edges": sorted(edge_records, key=lambda item: (item["from"], item["to"])),
        },
        "source_roots": sources,
    }
    graph["graph_sha256"] = sha256_bytes(canonical_json(graph))
    return graph


def run_tool(arguments: list[str]) -> str:
    process = subprocess.run(arguments, text=True, capture_output=True, check=False)
    if process.returncode != 0:
        raise VerificationError(
            f"command failed ({' '.join(arguments)}): {process.stderr.strip()}"
        )
    return process.stdout


def macho_loads(binary: Path) -> list[str]:
    output = run_tool(["otool", "-L", str(binary)])
    loads: list[str] = []
    for line in output.splitlines()[1:]:
        match = re.match(r"\s*(.+?)\s+\(compatibility version ", line)
        if match:
            loads.append(match.group(1))
    return loads


def macho_rpaths(binary: Path) -> list[str]:
    output = run_tool(["otool", "-l", str(binary)])
    return re.findall(r"(?m)^\s*path\s+(.+?)\s+\(offset\s+\d+\)\s*$", output)


def substitute_load_prefix(value: str, *, loader: Path, executable_directory: Path) -> Path:
    if value == "@loader_path":
        return loader.parent
    if value.startswith("@loader_path/"):
        return loader.parent / value.removeprefix("@loader_path/")
    if value == "@executable_path":
        return executable_directory
    if value.startswith("@executable_path/"):
        return executable_directory / value.removeprefix("@executable_path/")
    return Path(value)


def resolve_load(
    load: str,
    *,
    loader: Path,
    executable_directory: Path,
    bundle_root: Path,
) -> Path | None:
    if load.startswith("@loader_path") or load.startswith("@executable_path"):
        candidate = substitute_load_prefix(
            load,
            loader=loader,
            executable_directory=executable_directory,
        ).resolve(strict=False)
        if candidate.is_file():
            return candidate
        raise VerificationError(f"unresolved in-bundle load {load} from {loader}")
    if load.startswith("@rpath/"):
        suffix = load.removeprefix("@rpath/")
        for rpath in macho_rpaths(loader):
            root = substitute_load_prefix(
                rpath,
                loader=loader,
                executable_directory=executable_directory,
            )
            candidate = (root / suffix).resolve(strict=False)
            if candidate.is_file():
                return candidate
        raise VerificationError(f"unresolved @rpath load {load} from {loader}")
    if load.startswith("/"):
        candidate = Path(load).resolve(strict=False)
        try:
            candidate.relative_to(bundle_root)
        except ValueError:
            if not load.startswith(ALLOWED_EXTERNAL_LOAD_PREFIXES):
                raise VerificationError(f"non-system external load {load} from {loader}")
            return None
        if not candidate.is_file():
            raise VerificationError(f"missing absolute in-bundle load {load} from {loader}")
        return candidate
    raise VerificationError(f"unsupported relative Mach-O load {load} from {loader}")


def verify_no_dynamic_load_symbols(binary: Path) -> None:
    output = run_tool(["nm", "-a", str(binary)])
    for symbol in sorted(FORBIDDEN_DYNAMIC_SYMBOLS):
        if re.search(rf"(?m)(?:^|\s){re.escape(symbol)}(?:\s|$)", output):
            raise VerificationError(f"host load closure contains dynamic-load symbol {symbol}")
    swift_bundle_loader = re.search(
        r"\$s10Foundation6BundleC(?:4load|6unload|18loadAndReturnError)",
        output,
    )
    if swift_bundle_loader:
        raise VerificationError(
            f"host load closure contains dynamic-load symbol {swift_bundle_loader.group(0)}"
        )
    if "_OBJC_CLASS_$_NSBundle" in output:
        embedded_strings = run_tool(["strings", "-a", str(binary)])
        selector = re.search(
            r"(?m)^(?:load|loadAndReturnError:|preflightAndReturnError:|unload)$",
            embedded_strings,
        )
        if selector:
            raise VerificationError(
                f"host load closure contains NSBundle dynamic-load selector {selector.group(0)}"
            )


def relative_bundle_path(path: Path, bundle_root: Path) -> str:
    try:
        return path.resolve(strict=True).relative_to(bundle_root).as_posix()
    except ValueError as error:
        raise VerificationError(f"host load closure escaped app bundle: {path}") from error


def verify_host_artifact(app_bundle: Path, graph_sha256: str) -> dict[str, Any]:
    bundle_root = app_bundle.resolve(strict=True)
    info_plist = bundle_root / "Contents/Info.plist"
    if not info_plist.is_file():
        raise VerificationError(f"app Info.plist is missing: {info_plist}")
    with info_plist.open("rb") as stream:
        metadata = plistlib.load(stream)
    executable_name = metadata.get("CFBundleExecutable")
    if not isinstance(executable_name, str) or not executable_name:
        raise VerificationError("CFBundleExecutable is missing from app Info.plist")
    executable = bundle_root / "Contents/MacOS" / executable_name
    if not executable.is_file():
        raise VerificationError(f"app executable is missing: {executable}")

    audit = subprocess.run(
        [str(MACHO_AUDITOR), "--app-bundle", str(bundle_root)],
        text=True,
        capture_output=True,
        check=False,
    )
    if audit.returncode != 0:
        raise VerificationError(audit.stderr.strip() or audit.stdout.strip())

    initial = [executable]
    initial.extend(sorted(executable.parent.glob("*.debug.dylib")))
    queue = deque(path.resolve(strict=True) for path in initial)
    visited: set[Path] = set()
    load_edges: set[tuple[str, str, str]] = set()
    executable_directory = executable.parent.resolve(strict=True)
    while queue:
        binary = queue.popleft()
        if binary in visited:
            continue
        relative_bundle_path(binary, bundle_root)
        visited.add(binary)
        verify_no_dynamic_load_symbols(binary)
        for load in macho_loads(binary):
            target = resolve_load(
                load,
                loader=binary,
                executable_directory=executable_directory,
                bundle_root=bundle_root,
            )
            if target is None:
                continue
            target = target.resolve(strict=True)
            source_relative = relative_bundle_path(binary, bundle_root)
            target_relative = relative_bundle_path(target, bundle_root)
            load_edges.add((source_relative, load, target_relative))
            if target not in visited:
                queue.append(target)

    explicit_audit = subprocess.run(
        [
            str(MACHO_AUDITOR),
            "--info-plist",
            str(info_plist),
            *[argument for binary in sorted(visited) for argument in ("--binary", str(binary))],
        ],
        text=True,
        capture_output=True,
        check=False,
    )
    if explicit_audit.returncode != 0:
        raise VerificationError(explicit_audit.stderr.strip() or explicit_audit.stdout.strip())

    closure = [
        {"path": relative_bundle_path(binary, bundle_root), "sha256": sha256_file(binary)}
        for binary in sorted(visited)
    ]
    edges = [
        {"from": source, "load": load, "to": target}
        for source, load, target in sorted(load_edges)
    ]
    artifact: dict[str, Any] = {
        "executable": relative_bundle_path(executable, bundle_root),
        "load_closure": closure,
        "load_edges": edges,
        "linkage_auditor_sha256": sha256_file(MACHO_AUDITOR),
    }
    artifact["attestation_sha256"] = sha256_bytes(
        canonical_json({"graph_sha256": graph_sha256, "host_artifact": artifact})
    )
    return artifact


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--package-path", type=Path, required=True)
    result.add_argument("--product", required=True)
    result.add_argument("--app-bundle", type=Path)
    result.add_argument("--output", type=Path)
    result.add_argument("--swift", default=os.environ.get("SWIFT_EXEC", "swift"))
    return result


def main(arguments: list[str] | None = None) -> int:
    options = parser().parse_args(arguments)
    try:
        loader = PackageGraphLoader(options.swift)
        report: dict[str, Any] = {"schema_version": 1}
        report.update(graph_report(loader, options.package_path, options.product))
        if options.app_bundle is not None:
            report["host_artifact"] = verify_host_artifact(
                options.app_bundle,
                str(report["graph_sha256"]),
            )
        rendered = json.dumps(report, sort_keys=True, indent=2) + "\n"
        if options.output is not None:
            options.output.parent.mkdir(parents=True, exist_ok=True)
            temporary = options.output.with_name(options.output.name + ".tmp")
            temporary.write_text(rendered, encoding="utf-8")
            os.replace(temporary, options.output)
        sys.stdout.write(rendered)
        return 0
    except (OSError, VerificationError, plistlib.InvalidFileException) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
