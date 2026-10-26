#!/usr/bin/env python3
"""Exercise the measurement's real source fence in disposable Git histories; no native run."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/measure/pane-overflow-fade.sh"
source = SCRIPT.read_text()
# Execute the actual identity fence, before the native probe/build portion.
fence = source[source.index('\nFIXED_BLOB=') + 1:source.index('WORK="$(mktemp')]
PRODUCT = "product.swift"
REGRESSION = "regression.swift"


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()


def commit(repo, message):
    git(repo, "add", ".")
    git(repo, "-c", "user.name=fixture", "-c", "user.email=fixture@example.test",
        "-c", "core.hooksPath=/dev/null", "commit", "-qm", message)
    return git(repo, "rev-parse", "HEAD")


def run_case(kind):
    with tempfile.TemporaryDirectory(prefix="pane-fade-source-") as directory:
        repo = Path(directory) / "repo"
        repo.mkdir()
        git(repo, "init", "-q")
        (repo / PRODUCT).write_text("old product\n")
        (repo / REGRESSION).write_text("old tests\n")
        (repo / "unrelated").write_text("keep\n")
        base = commit(repo, "base")
        old_blob = git(repo, "rev-parse", f"HEAD:{PRODUCT}")
        (repo / REGRESSION).write_text("fade regression\n")
        if kind == "feature":
            red = commit(repo, "red")
        else:
            red = base
        (repo / PRODUCT).write_text("fixed product\n")
        commit(repo, "fix" if kind == "feature" else "squash")
        fixed_blob = git(repo, "rev-parse", f"HEAD:{PRODUCT}")
        test_blob = git(repo, "rev-parse", f"HEAD:{REGRESSION}")
        if kind == "feature":
            (repo / "proof-only").write_text("proof\n")
            commit(repo, "proof")
        if kind == "wrong-test":
            (repo / REGRESSION).write_text("unexpected tests\n")
            commit(repo, "unexpected test")
        head = git(repo, "rev-parse", "HEAD")
        env = os.environ | {
            "PRODUCT_PATH": PRODUCT, "REGRESSION_PATH": REGRESSION,
            "EXPECTED_FIXED_BLOB": fixed_blob, "EXPECTED_OLD_BLOB": old_blob,
            "EXPECTED_RED_TEST_BLOB": test_blob, "HEAD_SHA": head,
            "HEAD_TREE": git(repo, "rev-parse", "HEAD^{tree}"),
        }
        before = Path(directory) / "before"
        command = ('set -euo pipefail\n'
                   'die() { echo "$*" >&2; exit 2; }\n' + fence +
                   '\nprintf "%s\\n" "$BASE_SHA" "$RED_SHA" > identities\n'
                   f'git worktree add --detach "{before}" "$RED_SHA"\n'
                   f'prepare_before_regression "{before}"\n')
        result = subprocess.run(["bash", "-c", command], cwd=repo, env=env,
                                capture_output=True, text=True)
        if kind == "wrong-test":
            assert result.returncode != 0, "unexpected final regression blob was accepted"
            print("PASS unexpected final regression rejected")
            return
        assert result.returncode == 0, result.stdout + result.stderr
        selected_base, selected_red = (repo / "identities").read_text().splitlines()
        assert selected_base == base and selected_red == red
        assert git(before, "rev-parse", "HEAD") == red
        assert git(before, "hash-object", PRODUCT) == old_blob
        assert git(before, "hash-object", REGRESSION) == test_blob
        changed = git(before, "diff", "--name-only").splitlines()
        assert changed == ([REGRESSION] if kind == "squash" else [])
        assert (before / "unrelated").read_text() == "keep\n"
        print(f"PASS {kind}: exact old product with regression-only overlay")


for case in ("squash", "feature", "wrong-test"):
    run_case(case)
