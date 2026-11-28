#!/usr/bin/env python3
"""Rewrite every Linux x64 runner picker in the workflows to the one label, `cmux-linux`.

Leo, 2026-11-20: "you shouldn't have to think about sizing your f*** CI. Like 4V CPU, 8, 16, 32, who
gives a shit? Just send it somewhere. It'll scale up if it needs to. Scale down if it doesn't need
anything."

A Linux x64 picker (a size pool `fromJSON(vars.RUNNER_POOLS).linux_N`, `vars.LINUX_RUNNER`, a literal
vendor `<N>vcpu-ubuntu-2404` label, the overflow switch, `CI_TRUSTED_RUNNER`, the gate runner variable or
the old fleet label) becomes:

    ${{ <owner guard> || <fork pull request> && 'ubuntu-24.04' || <pins> || 'cmux-linux' }}

A fork repository and a fork pull request never reach an owned host: a fork pull request takes
GitHub-hosted Ubuntu, a literal (no repository variable picks it). Nightly and release pins
(`cmux-gcp-nightly-*`, `cmux-gcp-lane-build-x64`, `CI_RELEASE_PIN_SLOT`, the darwin cross build lane, a
caller's `inputs.*` override) keep their branch, after the fork branch; only the size fallback goes.

Left unchanged, and printed as exceptions: a line whose comment marks it `ephemeral-required`,
`github-hosted-required`, `owned-pool-unfit` (a job that failed on the owned pool) or `frozen-label` (an exception this
script froze), and a provenance or npm publish job. A job that leads with a GCP JIT label behind its `*_SKIP_FLEET`
switch keeps that switch. macOS, Windows and arm64 pickers are not
Linux x64; inside a mixed expression (a macOS job that takes Linux on one branch) only the Linux
`(fork && '<size>' || pool)` group is rewritten. `${{ matrix.* }}` runs-on lines are not touched; the
matrix values that feed them are rewritten like any other value line.

Re-runnable: a rewritten line has no picker left, so a second run changes nothing. Run it on a fresh
base to regenerate the change.

Usage: one_linux_label.py [--check] [WORKFLOW_DIR_OR_FILE ...]   (default: .github/workflows)
       --check rewrites nothing and exits 1 when a line would change.
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

LABEL = "cmux-linux"
OWNER_GUARD = "github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04'"
FORK_PR = ("github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository"
           " && 'ubuntu-24.04'")
CANONICAL = f"${{{{ {OWNER_GUARD} || {FORK_PR} || '{LABEL}' }}}}"

# A term naming or choosing a Linux x64 size.
PICKER = re.compile(
    r"RUNNER_POOLS\)\.linux(?!_arm)"
    r"|vars\.LINUX_RUNNER(?![A-Z_])"
    r"|blacksmith-\d+vcpu-ubuntu-2404(?!-)"
    r"|CI_CLOUD_OVERFLOW_SAVED"
    r"|cmux-fleet-linux-x64"
    r"|CI_TRUSTED_RUNNER"
    r"|CI_LINUX_GATE_OWNED_RUNNER"
    r"|head\.repo\.full_name != github\.repository"
    r"|'cmux-linux'"
)
# What makes a line worth reading at all (the fork test alone is not a picker).
TRIGGER = re.compile(
    r"RUNNER_POOLS\)\.linux(?!_arm)|vars\.LINUX_RUNNER(?![A-Z_])|blacksmith-\d+vcpu-ubuntu-2404(?!-)"
    r"|CI_CLOUD_OVERFLOW_SAVED|cmux-fleet-linux-x64|CI_TRUSTED_RUNNER|CI_LINUX_GATE_OWNED_RUNNER"
)
# A branch that pins a run to a named owned host or lane; it keeps its place.
PIN = re.compile(
    r"cmux-gcp-nightly|cmux-gcp-lane-build-x64|glaeda-nightly-only|CI_NIGHTLY_MINI|CI_RELEASE_PIN_SLOT"
    r"|vars\.LINUX_RUNNER_DARWIN_CROSS|vars\.LINUX_BUILD_RUNNER|vars\.CI_\w+_GATEWAY|inputs\.\w+"
    # A live placement's answer (fleet Linux, which now places onto cmux-linux, or an owned Mac or side lane).
    r"|needs\.[\w-]+\.outputs\."
)
# A conditioned arm that already names the label (`<condition> && 'cmux-linux'`): a placement, not a size.
LABEL_ARM = re.compile(rf"^.+ && '{LABEL}'$")
FORK_TEST = "head.repo.full_name != github.repository"
# One Linux arm of a mixed (macOS first) expression's top-level chain: `<condition> && <Linux size picker>`.
MIXED_TERM = re.compile(
    r"^(?P<cond>.+?) && (?:!startsWith\(vars\.LINUX_RUNNER, 'blacksmith-'\) && vars\.LINUX_RUNNER"
    r"|vars\.CI_CLOUD_OVERFLOW_SAVED && fromJSON\(vars\.RUNNER_POOLS\)\.linux_\d+"
    r"|fromJSON\(vars\.RUNNER_POOLS\)\.linux_\d+)$"
)
_SIGNING = "holds a signing secret; rule 7 of tests/test_ci_signing_keychain_is_deleted_before_bundle_code.py needs an ephemeral literal"
_SUBMODULES = ("checks out without submodules and has no stale-submodule reset; tests/test_cmux_next_checks_workflow.py "
               "keeps it off a reused workspace")
# Jobs a guard test keeps on a fresh vendor VM for a reason the route does not spell (workflow, job) -> why.
FRESH_VM_JOBS = {
    **{key: _SIGNING for key in (("ios-appstore-upload.yml", "set-testflight-notes"), ("ios-appstore-upload.yml", "assign-internal"),
                                 ("ios-testflight.yml", "set-testflight-notes"), ("ios-testflight.yml", "assign-internal-group"))},
    ("sdk-release-cut.yml", "cut-tags"): "holds the release app's signing key (#48337); a `# ephemeral-required` tag would "
                                         "need a JIT lead (tests/test_ci_write_token_jit_label.py)",
    ("cmux-next-dev-kick.yml", "kick"): "holds a write token; tests/test_cmux_next_dev_kick.py keeps it on the ephemeral_only pool",
    ("device-hub-logs.yml", "read"): "holds the Cloudflare API token; keeps the ephemeral_only linux_4 pool",
    ("cmux-next-web-pieces.yml", "switch"): "holds the R2 keys and the web OTA signing key; keeps the ephemeral_only linux_4 pool",
    ("nightly-sign.yml", "admit"): "nightly shadow job: reads no repository variable (tests/test_nightly_sign_shadow_workflow.py)",
    ("cmux-next.yml", "fast-tier-cargo"): "tests/test_cmux_next_checks_workflow.py needs an ephemeral Linux VM, never a reused host",
    **{("cmux-next.yml", job): _SUBMODULES for job in (
        "app-compile-placement", "dev-daily-place", "dev-daily-tree-wait", "dev-landing-place", "fast-tier-handback-placement",
        "fast-tier-rerun-placement", "macos-placement", "release-compile-fast-admission", "same-tree-cmux-tui",
        "same-tree-status-daemon", "same-tree-status-scheme", "swift-exports-cache")},
    ("machine-vault-e2e.yml", "machine_join"): "holds account secrets; frozen to the linux_8 label it read (tests/test_machine_join_e2e_workflow.py)",
    ("cmux-next-web-perf.yml", "validate"): "validates head output with base code; tests/test_web_perf_validation_boundary.py "
                                            "keeps it off any runner the measuring job may have touched",
}
# A runner whose label is what it measures: it probes the vendor runner pool, so it keeps its picker.
PROBE_JOBS = {("ci-cloud-overflow-probe.yml", "probe")}
NOT_LINUX_X64 = re.compile(r"'(?:macos|windows)[\w.-]*'|-arm'|ubuntu-latest|RUNNER_POOLS\)\.provenance")
EXCEPTION_COMMENT = re.compile(r"ephemeral-required|github-hosted-required|owned-pool-unfit|frozen-label")
# A credentialed job that leads with its one-job GCP JIT label behind that label's switch
# (tests/test_ci_write_token_jit_label.py: Blacksmith is the overflow behind `=1`). Freezing it to today's switch value
# would drop the JIT label and pin the overflow, so it keeps its switch.
JIT_LEAD = re.compile(r"vars\.CI_[A-Z_]+_SKIP_FLEET != '1' && 'cmux-gcp-[a-z-]+-jit-x64'")
# A route that admits only an ephemeral vendor runner (`contains(fromJSON('["<vendor sizes>"]'), vars.X) && vars.X`):
# a credentialed job the guard tests keep off persistent hosts. cmux-linux is a persistent pool, so it stays.
EPHEMERAL_ONLY = re.compile(r"contains\(fromJSON\('\[[^\]]*\"blacksmith-")
# Keys whose value is a runner label: runs-on itself, a matrix entry that feeds `runs-on: ${{ matrix.* }}`,
# a job output or env value that a later runs-on or placement reads.
VALUE_KEYS = {
    "runs-on", "runner", "os", "runs_on", "pool", "linux_runner", "FLEET_LINUX", "DAEMON_POOL", "RUNNER_LABEL",
    "LINUX_RUNNER", "LINUX_BUILD_RUNNER", "LINUX_DARWIN_RUNNER", "CMUX_NEXT_RUNNER",
}
LINE = re.compile(
    r"^(?P<lead>\s*(?:-\s+)?)(?P<key>[\w-]+):(?P<sp>\s+)(?P<anchor>&\S+\s+)?"
    r"(?P<expr>\$\{\{.*\}\})(?P<tail>\s*(?:#.*)?)$"
)
JOB = re.compile(r"^  (?P<id>[\w-]+):\s*(?:#.*)?$")
# The Linux arm of a mixed expression: `(fork && '<size>' || pool)`.
MIXED_GROUP = re.compile(
    r"\(github\.event_name == 'pull_request' && github\.event\.pull_request\.head\.repo\.full_name != "
    r"github\.repository && 'blacksmith-\d+vcpu-ubuntu-2404' \|\| fromJSON\(vars\.RUNNER_POOLS\)\.linux(?:_\d+)?\)"
)
MIXED_REPLACEMENT = f"({FORK_PR} || '{LABEL}')"


@dataclass
class Report:
    changed: list[tuple[str, int, str]] = field(default_factory=list)
    exceptions: list[tuple[str, int, str]] = field(default_factory=list)
    unconverted: list[tuple[str, int, str]] = field(default_factory=list)


def split_top(expr: str, op: str = "||") -> list[str]:
    """Split on `op` outside parentheses and string literals."""
    parts, depth, start, i, quoted = [], 0, 0, 0, False
    while i < len(expr):
        c = expr[i]
        if quoted:
            if c == "'":
                if expr[i + 1:i + 2] == "'":
                    i += 1
                else:
                    quoted = False
        elif c == "'":
            quoted = True
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        elif depth == 0 and expr.startswith(op, i):
            parts.append(expr[start:i].strip())
            i += len(op)
            start = i
            continue
        i += 1
    parts.append(expr[start:].strip())
    return parts


def wrapped(term: str) -> bool:
    """`(...)` around the whole term."""
    if not (term.startswith("(") and term.endswith(")")):
        return False
    depth, quoted = 0, False
    for i, c in enumerate(term):
        if quoted:
            quoted = c != "'"
        elif c == "'":
            quoted = True
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0 and i != len(term) - 1:
                return False
    return True


def or_terms(expr: str) -> list[str]:
    """The top-level `||` chain, with wholly parenthesized `||` terms flattened into it."""
    out = []
    for term in split_top(expr):
        if wrapped(term) and len(split_top(term[1:-1])) > 1:
            out.extend(or_terms(term[1:-1]))
        else:
            out.append(term)
    return out


# A pool list (`format('<owned label>,{0}', <picker>)`, DAEMON_POOL): only the picker inside moves.
FORMAT_TERM = re.compile(r"^format\('(?P<lead>[^'{}]*,)\{0\}', (?P<inner>.+)\)$")


def rewrite_expr(expr: str) -> str | None:
    """The one-label form of a `${{ ... }}` Linux x64 picker; None when it is not one, or holds an unknown term."""
    body = expr[3:-2].strip()
    terms = or_terms(body)
    if terms and terms[0].startswith("github.repository_owner != 'manaflow-ai' &&"):
        if NOT_LINUX_X64.search(terms[0]) or "ubuntu" not in terms[0]:
            return None
        terms = terms[1:]
    if len(terms) == 1 and (fm := FORMAT_TERM.match(terms[0])):
        inner = rewrite_expr("${{ " + fm["inner"] + " }}")
        if inner is None:
            return None
        inner = inner[3:-2].strip().removeprefix(OWNER_GUARD + " || ")
        return "${{ " + f"{OWNER_GUARD} || format('{fm['lead']}{{0}}', {inner})" + " }}"
    # Kept terms stay in their order; the fork branch takes the place of the first fork or size term, so a pin
    # that came before it (a push-only nightly arm) still comes first and one after it still comes after.
    kept, picked, fork_at, fork_literal = [], False, None, False
    for term in terms:
        if FORK_TEST in term and "vars." not in term and "fromJSON" not in term and fork_at is None:
            # A fork arm that is already a literal (a Blacksmith size the fork keeps) is not a picker: it stays.
            fork_at, fork_literal = len(kept), True
            kept.append(term)
        elif LABEL_ARM.match(term) and not TRIGGER.search(term) and FORK_TEST not in term:
            kept.append(term)  # a conditioned arm already on the label (PR control, push roots): keeps its place
        elif PICKER.search(term):
            picked = True
            fork_at = len(kept) if fork_at is None else fork_at
        elif PIN.search(term):
            kept.append(term)
        elif NOT_LINUX_X64.search(term):
            return None
        else:
            return None
    if not picked:
        return None
    if not fork_literal:
        kept.insert(fork_at, FORK_PR)
    return "${{ " + " || ".join([OWNER_GUARD, *kept, f"'{LABEL}'"]) + " }}"


def rewrite_mixed(expr: str) -> str:
    """In an expression that is not Linux x64 first (a macOS job with a Linux arm), only the Linux arms move.

    Its fork pull request has already taken its own (macOS) branch before any Linux arm."""
    expr = MIXED_GROUP.sub(MIXED_REPLACEMENT, expr)
    terms, out = split_top(expr[3:-2].strip()), []
    for term in terms:
        if m := MIXED_TERM.match(term):
            term = f"{m['cond']} && '{LABEL}'"
        if not out or out[-1] != term:
            out.append(term)
    return "${{ " + " || ".join(out) + " }}"


# What each repository variable a picker reads resolves to today on an own-branch run, read from the labels real
# jobs ran on (2026-11-24: ci-health-report's runner variable report, and cmux-tui-artifacts, cmux-next,
# cmux-next-base-autofix, cloud-vm-image-roll, cloud-chief-machine and machine-join-e2e runs). A line this script
# keeps (an exception) or cannot convert is frozen to that answer: a literal with the same owner guard, fork and
# event arms, and no variable (cmuxterm-hq goals/linux-pickers-gone.md: no runs-on reads a variable). A variable
# missing here stays, and the line is reported, so a picker is never guessed away.
TODAY_VARS = {
    "LINUX_RUNNER": "cmux-fleet-linux-x64",
    "CI_TRUSTED_RUNNER": "blacksmith-4vcpu-ubuntu-2404",
    "CI_CLOUD_OVERFLOW_SAVED": "",
    "CI_REPAIR_SKIP_FLEET": "1",
    "CI_DEPLOY_SKIP_FLEET": "",
    "CI_PR_CONTROL_SKIP_FLEET": "1",
}
TODAY_POOLS = {
    "linux_2": "cmux-fleet-linux-x64",
    "linux_4": "blacksmith-4vcpu-ubuntu-2404",
    "linux_8": "cmux-fleet-linux-x64",
    "provenance": "ubuntu-latest",
}
# Lines this pass freezes: the ones reading a size pool, the fleet variable or the overflow switch's saved state.
FREEZE_SCOPE = re.compile(
    r"RUNNER_POOLS|vars\.LINUX_RUNNER(?![A-Z_])|CI_CLOUD_OVERFLOW_SAVED|CI_TRUSTED_RUNNER|CI_(?:PR_CONTROL|REPAIR)_SKIP_FLEET")
_UNKNOWN = object()


def _lit(value) -> str:
    return ("true" if value else "false") if isinstance(value, bool) else "'" + str(value).replace("'", "''") + "'"


def _top_find(expr: str, needle: str) -> int:
    depth, quoted, i = 0, False, 0
    while i < len(expr):
        c = expr[i]
        if quoted:
            quoted = c != "'"
        elif c == "'":
            quoted = True
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
        elif depth == 0 and expr.startswith(needle, i):
            return i
        i += 1
    return -1


def _factor(f: str):
    """A value (str or bool) when F is known today, else F's simplified text in a list."""
    f = f.strip()
    if wrapped(f):
        inner = _or(f[1:-1])
        return inner if not isinstance(inner, list) else ["(" + inner[0] + ")"]
    for op in (" != ", " == "):
        at = _top_find(f, op)
        if at >= 0:
            a, b = _factor(f[:at]), _factor(f[at + len(op):])
            if isinstance(a, list) or isinstance(b, list):
                return [f"{a[0] if isinstance(a, list) else _lit(a)}{op}{b[0] if isinstance(b, list) else _lit(b)}"]
            same = str(a).lower() == str(b).lower()
            return same if op == " == " else not same
    if f.startswith("!"):
        v = _factor(f[1:])
        return not v if not isinstance(v, list) else ["!" + v[0]]
    if m := re.fullmatch(r"'((?:[^']|'')*)'", f):
        return m[1].replace("''", "'")
    if m := re.fullmatch(r"vars\.(\w+)", f):
        return TODAY_VARS[m[1]] if m[1] in TODAY_VARS else [f]
    if m := re.fullmatch(r"fromJSON\(vars\.RUNNER_POOLS\)\.(\w+)", f):
        return TODAY_POOLS[m[1]] if m[1] in TODAY_POOLS else [f]
    if m := re.fullmatch(r"(contains|startsWith)\((.*)\)", f):
        at = _top_find(m[2], ", ")
        if at >= 0:
            a_text, b_text = m[2][:at].strip(), m[2][at + 2:]
            listed = re.fullmatch(r"fromJSON\('(\[.*\])'\)", a_text)
            a = json.loads(listed[1]) if listed else _factor(a_text)
            b = _factor(b_text)
            if not isinstance(b, list) and (listed or not isinstance(a, list)):
                if m[1] == "contains" and listed:
                    return b in a
                if m[1] == "startsWith" and not listed:
                    return str(a).lower().startswith(str(b).lower())
            a_out = a_text if listed else (a[0] if isinstance(a, list) else _lit(a))
            b_out = b[0] if isinstance(b, list) else _lit(b)
            return [f"{m[1]}({a_out}, {b_out})"]
    return [f]


def _and(expr: str):
    texts, value = [], True
    factors = split_top(expr, "&&")
    for k, f in enumerate(factors):
        v = _factor(f)
        if isinstance(v, list):
            texts.append(v[0])
            value = _UNKNOWN
            continue
        if not v:
            return ""  # this term is false whatever came before it
        if k == len(factors) - 1:
            if not texts:
                return v
            texts.append(_lit(v))
    if value is True and not texts:
        return value
    return [" && ".join(texts)]


def _or(expr: str):
    out = []
    for term in split_top(expr):
        v = _and(term)
        if isinstance(v, list):
            out.append(v[0])
            continue
        if not v:
            continue
        if not out:
            return v
        out.append(_lit(v))
        break
    if not out:
        return ""
    return [" || ".join(out)]


def freeze_expr(expr: str) -> str:
    """EXPR (`${{ ... }}`) with every variable it reads replaced by today's answer and the dead arms dropped."""
    v = _or(expr[3:-2].strip())
    return "${{ " + (v[0] if isinstance(v, list) else _lit(v)) + " }}"


SIZE_LEFT = re.compile(r"blacksmith-\d+vcpu-ubuntu-2404(?!-)|RUNNER_POOLS\)\.linux(?!_arm)|vars\.LINUX_RUNNER(?![A-Z_])")


def signing_jobs(text: str) -> set[str]:
    """Jobs holding signing material (tests/runs_on_labels.py's detector): they keep an ephemeral runner."""
    import yaml
    if str(ROOT / "tests") not in sys.path:
        sys.path.insert(0, str(ROOT / "tests"))
    from runs_on_labels import holds_signing_material
    jobs = (yaml.safe_load(text) or {}).get("jobs") or {}
    return {name for name, job in jobs.items() if isinstance(job, dict) and holds_signing_material(job)}


def freeze_line(expr: str) -> str | None:
    """EXPR frozen to today's answer when it is a Linux line in FREEZE_SCOPE and no variable is left after; else None."""
    if not FREEZE_SCOPE.search(expr) or re.search(r"github\.repository_owner != 'manaflow-ai' && '(?:macos|windows)", expr):
        return None
    frozen = freeze_expr(expr)
    # `owner guard && 'ubuntu-latest' || 'ubuntu-latest'` (a provenance job) is the plain label.
    frozen = re.sub(r"^\$\{\{ github\.repository_owner != 'manaflow-ai' && '([^']*)' \|\| '\1' \}\}$", r"\1", frozen)
    # A fork pull request arm that now names the same label as the route after it says it once.
    fork = re.escape(FORK_PR.removesuffix(" && 'ubuntu-24.04'"))
    frozen = re.sub(rf"\({fork} && ('[^']*') \|\| \1\)", r"\1", frozen)
    frozen = re.sub(rf"{fork} && ('[^']*') \|\| \1 \}}\}}$", r"\1 }}", frozen)
    # A route with no owner guard failed in a fork while its variable was unset there; frozen to an owned or
    # vendor label it would queue forever instead, so it takes the guard every other Linux route leads with.
    if not frozen.startswith("${{ github.repository_owner") and re.search(r"'(?!ubuntu-)[^']+' \}\}$", frozen):
        frozen = frozen.replace("${{ ", f"${{{{ {OWNER_GUARD} || ", 1)
    # An expression left with one quoted label and nothing else is that label.
    frozen = re.sub(r"^\$\{\{ '([^']*)' \}\}$", r"\1", frozen)
    return frozen if frozen != expr and not re.search(r"vars\.|fromjson\(vars", frozen, re.I) else None


STALE_PICKER_NOTE = re.compile(r";? ?CI_TRUSTED_RUNNER picks the Blacksmith size")


def freeze_into(lines: list[str], n: int, m: re.Match, frozen: str | None, report: Report, where: str,
                reason: str = "") -> bool:
    """Write FROZEN over line N (keeping its key, anchor and comment) and report it; False when there is none.

    An exception frozen for REASON says so in a `# frozen-label:` comment, so a later run keeps it (EXCEPTION_COMMENT):
    with its variable gone, nothing else in the line marks it, and the next run would move it to the one label."""
    if frozen is None:
        return False
    # A comment that names the variable it no longer reads ("CI_TRUSTED_RUNNER picks the Blacksmith size") says so.
    tail = STALE_PICKER_NOTE.sub("", m["tail"])
    if reason and not EXCEPTION_COMMENT.search(tail):
        tail = f"{tail.rstrip()}; frozen-label: {reason}" if tail.strip() else f" # frozen-label: {reason}"
    lines[n - 1] = f"{m['lead']}{m['key']}:{m['sp']}{m['anchor'] or ''}{frozen}{tail}"
    report.changed.append((where.split(":")[0], n, f"{where} (frozen to today's label)"))
    return True


def rewrite_text(name: str, text: str, report: Report, signing: set[str] | None = None) -> str:
    lines = text.split("\n")
    signing = signing_jobs(text) if signing is None else signing
    job = ""
    for n, line in enumerate(lines, 1):
        if m := JOB.match(line):
            job = m["id"]
        m = LINE.match(line)
        if not m or m["key"] not in VALUE_KEYS:
            continue
        where = f"{name}:{n} ({job}.{m['key']})"
        if JIT_LEAD.search(m["expr"]):
            report.exceptions.append((name, n, f"{job}: leads with a JIT label behind its switch; keeps the switch"))
            continue
        frozen = freeze_line(m["expr"]) if (name, job) not in PROBE_JOBS else None
        if not TRIGGER.search(m["expr"]):
            # Not a Linux x64 size (a provenance publish job's GitHub-hosted runner): only its variable goes.
            freeze_into(lines, n, m, frozen, report, where)
            continue
        if EXCEPTION_COMMENT.search(m["tail"]):
            report.exceptions.append((name, n, f"{job}: {m['tail'].strip()}"))
            freeze_into(lines, n, m, frozen, report, where)
            continue
        if "provenance" in job or ("npm" in name and "publish" in job and "npm" in job):
            report.exceptions.append((name, n, f"{job}: provenance/npm publish job"))
            freeze_into(lines, n, m, frozen, report, where, "provenance or npm publish job")
            continue
        if EPHEMERAL_ONLY.search(m["expr"]):
            report.exceptions.append((name, n, f"{job}: admits only an ephemeral vendor runner (credentialed job)"))
            freeze_into(lines, n, m, frozen, report, where, "credentialed job, frozen to today's label")
            continue
        if job in signing:
            report.exceptions.append((name, n, f"{job}: holds signing material; keeps its ephemeral runner"))
            freeze_into(lines, n, m, frozen, report, where, "holds signing material")
            continue
        if (name, job) in FRESH_VM_JOBS:
            report.exceptions.append((name, n, f"{job}: {FRESH_VM_JOBS[(name, job)]}"))
            freeze_into(lines, n, m, frozen, report, where, FRESH_VM_JOBS[(name, job)])
            continue
        if (name, job) in PROBE_JOBS:
            report.exceptions.append((name, n, f"{job}: probes the vendor runner pool; its label is what it measures"))
            continue
        new = rewrite_expr(m["expr"])
        if new is None:
            mixed = rewrite_mixed(m["expr"])
            if mixed != m["expr"] and not SIZE_LEFT.search(mixed):
                new = mixed
        if new is None:
            if not freeze_into(lines, n, m, frozen, report, where):
                report.unconverted.append((name, n, where))
            continue
        if new == m["expr"]:
            continue
        lines[n - 1] = f"{m['lead']}{m['key']}:{m['sp']}{m['anchor'] or ''}{new}{m['tail']}"
        report.changed.append((name, n, where))
    return "\n".join(lines)


# Values that followed a size and must follow the new route: (workflow, old, new). A fork pull request's webview shard
# took the 16 vCPU vendor runner and 40 minutes; on GitHub-hosted 4 vCPU Ubuntu it needs the 4 vCPU arms' 90.
FOLLOW_ON = (
    ("ci-web.yml",
     "timeout-minutes: &webview-shard-minutes ${{ github.repository_owner != 'manaflow-ai' && 90 || github.event_name == "
     "'pull_request' && github.event.pull_request.head.repo.full_name != github.repository && 40 ||",
     "timeout-minutes: &webview-shard-minutes ${{ github.repository_owner != 'manaflow-ai' && 90 || github.event_name == "
     "'pull_request' && github.event.pull_request.head.repo.full_name != github.repository && 90 ||"),
)


def follow_on(name: str, text: str, report: Report) -> str:
    for workflow, old, new in FOLLOW_ON:
        if workflow == name and old in text:
            text = text.replace(old, new)
            report.changed.append((name, 0, f"{name} (follow-on: {new.split(':')[0]})"))
    return text


# Workflows a run leaves alone -> why. .github/language-boundaries.toml: a pull request that changes
# language-boundaries.yml fails its check unless Leo approves it (leo-approved-port), so its runs-on moves only in a PR
# he approves.
LEO_GATED = {"language-boundaries.yml": "a change to it needs Leo's leo-approved-port (.github/language-boundaries.toml)"}


def workflow_files(args: list[str]) -> list[Path]:
    paths = [Path(a) for a in args] or [ROOT / ".github/workflows"]
    files: list[Path] = []
    for p in paths:
        if p.is_dir():
            files.extend(f for f in sorted([*p.glob("*.yml"), *p.glob("*.yaml")]) if f.name not in LEO_GATED)
        else:
            files.append(p)
    return files


def main(argv: list[str]) -> int:
    check = "--check" in argv
    report = Report()
    for path in workflow_files([a for a in argv if a != "--check"]):
        text = path.read_text()
        new = follow_on(path.name, rewrite_text(path.name, text, report), report)
        if new != text and not check:
            path.write_text(new)
    files = sorted({name for name, _, _ in report.changed})
    print(f"changed {len(report.changed)} lines in {len(files)} files")
    for _, _, where in report.changed:
        print(f"  changed {where}")
    for name, n, why in report.exceptions:
        print(f"  exception {name}:{n} {why}")
    for _, _, where in report.unconverted:
        print(f"  unconverted {where}")
    return 1 if check and report.changed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
