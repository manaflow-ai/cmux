#!/usr/bin/env python3
"""Exercise the measurement's real source fence in disposable Git histories; no native run."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
SCRIPT = ROOT / "scripts/measure/pane-overflow-fade.sh"
source = Path(os.environ.get("NX_FADE_TEST_SCRIPT", SCRIPT)).read_text()
# Execute the actual fetch preflight against a cold shallow, detached checkout
# with no remote; only the canonical network destination is replaced by a local
# fixture server. A later tooling commit must still measure the requested fix.
def test_detached_fetch_preflight():
    with tempfile.TemporaryDirectory(prefix="pane-fade-no-origin-") as directory:
        upstream = Path(directory) / "upstream"
        upstream.mkdir()
        def fixture_git(repo, *args):
            return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()
        fixture_git(upstream, "init", "-q")
        for name in ("parent", "product", "tooling"):
            (upstream / "tracked").write_text(name + "\n")
            fixture_git(upstream, "add", ".")
            fixture_git(upstream, "-c", "user.name=fixture", "-c", "user.email=fixture@example.test",
                        "-c", "core.hooksPath=/dev/null", "commit", "-qm", name)
            if name == "product":
                product = fixture_git(upstream, "rev-parse", "HEAD")
                parent = fixture_git(upstream, "rev-parse", "HEAD^")
        repo = Path(directory) / "checkout"
        repo.mkdir()
        fixture_git(repo, "init", "-q")
        fixture_git(repo, "fetch", "--depth=1", upstream.as_uri(), "HEAD")
        fixture_git(repo, "checkout", "-q", "--detach", "FETCH_HEAD")
        script_head = fixture_git(repo, "rev-parse", "HEAD")
        assert fixture_git(repo, "remote") == ""
        start = source.index('SCRIPT_SHA=') if 'SCRIPT_SHA=' in source else source.index('HEAD_SHA=')
        preflight = source[start:source.index('\nFIXED_BLOB=')]
        preflight = preflight.replace("https://github.com/manaflow-ai/cmux.git", upstream.as_uri())
        result = subprocess.run(
            ["bash", "-c", 'set -euo pipefail\ndie() { echo "$*" >&2; exit 2; }\n' + preflight +
             '\ngit cat-file -e "$HEAD_SHA^"\nprintf "%s\\n" "$HEAD_SHA"\n', "fixture", product],
            cwd=repo, capture_output=True, text=True,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        assert f"head={product}" in result.stdout, result.stdout
        assert fixture_git(repo, "rev-parse", "HEAD") == script_head
        assert fixture_git(repo, "rev-parse", product + "^") == parent
        assert fixture_git(repo, "remote") == ""
        print("PASS cold detached preflight: target and parent fetched without changing HEAD or remotes")

test_detached_fetch_preflight()
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
            "EXPECTED_RED_TEST_BLOB": test_blob, "HEAD_SHA": head, "SCRIPT_SHA": head,
            "SCRIPT_TREE": git(repo, "rev-parse", "HEAD^{tree}"),
            "HEAD_TREE": git(repo, "rev-parse", "HEAD^{tree}"),
        }
        before = Path(directory) / "before"
        command = ('set -euo pipefail\n'
                   'die() { echo "$*" >&2; exit 2; }\n' + fence +
                   '\nprintf "%s\\n" "$BASE_SHA" "$RED_SHA" > identities\n'
                   f'git worktree add --detach "{before}" "$RED_SHA"\n'
                   f'prepare_before_regression "{before}"\n'
                   f'assert_measurement_checkout "{before}" "$RED_SHA"\n')
        if kind.startswith("tamper-"):
            target = {"tamper-product": PRODUCT, "tamper-unrelated": "unrelated",
                      "tamper-index": "unrelated", "tamper-regression": REGRESSION}[kind]
            command += f'printf "tampered\\n" >> "{before / target}"\n'
            if kind == "tamper-index":
                command += f'git -C "{before}" add "{target}"\n'
            command += f'assert_measurement_checkout "{before}" "$RED_SHA"\n'
        result = subprocess.run(["bash", "-c", command], cwd=repo, env=env,
                                capture_output=True, text=True)
        if kind.startswith("tamper-"):
            reason = {"tamper-product": "changed product or unrelated tracked files",
                      "tamper-unrelated": "changed product or unrelated tracked files",
                      "tamper-index": "index changed",
                      "tamper-regression": "regression test blob changed"}[kind]
            assert result.returncode != 0 and reason in result.stderr, result.stderr
            if kind in ("tamper-product", "tamper-unrelated"):
                assert "NATIVE_FADE_TRACKED_MUTATION" in result.stderr, result.stderr
                assert target in result.stderr, result.stderr
            print(f"PASS {kind}: tracked source guard rejected the mutation")
            return
        if kind == "wrong-test":
            assert result.returncode != 0, "unexpected final regression blob was accepted"
            assert "final regression test blob changed" in result.stderr, result.stderr
            print("PASS unexpected final regression rejected")
            return
        assert result.returncode == 0, result.stdout + result.stderr
        selected_base, selected_red = (repo / "identities").read_text().splitlines()
        assert selected_base == base and selected_red == red
        overlay = test_blob if kind == "squash" else "none"
        assert f"test_overlay_blob={overlay}" in result.stdout, result.stdout
        assert git(before, "rev-parse", "HEAD") == red
        assert git(before, "hash-object", PRODUCT) == old_blob
        assert git(before, "hash-object", REGRESSION) == test_blob
        changed = git(before, "diff", "--name-only").splitlines()
        assert changed == ([REGRESSION] if kind == "squash" else [])
        assert (before / "unrelated").read_text() == "keep\n"
        print(f"PASS {kind}: exact old product with regression-only overlay")


for case in ("squash", "feature", "wrong-test", "tamper-product", "tamper-unrelated",
             "tamper-index", "tamper-regression"):
    run_case(case)
