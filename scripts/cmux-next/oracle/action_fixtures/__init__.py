"""Shared setup of the oracle's action cases and the every-action sweep.

Spec: plans/cmux-next/chrome-parity/p15-oracle.md, section 3B and tasks 046 and 233. Stdlib only,
Python 3.9+, safe under `python3 -I` (the caller puts scripts/cmux-next/oracle on sys.path).
Per-family fixtures are the sibling modules (action_fixtures/<family>.py); p15-oracle-046 adds
their loader here.

Motion arm (p15-oracle-233)
---------------------------
Every case runs with `ui.animations.enabled=false` (the `old` arm of the `motion-on` virtual suite,
plans/cmux-next/refactor-switches/motion-on.json). CLAUDE.md requires that code works with no
animation: a change applies in one frame and completions still run. The `new` arm runs the same
cases with animation on; its settled snapshots must equal the motion-off ones, and the registry's
expected_differences list the only values allowed to differ.

The arm is a launch config value, not a RefactorSwitches key, so the driver writes it into the
bench config (`launch_config`) and removes it from `--cmux-switches` (`split_switches`). The arm is
read back from the settings facet (`readback` in the registry, /facets/settings/motion/enabled):
the applied settings, not the file the driver wrote. With Reduce Motion on, motion is not on, so
that readback is no arm. `case_report` gives the driver protocol's `switch_readback` and
`switch_hits` for one case. A hit is evidence that the arm ran: on the new arm, each animation span
`debug.motion` recorded (MotionTrace: first frame to rest); on the old arm, a case that read back
motion off and recorded no span. A span on the old arm counts as a new-arm hit: something animated
with the master switch off, and `oracle.py diff --switch` refuses that run as arm-not-applied.

Chrome reference (chromium/src):
- ui/compositor/scoped_animation_duration_scale_mode.h: browser and views tests run with
  ZERO_DURATION, so an animation completes in the frame it starts and the test reads the end state.
- third_party/blink/web_tests/VirtualTestSuites: a virtual suite reruns the same tests with extra
  arguments and compares them with the base tests' expectations; the motion-on arm is that rerun
  with animation on.
"""

from __future__ import annotations

import copy
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[3]
MOTION_SWITCH = "motion-on"
MOTION_REGISTRY = REPO / "plans" / "cmux-next" / "refactor-switches" / f"{MOTION_SWITCH}.json"
ARMS = ("old", "new")
# Reduce Motion replaces movement (spec 3B; Motion.basePolicy), so a motion-on arm needs it off.
REDUCE_MOTION_POINTER = "/facets/settings/motion/reduceMotion"
# The per-case readback when the checkpoints disagree about the arm (a mid-case settings change).
INCONSISTENT = "inconsistent"
# The settings facet was readable but showed no arm: motion on with Reduce Motion on.
NO_ARM = "none"


class MotionArmError(ValueError):
    """A malformed motion-on registry file, an unknown arm, or a case config that sets the arm itself."""


def _unescape(token: str) -> str:
    return token.replace("~1", "/").replace("~0", "~")


_MISSING = object()


def resolve(document: Any, pointer: str) -> Any:
    """The value at a JSON pointer (RFC 6901), or _MISSING."""
    if pointer == "":
        return document
    node = document
    for token in pointer[1:].split("/"):
        token = _unescape(token)
        if isinstance(node, dict) and token in node:
            node = node[token]
        elif isinstance(node, list) and token.isdigit() and int(token) < len(node):
            node = node[int(token)]
        else:
            return _MISSING
    return node


@dataclass(frozen=True)
class MotionArm:
    """The motion-on registry entry: which config key sets the arm and where the product reads it back."""

    name: str
    config_path: Tuple[str, ...]
    values: Mapping[str, bool]
    readback: str
    default: str

    @classmethod
    def load(cls, path: Path = MOTION_REGISTRY) -> "MotionArm":
        try:
            entry = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            raise MotionArmError(f"{path}: {error}") from None
        return cls.from_entry(entry, str(path))

    @classmethod
    def from_entry(cls, entry: Any, where: str = MOTION_SWITCH) -> "MotionArm":
        if not isinstance(entry, dict):
            raise MotionArmError(f"{where}: a switch file is a JSON object")
        key, arms, readback, default = (entry.get(k) for k in ("config_key", "config_arms", "readback", "default"))
        if not isinstance(key, str) or not key or any(not part for part in key.split(".")):
            raise MotionArmError(f"{where}: config_key must be a dotted settings path")
        if not (isinstance(arms, dict) and set(arms) == set(ARMS) and all(isinstance(v, bool) for v in arms.values())
                and arms["old"] != arms["new"]):
            raise MotionArmError(f"{where}: config_arms must map old and new to two different booleans")
        if not isinstance(readback, str) or not readback.startswith("/"):
            raise MotionArmError(f"{where}: readback must be a JSON pointer into the snapshot")
        if default not in ARMS:
            raise MotionArmError(f"{where}: default must be old or new")
        return cls(str(entry.get("name") or MOTION_SWITCH), tuple(key.split(".")), dict(arms), readback, default)

    def check_arm(self, arm: str) -> str:
        if arm not in ARMS:
            raise MotionArmError(f"{self.name}: unknown arm {arm!r} (old or new)")
        return arm

    def split_switches(self, switches: Mapping[str, str]) -> Tuple[Dict[str, str], str]:
        """The switches for `--cmux-switches` without this one, and this one's arm (the default when unset)."""
        rest = {name: arm for name, arm in switches.items() if name != self.name}
        return rest, self.check_arm(switches.get(self.name, self.default))

    def launch_config(self, config: Mapping[str, Any], arm: str) -> Dict[str, Any]:
        """`config` (the bench's cmux-next.json) with the arm's value at config_key.

        A config that already sets the key to another value is refused: a case does not pick the
        arm (case-v1 `environment`), the run does.
        """
        value = self.values[self.check_arm(arm)]
        out = copy.deepcopy(dict(config))
        node = out
        for part in self.config_path[:-1]:
            child = node.setdefault(part, {})
            if not isinstance(child, dict):
                raise MotionArmError(f"{self.name}: the config sets {'.'.join(self.config_path)} parent {part!r} "
                                     f"to {child!r}, not an object")
            node = child
        leaf = self.config_path[-1]
        if leaf in node and node[leaf] != value:
            raise MotionArmError(f"{self.name}: the config sets {'.'.join(self.config_path)}={node[leaf]!r}, "
                                 f"but the {arm} arm needs {value!r}")
        node[leaf] = value
        return out

    def read_arm(self, snapshot: Mapping[str, Any]) -> Optional[str]:
        """The arm a snapshot reads back: old, new, NO_ARM, or None when its settings facet has no value."""
        value = resolve(snapshot, self.readback)
        if not isinstance(value, bool):
            return None
        arm = next(a for a in ARMS if self.values[a] is value)
        if arm == "new" and resolve(snapshot, REDUCE_MOTION_POINTER) is True:
            return NO_ARM
        return arm

    def case_readback(self, snapshots: Iterable[Mapping[str, Any]]) -> Optional[str]:
        """One case's readback over its checkpoints: their common arm, INCONSISTENT, or None (none readable)."""
        seen = {arm for arm in (self.read_arm(s) for s in snapshots) if arm is not None}
        if not seen:
            return None
        return seen.pop() if len(seen) == 1 else INCONSISTENT

    def case_report(self, arm: str, snapshots: Sequence[Mapping[str, Any]], motion: Mapping[str, Any]) -> Dict[str, Any]:
        """The driver result's switch_readback and switch_hits of one case on `arm`.

        `motion` is the `debug.motion {"action": "stop"}` reply of the recording `start_calls`
        began (its `spans` list).
        """
        self.check_arm(arm)
        spans = motion.get("spans")
        if not isinstance(spans, list):
            raise MotionArmError(f"{self.name}: debug.motion reply has no spans list: {json.dumps(motion)[:200]}")
        readback = self.case_readback(snapshots)
        hits: Dict[str, int] = {}
        if spans:
            hits["new"] = len(spans)
        elif arm == "old" and readback == "old":
            hits["old"] = 1
        return {
            "switch_readback": {} if readback is None else {self.name: readback},
            "switch_hits": {self.name: hits} if hits else {},
        }

    def start_calls(self, arm: str) -> List[Tuple[str, Dict[str, Any]]]:
        """Socket calls before a case: start span recording; on the new arm, Reduce Motion off in memory."""
        calls: List[Tuple[str, Dict[str, Any]]] = [("debug.motion", {"action": "start"})]
        if self.check_arm(arm) == "new":
            calls.append(("debug.motion", {"action": "reduce", "value": False}))
        return calls

    @staticmethod
    def stop_call() -> Tuple[str, Dict[str, Any]]:
        """The socket call after a case's last checkpoint; its reply is case_report's `motion`."""
        return ("debug.motion", {"action": "stop"})

    def arm_pointers(self) -> List[str]:
        """The snapshot values that read the arm back, for diff.py --arm-pointer (p15-oracle-111)."""
        return [self.readback]
