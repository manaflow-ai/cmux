#!/usr/bin/env python3
import importlib.util
from pathlib import Path

ROOT = Path(__file__).parents[1]
spec = importlib.util.spec_from_file_location("census", ROOT / "scripts/ci/app_host_failure_census.py")
census = importlib.util.module_from_spec(spec)
spec.loader.exec_module(census)


def test_parses_xctest_swift_and_restart():
    text = """Test Case '-[cmuxTests.Foo testBad]' started.\nfile.swift:12: error: -[cmuxTests.Foo testBad] : XCTAssertEqual failed\nTest Case '-[cmuxTests.Foo testBad]' failed (0.1 seconds).\n◇ Test \"swift bad\" started.\n✘ Test \"swift bad\" recorded an issue at Foo.swift:4: Expectation failed: false\n✘ Test \"swift bad\" failed after 1 seconds with 1 issue.\nRestarting after unexpected exit, crash, or test timeout; summary\n"""
    record = census.parse_log(text, "1", "job")
    assert record["tests_failed"] == {"cmuxTests.Foo/testBad", "swift bad"}
    assert record["assertions"]["cmuxTests.Foo/testBad"] == "-[cmuxTests.Foo testBad] : XCTAssertEqual failed"
    assert record["restarts"][0]["test"] == "swift bad"


def test_known_issue_is_excluded_and_runs_are_deduplicated():
    a = census.parse_log('◇ Test "known" started.\n✘ Test "known" recorded an issue (known issue).\n', "r")
    b = census.parse_log("Test Case '-[cmuxTests.Foo testBad]' started.\nTest Case '-[cmuxTests.Foo testBad]' failed\n", "r")
    report = census.summarize([a, b])
    assert [row for row in report["tests"] if row["test"] == "known"] == []
    row = next(row for row in report["tests"] if row["test"] == "cmuxTests.Foo/testBad")
    assert row["runs_seen"] == 1 and row["runs_failed"] == 1


def test_swift_testing_known_issue_is_excluded():
    record = census.parse_log(
        '◇ Test "known" started.\n'
        '✘ Test "known" recorded a known issue.\n'
        '✘ Test "known" failed after 1 seconds with 1 issue.\n',
        "r",
    )
    assert record["tests_seen"] == set()
    assert record["tests_failed"] == set()


if __name__ == "__main__":
    test_parses_xctest_swift_and_restart()
    test_known_issue_is_excluded_and_runs_are_deduplicated()
    print("ok")
