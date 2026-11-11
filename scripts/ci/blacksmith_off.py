#!/usr/bin/env python3
"""CI_BLACKSMITH_OFF: one repository variable that keeps every job off Blacksmith while it is '1'.

Leo, 2026-11-10: "just stop using blacksmith temporarily".

This is temporary. To turn it on:  gh variable set CI_BLACKSMITH_OFF -R manaflow-ai/cmux -b 1
To go back to today's routing:     gh variable delete CI_BLACKSMITH_OFF -R manaflow-ai/cmux

Unset (the default), nothing changes: every wrapped runs-on starts with `vars.CI_BLACKSMITH_OFF == '1' && ...`,
which is false, so the job takes its original expression, kept whole as the last term.

Set to '1', a job whose original runs-on would pick a `blacksmith-*` label takes instead:
- Linux x64: the GCP fleet's ephemeral label `cmux-fleet-linux-x64` (cmuxterm-hq
  build-fleet/swift-linux-builder/gha-runners/README.md; the workflow file must be in that directory's
  workflows.json, or nothing boots for it);
- Linux arm64: GitHub-hosted `ubuntu-24.04-arm` (the GCP fleet is x64 only);
- macOS: an owned CI Mac label: the glaeda label the job's own runs-on already names, else the label for
  its class in .github/runners.json `macos_jobs` (OWNED_BY_CLASS);
- Windows: GitHub-hosted `windows-2025` (no owned Windows runner exists);
- a fork's pull request event (head repository is not this one, e.g. pull_request_target): GitHub-hosted
  `ubuntu-24.04` / `macos-15` / `macos-26`, never an owned Mac or the GCP fleet.

A job whose original runs-on picks a label that is not Blacksmith (an owned Mac from a picker, hosted
Ubuntu, the GCP fleet) keeps it: the switch only replaces a Blacksmith answer.

A fork's `pull_request` run gets no repository variables, so the switch cannot reach it: those jobs keep
their Blacksmith fork label. Jobs that only make sense on Blacksmith (the overflow probe, Testbox, sticky
disks) are skipped while the switch is on (tests/test_ci_blacksmith_off_switch.py checks both).

    python3 scripts/ci/blacksmith_off.py --write   # wrap every runs-on that can reach Blacksmith
    python3 scripts/ci/blacksmith_off.py --check   # exit 1 naming each one that is not wrapped
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOWS = ROOT / ".github" / "workflows"
RUNNERS = ROOT / ".github" / "runners.json"

VARIABLE = "CI_BLACKSMITH_OFF"
GATE = f"vars.{VARIABLE} == '1'"
# A job or step that only works on Blacksmith adds this to its `if:`.
SKIP_WHEN_OFF = f"vars.{VARIABLE} != '1'"
FORK = "github.event.pull_request && github.event.pull_request.head.repo.full_name != github.repository"
GCP_FLEET_LINUX = "cmux-fleet-linux-x64"
HOSTED_LINUX = "ubuntu-24.04"
HOSTED_LINUX_ARM = "ubuntu-24.04-arm"
HOSTED_WINDOWS = "windows-2025"
# Only a fork's pull request event takes these (FORK): it may not run on an owned Mac.
HOSTED_MACOS_15 = "macos-15"
HOSTED_MACOS_26 = "macos-26"
# The owned class a macOS job takes when its runs-on names no glaeda label of its own.
OWNED_BY_CLASS = {
    "apple-signing-release": "glaeda-trusted-next-signing",
    "apple-gui": "glaeda-gui-std-xcode-26.6",
}
OWNED_DEFAULT = "glaeda-std-xcode-26.6"
# An owned pool label a runs-on may already name (not glaeda-ios-sim, a capability beside a pool).
OWNED_POOL = re.compile(r"'(glaeda-[a-z0-9-]*xcode-[0-9.]+|glaeda-nightly-only-m4pro|glaeda-trusted-next-signing)'")

RUNS_ON = re.compile(r"^(?P<lead>\s*runs-on:\s*)(?P<value>\S.*?)(?P<comment>\s+#.*)?$")
EXPRESSION = re.compile(r"^\$\{\{\s*(?P<inner>.*?)\s*\}\}$")
JOB = re.compile(r"^  (?P<id>[A-Za-z0-9_-]+):\s*(?:#.*)?$")
BLACKSMITH = re.compile(r"blacksmith-[0-9]+vcpu-[a-z0-9.-]+")
WRAPPED = re.compile(
    r"^\$\{\{ " + re.escape(GATE) + r" && contains\(toJSON\((?P<orig>.*)\), '\"blacksmith-'\) && (?P<off>.*) \|\| "
    r"\((?P=orig)\) \}\}$")


def off_linux() -> str:
    return f"({FORK} && '{HOSTED_LINUX}' || '{GCP_FLEET_LINUX}')"


def off_macos(owned: str, hosted: str) -> str:
    return f"({FORK} && '{hosted}' || '{owned}')"


def macos_classes(runners: Path = RUNNERS) -> dict[str, str]:
    table = json.loads(runners.read_text(encoding="utf-8")).get("macos_jobs", {})
    out = {}
    for key, value in table.items():
        if key.startswith("$"):
            continue
        out[key] = value if isinstance(value, str) else str(value.get("class", ""))
    return out


def families(inner: str) -> set[str]:
    """The families (linux, arm, macos, windows) of the Blacksmith labels, pools and runner variables it names."""
    found = set()
    for label in BLACKSMITH.findall(inner):
        if "-macos-" in label:
            found.add("macos")
        elif "-windows-" in label:
            found.add("windows")
        elif label.endswith("-arm"):
            found.add("arm")
        else:
            found.add("linux")
    for pool in re.findall(r"fromJSON\(vars\.RUNNER_POOLS\)\.([a-z0-9_]+)", inner):
        found.add("macos" if pool.startswith("macos") else "windows" if pool == "windows"
                  else "arm" if pool == "linux_arm64" else "linux")
    for name in re.findall(r"vars\.([A-Z0-9_]+)", inner):
        if name.startswith("MACOS_RUNNER"):
            found.add("macos")
        elif name in {"LINUX_RUNNER", "CI_TRUSTED_RUNNER"}:
            found.add("linux")
        elif name == "WINDOWS_RUNNER":
            found.add("windows")
    for capability in re.findall(r"fromJSON\(needs\.runners\.outputs\.map\)\.([a-z0-9_]+)", inner):
        found.add("macos" if capability.startswith("macos") else "arm" if capability == "linux_arm64" else "linux")
    if not found:
        # The fork-owner branch names the job's OS family when nothing else does.
        owner = re.search(r"github\.repository_owner != 'manaflow-ai' && '([a-z0-9.-]+)'", inner)
        if owner:
            found.add("macos" if owner.group(1).startswith("macos") else
                      "windows" if owner.group(1).startswith("windows") else "linux")
    return found


# A job that holds signing or release material (tests/runs_on_labels.py SIGNING_JOB): its owned route is the trusted
# signing Mac, never a shared mini.
SIGNING_JOB = re.compile(
    r"secrets\.(?:APPLE|SIGN|CMUX_RELEASE|NOTARY)|codesign|notarytool|signing-keychain|gh release upload"
    r"|softprops/action-gh-release", re.IGNORECASE)


def job_classes(path: Path, classes: dict[str, str]) -> dict[str, str]:
    """job id -> its macos_jobs class, with apple-signing-release for any job that holds signing material."""
    import yaml
    document = yaml.load(path.read_text(encoding="utf-8"), Loader=yaml.BaseLoader) or {}
    out = {}
    for name, job in (document.get("jobs") or {}).items():
        out[name] = classes.get(f"{path.name}#{name}", "")
        if isinstance(job, dict) and SIGNING_JOB.search(yaml.safe_dump(job)):
            out[name] = "apple-signing-release"
    return out


def family(inner: str) -> str | None:
    """The one family the expression names, or None when it names several or none (read at run time)."""
    found = families(inner)
    return next(iter(found)) if len(found) == 1 else None


def hosted_macos(inner: str) -> str:
    """The GitHub-hosted image a fork's macOS job takes: macos-15 when every Blacksmith macOS label it names is 15."""
    labels = [label for label in BLACKSMITH.findall(inner) if "-macos-" in label]
    return HOSTED_MACOS_15 if labels and all("-macos-15" in label for label in labels) else HOSTED_MACOS_26


def owned_macos(inner: str, job_class: str) -> str:
    named = OWNED_POOL.search(inner)
    if named:
        return named.group(1)
    return OWNED_BY_CLASS.get(job_class, OWNED_DEFAULT)


def off_route(inner: str, job_class: str) -> str:
    kind = family(inner)
    owned = owned_macos(inner, job_class)
    if kind == "linux":
        return off_linux()
    if kind == "arm":
        return f"'{HOSTED_LINUX_ARM}'"
    if kind == "windows":
        return f"'{HOSTED_WINDOWS}'"
    if kind == "macos":
        return off_macos(owned, hosted_macos(inner))
    # The family is only known at run time (a matrix row, a picker's output, two families): read it from the label.
    possible = families(inner) or {"linux", "arm", "macos", "windows"}
    probe = f"toJSON({inner})"
    branches: list[tuple[str, str]] = []
    if "macos" in possible:
        branches.append((f"contains({probe}, '-macos-')", off_macos(owned, hosted_macos(inner))))
    if "windows" in possible:
        branches.append((f"contains({probe}, '-windows-')", f"'{HOSTED_WINDOWS}'"))
    if "arm" in possible:
        branches.append((f"contains({probe}, '-arm\"')", f"'{HOSTED_LINUX_ARM}'"))
    if "linux" in possible:
        branches.append(("", off_linux()))
    # The last family needs no test: it is what a Blacksmith label that is none of the others is.
    *tested, (_, last) = branches
    return "(" + " || ".join([f"{test} && {route}" for test, route in tested] + [last]) + ")"


def wrap(value: str, job_class: str = "") -> str:
    """The runs-on `value` (a label or `${{ }}`), wrapped so CI_BLACKSMITH_OFF=1 replaces a Blacksmith answer."""
    whole = EXPRESSION.match(value.strip())
    inner = whole.group("inner") if whole else "'" + value.strip().replace("'", "''") + "'"
    return (f"${{{{ {GATE} && contains(toJSON({inner}), '\"blacksmith-') && {off_route(inner, job_class)} || "
            f"({inner}) }}}}")


def unwrap(value: str) -> str:
    """The original runs-on of a wrapped value (the value itself when it is not wrapped)."""
    match = WRAPPED.match(value.strip())
    return "${{ " + match.group("orig") + " }}" if match else value


def is_wrapped(value: str) -> bool:
    return WRAPPED.match(value.strip()) is not None


def needs_wrap(value: str) -> bool:
    """Whether the runs-on can name Blacksmith: a Blacksmith label or pool, or any value read at run time."""
    value = value.strip()
    if is_wrapped(value):
        return False
    whole = EXPRESSION.match(value)
    if not whole:
        return BLACKSMITH.fullmatch(value) is not None
    inner = whole.group("inner")
    if BLACKSMITH.search(inner) or "RUNNER_POOLS" in inner:
        return True
    # Anything read at run time (a variable, a picker's output, a matrix row, an input) may be a Blacksmith label.
    return re.search(r"\b(?:vars|needs|matrix|inputs|steps|env)\.", inner) is not None


def rewrite(path: Path, classes: dict[str, str]) -> tuple[str, list[str]]:
    """The file's text with every runs-on that can reach Blacksmith wrapped, and `file#job` for each one."""
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    by_job = job_classes(path, classes)
    in_jobs = False
    job = ""
    changed: list[str] = []
    runs_on_value: dict[str, tuple[str, str]] = {}
    for index, line in enumerate(lines):
        body = line.rstrip("\n")
        if re.match(r"^jobs:\s*(#.*)?$", body):
            in_jobs = True
            continue
        if in_jobs and re.match(r"^\S", body) and not body.startswith("#"):
            in_jobs = False
        if in_jobs:
            match = JOB.match(body)
            if match:
                job = match.group("id")
        match = RUNS_ON.match(body)
        if not match or not in_jobs:
            continue
        value = match.group("value")
        if not needs_wrap(value):
            continue
        key = f"{path.name}#{job}"
        new = wrap(value, by_job.get(job, ""))
        runs_on_value[job] = (value, new)
        lines[index] = match.group("lead") + new + (match.group("comment") or "") + "\n"
        changed.append(key)
    # An env value that copies its job's runs-on (CMUX_NEXT_RUNNER) follows it, so the job's scripts see the label it runs on.
    job = ""
    in_jobs = False
    for index, line in enumerate(lines):
        body = line.rstrip("\n")
        if re.match(r"^jobs:\s*(#.*)?$", body):
            in_jobs = True
            continue
        if in_jobs and re.match(r"^\S", body) and not body.startswith("#"):
            in_jobs = False
        if in_jobs and JOB.match(body):
            job = JOB.match(body).group("id")
            continue
        if not in_jobs or job not in runs_on_value or RUNS_ON.match(body):
            continue
        old, new = runs_on_value[job]
        env = re.match(r"^(\s+[A-Z][A-Z0-9_]*:\s+)" + re.escape(old) + r"(\s+#.*)?$", body)
        if env:
            lines[index] = env.group(1) + new + (env.group(2) or "") + "\n"
    return "".join(lines), changed


def workflow_files(root: Path = ROOT) -> list[Path]:
    folder = root / ".github" / "workflows"
    return sorted([*folder.glob("*.yml"), *folder.glob("*.yaml")])


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--write", action="store_true", help="wrap every runs-on that can reach Blacksmith")
    mode.add_argument("--check", action="store_true", help="name each runs-on that can reach Blacksmith unwrapped")
    args = parser.parse_args(argv)
    classes = macos_classes()
    missing: list[str] = []
    for path in workflow_files():
        text, changed = rewrite(path, classes)
        if not changed:
            continue
        if args.write:
            path.write_text(text, encoding="utf-8")
            print(f"{path.relative_to(ROOT)}: wrapped {len(changed)} runs-on")
        else:
            missing.extend(changed)
    if args.check and missing:
        for key in missing:
            print(f"{key}: runs-on can reach Blacksmith and ignores {VARIABLE} "
                  f"(python3 scripts/ci/blacksmith_off.py --write)", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
