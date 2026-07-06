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

    if FAILURES:
        print(f"\n{len(FAILURES)} failure(s)")
        sys.exit(1)
    print("\nall ios testflight external distribution tests passed")


if __name__ == "__main__":
    main()
