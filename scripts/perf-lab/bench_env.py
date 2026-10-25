#!/usr/bin/env python3
"""Every switch a bench app gets, and the Swift line that reads it.

`bench_launch.BenchApp` starts every lab bench app with these values: no focus taken, the automation socket, a mock
agent pane, an isolated Chief, scratch config files, no update check, no telemetry or hang report, and feature
safe mode off. A switch nothing reads measures nothing, so each entry names its read site, and `--check` (and
`scripts/cmux-next/tests/test_bench_launch.py`) proves that file still names it.

Kinds:
- `env`: the launch sets the variable to `value`.
- `env-launch`: the launch sets the variable to a path of its own (scratch config, window frame).
- `env-unset`: the off state is the variable's absence; the launch never sets it (a bench of that path itself, for
  example `crash-ends-app-gate.py` with `CMUX_NEXT_DEV_SENTRY=1`, passes it explicitly).
- `config`: a cmux-next.json key the launch writes into the bench's config, under any value the bench sets itself.

`pending` names the task that adds the read site: until it lands its file does not exist, and when it lands the
file must name the switch.

The app strips at launch every inherited `CMUX*` variable that is not `CMUX_NEXT_*`
(`LaunchIdentity.inheritedKeys`), so a `CMUX_` switch works only when its reader captures it before
`LaunchIdentity.stripInheritedEnvironment` (as `CloudAuth.captureLaunchEnvironment` does). `stripped_at_launch`
says which names that rule removes.

    python3 -I scripts/perf-lab/bench_env.py            # the table
    python3 -I scripts/perf-lab/bench_env.py --json     # the table as JSON
    python3 -I scripts/perf-lab/bench_env.py --check    # exit 1 when a read site does not name its switch

Stdlib only; loaded by file path (bench_launch.py), so it runs under `python3 -I`.
"""
import argparse
import dataclasses
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SWIFT = "Packages/macOS/CmuxNext/Sources/"
KINDS = ("env", "env-launch", "env-unset", "config")


@dataclasses.dataclass(frozen=True)
class Switch:
    name: str
    kind: str
    value: object
    why: str
    read_site: str
    pending: str = None

    def token(self):
        """The text the read site must contain: the variable name, or a config key's last component."""
        return self.name.rsplit(".", 1)[-1] if self.kind == "config" else self.name


SWITCHES = (
    Switch("CMUX_NEXT_NO_ACTIVATE", "env", "1", "never take focus from the person or another bench",
           SWIFT + "CmuxNextApp/AppEnvironment.swift"),
    Switch("CMUX_NEXT_SOCKET_MODE", "env", "automation", "a process of the same account (the bench) may connect",
           SWIFT + "CmuxNextControl/ControlService.swift"),
    Switch("CMUX_NEXT_AGENT_PANE_MOCK", "env", "1", "the agent pane needs no agent login",
           SWIFT + "CmuxNextApp/AgentTabs+PaneSource.swift"),
    Switch("CMUX_NEXT_CHIEF_ISOLATED", "env", "1", "the launch never touches the account's Chief state",
           SWIFT + "CmuxNextHomeEngine/ChiefHome.swift"),
    Switch("ACPMUX_AGENT_LAUNCH", "env", "deny", "no real agent process starts",
           SWIFT + "CmuxNextAgentPane/AcpmuxEnvironment.swift"),
    Switch("SHELL", "env", "/bin/zsh", "the shell terminals start (a fleet step has none)",
           SWIFT + "CmuxNextTerminal/LocalPTYTerminalIO.swift"),
    Switch("CMUX_FEATURES_SAFE_MODE", "env", "off",
           "lab runs measure the resolved features, never a crash-streak fallback (bench builds only)",
           SWIFT + "CmuxNextFeatures/FeatureSafeMode.swift", pending="p12-perf-process-094"),
    Switch("CMUX_NEXT_NOTES_FETCH", "env", "off",
           "no release-notes or flags.json fetch: no network in a measured run",
           SWIFT + "CmuxNextUpdater/FlagsDocumentFetch.swift", pending="p12-perf-process-093"),
    Switch("CMUX_NEXT_CONFIG_FILE", "env-launch", None, "a scratch cmux-next.json (the config below)",
           SWIFT + "CmuxNextSettings/CmuxConfigFile.swift"),
    Switch("CMUX_NEXT_GHOSTTY_CONFIG", "env-launch", None, "an empty Ghostty config, not the account's",
           SWIFT + "CmuxNextTerminal/GhosttyRuntime.swift"),
    Switch("CMUX_NEXT_CHIEF_HOME", "env-launch", None, "a scratch Chief home",
           SWIFT + "CmuxNextHomeEngine/ChiefHome.swift"),
    Switch("CMUX_NEXT_TEST_WINDOW_FRAME", "env-launch", None, "the same window frame on every host",
           SWIFT + "CmuxNextApp/TestWindowPlacement.swift"),
    Switch("CMUX_NEXT_TEST_WINDOW_SCREEN", "env-launch", None, "the window on the main display",
           SWIFT + "CmuxNextApp/TestWindowPlacement.swift"),
    Switch("CMUX_NEXT_DEV_SENTRY", "env-unset", None, "telemetry off: a DEV or bench bundle reports only with it =1",
           SWIFT + "CmuxNextCrashReporting/CrashReportingPolicy.swift"),
    Switch("CMUX_NEXT_DEV_HANG_REPORTS", "env-unset", None, "hang reports off: a DEV bundle sends only with it =1",
           SWIFT + "CmuxNextApp/HangReports/HangReportsController.swift"),
    Switch("updates.checkAutomatically", "config", False, "updater off: no appcast check, download or install",
           SWIFT + "CmuxNextSettings/UpdatesSettings.swift"),
)


def fixed_env():
    """{name: value} of the variables every bench launch sets to a fixed value."""
    return {s.name: s.value for s in SWITCHES if s.kind == "env"}


def unset_env():
    """Names whose off state is their absence."""
    return tuple(s.name for s in SWITCHES if s.kind == "env-unset")


def config_defaults():
    """The cmux-next.json keys every bench config gets, as a nested dict."""
    root = {}
    for s in SWITCHES:
        if s.kind != "config":
            continue
        *parents, leaf = s.name.split(".")
        node = root
        for part in parents:
            node = node.setdefault(part, {})
        node[leaf] = s.value
    return root


def with_config_defaults(config):
    """`config` with each key of ``config_defaults`` it does not set itself (the bench's own value wins)."""
    def merge(base, own):
        out = dict(own)
        for key, value in base.items():
            if key not in out:
                out[key] = value
            elif isinstance(value, dict) and isinstance(out[key], dict):
                out[key] = merge(value, out[key])
        return out
    return merge(config_defaults(), config)


def stripped_at_launch(name):
    """Whether the app unsets `name` when it is inherited (LaunchIdentity.inheritedKeys): every `CMUX*` but the
    `CMUX_NEXT_*` launch knobs."""
    return name.startswith("CMUX") and not name.startswith("CMUX_NEXT_")


def read_site_problems(root=ROOT):
    """One line per switch whose read site does not name it (a pending one only once its file exists)."""
    problems = []
    for s in SWITCHES:
        if s.kind not in KINDS:
            problems.append(f"{s.name}: unknown kind {s.kind}")
            continue
        path = os.path.join(root, s.read_site)
        try:
            with open(path, encoding="utf-8") as f:
                text = f.read()
        except FileNotFoundError:
            if not s.pending:
                problems.append(f"{s.name}: read site {s.read_site} does not exist")
            continue
        if s.token() not in text:
            problems.append(f"{s.name}: {s.read_site} does not read {s.token()}"
                            + (f" ({s.pending} landed without it)" if s.pending else ""))
    return problems


def table():
    return [{**dataclasses.asdict(s), "stripped_at_launch": s.kind.startswith("env") and stripped_at_launch(s.name)}
            for s in SWITCHES]


def main(argv=None):
    parser = argparse.ArgumentParser(description="The bench app's switches and their Swift read sites.")
    parser.add_argument("--json", action="store_true", help="print the table as JSON")
    parser.add_argument("--check", action="store_true", help="exit 1 when a read site does not name its switch")
    opts = parser.parse_args(argv)
    if opts.check:
        problems = read_site_problems()
        for line in problems:
            print(f"bench_env: {line}", file=sys.stderr)
        return 1 if problems else 0
    rows = table()
    if opts.json:
        print(json.dumps(rows, indent=1))
        return 0
    for row in rows:
        value = "" if row["value"] is None else f"={json.dumps(row['value'])}"
        pending = f"  [pending {row['pending']}]" if row["pending"] else ""
        print(f"{row['kind']:<10} {row['name']}{value}  ({row['read_site']}){pending}\n           {row['why']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
