#!/usr/bin/env python3
"""A CI script that ends a command at its time limit ends the command's whole tree, not only the process it started.

`subprocess.run(..., timeout=N)` kills only the process it started on a timeout: a child that process started keeps
running. On 2026-11-12 (cmux#41752 review F1) a timed-out `git submodule update` left its `git clone` and transport
running, and the retry over the same checkout failed at once with "Unable to find current revision in submodule
path". The fixed shape is scripts/ci/ci_process_tree.py's run_bounded (the command in its own session; on a
timeout its process group and every descendant are stopped and reaped), or a Popen with start_new_session=True whose
caller stops the group itself.

This test reads every scripts/ci/*.py and finds each `subprocess.run`, `check_output`, `call` or `check_call` with a
`timeout=` and no `start_new_session=`, and each `subprocess.Popen` with no `start_new_session=`,
`process_group=` or `preexec_fn=`. The ones already there are listed in ALLOWED by "file.py:function:kind"; the
list may only shrink: a new one fails, and a listed one that no longer matches fails until it is dropped.
"""
from __future__ import annotations

import ast
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts" / "ci"
RUNS = {"run", "check_output", "call", "check_call"}
SESSION_KEYWORDS = {"start_new_session", "process_group", "preexec_fn"}

# Calls that predate this check, by "file.py:function:kind" (kind: run, a subprocess.run-like call with a timeout;
# popen, a Popen outside its own session). Most are short git, ps or tool calls with no children of their own; each
# moves to run_bounded (or its own session) when it is next touched.
ALLOWED = frozenset({
    "base_merge_warning.py:gh:run",
    "base_merge_warning.py:git:run",
    "base_merge_warning.py:is_ancestor:run",
    "base_red_excuse.py:git:run",
    "base_red_excuse.py:git_cache:run",
    "base_red_excuse.py:github_token:run",
    "base_red_excuse.py:run:run",
    "ci_process_tree.py:process_tree:run",
    "cmux_next_cloud_pair_proof.py:run:run",
    "cmux_next_pair_e2e.py:__init__:popen",
    "cmux_next_pair_e2e.py:_forget_tag_files:run",
    "cmux_next_pair_e2e.py:_security:run",
    "cmux_next_pair_e2e.py:forget_keychain:run",
    "cmux_next_pair_e2e.py:main:run",
    "cmux_next_pair_e2e.py:no_answer_evidence:run",
    "cmux_next_pair_e2e.py:run_bounded:run",
    "cmux_next_pair_e2e.py:scanner:run",
    "cmux_next_push_attribution.py:first_parent_chain:run",
    "cmux_next_push_attribution.py:pull_requests_for_commit:run",
    "cmux_next_route.py:base_workflow_text:run",
    "cmux_next_route.py:git:run",
    "cmux_tui_publisher_testing.py:jobs:run",
    "cmux_tui_superseded_push.py:asks_for_daemon_tests:run",
    "cmux_tui_superseded_push.py:ls_remote:run",
    "cmux_tui_tree_key.py:git:run",
    "cmux_tui_tree_key.py:make_tree:run",
    "cmux_tui_tree_key.py:tree_key:run",
    "cua_signed_host_check.py:probe:run",
    "cua_signed_host_check.py:run:run",
    "delta_since_green.py:_git:run",
    "dev_landing_place.py:git:run",
    "dev_release_product_reuse.py:download:run",
    "find_admitted_build.py:gh_api:run",
    "fleet_admission_transport.py:verify_authority:run",
    "fresh_home_launch_smoke.py:copy_app:run",
    "fresh_home_launch_smoke.py:copy_app_from_dmg:run",
    "fresh_home_launch_smoke.py:defaults:run",
    "fresh_home_launch_smoke.py:detach:run",
    "fresh_home_launch_smoke.py:gui_session_problem:run",
    "fresh_home_launch_smoke.py:screenshot:run",
    "fresh_home_launch_smoke.py:system_log_errors:run",
    "fresh_home_launch_smoke.py:terminal_host_pids:run",
    "fresh_home_launch_smoke.py:user_processes:run",
    "git_fetch_retry.py:gitmodules_paths:run",
    "git_tree.py:_blob:popen",
    "git_tree.py:_git:run",
    "glaeda_log.py:cached_job_log:run",
    "guard_attribution.py:run_steps:run",
    "guard_attribution.py:verified_fixes:run",
    "hung_test_watchdog.py:sample_stacks:run",
    "ios_internal_builder.py:_git_has_builder_script:run",
    "ios_internal_builder.py:changed_files:run",
    "ios_internal_builder.py:tick:run",
    "ios_internal_notes.py:resolve:run",
    "job_input_fingerprint.py:git:run",
    "job_input_fingerprint.py:object_ids:run",
    "job_input_fingerprint.py:product_inputs:run",
    "main_fix_evidence.py:run:popen",
    "measure-r2-artifact-run.py:gh_json:run",
    "measure-r2-artifact-run.py:log_for_job:run",
    "next_batch.py:freeze_check:run",
    "nightly_builder.py:_heads:run",
    "nightly_builder.py:_notify:run",
    "nightly_next_supersede.py:ls_remote_sha:run",
    "nightly_next_train_drive.py:one:run",
    "nightly_now.py:ls_remote_sha:run",
    "nightly_publish_guard.py:__call__:run",
    "nightly_publish_guard.py:__init__:run",
    "nightly_publish_guard.py:build_commit:run",
    "nightly_publish_guard.py:fetch:run",
    "nightly_publish_guard.py:read_list:run",
    "nightly_release_notes.py:request:run",
    "node_product_cache.py:github_metadata:run",
    "owned_build_state.py:bucket_compare:run",
    "owned_build_state.py:submodules:run",
    "owned_spm_scratch.py:bonsplit_commit:run",
    "owned_spm_scratch.py:source_files:run",
    "owned_spm_scratch.py:toolchain_parts:run",
    "package_interface_fingerprint.py:build_interface:run",
    "package_interface_fingerprint.py:extract_base:popen",
    "peer_product_source.py:lan_fetch_exact:run",
    "post_edit_checks.py:main:run",
    "pr_media_ocr_tesseract.py:frames:run",
    "pr_media_ocr_tesseract.py:read_picture:run",
    "pr_media_privacy.py:local_names:run",
    "pr_media_privacy.py:ocr_binary:run",
    "pr_media_privacy.py:ocr_file:run",
    "pr_red_checks_comment.py:git_head:run",
    "pr_status.py:app_token:run",
    "projection_check.py:journey:run",
    "prune_media_derived_data.py:executable:run",
    "prune_media_derived_data.py:open_paths:run",
    "publish-release-assets.py:_request:run",
    "r2_cas.py:runner_worker_pid:run",
    "react_doctor_gate.py:scan:run",
    "rebuild_mirror.py:candidate:run",
    "relaunch_restore_check.py:cmux:run",
    "relaunch_restore_check.py:process_home:run",
    "release_thanks.py:fetch_authors:run",
    "restore-r2-artifact.py:actions_identity:run",
    "restore-r2-artifact.py:download:run",
    "restore-r2-artifact.py:github_metadata:run",
    "reuse_app_host_products.py:read:run",
    "reuse_app_host_products.py:switch_root:run",
    "reuse_package_results.py:call:run",
    "risk_tier.py:merge_base_of:run",
    "risk_tier.py:recent_reverts:run",
    "seed_decide.py:gh_api:run",
    "seed_decide.py:warm_tier:run",
    "seed_derived_data.py:lineage:run",
    "stable_next_ui_journey.py:cmux:run",
    "stable_next_ui_journey.py:login_keychain:run",
    "stable_next_ui_journey.py:shot:run",
    "stable_next_ui_journey.py:start_recording:popen",
    "swiftpm_build_metrics.py:run_command:popen",
    "swiftpm_prefetch_binary_artifacts.py:curl_download:run",
    "swiftpm_prefetch_binary_artifacts.py:dump_package:run",
    "swiftpm_prefetch_binary_artifacts.py:pin_manifests:run",
    "swiftpm_test_product.py:read:run",
    "verify-link-root-boundary.py:run_root:run",
    "verify-r2-canary.py:metadata:run",
    "verify-r2-canary.py:request:run",
    "warm_distance.py:collect:run",
    "warm_distance.py:fetch_bases:run",
    "warm_distance.py:git:run",
    "web_coalesce.py:branch_tip:run",
    "xcode_build_timeline.py:read_log:run",
    "xcode_pin_audit.py:version:run",
    "xcodebuild_noninteractive.py:app_host_pids:run",
    "xcodebuild_noninteractive.py:compiler_process_snapshot:run",
    "xcodebuild_noninteractive.py:sample_app_host:run",
    "xcodebuild_noninteractive.py:sample_compilers:run",
})


def scan(directory: Path = SCRIPTS) -> set[str]:
    """{"file.py:function:kind"} for each call in DIRECTORY's scripts that can leave a child running."""
    found: set[str] = set()
    for path in sorted(directory.glob("*.py")):
        if path.name.startswith("test_"):
            continue
        tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))

        def visit(node: ast.AST, where: str) -> None:
            for child in ast.iter_child_nodes(node):
                inner = child.name if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef)) else where
                if isinstance(child, ast.Call) and isinstance(child.func, ast.Attribute) \
                        and isinstance(child.func.value, ast.Name) and child.func.value.id == "subprocess":
                    keywords = {keyword.arg for keyword in child.keywords}
                    if child.func.attr in RUNS and "timeout" in keywords and not keywords & SESSION_KEYWORDS:
                        found.add(f"{path.name}:{where or '<module>'}:run")
                    elif child.func.attr == "Popen" and not keywords & SESSION_KEYWORDS:
                        found.add(f"{path.name}:{where or '<module>'}:popen")
                visit(child, inner)

        visit(tree, "")
    return found


class TimeoutKillsTree(unittest.TestCase):
    def test_no_new_script_ends_only_the_process_it_started(self):
        unlisted = sorted(scan() - ALLOWED)
        self.assertEqual(unlisted, [], "these calls stop only the process they started on a timeout, so its children "
                         "keep running: use ci_process_tree.run_bounded, or Popen(start_new_session=True) and stop "
                         "the group (cmux#41752 review F1)")

    def test_the_allowlist_only_shrinks(self):
        gone = sorted(ALLOWED - scan())
        self.assertEqual(gone, [], "ALLOWED lists calls that are fixed or gone: drop them")

    def test_the_fixed_guards_are_not_allowed(self):
        """The three the cmux#41752 review reached: a timeout there stops the whole tree."""
        for key in ("submodule_forward_only.py:run:run", "generated_files_guard.py:run_check:run",
                    "car_guards.py:run_one:run"):
            self.assertNotIn(key, ALLOWED | scan())

    def test_the_detector_tells_the_shapes_apart(self):
        cases = {
            "bad_run.py": "import subprocess\ndef f():\n    subprocess.run(['x'], timeout=1)\n",
            "bad_popen.py": "import subprocess\ndef g():\n    subprocess.Popen(['x'])\n",
            "good_session.py": "import subprocess\ndef h():\n    subprocess.Popen(['x'], start_new_session=True)\n",
            "good_no_timeout.py": "import subprocess\ndef i():\n    subprocess.run(['x'])\n",
            "good_bounded.py": "import ci_process_tree\ndef j():\n    ci_process_tree.run_bounded(['x'], timeout=1)\n",
        }
        with tempfile.TemporaryDirectory() as tmp:
            for name, text in cases.items():
                (Path(tmp) / name).write_text(text, encoding="utf-8")
            self.assertEqual(sorted(scan(Path(tmp))), ["bad_popen.py:g:popen", "bad_run.py:f:run"])


# The second shape (cmux#41767 review F1): a SIGTERM to a process group whose SIGKILL is sent only when the leader
# has not exited yet. A child that ignores SIGTERM and holds no pipe outlives the leader, and nothing waits on it, so
# the group's SIGKILL must come after the grace period whether or not the leader is gone. Scanned in every directory
# of scripts a CI job or the pre-push hook runs; a function that sends SIGTERM to a group passes when it also sends
# SIGKILL to it unconditionally (not only inside the `except TimeoutExpired` of the leader's wait, or a branch the
# SIGTERM is not in), or in a (SIGTERM, SIGKILL) loop that leaves early only when the group is gone.
GROUP_DIRECTORIES = ("scripts/ci", "scripts/cmux-next", ".github/scripts")
GROUP_ALLOWED: frozenset[str] = frozenset()
LOOKUP_ERRORS = {"ProcessLookupError", "PermissionError", "OSError"}


def _signal(node: ast.AST, name: str) -> bool:
    return isinstance(node, ast.Attribute) and node.attr == name and isinstance(node.value, ast.Name) \
        and node.value.id == "signal"


def _catches(handler: ast.ExceptHandler, names: set[str]) -> bool:
    return handler.type is not None and any(
        (isinstance(n, ast.Name) and n.id in names) or (isinstance(n, ast.Attribute) and n.attr in names)
        for n in ast.walk(handler.type))


def scan_group_kills(root: Path = ROOT, directories: tuple[str, ...] = GROUP_DIRECTORIES) -> set[str]:
    """{"file.py:function"} for each function that SIGTERMs a process group and SIGKILLs it only if the leader
    lives on."""
    found: set[str] = set()
    for directory in directories:
        for path in sorted((root / directory).glob("*.py")):
            if path.name.startswith("test_"):
                continue
            tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
            parents = {child: node for node in ast.walk(tree) for child in ast.iter_child_nodes(node)}

            def above(node: ast.AST):
                while node in parents:
                    node = parents[node]
                    yield node

            terms: dict[ast.AST, list[ast.Call]] = {}
            kills: dict[ast.AST, list[ast.Call]] = {}
            loops: set[ast.AST] = set()
            for call in ast.walk(tree):
                if not (isinstance(call, ast.Call) and isinstance(call.func, ast.Attribute)
                        and call.func.attr == "killpg" and isinstance(call.func.value, ast.Name)
                        and call.func.value.id == "os" and len(call.args) == 2):
                    continue
                function = next((a for a in above(call) if isinstance(a, (ast.FunctionDef, ast.AsyncFunctionDef))),
                                None)
                if function is None:
                    continue
                sig = call.args[1]
                loop = next((a for a in above(call) if isinstance(a, ast.For) and isinstance(a.iter, ast.Tuple)
                             and isinstance(a.target, ast.Name) and isinstance(sig, ast.Name)
                             and a.target.id == sig.id), None)
                if loop is not None:
                    if any(_signal(e, "SIGTERM") for e in loop.iter.elts):
                        terms.setdefault(function, []).append(call)
                        breaks = [b for b in ast.walk(loop) if isinstance(b, ast.Break)]
                        if any(_signal(e, "SIGKILL") for e in loop.iter.elts) and all(
                                any(isinstance(a, ast.ExceptHandler) and _catches(a, LOOKUP_ERRORS) for a in above(b))
                                for b in breaks):
                            loops.add(function)
                elif _signal(sig, "SIGTERM"):
                    terms.setdefault(function, []).append(call)
                elif _signal(sig, "SIGKILL"):
                    kills.setdefault(function, []).append(call)

            def guards(node: ast.AST, function: ast.AST) -> list[ast.AST]:
                out = []
                for a in above(node):
                    if a is function:
                        break
                    if (isinstance(a, ast.ExceptHandler) and _catches(a, {"TimeoutExpired"})) \
                            or isinstance(a, (ast.If, ast.While)):
                        out.append(a)
                return out

            for function, term_calls in terms.items():
                fine = function in loops or any(
                    all(all(g in set(above(term)) for g in guards(kill, function)) for term in term_calls)
                    for kill in kills.get(function, []))
                if not fine:
                    found.add(f"{path.name}:{function.name}")
    return found


class GroupKillAfterGrace(unittest.TestCase):
    def test_no_script_sigkills_a_group_only_while_its_leader_lives(self):
        unlisted = sorted(scan_group_kills() - GROUP_ALLOWED)
        self.assertEqual(unlisted, [], "these SIGTERM a process group and SIGKILL it only if the leader has not "
                         "exited, so a child that ignores SIGTERM outlives them: SIGKILL the group after the grace "
                         "period whether or not the leader is gone (cmux#41767 review F1)")

    def test_the_group_allowlist_only_shrinks(self):
        self.assertEqual(sorted(GROUP_ALLOWED - scan_group_kills()), [])

    def test_the_detector_tells_the_group_shapes_apart(self):
        head = "import os, signal, subprocess\n"
        cases = {
            "bad_except.py": head + "def a(p):\n    os.killpg(p.pid, signal.SIGTERM)\n    try:\n"
                             "        p.wait(timeout=5)\n    except subprocess.TimeoutExpired:\n"
                             "        os.killpg(p.pid, signal.SIGKILL)\n",
            "bad_loop.py": head + "def b(p):\n    for sig in (signal.SIGTERM, signal.SIGKILL):\n"
                           "        os.killpg(p.pid, sig)\n        try:\n            p.wait(timeout=5)\n"
                           "            break\n        except subprocess.TimeoutExpired:\n            pass\n",
            "bad_term_only.py": head + "def c(p):\n    os.killpg(p.pid, signal.SIGTERM)\n    p.wait()\n",
            "good_always.py": head + "def d(p):\n    os.killpg(p.pid, signal.SIGTERM)\n    try:\n"
                              "        p.wait(timeout=5)\n    except subprocess.TimeoutExpired:\n        pass\n"
                              "    os.killpg(p.pid, signal.SIGKILL)\n",
            "good_loop.py": head + "def e(p):\n    for sig in (signal.SIGTERM, signal.SIGKILL):\n        try:\n"
                            "            os.killpg(p.pid, sig)\n        except ProcessLookupError:\n"
                            "            break\n        try:\n            p.wait(timeout=5)\n"
                            "        except subprocess.TimeoutExpired:\n            pass\n",
        }
        with tempfile.TemporaryDirectory() as tmp:
            (Path(tmp) / "d").mkdir()
            for name, text in cases.items():
                (Path(tmp) / "d" / name).write_text(text, encoding="utf-8")
            self.assertEqual(sorted(scan_group_kills(Path(tmp), ("d",))),
                             ["bad_except.py:a", "bad_loop.py:b", "bad_term_only.py:c"])


if __name__ == "__main__":
    unittest.main()
