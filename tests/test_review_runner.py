#!/usr/bin/env python3
"""Exercise native review orchestration with an executable, deterministic reviewer.

The fixture implements the Codex structured-output command boundary. It never
calls a model, connects to the app, or reads the contributor's repositories.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile


def check_review_runner_contract(cli_path: str) -> list[str]:
    failures: list[str] = []
    with tempfile.TemporaryDirectory(prefix="cmux-review-runner-") as temporary:
        root = Path(temporary)
        repository = root / "repo"
        repository.mkdir()
        environment = {
            key: value for key, value in os.environ.items()
            if not key.startswith("GIT_") and not key.startswith("CMUX_")
        }
        environment["CMUX_SOCKET_PATH"] = str(root / "absent.sock")

        def git(*arguments: str) -> str:
            return subprocess.check_output(
                ["git", "-C", str(repository), *arguments],
                env=environment, text=True, stderr=subprocess.PIPE, timeout=10,
            ).strip()

        git("init", "-q")
        git("config", "user.email", "review-fixture@example.invalid")
        git("config", "user.name", "Review fixture")
        nested = repository / "ios"
        nested.mkdir()
        (nested / "AGENTS.md").write_text("nested-rule\n")
        (nested / "value.txt").write_text("nested-original\n")
        (repository / "value.txt").write_text("original\n")
        (repository / ".gitattributes").write_text("value.txt export-ignore\n")
        git("add", "value.txt", ".gitattributes", "ios/AGENTS.md", "ios/value.txt")
        git("commit", "-qm", "fixture")
        head = git("rev-parse", "HEAD")
        (repository / "value.txt").write_text("staged\n")
        git("add", "value.txt")
        (repository / "value.txt").write_text("working\n")
        (repository / "new.txt").write_text("untracked\n")
        (nested / "value.txt").write_text("nested-working\n")
        filter_marker = root / "filter-ran"
        filter_script = root / "clean-filter.py"
        filter_script.write_text(
            "import pathlib, sys\n"
            f"pathlib.Path({str(filter_marker)!r}).write_text('executed')\n"
            "sys.stdout.write(sys.stdin.read())\n"
        )
        filter_script.chmod(0o755)
        git("config", "filter.review.clean", f"python3 {filter_script}")
        git("config", "filter.review.smudge", "cat")
        (repository / ".gitattributes").write_text("value.txt filter=review\n")
        index_before = git("diff", "--cached")
        status_before = git("status", "--porcelain=v1")
        filter_marker.unlink(missing_ok=True)
        hook_marker = root / "hook-ran"
        hook = repository / ".git" / "hooks" / "post-index-change"
        hook.write_text(f"#!/bin/sh\ntouch '{hook_marker}'\n")
        hook.chmod(0o755)

        driver = root / "reviewer"
        driver.write_text('''#!/usr/bin/env python3
import json
import pathlib
import sys

arguments = sys.argv[1:]
assert "read-only" in arguments, arguments
assert "--ephemeral" in arguments, arguments
output = pathlib.Path(arguments[arguments.index("--output-last-message") + 1])
candidate = pathlib.Path(arguments[arguments.index("--cd") + 1])
prompt = sys.stdin.read()
assert "+working" in prompt
assert "+untracked" in prompt
assert "nested-rule" in prompt
assert "default_tools_enabled=false" in arguments
assert "mcp_servers={}" in arguments
role = output.stem
if role in ("correctness", "impact"):
    assert "PRIMARY-CLAIM" not in prompt, "discovery was contaminated by a peer"
    findings = [{
        "title": "PRIMARY-CLAIM", "severity": "P0" if role == "impact" else "P1",
        "claim": "The changed value breaks a caller",
        "failure_mode": "Caller rejects the value", "paths": ["value.txt"]
    }]
    if role == "correctness":
        findings.append({
            "title": "Style preference", "severity": "P3",
            "claim": "A different spelling would look nicer",
            "failure_mode": "No behavioral failure", "paths": ["value.txt"]
        })
    result = {"behavior_changed": ["The value changes"], "findings": findings}
else:
    assert role.startswith("challenge-"), role
    assert "PRIMARY-CLAIM" in prompt
    assert "Style preference" not in prompt, "a suppressed nit reached challenge"
    result = {"disposition": "survives_challenge", "reason": "The caller needs executable verification"}
output.write_text(json.dumps(result))
''')
        driver.chmod(0o755)
        command = [
            cli_path, "review", "run", "--repo", str(repository),
            "--base", head, "--intent", "Update the value", "--reviewer", str(driver), "--json",
        ]
        result = subprocess.run(command, env=environment, text=True, capture_output=True, timeout=30)
        if result.returncode != 0:
            return [f"review run failed: {result.stderr.strip()}"]
        try:
            receipt = json.loads(result.stdout)
            assert receipt["source"]["head_sha"] == head
            assert receipt["source"]["base_sha"] == head
            assert receipt["source"]["working_tree_dirty"] is True
            tree = receipt["source"]["tree_sha"]
            assert git("show", f"{tree}:value.txt") == "working"
            assert git("show", f"{tree}:new.txt") == "untracked"
            assert not filter_marker.exists(), "repository clean filter executed during read-only capture"
            assert not hook_marker.exists(), "repository index hook executed during read-only capture"
            assert receipt["summary"]["verified"] == 0, "model agreement is not verification"
            assert receipt["summary"]["suppressed"] == 1
            assert len(receipt["findings"]) == 2, "duplicate discoveries must be merged"
            finding = next(f for f in receipt["findings"] if f["title"] == "PRIMARY-CLAIM")
            assert set(finding["discovery_sources"]) == {"correctness", "impact"}
            assert finding["severity"] == "P0", "deduplication must preserve the strongest severity"
            assert finding["verification"]["result"] == "human_judgment"
            assert finding["disposition"] == "human_required"
            assert all(c["kind"] == "inferred" for c in finding["claims"])
            assert git("diff", "--cached") == index_before
            assert git("status", "--porcelain=v1") == status_before
            read = subprocess.run(
                [cli_path, "review", "show", "latest", "--repo", str(repository), "--json"],
                env=environment, text=True, capture_output=True, timeout=10,
            )
            assert read.returncode == 0, read.stderr
            assert json.loads(read.stdout) == receipt, "persisted receipt differs from completed run"
        except (AssertionError, KeyError, ValueError, StopIteration) as error:
            failures.append(f"review runner contract: {error}")
            return failures

        driver.write_text(driver.read_text().replace('"disposition": "survives_challenge"', '"disposition": "refuted"'))
        disagreement = subprocess.run(command, env=environment, text=True, capture_output=True, timeout=30)
        if disagreement.returncode != 0:
            failures.append(f"review challenger fixture failed: {disagreement.stderr}")
        else:
            try:
                challenged = json.loads(disagreement.stdout)
                surviving = next(f for f in challenged["findings"] if f["title"] == "PRIMARY-CLAIM")
                if surviving["disposition"] != "human_required" or surviving["challenge"]["disposition"] != "uncertain":
                    failures.append("model disagreement was promoted to established refutation")
            except (KeyError, ValueError, StopIteration) as error:
                failures.append(f"review challenger contract: {error}")

        # Hook/parent Git context must never redirect a review or alter its snapshot.
        contaminated = dict(environment)
        contaminated["GIT_DIR"] = str(root / "unrelated.git")
        contaminated["GIT_WORK_TREE"] = str(root / "unrelated-worktree")
        ignore = root / "inherited-ignore"
        ignore.write_text("new.txt\n")
        configured = dict(environment)
        configured.update({"GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "core.excludesFile",
                           "GIT_CONFIG_VALUE_0": str(ignore)})
        for inherited in (contaminated, configured):
            isolated = subprocess.run(command, env=inherited, text=True, capture_output=True, timeout=30)
            if isolated.returncode != 0:
                failures.append(f"inherited Git context changed the review: {isolated.stderr.strip()}")
            else:
                isolated_receipt = json.loads(isolated.stdout)
                if isolated_receipt["source"]["tree_sha"] != tree:
                    failures.append("inherited Git configuration changed the captured tree")
            loaded = subprocess.run(
                [cli_path, "review", "show", "latest", "--repo", str(repository), "--json"],
                env=inherited, text=True, capture_output=True, timeout=10,
            )
            if loaded.returncode != 0:
                failures.append(f"inherited Git context redirected the ledger: {loaded.stderr.strip()}")

        # A failed model call must not publish a clean receipt or disturb prior runs.
        ledger = repository / ".git" / "cmux" / "reviews"
        before = sorted(p.name for p in ledger.glob("*.json"))
        driver.write_text("#!/bin/sh\nexit 17\n")
        failed = subprocess.run(command, env=environment, text=True, capture_output=True, timeout=30)
        if failed.returncode == 0:
            failures.append("review run unexpectedly succeeded after reviewer failure")
        if sorted(p.name for p in ledger.glob("*.json")) != before:
            failures.append("failed review published a receipt")

        invalid_base = subprocess.run(
            [cli_path, "review", "run", "--repo", str(repository), "--base", "missing-ref",
             "--intent", "Update the value", "--reviewer", str(driver), "--json"],
            env=environment, text=True, capture_output=True, timeout=30,
        )
        if invalid_base.returncode == 0 or "fatal:" in invalid_base.stderr.lower():
            failures.append("Git diagnostics leaked through the review-source error")
    return failures


if __name__ == "__main__":
    import sys

    errors = check_review_runner_contract(os.environ["CMUX_CLI_BIN"])
    for error in errors:
        print(f"FAIL: {error}")
    if not errors:
        print("PASS: native review runner contract")
    sys.exit(bool(errors))
