import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location(
    "ios_sim_agreement", Path(__file__).resolve().parents[1] / "scripts/ci/ios_sim_agreement.py")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)

MAC = """kit-tests\txcodebuild test (iOS simulator)\t2026-11-27T03:00:00.1Z FAILED: CmuxMobileLiveTests / LinkSuite / testA()
kit-tests\txcodebuild test (iOS simulator)\t2026-11-27T03:00:00.2Z NOT FINISHED (Running): CmuxMobileShellTests / S / testB
kit-tests\txcodebuild test (iOS simulator)\t2026-11-27T03:00:00.3Z iOS simulator test cases: Failed 1, Passed 9
kit-tests\tswift test (macOS)\t2026-11-27T03:00:00.4Z FAILED: CmuxMobileAuthTests / X / y
"""
JUNIT = """<testsuites><testsuite>
<testcase classname="CmuxMobileLiveTests.LinkSuite" name="testA()"><failure/></testcase>
<testcase classname="CmuxMobileAuthTests.X" name="y"/></testsuite></testsuites>"""


def test_parse_mac_only_the_simulator_step():
    ok, failing = m.parse_mac(MAC)
    assert ok
    assert failing == {("CmuxMobileLiveTests", "LinkSuite", "testA"), ("CmuxMobileShellTests", "S", "testB")}


def test_mac_without_marker_has_no_verdict():
    assert m.parse_mac("FAILED: A / B / c\n")[0] is False


def test_parse_junit():
    ok, failing = m.parse_junit(JUNIT)
    assert ok and failing == {("CmuxMobileLiveTests", "LinkSuite", "testA")}
    assert m.parse_junit("<testsuites/>") == (False, set())
    assert m.parse_junit("garbage")[0] is False


def run(i, mac, linux):
    return {"id": i, "mac": mac, "linux": linux}


def test_streak_disagreement_and_skip():
    a = {("CmuxMobileLiveTests", "S", "t")}
    runs = [  # newest first
        run(5, (True, set()), (True, set())),
        run(4, (True, set()), None),  # skipped, no effect
        run(3, (True, a), (True, a)),
        run(2, (True, a), (True, set())),  # Live disagrees
        run(1, (True, set()), (True, set())),
    ]
    rows, unc = m.evaluate(runs, 2)
    live = next(r for r in rows if r["bundle"] == "CmuxMobileLiveTests")
    assert (live["counted"], live["streak"]) == (4, 2)
    assert live["last_disagreement"] == (2, [("S", "t")], [])
    auth = next(r for r in rows if r["bundle"] == "CmuxMobileAuthTests")
    assert auth["streak"] == 4 and auth["last_disagreement"] is None
    assert [u[0] for u in unc] == [4]
    assert "CmuxMobileLiveTests" in m.table(rows, 2)


UNKNOWN = """job\tUNKNOWN STEP\t2026-11-27T04:30:22.1Z ##[group]Run something else
job\tUNKNOWN STEP\t2026-11-27T04:30:22.2Z FAILED: CmuxMobileAuthTests / Z / q
job\tUNKNOWN STEP\t2026-11-27T04:30:23.1Z ##[group]Run bash ../../scripts/ci/ios-kit-sim-mac-test.sh
job\tUNKNOWN STEP\t2026-11-27T04:30:24.1Z FAILED: CmuxMobileKit-Package / CmuxMobileLiveTests / Suite / aTest()
job\tUNKNOWN STEP\t2026-11-27T04:30:24.2Z iOS simulator test cases: Failed 1
job\tUNKNOWN STEP\t2026-11-27T04:30:25.1Z ##[group]Run next step
job\tUNKNOWN STEP\t2026-11-27T04:30:25.2Z FAILED: CmuxMobileShellTests / Z / q
"""


def test_unknown_step_log_is_cut_by_group_markers_and_root_is_dropped():
    ok, failing = m.parse_mac(UNKNOWN)
    assert ok and failing == {("CmuxMobileLiveTests", "Suite", "aTest")}
