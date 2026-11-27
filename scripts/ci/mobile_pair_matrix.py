#!/usr/bin/env python3
"""Exercise each distinct source in the supported shipped window in both roles."""
import argparse
import io
import json
import os
from pathlib import Path
import posixpath
import re
import resource
import signal
import subprocess
import tempfile
import time
import tomllib


def run_source(command, *, timeout=120, **kwargs):
    """Bound the whole Git process group, including wrappers and checkout children."""
    with subprocess.Popen(command, start_new_session=True, **kwargs) as process:
        try:
            stdout, stderr = process.communicate(timeout=timeout)
        except BaseException:
            for sig in (signal.SIGTERM, signal.SIGKILL):
                try:
                    os.killpg(process.pid, sig)
                except ProcessLookupError:
                    pass
                if sig == signal.SIGTERM:
                    try:
                        process.wait(timeout=1)
                    except subprocess.TimeoutExpired:
                        pass
            process.communicate()
            raise
        result = subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
        result.check_returncode()
        return result


def source_paths(head, sha):
    """Read manifests in two Git calls; include Cargo's complete local resolution graph."""
    names = run_source(["git", "-C", str(head), "ls-tree", "-r", "--name-only", sha],
                       stdout=subprocess.PIPE).stdout.decode().splitlines()
    manifests = [name for name in names if name == "Cargo.toml" or name.endswith("/Cargo.toml")]
    # A file supplies stdin so Popen's timeout covers the batch without a writer thread.
    with tempfile.TemporaryFile() as requests:
        requests.write("".join(f"{sha}:{name}\n" for name in manifests).encode())
        requests.seek(0)
        batch = run_source(["git", "-C", str(head), "cat-file", "--batch"],
                           stdin=requests, stdout=subprocess.PIPE).stdout
    stream = io.BytesIO(batch)
    docs = {}
    for name in manifests:
        header = stream.readline().split()
        if len(header) != 3 or header[1] != b"blob":
            raise ValueError(f"missing Cargo manifest {sha}:{name}")
        docs[name] = stream.read(int(header[2])).decode()
        if stream.read(1) != b"\n":
            raise ValueError("invalid Git manifest batch")
    return cargo_paths(docs, names)


def cargo_paths(docs, names=()):
    def read(name):
        if isinstance(docs[name], str):
            docs[name] = tomllib.loads(docs[name])
        return docs[name]

    mobile = "cmux-next-ios/rust"
    selected = {mobile}
    pending = [name for name in docs if name.startswith(mobile + "/")]
    visited = set()
    while pending:
        name = pending.pop()
        if name in visited:
            continue
        visited.add(name)
        doc = read(name)
        directory = posixpath.dirname(name)
        workspace_dir = directory
        explicit = doc.get("package", {}).get("workspace")
        if explicit is not None:
            workspace_dir = posixpath.normpath(posixpath.join(directory, explicit))
        else:
            while not (posixpath.join(workspace_dir, "Cargo.toml") in docs and
                       "workspace" in read(posixpath.join(workspace_dir, "Cargo.toml"))):
                parent = posixpath.dirname(workspace_dir)
                if parent == workspace_dir:
                    break
                workspace_dir = parent
        workspace = (read(posixpath.join(workspace_dir, "Cargo.toml")).get("workspace", {})
                     if posixpath.join(workspace_dir, "Cargo.toml") in docs else {})
        tables = [doc, *doc.get("target", {}).values()]
        dependencies = []
        for table in tables:
            for kind in ("dependencies", "build-dependencies", "dev-dependencies"):
                dependencies.extend(table.get(kind, {}).items())
        for patches in doc.get("patch", {}).values():
            dependencies.extend(patches.items())
        for dependency, spec in dependencies:
            if not isinstance(spec, dict):
                continue
            base = directory
            if spec.get("workspace"):
                spec = workspace["dependencies"][dependency]
                base = workspace_dir
            if not isinstance(spec, dict) or "path" not in spec:
                continue
            path = posixpath.normpath(posixpath.join(base, spec["path"]))
            manifest = path + "/Cargo.toml"
            if path.startswith("../") or path.startswith("/") or manifest not in docs:
                raise ValueError(f"missing local dependency {dependency}: {manifest}")
            selected.add(path)
            pending.append(manifest)
    if any(name.startswith(".cargo/") for name in names):
        selected.add(".cargo")
    # Cone mode also includes ancestor files: inherited workspace manifests/toolchains.
    return sorted(path for path in selected if not any(
        path.startswith(other + "/") for other in selected if other != path))


def prepare_source(head, sha, tree, added):
    run_source(["git", "-C", str(head), "fetch", "--no-tags", "--depth=1", "origin", sha])
    paths = source_paths(head, sha)
    try:
        run_source(["git", "-C", str(head), "worktree", "add", "--no-checkout",
                    "--detach", str(tree), sha])
    except BaseException:
        if (tree / ".git").exists():
            added.append(tree)
        raise
    added.append(tree)  # Register before materialization: a failed checkout still needs removal.
    run_source(["git", "-C", str(tree), "sparse-checkout", "set", "--cone", *paths])
    run_source(["git", "-C", str(tree), "checkout", "--detach", sha])


def cleanup_sources(head, added):
    for tree in reversed(added):
        run_source(["git", "-C", str(head), "worktree", "remove", "--force", str(tree)])


def pairs(window, head, trees):
    rows = window["include"]
    if not rows or {row["role"] for row in rows} != {"host", "dial"}:
        raise ValueError("the shipped window must contain both host and dial sources")
    for row in rows:
        if not re.fullmatch(r"[0-9a-f]{40}", row["sha"]) or not row["release_ids"]:
            raise ValueError("source and publication IDs are required")
        shipped = trees[row["sha"]]
        yield row, (shipped, head) if row["role"] == "host" else (head, shipped)


def publish_verdict(verdict):
    if os.environ.get("GITHUB_OUTPUT"):
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            print(f"verdict={verdict}", file=output)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("window", type=Path)
    parser.add_argument("--head", type=Path, default=Path.cwd())
    args = parser.parse_args()
    head = args.head.resolve()
    window = json.loads(args.window.read_text())
    logs = Path(os.environ["SKEW_LOG_DIR"]).resolve()
    logs.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="phone-pair-sources-") as directory:
        trees = {row["sha"]: Path(directory) / row["sha"] for row in window["include"]}
        plan = list(pairs(window, head, trees))
        added = []
        (logs / "matrix-result.json").write_text(json.dumps({
            "completed": [], "not_run": window["include"], "passed": False,
            "failed_stage": "source-preparation-incomplete",
        }, indent=2) + "\n")
        try:
            for sha, tree in trees.items():
                prepare_source(head, sha, tree, added)
            completed = []
            for index, (row, (host, dial)) in enumerate(plan):
                label = row["role"] + "-" + row["sha"][:12]
                env = dict(os.environ, SKEW_LOG_DIR=str(logs / label))
                verdict_path = logs / label / "assertion-verdict"
                verdict_path.parent.mkdir(parents=True, exist_ok=True)
                verdict_path.write_text("")  # Never reuse a receipt from an interrupted attempt.
                start = time.monotonic()
                cpu = resource.getrusage(resource.RUSAGE_CHILDREN)
                status, failed_stage = 1, ""
                try:
                    result = subprocess.run([
                        "bash", str(head / "scripts/ci/timeout.sh"), "--kill-after=5", "1800",
                        "bash", str(head / "scripts/ci/mobile-pair-skew.sh"), str(host), str(dial),
                    ], env=env, timeout=1815)
                    status = result.returncode
                    failed_stage = ("pair-timeout" if status in (124, 137) else "pair") if status else ""
                except subprocess.TimeoutExpired:
                    status, failed_stage = 124, "pair-timeout"
                except OSError:
                    status, failed_stage = 127, "pair-launch"
                verdict = verdict_path.read_text().strip()
                if status in (124, 126, 127, 137) or status < 0:
                    verdict = ""
                if status == 0 and verdict != "success":
                    status, failed_stage = 1, "missing-assertion-verdict"
                if verdict == "failure":
                    publish_verdict("failure")
                after = resource.getrusage(resource.RUSAGE_CHILDREN)
                receipt = dict(row, pr_sha=subprocess.check_output(
                    ["git", "-C", str(head), "rev-parse", "HEAD"], text=True).strip(),
                    wall_seconds=time.monotonic() - start,
                    cpu_seconds=(after.ru_utime + after.ru_stime - cpu.ru_utime - cpu.ru_stime),
                    exit_code=status, failed_stage=failed_stage, verdict=verdict,
                    cost_scope="pair including any build; excludes setup and source fetch")
                (logs / (label + ".json")).write_text(json.dumps(receipt, indent=2) + "\n")
                print(json.dumps(receipt), flush=True)
                completed.append(receipt)
                (logs / "matrix-result.json").write_text(json.dumps({
                    "completed": completed,
                    "not_run": [pending for pending, _ in plan[index + 1:]],
                    "passed": status == 0 and index + 1 == len(plan),
                }, indent=2) + "\n")
                if status:
                    raise SystemExit(status)
            publish_verdict("success")
        finally:
            cleanup_sources(head, added)


if __name__ == "__main__":
    def terminate(signum, _frame):
        raise SystemExit(128 + signum)
    signal.signal(signal.SIGTERM, terminate)
    main()
