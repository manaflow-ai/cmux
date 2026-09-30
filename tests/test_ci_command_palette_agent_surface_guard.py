#!/usr/bin/env python3
"""CI guard for ./scripts/check-command-palette-agent-surface.py.

Two guarded properties. First, every `palette.*` id in the app sources is
classified for the agent surface, so a palette command added later cannot reach
`cmux palette list` before anyone decided it should. Second, no contribution
gates `when` on a probe-backed context key: in the agent listing a false `when`
removes the row, so a key that reads false until its probe runs would report
that the command does not exist on a window where it does. The negative cases
below are what keep the guard from rotting into a no-op.

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
  (n) An id built by interpolation whose family is not declared fails. Without
      this the guard would be blind to whole command families, since an
      interpolated id has no closing quote for the literal scan to find.
  (o) An interpolation that completes an id mid-segment fails, because no
      inventory prefix can describe the ids it produces.
  (p) A contribution gating `when` on a probe-backed context key fails. This is
      the regression the rule exists for.
  (q) The same test in `enablement` passes, so the guard is a rule about where
      the key is read and not a ban on reading it.
  (r) A `when` predicate that reaches the key indirectly, through a closure
      named `...Enablement`, fails too.
  (s) A probe-backed name the inventory lists but the doc comment no longer
      marks fails, and so does a marked key the inventory does not list. The
      marker and the inventory cannot drift apart.
  (t) Dropping `probeBackedContextKeys` fails instead of turning the rule off.
  (u) A contribution whose argument list will not parse fails, and so does a
      source tree with contributions the scan cannot see. Blindness here has to
      be loud, since this rule reads the constructions the id scan avoids.
  (v) A non-string id in a bucket is reported as a violation, not raised as a
      traceback, so a typo in the inventory names its own line.
  (w) The same for a bucket that should be an object and is not: the guard
      reports it and keeps checking, so one wrong bucket does not hide the
      findings in the others.
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
CONTEXT_KEYS_RELATIVE = os.path.join(
    "Packages", "macOS", "CmuxCommandPalette", "Sources", "CmuxCommandPalette",
    "Context", "CommandPaletteContextKeys.swift",
)

FIXTURE_SOURCE = """\
import CmuxCommandPalette

extension ContentView {
    static let installCLICommandId = "palette.installCLI"

    static func contributions() -> [CommandPaletteCommandContribution] {
        [
            CommandPaletteCommandContribution(
                commandId: "palette.newWorkspace",
                // A comment with a stray ( and "quote to parse past.
                title: "New Workspace, please",
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) },
                enablement: { $0.bool(CommandPaletteContextKeys.panelHasForkableAgent) }
            ),
            CommandPaletteCommandContribution(commandId: installCLICommandId),
        ]
    }

    static func settingsToggleIdPrefix() -> String { "palette.toggleSetting." }

    static func statusCommandId(_ status: String) -> String {
        "palette.workspaceStatus.\\(status)"
    }

    func logInvocation() { cmuxDebugLog("palette.openSettings.invoke") }
}
"""

FIXTURE_CONTEXT_KEYS = """\
public struct CommandPaletteContextKeys: Sendable {
    /// Whether the focused panel is a terminal.
    public static let panelIsTerminal = CommandPaletteContextKeys(rawValue: "panel.isTerminal")
    /// Whether the focused panel hosts a forkable agent.
    ///
    /// Probe-backed: an availability probe answers this.
    public static let panelHasForkableAgent = CommandPaletteContextKeys(rawValue: "panel.hasForkableAgent")
}
"""

WHEN_BOTH = """\
                when: { $0.bool(CommandPaletteContextKeys.panelIsTerminal) },
                enablement: { $0.bool(CommandPaletteContextKeys.panelHasForkableAgent) }"""

FIXTURE_SURFACE = """\
public struct CommandPaletteAgentSurface: Sendable {
    public static let notAgentSurfaceCommandIds: Set<String> = [
        "palette.installCLI",
    ]
}
"""


def fixture_inventory():
    return {
        "probeBackedContextKeys": {
            "panelHasForkableAgent": "answered by the fork availability probe",
        },
        "listedCommandIds": ["palette.newWorkspace"],
        "excludedCommandIds": ["palette.installCLI"],
        "dynamicFamilies": {
            "palette.toggleSetting.": {
                "reason": "one command per settings descriptor",
                "agentVisible": True,
            },
            "palette.workspaceStatus.": {
                "reason": "one command per workspace status",
                "agentVisible": True,
            },
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
    context_keys=FIXTURE_CONTEXT_KEYS,
):
    write_text(os.path.join(directory, "Sources", "Fixture.swift"), source)
    write_text(os.path.join(directory, AGENT_SURFACE_RELATIVE), surface)
    write_text(os.path.join(directory, CONTEXT_KEYS_RELATIVE), context_keys)
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


def case_n_undeclared_interpolated_family(tmp):
    inventory = fixture_inventory()
    del inventory["dynamicFamilies"]["palette.workspaceStatus."]
    root = make_fixture_root(os.path.join(tmp, "n"), inventory=inventory)
    expect_failure(root, "(n) undeclared interpolated family",
                   "interpolated palette id family palette.workspaceStatus.",
                   "not declared in dynamicFamilies")


def case_o_interpolation_mid_segment(tmp):
    root = make_fixture_root(
        os.path.join(tmp, "o"),
        source=FIXTURE_SOURCE + '\nlet mid = "palette.openTab\\(index)"\n',
    )
    expect_failure(root, "(o) interpolation mid-segment",
                   "palette.openTab", "completes mid-segment")


def case_p_probe_backed_in_when(tmp):
    source = FIXTURE_SOURCE.replace(
        WHEN_BOTH,
        """                when: {
                    $0.bool(CommandPaletteContextKeys.panelIsTerminal) &&
                    $0.bool(CommandPaletteContextKeys.panelHasForkableAgent)
                }""",
    )
    root = make_fixture_root(os.path.join(tmp, "p"), source=source)
    expect_failure(root, "(p) probe-backed key in when",
                   "`when` gates on the probe-backed context key panelHasForkableAgent",
                   "Move the test into `enablement`")


def case_q_probe_backed_in_enablement(tmp):
    expect_pass(make_fixture_root(os.path.join(tmp, "q")),
                "(q) probe-backed key in enablement")


def case_r_indirect_predicate(tmp):
    source = FIXTURE_SOURCE.replace(
        WHEN_BOTH,
        """                when: forkableAgentEnablement,
                enablement: { $0.bool(CommandPaletteContextKeys.panelHasForkableAgent) }""",
    )
    root = make_fixture_root(os.path.join(tmp, "r"), source=source)
    expect_failure(root, "(r) indirect predicate in when",
                   "`when` uses the predicate forkableAgentEnablement")


def case_s_marker_drift(tmp):
    context_keys = FIXTURE_CONTEXT_KEYS.replace(
        "    /// Probe-backed: an availability probe answers this.\n", ""
    )
    root = make_fixture_root(os.path.join(tmp, "s1"), context_keys=context_keys)
    expect_failure(root, "(s) marker removed",
                   "probeBackedContextKeys panelHasForkableAgent is no longer marked")

    inventory = fixture_inventory()
    inventory["probeBackedContextKeys"] = {"panelIsTerminal": "wrong key"}
    root = make_fixture_root(os.path.join(tmp, "s2"), inventory=inventory)
    expect_failure(root, "(s) marked key unlisted",
                   "context key panelHasForkableAgent is marked",
                   "not listed in probeBackedContextKeys")


def case_t_missing_bucket(tmp):
    inventory = fixture_inventory()
    del inventory["probeBackedContextKeys"]
    root = make_fixture_root(os.path.join(tmp, "t"), inventory=inventory)
    expect_failure(root, "(t) bucket removed",
                   "probeBackedContextKeys must be a non-empty object")


def case_u_blind_scan(tmp):
    source = FIXTURE_SOURCE.replace(
        "                enablement: { $0.bool(CommandPaletteContextKeys.panelHasForkableAgent) }\n            ),",
        "                enablement: { $0.bool(CommandPaletteContextKeys.panelHasForkableAgent) }\n            ,",
    )
    root = make_fixture_root(os.path.join(tmp, "u1"), source=source)
    expect_failure(root, "(u) unparsable contribution",
                   "could not read the argument list of this contribution")

    source = FIXTURE_SOURCE.replace("CommandPaletteCommandContribution(", "PaletteRow(")
    root = make_fixture_root(os.path.join(tmp, "u2"), source=source)
    expect_failure(root, "(u) no contributions found",
                   "found no `CommandPaletteCommandContribution(` constructions")


def case_v_non_string_entry(tmp):
    inventory = fixture_inventory()
    inventory["listedCommandIds"] = ["palette.newWorkspace", None]
    root = make_fixture_root(os.path.join(tmp, "v"), inventory=inventory)
    expect_failure(root, "(v) non-string entry",
                   "listedCommandIds entry None must be a string")


def case_w_wrong_bucket_shape(tmp):
    for index, (name, bad, expected) in enumerate((
        ("dynamicFamilies", ["chat.model."],
         "dynamicFamilies must be an object keyed by id prefix"),
        ("notCommandIds", None,
         "notCommandIds must be an object keyed by the literal"),
    )):
        inventory = fixture_inventory()
        inventory[name] = bad
        root = make_fixture_root(os.path.join(tmp, "w{0}".format(index)),
                                 inventory=inventory)
        # The other buckets are still checked, so the run reports this bucket
        # and whatever its emptiness makes unclassified, not a traceback.
        expect_failure(root, "(w) {0} wrong shape".format(name), expected)


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
        case_n_undeclared_interpolated_family(tmp)
        case_o_interpolation_mid_segment(tmp)
        case_p_probe_backed_in_when(tmp)
        case_q_probe_backed_in_enablement(tmp)
        case_r_indirect_predicate(tmp)
        case_s_marker_drift(tmp)
        case_t_missing_bucket(tmp)
        case_u_blind_scan(tmp)
        case_v_non_string_entry(tmp)
        case_w_wrong_bucket_shape(tmp)
    print("test_ci_command_palette_agent_surface_guard: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
