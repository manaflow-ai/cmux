#!/usr/bin/env python3
"""Rerun app-host tests against products CI already compiled.

A test-only change does not need a new app. `plan` finds an upstream CI run
whose `app-host-products-v1-*` artifact was built from a revision that differs
from the requested one only under `cmuxTests/`. `detach` then rewrites the
checked-out project so `cmuxTests` builds by itself against those products: it
drops the target's dependency on the app and on its Swift package products,
and links the prebuilt package frameworks and objects instead. Xcode still
derives every compiler flag from the real target, so the bundle is compiled
the way CI compiles it; only the dependency graph is cut.

Used by .github/workflows/app-host-test-rerun.yml.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Callable, Iterable

TEST_ROOT = "cmuxTests/"
PRODUCTS_PREFIX = "app-host-products-v1-"
TEST_TARGET = "cmuxTests"
SELECTOR = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*(/[A-Za-z_][A-Za-z0-9_]*(/[A-Za-z_][A-Za-z0-9_]*(\(\))?)?)?$")


def git(*args: str, cwd: str | None = None) -> str:
    return subprocess.check_output(["git", *args], text=True, cwd=cwd).strip()


def non_test_changes(base: str, head: str, cwd: str | None = None) -> list[str]:
    """Paths that differ between two revisions outside the test bundle's sources."""
    changed = git("diff", "--name-only", "--no-renames", base, head, cwd=cwd).splitlines()
    return [path for path in changed if path and not path.startswith(TEST_ROOT)]


def eligible_revisions(head: str, limit: int, cwd: str | None = None) -> tuple[list[str], dict | None]:
    """First-parent ancestors of head whose app is identical to head's.

    Returns the eligible revisions, nearest first, and the first ancestor that
    is not eligible together with the paths that disqualify it.
    """
    eligible: list[str] = []
    for revision in git("rev-list", "--first-parent", f"--max-count={limit}", head, cwd=cwd).splitlines():
        blocking = non_test_changes(revision, head, cwd=cwd)
        if blocking:
            return eligible, {"revision": revision, "paths": blocking}
        eligible.append(revision)
    return eligible, None


def gh_api(path: str) -> dict:
    return json.loads(subprocess.check_output(["gh", "api", path], text=True))


def products_artifact(repository: str, run_id: str, api: Callable[[str], dict]) -> dict | None:
    """The unexpired app-host product artifact a run uploaded, if any."""
    listing = api(f"repos/{repository}/actions/runs/{run_id}/artifacts?per_page=100")
    for artifact in listing.get("artifacts", []):
        if artifact.get("name", "").startswith(PRODUCTS_PREFIX) and not artifact.get("expired"):
            return artifact
    return None


MERGE_REF = re.compile(r"refs/pull/\d+/merge")
E2E_WORKFLOW = ".github/workflows/test-e2e.yml"
# test-e2e.yml's run title ends "@ <ref> [<dispatch id>]"; run-e2e.sh passes a full SHA.
DISPATCHED_REVISION = re.compile(r" @ ([0-9a-f]{40})(?: \[[^\]]*\])?$")


def commit_parents(revision: str, cwd: str | None = None) -> list[str]:
    """A commit's parents, read from the commit object so a shallow boundary still names them."""
    header = git("cat-file", "commit", revision, cwd=cwd).split("\n\n", 1)[0]
    return [line.split(" ", 1)[1] for line in header.splitlines() if line.startswith("parent ")]


def fetch_commit(revision: str, cwd: str | None = None) -> None:
    """Fetch a commit outside the checkout's history, such as a pull request merge.

    GitHub serves any commit in the fork network by SHA, so this also reaches
    a merge that `refs/pull/N/merge` has since moved past.
    """
    present = subprocess.run(["git", "cat-file", "-e", f"{revision}^{{commit}}"], cwd=cwd, capture_output=True)
    if present.returncode != 0:
        git("fetch", "--no-tags", "--quiet", "origin", revision, cwd=cwd)


def built_revision(run: dict, cwd: str | None = None, fetch: Callable[[str], None] | None = None) -> str:
    """The revision a CI run checked out, and so the one its products were built from.

    A pull_request run builds `refs/pull/N/merge`, GitHub's merge of the head
    into the base, while the run's `head_sha` is the head. The receipt in its
    products names the merge. GitHub still records that merge on the run: ci.yml
    loads its reusable workflows from the same ref, and `referenced_workflows`
    names the commit each came from. The merge must name `head_sha` as its
    second parent, which ties it to this run's head rather than any commit.
    A dispatched test-e2e.yml run's `head_sha` is its workflow's branch, so
    its title says what it built instead.
    """
    head = run["head_sha"]
    fetch = fetch or (lambda revision: fetch_commit(revision, cwd=cwd))
    if run.get("event") == "workflow_dispatch" and run.get("path") == E2E_WORKFLOW:
        # A dispatched test-e2e.yml run lists under the branch its workflow came
        # from, usually main, but compiles the `ref` input its title names.
        # Other dispatches, such as main's ci.yml, build their head.
        match = DISPATCHED_REVISION.search(str(run.get("display_title", "")))
        if not match:
            raise ValueError(f"dispatched run {run.get('id')} names no full revision in its title")
        fetch(match.group(1))
        return match.group(1)
    if run.get("event") != "pull_request":
        return head
    merges = {
        item.get("sha")
        for item in run.get("referenced_workflows") or []
        if isinstance(item, dict) and MERGE_REF.fullmatch(str(item.get("ref", ""))) and item.get("sha")
    }
    if len(merges) != 1:
        raise ValueError(
            f"pull_request run {run.get('id')} built the merge of {head} into its base, "
            "but GitHub recorded no single merge commit for it"
        )
    merge = merges.pop()
    fetch(merge)
    parents = commit_parents(merge, cwd=cwd)
    if len(parents) != 2 or parents[1] != head:
        raise ValueError(f"run {run.get('id')} recorded {merge}, which is not a merge of its head {head}")
    return merge


def find_products(
    repository: str,
    revisions: Iterable[str],
    api: Callable[[str], dict],
    resolve: Callable[[dict, str], str | None] = lambda run, revision: revision,
) -> dict | None:
    """Newest product-bearing run for the nearest eligible revision.

    Runs are listed by `head_sha`, which is not what a pull_request run built.
    `resolve` maps a run to the revision its products were built from, or to
    None when that revision is not eligible.
    """
    for revision in revisions:
        runs = api(f"repos/{repository}/actions/runs?head_sha={revision}&status=completed&per_page=50")
        for run in sorted(runs.get("workflow_runs", []), key=lambda item: item.get("created_at", ""), reverse=True):
            artifact = products_artifact(repository, str(run["id"]), api)
            if not artifact:
                continue
            built = resolve(run, revision)
            if built:
                return {"revision": built, "run_id": str(run["id"]), "artifact": artifact}
    return None


ADMISSION_JOB = "macOS compile admission"
PRODUCT_RUNNERS = {"15": "blacksmith-6vcpu-macos-15", "26": "blacksmith-6vcpu-macos-26"}


def product_runner(repository: str, run_id: str, api: Callable[[str], dict], pages: int = 5) -> str:
    """The Blacksmith pool with the macOS, and so the Xcode, that built a run's products.

    The rerun rebuilds cmuxTests with the products' own Xcode, and each macOS
    image carries one pinned Xcode (26.3 on 15, 26.6 on 26). Compile admission
    follows MACOS_RUNNER_PR, so read the pool it actually ran on; a test-e2e.yml
    run compiles in its `build` job. A run without either keeps the macOS 15
    default.
    """
    for page in range(1, pages + 1):
        listing = api(f"repos/{repository}/actions/runs/{run_id}/jobs?filter=latest&per_page=100&page={page}")
        jobs = listing.get("jobs", [])
        for job in jobs:
            # test-e2e.yml compiles in its `build` job.
            if job.get("name", "").endswith(ADMISSION_JOB) or job.get("name") == "build":
                for label in job.get("labels", []):
                    match = re.search(r"macos-(\d+)", label)
                    if match and match.group(1) in PRODUCT_RUNNERS:
                        return PRODUCT_RUNNERS[match.group(1)]
                return PRODUCT_RUNNERS["15"]
        if len(jobs) < 100:
            break
    return PRODUCT_RUNNERS["15"]


def parse_selectors(text: str) -> list[str]:
    """Normalize newline, comma, or space separated selectors to cmuxTests/... form."""
    selectors = []
    for raw in re.split(r"[\s,]+", text.strip()):
        if not raw:
            continue
        selector = raw.removeprefix("-only-testing:")
        if not selector.startswith(TEST_ROOT):
            selector = TEST_ROOT + selector
        if not SELECTOR.match(selector):
            raise ValueError(f"not an XCTest or Swift Testing selector: {raw!r}")
        selectors.append(selector)
    if not selectors:
        raise ValueError("no test selectors given")
    return selectors


def plan(args: argparse.Namespace, api: Callable[[str], dict] = gh_api) -> dict:
    head = git("rev-parse", f"{args.ref}^{{commit}}")
    selectors = parse_selectors(args.only_testing)
    if args.source_run_id:
        run = api(f"repos/{args.repository}/actions/runs/{args.source_run_id}")
        try:
            revision = built_revision(run)
        except ValueError as error:
            raise SystemExit(str(error))
        except subprocess.CalledProcessError:
            raise SystemExit(f"run {args.source_run_id} built a revision other than {run['head_sha']} that could not be fetched")
        try:
            blocking = non_test_changes(revision, head)
        except subprocess.CalledProcessError:
            raise SystemExit(f"run {args.source_run_id} built {revision}, which is not in this checkout's history")
        if blocking:
            raise SystemExit(
                f"run {args.source_run_id} built {revision}; it differs from {head} outside {TEST_ROOT}:\n  "
                + "\n  ".join(blocking[:20])
            )
        artifact = products_artifact(args.repository, args.source_run_id, api)
        if not artifact:
            raise SystemExit(f"run {args.source_run_id} has no unexpired {PRODUCTS_PREFIX}* artifact")
        found = {"revision": revision, "run_id": args.source_run_id, "artifact": artifact}
    else:
        revisions, blocker = eligible_revisions(head, args.max_commits)

        def resolve(run: dict, revision: str) -> str | None:
            try:
                built = built_revision(run)
                return built if built == revision or not non_test_changes(built, head) else None
            except (KeyError, ValueError, subprocess.CalledProcessError):
                return None

        found = find_products(args.repository, revisions, api, resolve)
        if not found:
            detail = ""
            if blocker:
                detail = (
                    f"\n{blocker['revision']} is the nearest ancestor that changes more than tests:\n  "
                    + "\n  ".join(blocker["paths"][:20])
                )
            raise SystemExit(
                f"No {args.repository} CI run left app-host products for {head} or an ancestor that differs "
                f"from it only under {TEST_ROOT} ({len(revisions)} checked).{detail}\n"
                "Rebase the test change onto a commit CI has built (any recent main CI run), "
                "or pass source-run-id, or use test-depot.yml for a full build."
            )
    changed = git("diff", "--name-only", found["revision"], head).splitlines()
    return {
        "sha": head,
        "source_sha": found["revision"],
        "source_run_id": found["run_id"],
        "artifact_id": str(found["artifact"]["id"]),
        "artifact_name": found["artifact"]["name"],
        "artifact_bytes": str(found["artifact"].get("size_in_bytes", 0)),
        "runner": product_runner(args.repository, found["run_id"], api),
        "selectors": " ".join(selectors),
        "changed_tests": ",".join(changed),
    }


# --- project detachment -----------------------------------------------------------


def _object(text: str, object_id: str) -> re.Match:
    """An object in Xcode's multi-line layout; group 1 is its body."""
    match = re.search(r"\n\t\t" + re.escape(object_id) + r"(?: /\*[^\n]*?\*/)? = \{\n(.*?)\n\t\t\};", text, re.S)
    if not match:
        raise ValueError(f"project object {object_id} not found")
    return match


def _object_body(text: str, object_id: str) -> str:
    """An object's body in either the multi-line or the one-line layout."""
    single = re.search(r"\n\t\t" + re.escape(object_id) + r"(?: /\*[^\n]*?\*/)? = \{([^\n]*)\};\n", text)
    if single:
        return single.group(1)
    return _object(text, object_id).group(1)


def _list(body: str, key: str) -> list[tuple[str, str]]:
    match = re.search(r"\n\t\t\t" + key + r" = \((.*?)\);", "\n" + body, re.S)
    if not match:
        return []
    return re.findall(r"(\w+)(?: /\* (.*?) \*/)?,", match.group(1))


def _replace_list(body: str, key: str, keep: list[str]) -> str:
    lines = "".join(f"\t\t\t\t{item},\n" for item in keep)
    return re.sub(
        r"(\n\t\t\t" + key + r" = \()(.*?)(\);)",
        lambda m: m.group(1) + "\n" + lines + "\t\t\t" + m.group(3),
        "\n" + body,
        count=1,
        flags=re.S,
    )[1:]


def detach_project(text: str, target: str = TEST_TARGET) -> tuple[str, list[str]]:
    """Cut a test target loose from its target and package dependencies.

    Returns the rewritten project and the package product names the target
    linked, which the caller must now link from prebuilt products.
    """
    match = re.search(
        r"\n\t\t(\w+) /\* " + re.escape(target) + r" \*/ = \{\n\t\t\tisa = PBXNativeTarget;\n(.*?)\n\t\t\};", text, re.S
    )
    if not match:
        raise ValueError(f"native target {target} not found")
    body = match.group(2)
    product_ids = [object_id for object_id, _ in _list(body, "packageProductDependencies")]
    products = []
    for object_id in product_ids:
        product = re.search(r"productName = \"?([^\";]+)\"?;", _object_body(text, object_id))
        if not product:
            raise ValueError(f"package product {object_id} has no productName")
        products.append(product.group(1))
    frameworks_phase = None
    for phase_id, name in _list(body, "buildPhases"):
        if name == "Frameworks":
            frameworks_phase = phase_id
    new_body = _replace_list(_replace_list(body, "dependencies", []), "packageProductDependencies", [])
    text = text[: match.start(2)] + new_body + text[match.end(2) :]
    if frameworks_phase:
        phase = _object(text, frameworks_phase)
        keep = []
        for build_file, comment in _list(phase.group(1), "files"):
            build_body = _object_body(text, build_file)
            if "productRef = " not in build_body:
                keep.append(f"{build_file} /* {comment} */" if comment else build_file)
        new_phase = _replace_list(phase.group(1), "files", keep)
        text = text[: phase.start(1)] + new_phase + text[phase.end(1) :]
    return text, products


def link_inputs(products: list[str], debug_products: Path) -> list[str]:
    """Linker arguments that stand in for the removed package product dependencies.

    Xcode builds a package product that the app and its tests share as a
    PackageFrameworks/<name>_<hash>_PackageProduct.framework, and a static one
    as a prelinked <name>.o. The prebuilt products already hold both.
    """
    frameworks = debug_products / "PackageFrameworks"
    arguments = []
    missing = []
    for product in products:
        pattern = re.compile(re.escape(product) + r"_-?[0-9A-F]+_PackageProduct\.framework")
        matches = sorted(p.name for p in frameworks.iterdir() if pattern.fullmatch(p.name)) if frameworks.is_dir() else []
        if matches:
            arguments += ["-framework", matches[0].removesuffix(".framework")]
        elif (debug_products / f"{product}.o").is_file():
            arguments.append(str(debug_products / f"{product}.o"))
        else:
            missing.append(product)
    if missing:
        raise ValueError("prebuilt products lack package products: " + ", ".join(missing))
    return arguments


def host_debug_dylib(debug_products: Path, target: str) -> list[str]:
    """The host app's debug dylib, which holds the app code a Debug test links against.

    With ENABLE_DEBUG_DYLIB the app executable is a stub, so -bundle_loader
    alone resolves nothing; Xcode links the dylib only through the target
    dependency that detach removes.
    """
    hosts = sorted(debug_products.glob(f"*.app/Contents/PlugIns/{target}.xctest"))
    if len(hosts) != 1:
        raise ValueError(f"expected one app hosting {target}.xctest, found {len(hosts)}")
    return [str(path) for path in sorted((hosts[0].parents[1] / "MacOS").glob("*.debug.dylib"))]


def c_module_targets(debug_products: Path) -> list[str]:
    """Package C targets: Xcode leaves a prelinked object but no Swift module for them."""
    names = []
    for path in sorted(debug_products.glob("*.o")):
        if not (debug_products / f"{path.stem}.swiftmodule").exists():
            names.append(path.stem)
    return names


def module_map(module: str, include: Path) -> str:
    """The module map SwiftPM generates for a C target's public headers."""
    for header in (include / f"{module}.h", include / module / f"{module}.h"):
        if header.is_file():
            return f'module {module} {{\n    umbrella header "{header}"\n    export *\n}}\n'
    return f'module {module} {{\n    umbrella "{include}"\n    export *\n}}\n'


def c99name(name: str) -> str:
    return re.sub(r"[^A-Za-z0-9_]", "_", name)


def dump_package(directory: Path) -> dict:
    return json.loads(subprocess.check_output(["swift", "package", "dump-package", "--package-path", str(directory)], text=True))


def locate_c_targets(names: list[str], roots: list[Path], dump: Callable[[Path], dict] = dump_package) -> dict[str, Path]:
    """Public header directories of the named C targets across local and fetched packages."""
    manifests = [m for root in roots if root.is_dir() for m in sorted(root.rglob("Package.swift")) if ".build" not in m.parts]
    dumped: dict[Path, dict] = {}
    found: dict[str, Path] = {}
    for name in names:
        literal = f'"{name}"'
        for manifest in manifests:
            try:
                if literal not in manifest.read_text(errors="replace"):
                    continue
            except OSError:
                continue
            package = manifest.parent
            if package not in dumped:
                try:
                    dumped[package] = dump(package)
                except (subprocess.CalledProcessError, ValueError):
                    dumped[package] = {}
            for target in dumped[package].get("targets", []):
                if target.get("name") != name:
                    continue
                source = package / (target.get("path") or f"Sources/{name}")
                include = source / (target.get("publicHeadersPath") or "include")
                if include.is_dir():
                    found[name] = include
            if name in found:
                break
    return found


def detach(args: argparse.Namespace, dump: Callable[[Path], dict] = dump_package) -> None:
    project = Path(args.project)
    derived = Path(args.derived_data)
    debug_products = derived / "Build" / "Products" / "Debug"
    text, products = detach_project(project.read_text(), args.target)
    ldflags = link_inputs(products, debug_products) + host_debug_dylib(debug_products, args.target)
    swift_flags = []
    generated = derived / "Build" / "Intermediates.noindex" / "GeneratedModuleMaps"
    generated.mkdir(parents=True, exist_ok=True)
    roots = [Path(root) for root in args.package_root]
    for name, include in sorted(locate_c_targets(c_module_targets(debug_products), roots, dump).items()):
        own = include / "module.modulemap"
        if own.is_file():
            path = own
        else:
            path = generated / f"{c99name(name)}.modulemap"
            path.write_text(module_map(c99name(name), include))
        swift_flags += ["-Xcc", f"-fmodule-map-file={path}", "-Xcc", f"-I{include}"]
    # Binary xcframeworks such as GhosttyKit publish their headers and module
    # map here; Xcode adds it only for targets that depend on the package.
    if (debug_products / "include").is_dir():
        swift_flags += ["-Xcc", f"-I{debug_products / 'include'}"]
    project.write_text(text)
    quote = lambda value: '"' + value.replace('"', '\\"') + '"' if re.search(r"\s", value) else value
    settings = {
        "FRAMEWORK_SEARCH_PATHS": ["$(inherited)", "$(BUILT_PRODUCTS_DIR)/PackageFrameworks"],
        "OTHER_LDFLAGS": ["$(inherited)", *ldflags],
        "OTHER_SWIFT_FLAGS": ["$(inherited)", *swift_flags],
    }
    Path(args.xcconfig).write_text(
        "".join(f"{key} = {' '.join(quote(value) for value in values)}\n" for key, values in settings.items())
    )
    print(f"Detached {args.target}: {len(products)} package products now link prebuilt products")
    for key, values in settings.items():
        print(f"  {key} = {' '.join(values)}")


def download(args: argparse.Namespace) -> None:
    """Fetch the product tarball over parallel ranges, or one stream if that misses."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import parallel_artifact_download as transport

    destination = Path(args.destination)
    archive = destination.parent / f"{destination.name}.zip"
    try:
        metadata = transport.artifact_metadata(args.repository, args.artifact_id)
        transport.download_zip(args.repository, args.artifact_id, archive, int(metadata["size_in_bytes"]))
        digest = str(metadata.get("digest") or "")
        if digest.startswith("sha256:") and transport.sha256_file(archive) != digest.removeprefix("sha256:"):
            raise transport.TransportError("artifact digest mismatch")
        transport.unpack_single_member(archive, destination)
        print(f"Downloaded artifact {args.artifact_id} over parallel ranges")
    except Exception as error:  # noqa: BLE001 - any miss falls back to the canonical reader
        print(f"Parallel download missed ({type(error).__name__}: {error}); using gh run download")
        subprocess.run(["rm", "-rf", str(destination)], check=True)
        subprocess.run(
            ["gh", "run", "download", args.run_id, "-R", args.repository, "-n", args.artifact_name, "-D", str(destination)],
            check=True,
        )
    finally:
        archive.unlink(missing_ok=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    plan_parser = commands.add_parser("plan")
    plan_parser.add_argument("--ref", required=True)
    plan_parser.add_argument("--repository", required=True)
    plan_parser.add_argument("--only-testing", required=True)
    plan_parser.add_argument("--source-run-id", default="")
    plan_parser.add_argument("--max-commits", type=int, default=200)
    detach_parser = commands.add_parser("detach")
    detach_parser.add_argument("--project", required=True)
    detach_parser.add_argument("--derived-data", required=True)
    detach_parser.add_argument("--xcconfig", required=True)
    detach_parser.add_argument("--target", default=TEST_TARGET)
    detach_parser.add_argument("--package-root", action="append", default=[])
    download_parser = commands.add_parser("download")
    download_parser.add_argument("--repository", required=True)
    download_parser.add_argument("--run-id", required=True)
    download_parser.add_argument("--artifact-id", required=True, type=int)
    download_parser.add_argument("--artifact-name", required=True)
    download_parser.add_argument("--destination", required=True)
    args = parser.parse_args(argv)
    if args.command == "plan":
        try:
            result = plan(args)
        except ValueError as error:
            raise SystemExit(str(error))
        output = os.environ.get("GITHUB_OUTPUT")
        if output:
            with open(output, "a") as handle:
                for key, value in result.items():
                    handle.write(f"{key}={value}\n")
        print(json.dumps(result, indent=2))
    elif args.command == "download":
        download(args)
    else:
        detach(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
