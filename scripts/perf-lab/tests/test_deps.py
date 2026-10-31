#!/usr/bin/env python3
"""deps.py: a culprit that only rolls ghostty, ghostty-next or the CEF pin becomes a nested bisect.

  python3 -m unittest scripts/perf-lab/tests/test_deps.py
"""
from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

LAB = Path(__file__).resolve().parent.parent


def _load(name: str, path: Path):
    if name in sys.modules:
        return sys.modules[name]
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


pinpoint = _load("perf_lab_pinpoint", LAB / "pinpoint.py")
deps = _load("perf_lab_deps", LAB / "deps.py")

CLASS = "apple-m6/24gb/120hz"
STORY, METRIC = "terminal.key-frame.light", "key_to_frame_ms"


def sha(tag: str, i: int) -> str:
    return (tag.encode().hex() + f"{i:x}").rjust(40, "0")[-40:]


def cmux(i: int) -> str:
    return sha("c", i)


def up(i: int, tag: str = "u") -> str:
    return sha(tag, i)


def gitmodules(*paths: str) -> bytes:
    return "".join(f'[submodule "{p}"]\n\tpath = {p}\n\turl = https://github.com/manaflow-ai/{p}.git\n'
                   for p in paths).encode()


def manifest(fork_ref: str, repo: str = "manaflow-ai/cef", sha256: str = "a" * 64) -> bytes:
    return json.dumps({"repo": repo, "fork_ref": fork_ref, "sha256": sha256}).encode()


class FakeRepo:
    """Trees of cmux commits ({path: bytes, or ('commit', sha) for a gitlink}) and linear dependency histories."""

    def __init__(self, trees: dict, histories: dict | None = None) -> None:
        self.trees = trees
        self.histories = histories or {}
        self.asked: list = []

    def changed_paths(self, parent, change):
        a, b = self.trees[parent], self.trees[change]
        return tuple(sorted(p for p in a.keys() | b.keys() if a.get(p) != b.get(p)))

    def gitlink(self, sha_, path):
        entry = self.trees[sha_].get(path)
        return entry[1] if isinstance(entry, tuple) else None

    def read_file(self, sha_, path):
        entry = self.trees[sha_].get(path)
        return entry if isinstance(entry, bytes) else None

    def dep_path(self, pin, url, old, new):
        self.asked.append((pin, url, old, new))
        line = self.histories[pin]
        if old not in line or new not in line:
            return None
        i, j = line.index(old), line.index(new)
        return tuple(line[i + 1:j + 1]) if i < j else tuple(reversed(line[j:i]))


HOST_PIN = deps.REMOTE_BROWSER_HOST_PIN


def host_pin(cef_sha256: str = "a" * 64, crate_tree: str = "t1") -> bytes:
    return json.dumps({"asset": "cmux-remote-browser-host-macos-arm64", "arch": "arm64", "sha256": cef_sha256[:8],
                       "source_commit": "s1", "crate_tree": crate_tree, "cef_sha256": cef_sha256}).encode()


def package_swift(commit: str, comment: str = "", other: str = "") -> bytes:
    """CmuxGhosttyKit's Package.swift with GhosttyNextKit pinned at commit, in the shape of the real one."""
    return f"""// swift-tools-version: 6.2
import PackageDescription
// Since a04c57e81 a snapshot restore keeps a scrolled-back viewport.{comment}
let package = Package(
    name: "CmuxGhosttyKit",
    targets: [
        .target(name: "CmuxGhosttyKitLink"{other}),
        .binaryTarget(
            name: "GhosttyNextKit",
            url: "https://github.com/manaflow-ai/ghostty-next/releases/download/xcframework-{commit}-apple-v6/GhosttyNextKit.xcframework.zip",
            checksum: "{commit[:8]}"
        ),
    ]
)
""".encode()


def notices(commit: str, musl: str = "1.2.5") -> bytes:
    return json.dumps({"comment": "c", "musl": {"version": musl},
                       "libghostty_vt": {"source": "ghostty-next", "commit": commit, "license_tree": f"tree {commit}"}
                       }).encode()


def link_graph(commit: str) -> bytes:
    return json.dumps({"commit": commit, "schema": 1, "source": "ghostty-next", "targets": {"t": commit[:4]}}).encode()


def checksums(*commits: str) -> bytes:
    return "".join(f"{c} {c[:8]}\n" for c in commits).encode()


def tree(overrides: dict | None = None) -> dict:
    """A cmux tree with every pin at its first commit and its companion files following it, and overrides by path."""
    return {"Sources/App.swift": b"app", ".gitmodules": gitmodules("ghostty", "ghostty-next"),
            "ghostty": ("commit", up(0, "g")), "ghostty-next": ("commit", up(0)),
            deps.GHOSTTYKIT_CHECKSUMS: checksums(up(0, "g")), deps.GHOSTTY_FORK_DOC: b"# fork\n",
            deps.GHOSTTYKIT_WORKFLOW: b"jobs: {}\n",
            deps.GHOSTTY_NEXT_PACKAGE: package_swift(up(0)), deps.PACKAGE_NOTICES: notices(up(0)),
            deps.VT_LINK_GRAPH: link_graph(up(0)),
            deps.CEF_MANIFEST: manifest(up(0, "f")), HOST_PIN: host_pin(), **(overrides or {})}


def ghostty_next_roll(new: str, **package) -> dict:
    """The real shape of a ghostty-next roll (ede77f98de9, 8d71dd9520b): gitlink, Package.swift, both notices."""
    return {"ghostty-next": ("commit", new), deps.GHOSTTY_NEXT_PACKAGE: package_swift(new, **package),
            deps.PACKAGE_NOTICES: notices(new), deps.VT_LINK_GRAPH: link_graph(new)}


def ghostty_roll(new: str) -> dict:
    """The real shape of a ghostty roll (57ad4a5e09a, 11bd7073493): gitlink, checksums, fork notes, workflow."""
    return {"ghostty": ("commit", new), deps.GHOSTTYKIT_CHECKSUMS: checksums(up(0, "g"), new),
            deps.GHOSTTY_FORK_DOC: f"# fork\n{new}\n".encode(), deps.GHOSTTYKIT_WORKFLOW: b"jobs: {test: 1}\n"}


def bisect_job(range_) -> "pinpoint.Job":
    return pinpoint.Job(kind=pinpoint.BISECT, mode=pinpoint.PERFORMANCE, story=STORY, metric=METRIC,
                        host_class=CLASS, good=range_[0].change, bad=range_[-1].change, magnitude=None,
                        better="lower", commits=tuple(range_))


def run(job, level):
    """The job driven to its result: every build succeeds; attempt k of a Change measures level(change) + jitter."""
    built = []

    def build(change):
        built.append(change)
        return True

    def attempt(change, k):
        return pinpoint.Attempt(change, k, values=(level(change) + 0.1 * (k % 7),))

    return pinpoint.run_to_end(pinpoint.JobState(job), build, attempt), built


def culprit_of(job, level):
    result, _ = run(job, level)
    assert result.outcome == pinpoint.CULPRITS, result.outcome
    assert len(result.culprits) == 1
    return result.culprits[0]


GHOSTTY_NEXT_LINE = [up(i) for i in range(12)]  # u0 .. u11, first-parent line of ghostty-next main


def bump_fixture(new_index: int = 8, other: dict | None = None, roll: dict | None = None):
    """cmux c0 -> c1 -> c2 (ghostty-next u0 -> u<new_index>: the gitlink alone, as 769ae064b16, or roll) -> c3.
    The outer bisect's culprit is c2."""
    bumped = {**(roll or {"ghostty-next": ("commit", up(new_index))}), **(other or {})}
    trees = {cmux(0): tree(), cmux(1): tree({"Sources/App.swift": b"app 1"}),
             cmux(2): tree({"Sources/App.swift": b"app 1", **bumped}),
             cmux(3): tree({"Sources/App.swift": b"app 3", **bumped})}
    range_ = [pinpoint.Commit(cmux(i), batch_tip=i in (0, 3), stored_build=i in (0, 3)) for i in range(4)]
    return FakeRepo(trees, {deps.GHOSTTY_NEXT: GHOSTTY_NEXT_LINE}), bisect_job(range_)


def outer_level(change):
    return 10.0 if change.sha in (cmux(0), cmux(1)) else 14.0


class SubmoduleBumpTests(unittest.TestCase):
    def test_bump_with_8_upstream_commits_becomes_a_nested_bisect_that_names_the_upstream_commit(self) -> None:
        repo, job = bump_fixture()
        culprit = culprit_of(job, outer_level)
        self.assertEqual((culprit.parent.sha, culprit.change.sha), (cmux(1), cmux(2)))

        expansion = deps.expand(job, culprit, repo)

        self.assertIsInstance(expansion, deps.Expansion)
        self.assertEqual(repo.asked, [(deps.GHOSTTY_NEXT, "https://github.com/manaflow-ai/ghostty-next.git",
                                       up(0), up(8))])
        (move,) = expansion.moves
        self.assertEqual((move.pin, move.old, move.new), (deps.GHOSTTY_NEXT, up(0), up(8)))
        self.assertEqual(move.path, tuple(up(i) for i in range(1, 9)))
        nested = expansion.job
        self.assertEqual(nested.kind, pinpoint.BISECT)
        self.assertEqual((nested.story, nested.metric, nested.host_class, nested.mode, nested.better),
                         (STORY, METRIC, CLASS, pinpoint.PERFORMANCE, "lower"))
        self.assertEqual((nested.good, nested.bad), (culprit.parent, culprit.change))
        # P, then P with ghostty-next at u1..u7, then C itself (u8 is C's own tree): 9 Changes for 8 commits.
        self.assertEqual(len(nested.commits), 9)
        middle = nested.commits[1:-1]
        self.assertEqual([c.sha for c in middle], [cmux(1)] * 7)
        self.assertEqual([c.deps for c in middle], [((deps.GHOSTTY_NEXT, up(i)),) for i in range(1, 8)])
        self.assertFalse(any(c.batch_tip or c.stored_build for c in middle))
        self.assertEqual([(p.pin, p.sha) for p in expansion.points],
                         [(None, None)] + [(deps.GHOSTTY_NEXT, up(i)) for i in range(1, 9)])
        ids = {deps.build_id(c.change) for c in nested.commits}
        self.assertEqual(len(ids), 9, "each dependency state builds on its own; none reads P's build")

        # The regression is upstream commit u5: every state with ghostty-next at u5 or later is slow.
        def nested_level(change):
            if change == culprit.change:
                return 14.0
            at = dict(change.deps).get(deps.GHOSTTY_NEXT)
            return 14.0 if at is not None and GHOSTTY_NEXT_LINE.index(at) >= 5 else 10.0

        result, built = run(nested, nested_level)
        self.assertEqual(result.outcome, pinpoint.CULPRITS)
        (inner,) = result.culprits
        self.assertEqual(expansion.dep_commits(inner), ((deps.GHOSTTY_NEXT, up(5)),))
        self.assertEqual(inner.change, pinpoint.Change(cmux(1), ((deps.GHOSTTY_NEXT, up(5)),)))
        self.assertTrue(all(change.deps for change in built), "only dependency states are built; the ends exist")

    def test_nested_job_round_trips_through_the_executor_job_document(self) -> None:
        exec_module = _load("perf_lab_pinpoint_exec", LAB / "pinpoint_exec.py")
        repo, job = bump_fixture()
        expansion = deps.expand(job, culprit_of(job, outer_level), repo)
        document = json.loads(json.dumps(exec_module.job_doc(expansion.job, config="bench")))
        restored = exec_module.job_of(document)
        self.assertEqual(exec_module.job_doc(restored, config="bench"), document)
        self.assertEqual([(c.sha, c.deps) for c in restored.commits], [(c.sha, c.deps) for c in expansion.job.commits])

    def test_culprit_that_changes_more_than_the_pin_is_not_expanded(self) -> None:
        repo, job = bump_fixture(other={"Sources/Other.swift": b"new"})
        culprit = culprit_of(job, outer_level)
        expansion = deps.expand(job, culprit, repo)
        self.assertIsInstance(expansion, deps.NotExpanded)
        self.assertIn("Sources/Other.swift", expansion.reason)
        self.assertEqual(repo.asked, [])

    def test_gitmodules_change_with_the_bump_is_not_only_a_pin_move(self) -> None:
        repo, job = bump_fixture(other={".gitmodules": gitmodules("ghostty-next")})
        self.assertIn(".gitmodules", deps.expand(job, culprit_of(job, outer_level), repo).reason)

    def test_one_upstream_commit_names_it_without_a_nested_job(self) -> None:
        repo, job = bump_fixture(new_index=1)
        culprit = culprit_of(job, outer_level)
        expansion = deps.expand(job, culprit, repo)
        self.assertIsNone(expansion.job)
        self.assertEqual(expansion.dep_commits(culprit), ((deps.GHOSTTY_NEXT, up(1)),))

    def test_roll_back_walks_the_first_parents_down(self) -> None:
        trees = {cmux(0): tree({"ghostty-next": ("commit", up(6))}), cmux(1): tree({"ghostty-next": ("commit", up(2))})}
        repo = FakeRepo(trees, {deps.GHOSTTY_NEXT: GHOSTTY_NEXT_LINE})
        found = deps.moves(repo, cmux(0), cmux(1))
        self.assertEqual(found[0].path, (up(5), up(4), up(3), up(2)))

    def test_nonlinear_dependency_history_is_not_expanded(self) -> None:
        trees = {cmux(0): tree(), cmux(1): tree({"ghostty-next": ("commit", up(3, "x"))})}
        found = deps.moves(FakeRepo(trees, {deps.GHOSTTY_NEXT: GHOSTTY_NEXT_LINE}), cmux(0), cmux(1))
        self.assertIsInstance(found, deps.NotExpanded)
        self.assertIn("first-parent", found.reason)

    def test_a_path_that_does_not_reach_the_new_pin_is_an_error(self) -> None:
        trees = {cmux(0): tree(), cmux(1): tree({"ghostty-next": ("commit", up(3))})}
        repo = FakeRepo(trees)
        repo.dep_path = lambda pin, url, old, new: (up(1), up(2))
        with self.assertRaises(deps.DepsError):
            deps.moves(repo, cmux(0), cmux(1))

    def test_added_submodule_is_not_a_roll(self) -> None:
        before = tree()
        del before["ghostty-next"]
        found = deps.moves(FakeRepo({cmux(0): before, cmux(1): tree()}), cmux(0), cmux(1))
        self.assertIn("added", found.reason)

    def test_already_nested_culprit_is_not_expanded_again(self) -> None:
        repo, job = bump_fixture()
        expansion = deps.expand(job, culprit_of(job, outer_level), repo)
        inner = culprit_of(expansion.job, lambda c: 14.0 if c == expansion.job.bad else 10.0)
        again = deps.expand(expansion.job, inner, repo)
        self.assertIsInstance(again, deps.NotExpanded)
        self.assertIn("already", again.reason)

    def test_range_culprit_of_a_nested_job_whose_every_state_fails_to_build_is_not_expanded_again(self) -> None:
        repo, job = bump_fixture()
        expansion = deps.expand(job, culprit_of(job, outer_level), repo)
        nested = expansion.job
        level = lambda c: 14.0 if c == nested.bad else 10.0  # noqa: E731
        result = pinpoint.run_to_end(pinpoint.JobState(nested), lambda change: not change.deps,
                                     lambda change, k: pinpoint.Attempt(change, k, values=(level(change) + 0.1 * (k % 7),)))
        self.assertEqual(result.outcome, pinpoint.CULPRITS)
        (inner,) = result.culprits
        self.assertEqual((inner.parent, inner.change), (nested.good, nested.bad), "the range culprit (P, C)")
        self.assertEqual(len(expansion.dep_commits(inner)), 8)
        repo.asked.clear()
        again = deps.expand(nested, inner, repo)
        self.assertIsInstance(again, deps.NotExpanded)
        self.assertIn("nested bisect", again.reason)
        self.assertEqual(repo.asked, [], "the nested range is not read again")


class RealRollShapeTests(unittest.TestCase):
    """The files a roll moves with its pin, in the shape of this repository's real rolls."""

    def test_ghostty_next_roll_with_package_and_notices_becomes_a_nested_bisect(self) -> None:
        repo, job = bump_fixture(roll=ghostty_next_roll(up(8), comment="\n// Since u8 the prompt redraws."))
        culprit = culprit_of(job, outer_level)
        expansion = deps.expand(job, culprit, repo)
        self.assertIsInstance(expansion, deps.Expansion, getattr(expansion, "reason", ""))
        (move,) = expansion.moves
        self.assertEqual((move.pin, move.old, move.new), (deps.GHOSTTY_NEXT, up(0), up(8)))
        self.assertEqual(len(expansion.job.commits), 9)

        def nested_level(change):
            at = dict(change.deps).get(deps.GHOSTTY_NEXT)
            return 14.0 if change == culprit.change or (at and GHOSTTY_NEXT_LINE.index(at) >= 3) else 10.0

        result, _ = run(expansion.job, nested_level)
        (inner,) = result.culprits
        self.assertEqual(expansion.dep_commits(inner), ((deps.GHOSTTY_NEXT, up(3)),))

    def test_ghostty_roll_with_checksums_fork_notes_and_workflow_expands(self) -> None:
        trees = {cmux(0): tree(), cmux(1): tree(ghostty_roll(up(3, "g")))}
        repo = FakeRepo(trees, {deps.GHOSTTY: [up(i, "g") for i in range(5)]})
        (move,) = deps.moves(repo, cmux(0), cmux(1))
        self.assertEqual((move.pin, move.path), (deps.GHOSTTY, (up(1, "g"), up(2, "g"), up(3, "g"))))

    def assertNotExpanded(self, overrides: dict, reason: str, histories: dict | None = None) -> None:
        trees = {cmux(0): tree(), cmux(1): tree(overrides)}
        found = deps.moves(FakeRepo(trees, histories or {deps.GHOSTTY_NEXT: GHOSTTY_NEXT_LINE,
                                                         deps.GHOSTTY: [up(i, "g") for i in range(5)]}),
                           cmux(0), cmux(1))
        self.assertIsInstance(found, deps.NotExpanded)
        self.assertIn(reason, found.reason)

    def test_package_swift_changing_more_than_the_binary_target_is_not_expanded(self) -> None:
        self.assertNotExpanded(ghostty_next_roll(up(4), other=', path: "Other"'), "more than the GhosttyNextKit")

    def test_package_swift_pinned_at_another_commit_is_not_expanded(self) -> None:
        self.assertNotExpanded({**ghostty_next_roll(up(4)), deps.GHOSTTY_NEXT_PACKAGE: package_swift(up(5))},
                               "does not pin GhosttyNextKit at the new commit")

    def test_notices_changing_more_than_libghostty_vt_is_not_expanded(self) -> None:
        self.assertNotExpanded({**ghostty_next_roll(up(4)), deps.PACKAGE_NOTICES: notices(up(4), musl="1.2.6")},
                               "more than libghostty_vt")

    def test_link_graph_of_another_commit_is_not_expanded(self) -> None:
        self.assertNotExpanded({**ghostty_next_roll(up(4)), deps.VT_LINK_GRAPH: link_graph(up(3))},
                               "vt-link-graph.json does not move to the new commit")

    def test_ghostty_next_companion_without_its_pin_is_not_expanded(self) -> None:
        roll = ghostty_next_roll(up(4))
        del roll["ghostty-next"]
        self.assertNotExpanded(roll, "without the ghostty-next pin")

    def test_ghostty_next_companion_with_only_the_ghostty_pin_is_not_expanded(self) -> None:
        self.assertNotExpanded({"ghostty": ("commit", up(2, "g")), deps.VT_LINK_GRAPH: link_graph(up(4))},
                               "without the ghostty-next pin")

    def test_ghostty_checksums_that_drop_a_line_are_not_expanded(self) -> None:
        self.assertNotExpanded({**ghostty_roll(up(3, "g")), deps.GHOSTTYKIT_CHECKSUMS: checksums(up(3, "g"))},
                               "drops or edits a checksum")

    def test_ghostty_checksums_without_the_new_commit_are_not_expanded(self) -> None:
        self.assertNotExpanded({**ghostty_roll(up(3, "g")),
                                deps.GHOSTTYKIT_CHECKSUMS: checksums(up(0, "g"), up(2, "g"))},
                               "no checksum for the new ghostty commit")

    def test_fork_notes_without_the_ghostty_pin_are_not_expanded(self) -> None:
        self.assertNotExpanded({deps.GHOSTTY_FORK_DOC: b"# notes\n"}, "without the ghostty pin")

    def test_this_repository_s_real_rolls(self) -> None:
        """deps.moves on real roll commits of this checkout, when its history has them."""
        root = LAB.parent.parent
        rolls = {"ede77f98de926b108860ec4f855f56f6a8153e6f": deps.GHOSTTY_NEXT,
                 "57ad4a5e09a3a95996feb94a642e32078336d436": deps.GHOSTTY}
        for change, pin in rolls.items():
            probe = subprocess.run(["git", "-C", str(root), "cat-file", "-e", f"{change}^^{{commit}}"],
                                   capture_output=True, check=False)
            if probe.returncode != 0:
                # skip-owner: PL-perf-lab; expiry: 2026-11-06; tracking: handoff/followups.md "skips audit 2026-10-30"
                self.skipTest(f"{change[:11]} is not in this checkout's history")
            repo = deps.GitRepo(root, fetch=False)
            repo.dep_path = lambda pin_, url, old, new: (new,)
            with self.subTest(change=change[:11]):
                found = deps.moves(repo, f"{change}^", change)
                self.assertIsInstance(found, tuple, getattr(found, "reason", ""))
                self.assertEqual([m.pin for m in found], [pin])
                self.assertEqual(found[0].new, repo.gitlink(change, pin))


class TwoPinsAndCefTests(unittest.TestCase):
    def test_two_pins_chain_in_pin_order(self) -> None:
        trees = {cmux(0): tree(), cmux(1): tree({"ghostty": ("commit", up(2, "g")), "ghostty-next": ("commit", up(3))})}
        repo = FakeRepo(trees, {deps.GHOSTTY: [up(i, "g") for i in range(4)], deps.GHOSTTY_NEXT: GHOSTTY_NEXT_LINE})
        range_ = [pinpoint.Commit(cmux(0), stored_build=True), pinpoint.Commit(cmux(1), stored_build=True)]
        job = bisect_job(range_)
        culprit = culprit_of(job, lambda c: 10.0 if c.sha == cmux(0) else 14.0)
        expansion = deps.expand(job, culprit, repo)
        self.assertEqual([m.pin for m in expansion.moves], [deps.GHOSTTY, deps.GHOSTTY_NEXT])
        g, n = deps.GHOSTTY, deps.GHOSTTY_NEXT
        self.assertEqual([c.change for c in expansion.job.commits], [
            pinpoint.Change(cmux(0)),
            pinpoint.Change(cmux(0), ((g, up(1, "g")),)),
            pinpoint.Change(cmux(0), ((g, up(2, "g")),)),
            pinpoint.Change(cmux(0), ((g, up(2, "g")), (n, up(1)))),
            pinpoint.Change(cmux(0), ((g, up(2, "g")), (n, up(2)))),
            pinpoint.Change(cmux(1)),
        ])
        self.assertEqual(expansion.points[-1].pin, n)
        self.assertEqual(expansion.points[2].sha, up(2, "g"))

    def test_cef_pin_with_its_host_pin_expands_into_fork_commits(self) -> None:
        trees = {cmux(0): tree(), cmux(1): tree({deps.CEF_MANIFEST: manifest(up(3, "f"), sha256="b" * 64),
                                                   HOST_PIN: host_pin("b" * 64)})}
        repo = FakeRepo(trees, {deps.CEF: [up(i, "f") for i in range(5)]})
        (move,) = deps.moves(repo, cmux(0), cmux(1))
        self.assertEqual((move.pin, move.url, move.old, move.new), (deps.CEF, "https://github.com/manaflow-ai/cef.git",
                                                                    up(0, "f"), up(3, "f")))
        self.assertEqual(move.path, (up(1, "f"), up(2, "f"), up(3, "f")))

    def test_cef_re_pin_at_the_same_fork_commit_has_nothing_to_bisect(self) -> None:
        trees = {cmux(0): tree(), cmux(1): tree({deps.CEF_MANIFEST: manifest(up(0, "f"), sha256="c" * 64)})}
        found = deps.moves(FakeRepo(trees), cmux(0), cmux(1))
        self.assertIn("same fork commit", found.reason)

    def test_ghostty_next_bump_with_a_same_fork_ref_manifest_change_is_not_expanded(self) -> None:
        trees = {cmux(0): tree(), cmux(1): tree({**ghostty_next_roll(up(4)),
                                                   deps.CEF_MANIFEST: manifest(up(0, "f"), sha256="c" * 64),
                                                   HOST_PIN: host_pin("c" * 64)})}
        repo = FakeRepo(trees, {deps.GHOSTTY_NEXT: GHOSTTY_NEXT_LINE})
        found = deps.moves(repo, cmux(0), cmux(1))
        self.assertIsInstance(found, deps.NotExpanded)
        self.assertIn("same fork commit", found.reason)
        self.assertEqual(repo.asked, [])

    def test_cef_policy_change_with_the_fork_move_is_not_expanded(self) -> None:
        before = json.loads(manifest(up(0, "f")))
        after = {**json.loads(manifest(up(3, "f"))), "require_dcheck_off": True}
        trees = {cmux(0): tree({deps.CEF_MANIFEST: json.dumps(before).encode()}),
                 cmux(1): tree({**ghostty_next_roll(up(4)), deps.CEF_MANIFEST: json.dumps(after).encode()})}
        found = deps.moves(FakeRepo(trees, {deps.CEF: [up(i, "f") for i in range(5)],
                                            deps.GHOSTTY_NEXT: GHOSTTY_NEXT_LINE}), cmux(0), cmux(1))
        self.assertIsInstance(found, deps.NotExpanded)
        self.assertIn("require_dcheck_off", found.reason)

    def test_host_pin_rebuilt_from_other_host_source_is_not_expanded(self) -> None:
        trees = {cmux(0): tree(), cmux(1): tree({deps.CEF_MANIFEST: manifest(up(3, "f"), sha256="b" * 64),
                                                   HOST_PIN: host_pin("b" * 64, crate_tree="t2")})}
        found = deps.moves(FakeRepo(trees, {deps.CEF: [up(i, "f") for i in range(5)]}), cmux(0), cmux(1))
        self.assertIn("crate_tree", found.reason)

    def test_host_pin_not_built_against_the_new_cef_is_not_expanded(self) -> None:
        trees = {cmux(0): tree(), cmux(1): tree({deps.CEF_MANIFEST: manifest(up(3, "f"), sha256="b" * 64),
                                                   HOST_PIN: host_pin("d" * 64)})}
        found = deps.moves(FakeRepo(trees, {deps.CEF: [up(i, "f") for i in range(5)]}), cmux(0), cmux(1))
        self.assertIn("not built against the new CEF artifact", found.reason)

    def test_host_pin_alone_is_not_a_cef_roll(self) -> None:
        trees = {cmux(0): tree(), cmux(1): tree({HOST_PIN: b"{}"})}
        self.assertIn("without the CEF pin", deps.moves(FakeRepo(trees), cmux(0), cmux(1)).reason)

    def test_cef_fork_repository_change_is_not_one_history(self) -> None:
        trees = {cmux(0): tree(), cmux(1): tree({deps.CEF_MANIFEST: manifest(up(1, "f"), repo="other/cef")})}
        self.assertIn("no single history", deps.moves(FakeRepo(trees), cmux(0), cmux(1)).reason)


class BuildIdTests(unittest.TestCase):
    def test_plain_commit_keeps_its_sha_and_dependency_states_get_their_own_key(self) -> None:
        plain = pinpoint.Change(cmux(1))
        a = pinpoint.Change(cmux(1), ((deps.GHOSTTY_NEXT, up(3)),))
        b = pinpoint.Change(cmux(1), ((deps.GHOSTTY_NEXT, up(4)),))
        self.assertEqual(deps.build_id(plain), cmux(1))
        self.assertRegex(deps.build_id(a), r"^[0-9a-f]{40}$")
        self.assertNotEqual(deps.build_id(a), deps.build_id(b))
        self.assertNotEqual(deps.build_id(a), cmux(1))
        self.assertEqual(deps.build_id(a), deps.build_id(pinpoint.Change(cmux(1), ((deps.GHOSTTY_NEXT, up(3)),))))


class GitRepoTests(unittest.TestCase):
    """GitRepo against real repositories: a dependency with a first-parent line and a side branch, and a cmux
    repository whose commits move a gitlink and the CEF manifest."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.env = {**os.environ, "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@t", "GIT_COMMITTER_NAME": "t",
                    "GIT_COMMITTER_EMAIL": "t@t", "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
        self.dep = root / "ghostty-next"
        self.git(self.dep.parent, "init", "-q", "-b", "main", str(self.dep))
        self.line = [self.commit(self.dep, f"u{i}") for i in range(6)]
        self.git(self.dep, "checkout", "-q", "-b", "side", self.line[2])
        self.side = self.commit(self.dep, "side")
        self.git(self.dep, "checkout", "-q", "main")
        self.cmux = root / "cmux"
        self.git(root, "init", "-q", "-b", "main", str(self.cmux))
        (self.cmux / ".gitmodules").write_text(gitmodules("ghostty-next").decode())
        (self.cmux / "scripts" / "cmux-next").mkdir(parents=True)
        self.shas = []
        for gitlink, extra in ((self.line[1], None), (self.line[4], None), (self.line[4], "Sources.swift")):
            self.git(self.cmux, "update-index", "--add", "--cacheinfo", f"160000,{gitlink},ghostty-next")
            if extra:
                (self.cmux / extra).write_text("x")
            self.shas.append(self.commit(self.cmux, f"cmux {len(self.shas)}"))
        self.repo = deps.GitRepo(self.cmux, {deps.GHOSTTY_NEXT: self.dep}, fetch=False)

    def git(self, where: Path, *args: str) -> str:
        return subprocess.run(["git", "-C", str(where), *args], check=True, capture_output=True, env=self.env,
                              text=True).stdout.strip()

    def commit(self, where: Path, message: str) -> str:
        if (where / ".gitmodules").exists() or where == getattr(self, "cmux", None):
            self.git(where, "add", "-A", "--", ".", ":!ghostty-next")
        self.git(where, "commit", "-q", "--allow-empty", "-m", message)
        return self.git(where, "rev-parse", "HEAD")

    def test_reads_the_diff_gitlinks_and_files(self) -> None:
        c0, c1, c2 = self.shas
        self.assertEqual(self.repo.changed_paths(c0, c1), ("ghostty-next",))
        self.assertEqual(set(self.repo.changed_paths(c1, c2)), {"Sources.swift"})
        self.assertEqual((self.repo.gitlink(c0, "ghostty-next"), self.repo.gitlink(c1, "ghostty-next")),
                         (self.line[1], self.line[4]))
        self.assertIsNone(self.repo.gitlink(c0, ".gitmodules"))
        self.assertIn(b"ghostty-next", self.repo.read_file(c0, ".gitmodules"))
        self.assertIsNone(self.repo.read_file(c0, deps.CEF_MANIFEST))

    def test_dependency_paths_forward_back_and_nonlinear(self) -> None:
        url = "unused"
        self.assertEqual(self.repo.dep_path(deps.GHOSTTY_NEXT, url, self.line[1], self.line[4]), tuple(self.line[2:5]))
        self.assertEqual(self.repo.dep_path(deps.GHOSTTY_NEXT, url, self.line[4], self.line[1]),
                         (self.line[3], self.line[2], self.line[1]))
        self.assertIsNone(self.repo.dep_path(deps.GHOSTTY_NEXT, url, self.line[4], self.side))
        with self.assertRaises(deps.DepsError):
            self.repo.dep_path(deps.GHOSTTY_NEXT, url, self.line[1], "f" * 40)

    def test_moves_of_a_real_bump_and_the_cli(self) -> None:
        c0, c1, c2 = self.shas
        (move,) = deps.moves(self.repo, c0, c1)
        self.assertEqual(move.path, tuple(self.line[2:5]))
        self.assertIsInstance(deps.moves(self.repo, c1, c2), deps.NotExpanded)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            code = deps.main(["moves", "--repo", str(self.cmux), "--parent", c0, "--change", c1, "--no-fetch",
                              "--dep-dir", f"ghostty-next={self.dep}"])
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(out.getvalue())["moves"][0]["path"], self.line[2:5])
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(deps.main(["moves", "--repo", str(self.cmux), "--parent", c1, "--change", c2,
                                        "--no-fetch", "--dep-dir", f"ghostty-next={self.dep}"]), 1)


if __name__ == "__main__":
    unittest.main()
