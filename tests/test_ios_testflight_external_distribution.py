#!/usr/bin/env python3
"""Tests for ios/scripts/asc_assign_external_testflight_group.py selection logic."""

import importlib.util
import os
import sys

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPT = os.path.join(REPO_ROOT, "ios", "scripts", "asc_assign_external_testflight_group.py")

FAILURES = []


def _check(condition, message):
    if condition:
        print(f"ok: {message}")
    else:
        FAILURES.append(message)
        print(f"FAIL: {message}")


def _load_module():
    spec = importlib.util.spec_from_file_location("asc_assign_external_testflight_group", SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load module from {SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _group(group_id, name, is_internal, has_access_to_all_builds=False):
    return {
        "id": group_id,
        "name": name,
        "is_internal": is_internal,
        "has_access_to_all_builds": has_access_to_all_builds,
    }


def main():
    module = _load_module()
    real_time = module.time.time
    real_sleep = module.time.sleep
    module._token = lambda: "jwt"

    groups = [
        _group("internal-1", "cmux beta", True),
        _group("external-1", "Founders Edition", False),
    ]
    chosen = module._select_group(groups, "", "")
    _check(chosen["id"] == "external-1", "auto-select picks the single external group")

    chosen = module._select_group(groups, "", "Founders Edition")
    _check(chosen["id"] == "external-1", "explicit external group name resolves correctly")

    chosen = module._select_group(groups, "external-1", "")
    _check(chosen["id"] == "external-1", "explicit external group id resolves correctly")

    try:
        module._select_group(groups, "missing-group", "")
    except RuntimeError as exc:
        _check("no beta group found for id missing-group" in str(exc), "missing group id fails loudly")
    else:
        _check(False, "missing group id fails loudly")

    try:
        module._select_group(groups, "", "Missing Group")
    except RuntimeError as exc:
        _check("no beta group found named 'Missing Group'" in str(exc), "missing group name fails loudly")
    else:
        _check(False, "missing group name fails loudly")

    try:
        module._select_group(groups, "", "cmux beta")
    except RuntimeError as exc:
        _check("internal" in str(exc), "explicit internal group is rejected")
    else:
        _check(False, "explicit internal group is rejected")

    ambiguous_groups = groups + [_group("external-2", "VIP Founders", False)]
    try:
        module._select_group(ambiguous_groups, "", "")
    except RuntimeError as exc:
        _check("multiple external beta groups" in str(exc), "ambiguous external groups fail loudly")
    else:
        _check(False, "ambiguous external groups fail loudly")

    try:
        module._select_group([_group("internal-1", "cmux beta", True)], "", "")
    except RuntimeError as exc:
        _check("no external beta groups" in str(exc), "missing external group fails loudly")
    else:
        _check(False, "missing external group fails loudly")

    submissions = []

    def fake_submit(token, build_id):
        submissions.append((token, build_id))

    module._submit_beta_review = fake_submit
    module._find_active_review_submission_on_sibling_build = lambda token, build_id: None
    module._build_beta_detail = lambda token, build_id: {
        "external_build_state": "READY_FOR_BETA_SUBMISSION",
        "internal_build_state": "READY_FOR_BETA_TESTING",
    }
    module._beta_review_submission = lambda token, build_id: None
    module._ensure_external_review_submission("jwt", "build-1", "42", real_time() + 1, 1)
    _check(submissions == [("jwt", "build-1")], "ready-for-submission builds create a beta review submission")

    submissions.clear()
    module._beta_review_submission = lambda token, build_id: {
        "id": "submission-1",
        "beta_review_state": "WAITING_FOR_REVIEW",
    }
    module._ensure_external_review_submission("jwt", "build-1", "42", real_time() + 1, 1)
    _check(not submissions, "existing beta review submissions are not duplicated")

    module._build_beta_detail = lambda token, build_id: {
        "external_build_state": "READY_FOR_BETA_TESTING",
        "internal_build_state": "READY_FOR_BETA_TESTING",
    }
    module._beta_review_submission = lambda token, build_id: None
    module._ensure_external_review_submission("jwt", "build-1", "42", real_time() + 1, 1)
    _check(not submissions, "ready-for-testing builds do not resubmit beta review")

    polls = {"count": 0}

    def transient_detail(token, build_id):
        polls["count"] += 1
        if polls["count"] == 1:
            return {
                "external_build_state": "",
                "internal_build_state": "READY_FOR_BETA_TESTING",
            }
        return {
            "external_build_state": "READY_FOR_BETA_SUBMISSION",
            "internal_build_state": "READY_FOR_BETA_TESTING",
        }

    module._build_beta_detail = transient_detail
    module._beta_review_submission = lambda token, build_id: None
    module.time.sleep = lambda seconds: None
    module._ensure_external_review_submission("jwt", "build-1", "42", real_time() + 1, 1)
    _check(
        submissions == [("jwt", "build-1")],
        "transient empty external state retries until beta review submission is possible",
    )

    submissions.clear()
    module._build_beta_detail = lambda token, build_id: {
        "external_build_state": "READY_FOR_BETA_SUBMISSION",
        "internal_build_state": "READY_FOR_BETA_TESTING",
    }
    module._find_active_review_submission_on_sibling_build = lambda token, build_id: {
        "build_id": "build-2",
        "submission_id": "submission-2",
        "beta_review_state": "WAITING_FOR_REVIEW",
        "pre_release_version": "1.0.4",
    }
    module._ensure_external_review_submission("jwt", "build-1", "42", real_time() + 1, 1)
    _check(
        not submissions,
        "same-version sibling builds already in beta review are left alone",
    )

    module._build_beta_detail = lambda token, build_id: {
        "external_build_state": "",
        "internal_build_state": "READY_FOR_BETA_TESTING",
    }
    module._ensure_external_review_submission("jwt", "build-1", "42", real_time() + 1, 1)
    _check(
        not submissions,
        "same-version sibling reviews short-circuit even before external state settles",
    )

    module._find_active_review_submission_on_sibling_build = lambda token, build_id: None
    try:
        module._beta_review_submission = lambda token, build_id: {
            "id": "submission-1",
            "beta_review_state": "REJECTED",
        }
        module._ensure_external_review_submission("jwt", "build-1", "42", real_time() + 1, 1)
    except RuntimeError as exc:
        _check(
            "unexpected betaReviewState=REJECTED" in str(exc),
            "rejected beta review submissions fail loudly",
        )
    else:
        _check(False, "rejected beta review submissions fail loudly")

    submissions.clear()
    module._build_beta_detail = lambda token, build_id: {
        "external_build_state": "READY_FOR_BETA_SUBMISSION",
        "internal_build_state": "READY_FOR_BETA_TESTING",
    }
    calls = {"count": 0}

    def sibling_after_submit_failure(token, build_id):
        calls["count"] += 1
        if calls["count"] >= 2:
            return {
                "build_id": "build-2",
                "submission_id": "submission-2",
                "beta_review_state": "WAITING_FOR_REVIEW",
                "pre_release_version": "1.0.4",
            }
        return None

    module._find_active_review_submission_on_sibling_build = sibling_after_submit_failure
    module._beta_review_submission = lambda token, build_id: None
    module._submit_beta_review = lambda token, build_id: (_ for _ in ()).throw(RuntimeError("submit failed"))
    module._ensure_external_review_submission("jwt", "build-1", "42", real_time() + 1, 1)
    _check(
        not submissions,
        "submit races against a sibling review are treated as pending instead of failing",
    )

    module._submit_beta_review = fake_submit
    module._find_active_review_submission_on_sibling_build = lambda token, build_id: None
    module._beta_review_submission = lambda token, build_id: None
    module.time.time = lambda: real_time() + 999
    module._build_beta_detail = lambda token, build_id: {
        "external_build_state": "BETA_REJECTED",
        "internal_build_state": "READY_FOR_BETA_TESTING",
    }
    try:
        module._ensure_external_review_submission("jwt", "build-1", "42", real_time() - 1, 1)
    except RuntimeError as exc:
        _check(
            "unexpected externalBuildState=BETA_REJECTED" in str(exc),
            "unexpected external state without submission fails loudly",
        )
    else:
        _check(False, "unexpected external state without submission fails loudly")

    module.time.time = real_time
    module.time.sleep = real_sleep

    if FAILURES:
        print(f"\n{len(FAILURES)} failure(s)")
        sys.exit(1)
    print("\nall ios testflight external distribution tests passed")


if __name__ == "__main__":
    main()
