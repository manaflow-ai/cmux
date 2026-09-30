#!/usr/bin/env python3
"""CI guard for ./scripts/check-command-palette-agent-surface.py.

The guarded property: every `palette.*` id in the app sources is classified for
the agent surface, so a palette command added later cannot reach `cmux palette
list` before anyone decided it should. The negative cases below are what keep the
guard from rotting into a no-op.

Cases:
  (a) The real cmux checkout passes.
  (b) A minimal fixture tree passes.
  (c) A palette command added to the sources but not to the inventory fails.
  (d) An inventory entry whose id left the sources fails (dead entry).
  (e) An exclusion whose command left the sources fails. This is the case that
      proves the scan skips the Swift exclusion constant itself: if it did not,
      the constant would vouch for its own dead entries.
  (f) An id excluded in Swift but listed as agent-visible in the inventory fails
      from both directions.
  (g) An id in two buckets fails.
  (h) A notCommandIds entry with a blank reason fails.
  (i) A dynamicFamilies entry missing `agentVisible`, and a family key without a
      trailing dot, fail.
  (j) A runtime-completed prefix parked in listedCommandIds fails.
  (k) An unsorted listedCommandIds fails.
  (l) Renaming `notAgentSurfaceCommandIds` fails loudly instead of skipping.
  (m) A root with no palette ids at all fails loudly (wrong scan globs).
"""

import json
import os
import subprocess
import sys
import tempfile

ROOT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GUARD = os.path.join(ROOT_DIR, "scripts", "check-command-palette-agent-surface.py")
INVENTORY_RELATIVE = os.path.join(
    "scripts", "command-palette-agent-surface-inventory.json"
)
AGENT_SURFACE_RELATIVE = os.path.join(
    "Packages", "macOS", "CmuxCommandPalette", "Sources", "CmuxCommandPalette",
    "AgentSurface", "CommandPaletteAgentSurface.swift",
)

FIXTURE_SOURCE = """\
import CmuxCommandPalette

extension ContentView {
    static let installCLICommandId = "palette.installCLI"

    static func contributions() -> [CommandPaletteCommandContribution] {
        [
            CommandPaletteCommandContribution(commandId: "palette.newWorkspace"),
            CommandPaletteCommandContribution(commandId: installCLICommandId),
        ]
    }

    static func settingsToggleIdPrefix() -> String { "palette.toggleSetting." }

    func logInvocation() { cmuxDebugLog("palette.openSettings.invoke") }
}
"""

FIXTURE_SURFACE = """\
public enum CommandPaletteAgentSurface {
    public static let notAgentSurfaceCommandIds: Set<String> = [
        "palette.installCLI",
    ]
}
"""


def fixture_inventory():
    return {
        "listedCommandIds": ["palette.newWorkspace"],
        "excludedCommandIds": ["palette.installCLI"],
        "dynamicFamilies": {
            "palette.toggleSetting.": {
                "reason": "one command per settings descriptor",
                "agentVisible": True,
            }
        },
        "notCommandIds": {"palette.openSettings.invoke": "debug log tag"},
    }


def write_text(path, contents):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(contents)


def make_fixture_root(
    directory,
    source=FIXTURE_SOURCE,
    surface=FIXTURE_SURFACE,
    inventory=None,
):
    write_text(os.path.join(directory, "Sources", "Fixture.swift"), source)
    write_text(os.path.join(directory, AGENT_SURFACE_RELATIVE), surface)
    write_text(
        os.path.join(directory, INVENTORY_RELATIVE),
        json.dumps(inventory if inventory is not None else fixture_inventory(), indent=2) + "\n",
    )
    return directory


def run_guard(root):
    return subprocess.run(
        [sys.executable, GUARD, "--root", root],
        cwd=ROOT_DIR,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )


def expect_pass(root, case):
    result = run_guard(root)
    assert result.returncode == 0, "{0}: expected pass, got:\n{1}".format(case, result.stdout)


def expect_failure(root, case, *needles):
    result = run_guard(root)
    assert result.returncode == 1, "{0}: expected failure, got:\n{1}".format(case, result.stdout)
    for needle in needles:
        assert needle in result.stdout, "{0}: missing {1!r} in:\n{2}".format(
            case, needle, result.stdout
        )


def case_a_real_repo():
    expect_pass(ROOT_DIR, "(a) real repo")


def case_b_fixture_baseline(tmp):
    expect_pass(make_fixture_root(os.path.join(tmp, "b")), "(b) fixture baseline")


def case_c_unclassified_command(tmp):
    root = make_fixture_root(
        os.path.join(tmp, "c"),
        source=FIXTURE_SOURCE + '\nlet extra = "palette.brandNewCommand"\n',
    )
    expect_failure(root, "(c) unclassified command",
                   "unclassified palette id palette.brandNewCommand")


def case_d_dead_entry(tmp):
    inventory = fixture_inventory()
    inventory["listedCommandIds"] = ["palette.newWorkspace", "palette.removedCommand"]
    root = make_fixture_root(os.path.join(tmp, "d"), inventory=inventory)
    expect_failure(root, "(d) dead entry",
                   "listedCommandIds entry palette.removedCommand no longer appears")


def case_e_dead_exclusion(tmp):
    surface = FIXTURE_SURFACE.replace(
        '"palette.installCLI",',
        '"palette.installCLI",\n        "palette.retiredUpdateCommand",',
    )
    inventory = fixture_inventory()
    inventory["excludedCommandIds"] = [
        "palette.installCLI",
        "palette.retiredUpdateCommand",
    ]
    root = make_fixture_root(os.path.join(tmp, "e"), surface=surface, inventory=inventory)
    expect_failure(root, "(e) dead exclusion",
                   "excludedCommandIds entry palette.retiredUpdateCommand no longer appears")


def case_f_exclusion_drift(tmp):
    inventory = fixture_inventory()
    inventory["listedCommandIds"] = ["palette.installCLI", "palette.newWorkspace"]
    inventory["excludedCommandIds"] = []
    root = make_fixture_root(os.path.join(tmp, "f"), inventory=inventory)
    expect_failure(root, "(f) exclusion drift",
                   "notAgentSurfaceCommandIds excludes palette.installCLI but the inventory does not")


def case_g_two_buckets(tmp):
    inventory = fixture_inventory()
    inventory["notCommandIds"]["palette.newWorkspace"] = "claimed twice"
    root = make_fixture_root(os.path.join(tmp, "g"), inventory=inventory)
    expect_failure(root, "(g) two buckets", "also appears in another bucket: palette.newWorkspace")


def case_h_blank_reason(tmp):
    inventory = fixture_inventory()
    inventory["notCommandIds"]["palette.openSettings.invoke"] = "   "
    root = make_fixture_root(os.path.join(tmp, "h"), inventory=inventory)
    expect_failure(root, "(h) blank reason",
                   "notCommandIds palette.openSettings.invoke needs a reason")


def case_i_family_shape(tmp):
    inventory = fixture_inventory()
    del inventory["dynamicFamilies"]["palette.toggleSetting."]["agentVisible"]
    root = make_fixture_root(os.path.join(tmp, "i1"), inventory=inventory)
    expect_failure(root, "(i) family missing agentVisible",
                   "dynamicFamilies palette.toggleSetting. needs agentVisible true or false")

    inventory = fixture_inventory()
    family = inventory["dynamicFamilies"].pop("palette.toggleSetting.")
    inventory["dynamicFamilies"]["palette.toggleSetting"] = family
    root = make_fixture_root(
        os.path.join(tmp, "i2"),
        source=FIXTURE_SOURCE.replace('"palette.toggleSetting."', '"palette.toggleSetting"'),
        inventory=inventory,
    )
    expect_failure(root, "(i) family key without a dot",
                   "dynamicFamilies key palette.toggleSetting must end with a dot")


def case_j_prefix_in_listed(tmp):
    inventory = fixture_inventory()
    inventory["dynamicFamilies"] = {}
    inventory["listedCommandIds"] = ["palette.newWorkspace", "palette.toggleSetting."]
    root = make_fixture_root(os.path.join(tmp, "j"), inventory=inventory)
    expect_failure(root, "(j) prefix in listedCommandIds",
                   "belongs in dynamicFamilies")


def case_k_unsorted(tmp):
    inventory = fixture_inventory()
    inventory["listedCommandIds"] = ["palette.newWorkspace", "palette.aaaCommand"]
    root = make_fixture_root(
        os.path.join(tmp, "k"),
        source=FIXTURE_SOURCE + '\nlet extra = "palette.aaaCommand"\n',
        inventory=inventory,
    )
    expect_failure(root, "(k) unsorted", "listedCommandIds must stay sorted")


def case_l_renamed_constant(tmp):
    surface = FIXTURE_SURFACE.replace(
        "notAgentSurfaceCommandIds", "hiddenFromAgentsCommandIds"
    )
    root = make_fixture_root(os.path.join(tmp, "l"), surface=surface)
    expect_failure(root, "(l) renamed constant",
                   "could not locate `notAgentSurfaceCommandIds`")


def case_m_empty_universe(tmp):
    root = make_fixture_root(os.path.join(tmp, "m"))
    os.remove(os.path.join(root, "Sources", "Fixture.swift"))
    expect_failure(root, "(m) empty universe", "found no palette ids")


def main():
    with tempfile.TemporaryDirectory(prefix="palette-agent-surface-guard-") as tmp:
        case_a_real_repo()
        case_b_fixture_baseline(tmp)
        case_c_unclassified_command(tmp)
        case_d_dead_entry(tmp)
        case_e_dead_exclusion(tmp)
        case_f_exclusion_drift(tmp)
        case_g_two_buckets(tmp)
        case_h_blank_reason(tmp)
        case_i_family_shape(tmp)
        case_j_prefix_in_listed(tmp)
        case_k_unsorted(tmp)
        case_l_renamed_constant(tmp)
        case_m_empty_universe(tmp)
    print("test_ci_command_palette_agent_surface_guard: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
