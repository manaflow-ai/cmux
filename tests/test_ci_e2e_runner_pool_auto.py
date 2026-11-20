#!/usr/bin/env python3
"""`e2e_runner_pool.py --requested auto` answers with a pool, as its callers' gates expect.

cmux-next-frame-pacing.yml and iroh-release-gate.yml ask it for a runner with
`--requested auto` and take an owned Mac only when it answers with a glaeda
label. A merge from main brought back a `ui_run(args.test_filter)` check whose
function and flag feat-cmux-next had removed, so every auto pick raised
NameError, the gates read the empty answer as "no owned Mac free", and the
frame pacing bench never ran (cx-v9hdp).

The live pool read (simple_pool_picker.observe) is stubbed: the test drives
main() as the gate's command line does and reads what it prints.
"""

from __future__ import annotations

import contextlib
import io
import json
import sys
from pathlib import Path
from unittest import mock

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import e2e_runner_pool  # noqa: E402
import simple_pool_picker  # noqa: E402

GUI = "glaeda-gui-std-xcode-26.6"


def auto_pick(label: str) -> tuple[int, str]:
    observe = simple_pool_picker.observe
    pick = simple_pool_picker.pick
    simple_pool_picker.observe = lambda **_: simple_pool_picker.State(jobs=1)
    simple_pool_picker.pick = lambda _state: simple_pool_picker.Choice(label=label, reason="test", owned=bool(label))
    out = io.StringIO()
    try:
        with contextlib.redirect_stdout(out):
            code = e2e_runner_pool.main(
                ["--requested", "auto", "--owned", "1", "--owned-slots", f'{{"{GUI}": 1}}',
                 "--pr-xcode-app", "/Applications/Xcode_26.6.app"],
                env={"GH_REPO": "manaflow-ai/cmux", "ROUTE_TOKEN": "token"},
            )
    finally:
        simple_pool_picker.observe = observe
        simple_pool_picker.pick = pick
    return code, out.getvalue().strip()


def test_an_auto_pick_with_an_owned_mac_free_names_it() -> None:
    assert auto_pick(GUI) == (0, GUI)


def test_an_auto_pick_with_no_owned_mac_free_names_a_blacksmith_pool() -> None:
    code, label = auto_pick("")
    assert code == 0 and label and not label.startswith("glaeda-"), (code, label)


AWS = "glaeda-aws-std-xcode-26.6"
MINI = "glaeda-std-xcode-26.6"


def frame_pacing_pick(labels: list[str], *, busy: tuple[str, ...] = (), fork: bool = False,
                      gui_setting: str | None = None) -> str:
    """Drive the workflow's actual gate environment through the real observer and picker."""
    workflow = yaml.safe_load((ROOT / ".github/workflows/cmux-next-frame-pacing.yml").read_text())
    gate = next(step for step in workflow["jobs"]["gate"]["steps"] if step.get("id") == "decide")
    env = {key: str(value) for key, value in gate["env"].items() if "${{" not in str(value)}
    env.update({"GH_REPO": "manaflow-ai/cmux", "GITHUB_REPOSITORY": "manaflow-ai/cmux",
                "ROUTE_TOKEN": "fixture", "FORK_PULL_REQUEST": str(fork).lower()})
    if gui_setting is not None:
        env["CMUX_CI_GUI_REQUIRED"] = gui_setting
    runners = [{"name": label, "status": "online", "busy": label in busy,
                "labels": [{"name": label}]} for label in labels]
    with mock.patch.object(simple_pool_picker.LiveState, "runners", return_value=runners), \
         mock.patch.object(simple_pool_picker.LiveState, "snapshot", return_value={}), \
         contextlib.redirect_stdout(io.StringIO()) as out:
        code = e2e_runner_pool.main(
            ["--requested", "auto", "--owned", "1", "--owned-slots", json.dumps(dict.fromkeys(labels, 1)),
             "--pr-xcode-app", "/Applications/Xcode_26.6.app"], env=env)
    assert code == 0
    return out.getvalue().strip()


def test_frame_pacing_skips_an_idle_headless_pool() -> None:
    label = frame_pacing_pick([AWS])
    assert not label.startswith("glaeda-"), label


def test_frame_pacing_selects_available_gui_pool_beside_headless_pool() -> None:
    assert frame_pacing_pick([AWS, MINI]) == MINI


def test_frame_pacing_skips_when_gui_pool_is_busy_even_with_headless_capacity() -> None:
    label = frame_pacing_pick([AWS, MINI], busy=(MINI,))
    assert not label.startswith("glaeda-"), label


def test_frame_pacing_fork_never_selects_owned_pool() -> None:
    label = frame_pacing_pick([AWS, MINI], fork=True)
    assert not label.startswith("glaeda-"), label


def test_non_gui_work_can_still_select_headless_capacity() -> None:
    assert frame_pacing_pick([AWS], gui_setting="false") == AWS


if __name__ == "__main__":
    failures = 0
    for name, test in list(globals().items()):
        if name.startswith("test_") and callable(test):
            try:
                test()
                print(f"ok {name}")
            except Exception as error:  # a NameError is the regression this guards
                failures += 1
                print(f"FAIL {name}: {type(error).__name__}: {error}")
    sys.exit(1 if failures else 0)
