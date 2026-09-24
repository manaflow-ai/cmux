#!/usr/bin/env python3

import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace

ROOT = Path(__file__).parents[1]
SCRIPT = ROOT / "scripts/ci/app_host_result_accounting.py"
SPEC = importlib.util.spec_from_file_location("app_host_result_accounting", SCRIPT)
accounting = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(accounting)


def test_enumeration_uses_built_bundle_identifiers() -> None:
    data = {
        "values": [
            {
                "name": "Test Plan",
                "children": [
                    {
                        "name": "cmuxTests",
                        "children": [
                            {
                                "name": "FooTests",
                                "children": [
                                    {"name": "testOne()"},
                                    {"name": "testTwo()"},
                                ],
                            },
                            {
                                "name": "Swift Display Suite",
                                "children": [
                                    {
                                        "name": "nested suite",
                                        "children": [
                                            {"name": "modern test"},
                                        ],
                                    }
                                ],
                            },
                        ],
                    }
                ],
            }
        ]
    }
    assert accounting.parse_enumeration(data) == {
        "FooTests/testOne()",
        "FooTests/testTwo()",
        "Swift Display Suite/nested suite/modern test",
    }


def test_enumeration_accepts_explicit_flat_identifiers() -> None:
    data = {
        "values": [
            {
                "children": [
                    {"identifier": "cmuxTests/FooTests/testOne()"},
                    {"identifier": "cmuxTests/ModernSuite/modern test"},
                ]
            }
        ]
    }
    assert accounting.parse_enumeration(data) == {
        "FooTests/testOne()",
        "ModernSuite/modern test",
    }


def test_typed_results_cover_xctest_and_swift_testing_the_same_way() -> None:
    data = {
        "testNodes": [
            {
                "nodeType": "Test Suite",
                "name": "FooTests",
                "result": "Failed",
                "children": [
                    {
                        "nodeType": "Test Case",
                        "name": "testLegacy()",
                        "nodeIdentifier": "FooTests/testLegacy()",
                        "result": "Failed",
                    },
                    {
                        "nodeType": "Test Case",
                        "name": "modern test",
                        "nodeIdentifier": "ModernSuite/modern test",
                        "result": "Passed",
                    },
                ],
            }
        ]
    }
    assert accounting.parse_xcresult_tests(data) == {
        "FooTests/testLegacy()": "Failed",
        "ModernSuite/modern test": "Passed",
    }


def test_selector_index_preserves_suite_and_exact_test_matching() -> None:
    inventory = {
        "FooTests/testOne()",
        "FooTests/Nested/testTwo()",
        "BarTests/testThree()",
    }

    index = accounting.inventory_selector_index(inventory)
    assert index["FooTests"] == {
        "FooTests/testOne()",
        "FooTests/Nested/testTwo()",
    }
    assert index["FooTests/Nested"] == {"FooTests/Nested/testTwo()"}
    assert index["FooTests/testOne"] == {"FooTests/testOne()"}

    selected, missing = accounting.selected_inventory(
        inventory,
        ["-only-testing:cmuxTests/FooTests", "BarTests/testThree()", "MissingSuite"],
    )
    assert selected == inventory
    assert missing == ["MissingSuite"]


def test_known_failure_is_tolerated_but_new_failure_blocks() -> None:
    inventory = {"FooTests/testBad()", "BarTests/testGood()"}
    selectors = ["FooTests", "BarTests"]
    results = {
        "FooTests/testBad()": "Failed",
        "BarTests/testGood()": "Passed",
    }
    complete_log = "** TEST FAILED **\n"

    passed, messages = accounting.check_run(
        inventory=inventory,
        selectors=selectors,
        results=results,
        known={"FooTests/testBad()": {"classification": "test bug"}},
        log_text=complete_log,
        xcode_status=65,
    )
    assert passed is True
    assert any("RATCHET_KNOWN_FAILURE FooTests/testBad()" in line for line in messages)

    passed, messages = accounting.check_run(
        inventory=inventory,
        selectors=selectors,
        results=results,
        known={},
        log_text=complete_log,
        xcode_status=65,
    )
    assert passed is False
    assert "RATCHET_NEW_FAILURE FooTests/testBad()" in messages


def test_zero_matching_selector_never_passes() -> None:
    passed, messages = accounting.check_run(
        inventory={"FooTests/testOne()"},
        selectors=["MissingSuite"],
        results={"FooTests/testOne()": "Passed"},
        known={},
        log_text="** TEST SUCCEEDED **\n",
        xcode_status=0,
    )
    assert passed is False
    assert messages == ["selector matched zero built tests: MissingSuite"]


def test_missing_selected_test_result_never_passes() -> None:
    passed, messages = accounting.check_run(
        inventory={"FooTests/testOne()", "BarTests/testTwo()"},
        selectors=["FooTests", "BarTests"],
        results={"FooTests/testOne()": "Passed"},
        known={},
        log_text="",
        xcode_status=0,
    )
    assert passed is False
    assert messages == [
        "typed xcresult is incomplete: 1 selected Test Case(s) have no terminal result",
        "missing typed test result: BarTests/testTwo()",
    ]


def test_incomplete_run_still_names_the_failures_it_recorded() -> None:
    """A shard with one missing result must still report what actually failed.

    On main's full suite at f3d204a462 all six app-host shards returned at the
    incompleteness gate, so not one RATCHET_NEW_FAILURE line was printed across
    the whole run even though the logs carried real assertion failures. A red
    suite that names no regression cannot tell anyone whether a fix landed.
    """
    passed, messages = accounting.check_run(
        inventory={"FooTests/testOne()", "BarTests/testTwo()", "BazTests/testThree()"},
        selectors=["FooTests", "BarTests", "BazTests"],
        results={
            "FooTests/testOne()": "Failed",
            "BazTests/testThree()": "Failed",
        },
        known={"BazTests/testThree()": "known on main"},
        log_text="",
        xcode_status=65,
    )
    assert passed is False
    assert "typed xcresult is incomplete: 1 selected Test Case(s) have no terminal result" in messages
    assert "missing typed test result: BarTests/testTwo()" in messages
    assert "RATCHET_NEW_FAILURE FooTests/testOne()" in messages
    assert "RATCHET_KNOWN_FAILURE BazTests/testThree()" in messages
    assert "recorded verdicts: 1 new, 1 known-main; typed test cases: 2" in messages


def test_incomplete_run_without_failures_adds_no_ratchet_noise() -> None:
    passed, messages = accounting.check_run(
        inventory={"FooTests/testOne()", "BarTests/testTwo()"},
        selectors=["FooTests", "BarTests"],
        results={"FooTests/testOne()": "Passed"},
        known={},
        log_text="",
        xcode_status=0,
    )
    assert passed is False
    assert not [m for m in messages if m.startswith("RATCHET_")]


def test_partial_suite_result_never_passes() -> None:
    passed, messages = accounting.check_run(
        inventory={"FooTests/testOne()", "FooTests/testTwo()"},
        selectors=["FooTests"],
        results={"FooTests/testOne()": "Passed"},
        known={},
        log_text="",
        xcode_status=0,
    )
    assert passed is False
    assert "missing typed test result: FooTests/testTwo()" in messages


def test_console_terminal_banner_is_not_required_when_typed_set_is_complete() -> None:
    passed, messages = accounting.check_run(
        inventory={"FooTests/testOne()"},
        selectors=["FooTests"],
        results={"FooTests/testOne()": "Passed"},
        known={},
        log_text="ordinary xcodebuild output without a footer\n",
        xcode_status=0,
    )
    assert passed is True
    assert messages == ["typed app-host run passed: 1 test cases"]


def test_unknown_or_nonterminal_typed_result_never_passes() -> None:
    for result in ("unknown", "Running", ""):
        passed, messages = accounting.check_run(
            inventory={"FooTests/testOne()"},
            selectors=["FooTests"],
            results={"FooTests/testOne()": result},
            known={},
            log_text="** TEST SUCCEEDED **\n",
            xcode_status=0,
        )
        assert passed is False
        assert messages == [
            f"typed Test Case has nonterminal or unknown result: FooTests/testOne() ({result})"
        ]


def test_restart_or_outer_timeout_is_never_ratcheted_green() -> None:
    for log in (
        "Restarting after unexpected exit, crash, or test timeout\n** TEST FAILED **\n",
        "xcodebuild unit-test batch 1/12 timeout after 900s; terminating\n",
        "Idle timed out after 300s (no test progress; app-host log lines do not count)\n",
    ):
        passed, messages = accounting.check_run(
            inventory={"FooTests/testBad()"},
            selectors=["FooTests"],
            results={"FooTests/testBad()": "Failed"},
            known={"FooTests/testBad()": {"classification": "timeout/hang"}},
            log_text=log,
            xcode_status=65,
        )
        assert passed is False
        assert messages[0].startswith("incomplete app-host run:")


def test_interrupted_run_still_names_the_failures_it_recorded() -> None:
    """A restarted app host must not hide the failures recorded before it.

    On main's full suite at 638aaa717 (run 35862070143), shard 4 recorded a
    failed XCTest case, then reported `app host restarted after test
    execution` and printed no RATCHET line, so the run never named it.
    """
    passed, messages = accounting.check_run(
        inventory={"FooTests/testBad()", "FooTests/testGood()", "BazTests/testKnown()"},
        selectors=["FooTests", "BazTests"],
        results={
            "FooTests/testBad()": "Failed",
            "FooTests/testGood()": "Passed",
            "BazTests/testKnown()": "Failed",
        },
        known={"BazTests/testKnown()": "known on main"},
        log_text="Restarting after unexpected exit, crash, or test timeout\n",
        xcode_status=65,
    )
    assert passed is False
    assert messages[0] == "incomplete app-host run: app host restarted after test execution"
    assert "RATCHET_NEW_FAILURE FooTests/testBad()" in messages
    assert "RATCHET_KNOWN_FAILURE BazTests/testKnown()" in messages
    assert "recorded verdicts: 1 new, 1 known-main; typed test cases: 3" in messages


def _catalog(tests: dict[str, dict[str, object]]) -> dict[str, object]:
    return {
        "bootstrap_main_sha": "1" * 40,
        "version": 1,
        "tests": tests,
    }


def test_catalog_may_only_shrink() -> None:
    old_tests = {
        "FooTests/testOne()": {"classification": "product bug"},
        "BarTests/testTwo()": {"classification": "test bug"},
    }
    old = _catalog(old_tests)
    shrunk = _catalog({"BarTests/testTwo()": {"classification": "test bug"}})
    grown = _catalog({
        **old_tests,
        "BazTests/testThree()": {"classification": "unknown"},
    })

    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        base_path = root / "base.json"
        current_path = root / "current.json"
        base_path.write_text(json.dumps(old), encoding="utf-8")

        for candidate, expected in ((shrunk, 0), (grown, 1)):
            current_path.write_text(json.dumps(candidate), encoding="utf-8")
            status = accounting.command_catalog_diff(
                SimpleNamespace(base=base_path, current=current_path)
            )
            assert status == expected


def _catalog_diff(base: dict[str, object], current: dict[str, object]) -> int:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        base_path = root / "base.json"
        current_path = root / "current.json"
        base_path.write_text(json.dumps(base), encoding="utf-8")
        current_path.write_text(json.dumps(current), encoding="utf-8")
        return accounting.command_catalog_diff(
            SimpleNamespace(base=base_path, current=current_path)
        )


def test_empty_catalog_bootstraps_once_from_a_pinned_main_census() -> None:
    """The catalog's own comment promises a bootstrap; the diff used to forbid it.

    Every addition was rejected, including the first, so the ratchet could
    never tolerate anything and every app-host PR inherited main's whole red
    set.
    """
    empty = {"bootstrap_main_sha": None, "version": 1, "tests": {}}
    census = _catalog({
        "FooTests/testOne()": {"classification": "product bug", "issue": 1},
        "BarTests/testTwo()": {"classification": "unknown"},
    })
    assert _catalog_diff(empty, census) == 0

    # Once pinned, growth is closed again, even by re-stating the same SHA.
    grown = json.loads(json.dumps(census))
    grown["tests"]["BazTests/testThree()"] = {"classification": "unknown"}
    assert _catalog_diff(census, grown) == 1


def test_bootstrap_still_requires_a_pinned_sha() -> None:
    empty = {"bootstrap_main_sha": None, "version": 1, "tests": {}}
    unpinned = {
        "bootstrap_main_sha": None,
        "version": 1,
        "tests": {"FooTests/testOne()": {"classification": "unknown"}},
    }
    try:
        _catalog_diff(empty, unpinned)
    except ValueError as error:
        assert "bootstrap_main_sha" in str(error)
    else:
        raise AssertionError("an unpinned catalog was bootstrapped")


def test_catalog_diff_rejects_changed_bootstrap_sha_even_when_tests_match() -> None:
    base = {
        "bootstrap_main_sha": "1" * 40,
        "version": 1,
        "tests": {
            "FooTests/testOne()": {"classification": "product bug"},
        },
    }
    current = json.loads(json.dumps(base))
    current["bootstrap_main_sha"] = "2" * 40

    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        base_path = root / "base.json"
        current_path = root / "current.json"
        base_path.write_text(json.dumps(base), encoding="utf-8")
        current_path.write_text(json.dumps(current), encoding="utf-8")
        status = accounting.command_catalog_diff(
            SimpleNamespace(base=base_path, current=current_path)
        )

    assert status == 1


def test_nonempty_catalog_requires_exact_bootstrap_main_sha() -> None:
    data = {
        "bootstrap_main_sha": None,
        "version": 1,
        "tests": {
            "FooTests/testOne()": {
                "classification": "unknown",
            }
        },
    }
    try:
        accounting.validate_catalog(data)
    except ValueError as error:
        assert "bootstrap_main_sha" in str(error)
    else:
        raise AssertionError("non-empty catalog without exact main SHA was accepted")


def test_catalog_requires_campaign_classification() -> None:
    data = {
        "bootstrap_main_sha": "0123456789abcdef0123456789abcdef01234567",
        "version": 1,
        "tests": {
            "FooTests/testOne()": {
                "classification": "host/display dependency",
                "issue": 123,
            }
        },
    }
    parsed = accounting.validate_catalog(data)
    assert set(parsed) == {"FooTests/testOne()"}

    bad = json.loads(json.dumps(data))
    bad["tests"]["FooTests/testOne()"]["classification"] = "flaky"
    try:
        accounting.validate_catalog(bad)
    except ValueError as error:
        assert "invalid classification" in str(error)
    else:
        raise AssertionError("invalid classification was accepted")


if __name__ == "__main__":
    for name, value in sorted(globals().items()):
        if name.startswith("test_") and callable(value):
            value()
    print("ok")
