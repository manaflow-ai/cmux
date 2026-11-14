#!/usr/bin/env python3
"""The cmux NEXT nightly, built, signed, notarized and published from an owned Mac while GitHub Actions starts no runs.

Leo, 2026-11-11, on "when Actions isn't starting runs, our fleet picks up the nightly build and our compile/test
checks straight from the git mirror. Merges still wait on GitHub, but you keep getting builds and agents keep
testing.": "Yeah, IMO, we should just definitely do these." That day 20:17Z-21:38Z Actions started no runs
anywhere (every run queued with 0 jobs or startup_failure); git kept working, and the nightly waited 81 minutes.

  nightly_next_fleet_fallback.py run --sha SHA --build N|auto [--workdir D] [--git-dir G] [--dry-run]
  nightly_next_fleet_fallback.py run --sha SHA --build N|auto --candidate-out DIR [--no-smoke]
                                                            an unsigned candidate, no credentials (run_candidate)
  nightly_next_fleet_fallback.py plan [--workflow FILE]     the steps a run executes and skips, as JSON
  nightly_next_fleet_fallback.py gh-shim ARGS...            the `gh` every step sees (see below)

Entry point: scripts/ci/nightly-next-fleet-fallback.sh (it runs this file's `run`).

Same scripts, same order, same env names, by construction: this file does not restate the pipeline. It reads
.github/workflows/nightly.yml at SHA and executes the jobs that build, sign, notarize, verify and publish the arm64
Nightly-ring feed (MIRRORED_JOBS, in their `needs` order), step by step: each step's `if:`, `env:` (workflow, job,
step), `with:` and `run:` body evaluated as Actions would (GitHub expression syntax, GITHUB_OUTPUT/GITHUB_ENV/
GITHUB_PATH, continue-on-error, timeout-minutes), each job's `outputs:` feeding the next job's `needs`. The only
departures are listed, each with its reason:

  SKIPPED_STEPS      steps it does not run (GitHub API, glaeda runner plumbing, Sentry); the rest run verbatim.
  ACTIONS            how each `uses:` action is stood in for: checkout from the git mirror (alternates, no copy),
                     upload/download-artifact through a local directory, caches and toolchain setup as no-ops
                     (the host has its toolchains), app tokens as a placeholder the gh shim never sends anywhere.
  synthetic needs    the jobs it does not run (decide, the runner pickers, recovery) are given the outputs a plain
                     nightly-next push run gives them (decide_outputs()).

tests/test_nightly_next_fleet_fallback.py is the class detector for drift: it fails when a mirrored job gains a
step or a script this file has not classified (listing it), when a skipped step no longer exists, or when a step
reads a `secrets.*`, `vars.*` or `needs.decide.outputs.*` this file does not provide. The run itself checks the
same at SHA before building anything, so an older or newer nightly.yml than this file knows refuses (exit 1).

No GitHub API. Every step's PATH starts with a `gh` (this file's gh-shim) that answers from the git mirror and the
cached repository variables only: `repos/R/compare/A...B` (git merge-base), raw file contents at a ref (git show),
`repos/R/actions/variables/NAME` (the variables snapshot, see below). Anything else fails with a clear line, so a
step that would need the API fails loudly instead of half-working. write-feed orders sources with
NIGHTLY_NEXT_SOURCE_GIT_DIR (git merge-base in the mirror). Git over the git protocol is fine (submodules).

NIGHTLY_NEXT_WRITER and the other repository variables: the workflow reads vars.* at run start, and
publish-final-gate.sh reads NIGHTLY_NEXT_WRITER live through the API. The fallback reads both from a snapshot
(--vars FILE, default $NIGHTLY_FALLBACK_VARS or ~/.cache/actions-stall/cmux-vars.json: {"NAME": "value"}), the last
values a reader saw while the API answered (the stall dispatcher writes it). With no snapshot the gate cannot tell
who the writer is and refuses (nothing published, exit 1): an unknown writer never publishes. A snapshot without
NIGHTLY_NEXT_WRITER means the variable is unset, which publish-final-gate.sh reads as mac.

Build numbers (nightly_version.py fallback-build): <live run id><50+k>. Above live, below any later Actions run.

Credentials come from the environment only, under the workflow's secret names (run it under `op run --env-file`).
Any REQUIRED_CREDENTIALS name missing exits 78 before anything is cloned or built, naming the missing names (never a
value). A step sees a secret only when its own `env:` names it, as in Actions.

Stand-down before building: the live feed is read first (public URL). If it already serves SHA, or a source that SHA
does not descend from, nothing is built (exit 3). write-feed decides again inside the publish lease (a same-source
build already live stands down there too, whatever its number), so Actions recovering mid-fallback never publishes
the same commit twice.

The GitHub release copy, the nightly-next tag, the release body, Actions artifacts and caches need the API: they are
not done here, and the result says `"github_names": "pending"`; the next Actions build supersedes the fallback's.
A fallback build is never merge evidence. Nothing here cancels anything.

Exit: 0 published, 3 stood down (already live, superseded, a newer source live, the writer is linux/none),
78 no credentials, anything else a failure. The last stdout line is NIGHTLY_FALLBACK_RESULT=<json>
{sha, build, outcome, feed_build_before, feed_build_after, github_names, steps: [{job, step, outcome}]}.
"""
from __future__ import annotations

import argparse
import fnmatch
import glob
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = Path(__file__).resolve().parent
WORKFLOW = ".github/workflows/nightly.yml"
REPOSITORY = "manaflow-ai/cmux"
DEFAULT_GIT_DIR = "/Users/Shared/cmux-build-fleet/git/cmux.git"
FEED = "appcast-arm64.xml"
EXIT_PUBLISHED, EXIT_STOOD_DOWN, EXIT_FAILED, EXIT_NO_CREDENTIALS = 0, 3, 1, 78
RESULT_PREFIX = "NIGHTLY_FALLBACK_RESULT="

# The jobs that make and publish the arm64 Nightly-ring build of a nightly-next push, in `needs` order.
MIRRORED_JOBS = (
    "resolve-nightly-cmux-tui-client",
    "build-nightly-inputs",
    "build-nightly-ghostty-cli-helper",
    "build-nightly-remote-daemon",
    "build-nightly-app",
    "check-nightly-webviews",
    "prepare-nightly-variant-primary",
    "build-sign-notarize-nightly",
    "verify-signed-nightly",
    "verify-final-dmg-nightly",
    "publish-nightly",
)
# Jobs a mirrored job `needs` that the fallback does not run: their result as a plain nightly-next push run
# (pipeline off) leaves it, and the outputs that run gives them.
SYNTHETIC_JOBS = {
    "decide": "success",
    "pick-nightly-build-runner": "success",
    "pick-nightly-sign-runner": "success",
    "resolve-nightly-ghostty-cli-helper": "success",  # no reusable helper: hit=false, built here
    "recover-nightly-next-notarization": "skipped",
    "verify-recovered-nightly-next": "skipped",
    "republish-nightly-next": "skipped",
    "await-nightly-tree-marker": "skipped",  # the resolver below takes a published tree only
}
# prepare-nightly-variant is the retry of prepare-nightly-variant-primary (PREPARE_FALLBACK reuses its artifact);
# the sign job reads it, so it stands for the primary.
JOB_ALIASES = {"prepare-nightly-variant": "prepare-nightly-variant-primary"}

# (job, step name) -> why the fallback does not run it. Every other step of a mirrored job runs as written.
SKIPPED_STEPS = {
    ("resolve-nightly-cmux-tui-client", "Install gh if this runner lacks it"):
        "the fallback's gh is the git-backed shim; no GitHub API",
    ("resolve-nightly-cmux-tui-client", "Wait through GitHub API rate limits in this job's gh calls"):
        "no GitHub API",
    ("resolve-nightly-cmux-tui-client", "Build the tip while its tree publishes"):
        "it waits for a cmux-tui tree an Actions run publishes; during a stall nothing publishes it, so the "
        "resolver builds the newest commit whose tree is published (its rule for a tree nothing will publish)",
    ("resolve-nightly-cmux-tui-client", "Leave the build slot to a newer nightly-next push"):
        "reads Actions runs through the API; the stall dispatcher picks the newest commit",
    ("build-nightly-app", "Wait through GitHub API rate limits in this job's gh calls"): "no GitHub API",
    ("build-nightly-app", "Look up the nightly app compiled on the same inputs"):
        "product reuse reads Actions artifacts through the API; the fallback compiles",
    ("build-nightly-app", "Stop when the run can no longer publish (before the compile)"):
        "reads this run's state through the API; the pre-check and write-feed decide supersession",
    ("build-nightly-app", "Stop when the run can no longer publish (before the upload)"):
        "reads this run's state through the API; the pre-check and write-feed decide supersession",
    ("build-nightly-app", "Upload dSYMs to Sentry"): "Sentry upload stays with Actions (pending)",
    ("build-nightly-app", "Finish the dSYM upload to Sentry"): "Sentry upload stays with Actions (pending)",
    ("build-nightly-app", "Mint the routing token for the light-job placement"): "glaeda routing; no runners here",
    ("build-nightly-app", "Place the light jobs on a free mini"): "glaeda routing; no runners here",
    ("build-nightly-app", "Collect the light-job placement"): "glaeda routing; no runners here",
    ("prepare-nightly-variant-primary", "Wait through GitHub API rate limits in this job's gh calls"):
        "no GitHub API",
    ("prepare-nightly-variant-primary", "Download signing inputs (parallel)"):
        "downloads this run's artifacts through the API; the download-artifact steps after it (its fallback when "
        "it reports nothing) read the fallback's local artifact store",
    ("verify-final-dmg-nightly", "Download final DMG (parallel ranges)"):
        "reads the Actions artifact service; the download-artifact step after it (its fallback) reads the local store",
    ("build-sign-notarize-nightly", "Hold the whole Mac before any credential"):
        "glaeda's exclusive claim; the fallback requires NIGHTLY_FALLBACK_HOST_CLAIM=exclusive instead",
    ("build-sign-notarize-nightly", "Claim the whole Mac for signing"):
        "glaeda's exclusive claim; the fallback requires NIGHTLY_FALLBACK_HOST_CLAIM=exclusive instead",
    ("build-sign-notarize-nightly", "Yield the sign slot to a newer build"):
        "reads Actions runs through the API; the pre-check and write-feed decide supersession",
    ("publish-nightly", "Hold the whole Mac before any credential"):
        "glaeda's exclusive claim; the fallback requires NIGHTLY_FALLBACK_HOST_CLAIM=exclusive instead",
    ("publish-nightly", "Claim the whole Mac for signing"):
        "glaeda's exclusive claim; the fallback requires NIGHTLY_FALLBACK_HOST_CLAIM=exclusive instead",
    ("publish-nightly", "Send this job's gh calls as the release App, github.token as the fallback"):
        "no GitHub API (it would put the API-calling gh wrapper ahead of the shim)",
    ("publish-nightly", "Wait through GitHub API rate limits in this job's gh calls"): "no GitHub API",
}

# The scripts each mirrored job's running steps call, as reviewed for the fallback (no GitHub API, or the shim
# answers it). A script a mirrored job starts calling that is not here fails the parity test and the run's own
# check: review it, then add it here or skip its step.
REVIEWED_SCRIPTS: dict[str, tuple[str, ...]] = {}  # filled from REVIEWED_SCRIPTS_JSON below

# Secrets the mirrored steps read for the arm64 nightly-next build. Missing any: exit 78, nothing built.
REQUIRED_CREDENTIALS = (
    "APPLE_CERTIFICATE_BASE64",
    "APPLE_CERTIFICATE_PASSWORD",
    "APPLE_SIGNING_IDENTITY",
    "APPLE_NIGHTLY_PROVISIONING_PROFILE_BASE64",
    "ASC_API_ISSUER_ID",
    "ASC_API_KEY_ID",
    "ASC_API_KEY_P8_BASE64",
    "SPARKLE_NEXT_PRIVATE_KEY",
    "NIGHTLY_NEXT_R2_ACCOUNT_ID",
    "NIGHTLY_NEXT_R2_ACCESS_KEY_ID",
    "NIGHTLY_NEXT_R2_SECRET_ACCESS_KEY",
    "CMUX_CEF_R2_ACCOUNT_ID",
    "CMUX_CEF_R2_ACCESS_KEY_ID",
    "CMUX_CEF_R2_SECRET_ACCESS_KEY",
)
# Secrets a mirrored step names that the arm64 nightly-next build does not need, and why.
OPTIONAL_CREDENTIALS = {
    "CMUX_CEF_READ_TOKEN": "a GitHub token for the Chromium engine fetch's GitHub fallback; R2 serves it",
    "CMUX_RELEASE_APP_ID": "the release App token is a placeholder here (no GitHub API)",
    "CMUX_RELEASE_APP_KEY": "the release App token is a placeholder here (no GitHub API)",
    "CI_CACHE_R2_ACCOUNT_ID": "compilation caches are skipped (cold build)",
    "CI_CACHE_R2_ACCESS_KEY_ID": "compilation caches are skipped (cold build)",
    "CI_CACHE_R2_SECRET_ACCESS_KEY": "compilation caches are skipped (cold build)",
    "CF_R2_ACCOUNT_ID": "main's nightly feeds only (track nightly, not nightly-next)",
    "CF_R2_ACCESS_KEY_ID": "main's nightly feeds only (track nightly, not nightly-next)",
    "CF_R2_SECRET_ACCESS_KEY": "main's nightly feeds only (track nightly, not nightly-next)",
    "SPARKLE_PRIVATE_KEY": "main's track only (the expression passes it only off nightly-next)",
    "NIGHTLY_SPARKLE_PRIVATE_KEY": "main's track only (the expression passes it only off nightly-next)",
    "APPLE_RC_PROVISIONING_PROFILE_BASE64": "RC channel only (profile_channel NIGHTLY here)",
    "APPLE_RELEASE_PROVISIONING_PROFILE_BASE64": "production probe only (profile_channel NIGHTLY here)",
    "GLAEDA_ROUTE_APP_KEY": "glaeda routing; skipped",
    "SENTRY_AUTH_TOKEN": "Sentry upload skipped (pending)",
}
# Repository variables the mirrored steps read; values come from the snapshot, else these defaults (the value an
# unset variable gives the expression).
KNOWN_VARS = (
    "CI_CACHE_BACKEND", "CI_CACHE_R2_BUCKET", "CI_NIGHTLY_MINI", "CI_NIGHTLY_MINI_BUILDER",
    "CI_NIGHTLY_MINI_PUBLISHER", "CI_NIGHTLY_MINI_SIGNER", "CI_NIGHTLY_NEXT_BUILD_RUNNER",
    "CI_NIGHTLY_NEXT_PRODUCT_REUSE", "CI_NIGHTLY_ONLY_RUNNER", "CI_PR_POOL_OWNED", "CI_RUNNER_STATE",
    "CI_SEED_TRUSTED_POOL", "CI_SIDE_LANE_RUNNER", "CMUX_CI_XCODE_APP_MACOS_26", "CMUX_CI_XCODE_APP_PR",
    "CMUX_NEXT_CEF_ON_DEMAND", "CMUX_NEXT_PUBLISH_SOURCE_ARCHIVE", "CMUX_SERVER_RELEASE_KEYS",
    "GLAEDA_ROUTE_APP_ID", "NIGHTLY_LEGACY_REQUIRED_COMMITS", "NIGHTLY_NEXT_DEV_RING", "NIGHTLY_NEXT_SIGN_YIELD",
    "NIGHTLY_SPARKLE_KEY", "NIGHTLY_NEXT_SUPERSEDE_SKIP", "NIGHTLY_NEXT_WRITER", "NIGHTLY_NEXT_NOTARY_PAUSED",
    "NIGHTLY_NEXT_SUBMISSIONS_PAUSED", "CI_CACHE_R2_PUBLIC_URL",
)
APP_TOKEN_PLACEHOLDER = "fleet-fallback-no-github-api"


# ------------------------------------------------------------------------------------------------ expressions

class ExpressionError(Exception):
    pass


TOKEN = re.compile(r"""\s*(?:
    (?P<str>'(?:[^']|'')*')
  | (?P<num>-?(?:0x[0-9a-fA-F]+|\d+(?:\.\d+)?(?:[eE][-+]?\d+)?))
  | (?P<op>==|!=|<=|>=|&&|\|\||[<>!()\[\],.*])
  | (?P<ident>[A-Za-z_][A-Za-z0-9_-]*)
)""", re.X)


def tokenize(text: str) -> list[tuple[str, object]]:
    tokens, pos = [], 0
    text = text.strip()
    while pos < len(text):
        match = TOKEN.match(text, pos)
        if not match or match.end() == pos:
            raise ExpressionError(f"cannot read {text[pos:pos + 20]!r} in {text!r}")
        pos = match.end()
        if match.group("str") is not None:
            tokens.append(("str", match.group("str")[1:-1].replace("''", "'")))
        elif match.group("num") is not None:
            raw = match.group("num")
            tokens.append(("num", int(raw, 16) if "x" in raw.lower() else float(raw)))
        elif match.group("op") is not None:
            tokens.append(("op", match.group("op")))
        else:
            tokens.append(("ident", match.group("ident")))
    return tokens


def to_number(value):
    if value is None:
        return 0.0
    if isinstance(value, bool):
        return 1.0 if value else 0.0
    if isinstance(value, (int, float)):
        return float(value)
    if isinstance(value, str):
        stripped = value.strip()
        if stripped == "":
            return 0.0
        try:
            return float(int(stripped, 16)) if stripped.lower().startswith("0x") else float(stripped)
        except ValueError:
            return float("nan")
    return float("nan")


def truthy(value) -> bool:
    if value is None or value is False:
        return False
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        return value == value and value != 0
    if isinstance(value, str):
        return value != ""
    return True


def to_string(value) -> str:
    if value is None:
        return ""
    if value is True:
        return "true"
    if value is False:
        return "false"
    if isinstance(value, float):
        return str(int(value)) if value.is_integer() else repr(value)
    if isinstance(value, (dict, list)):
        return json.dumps(value, indent=2)
    return str(value)


def loose_equal(a, b) -> bool:
    if isinstance(a, (dict, list)) or isinstance(b, (dict, list)):
        return a is b
    if a is None and b is None:
        return True
    if isinstance(a, str) and isinstance(b, str):
        return a.lower() == b.lower()
    if type(a) is type(b) and not isinstance(a, (int, float)):
        return a == b
    return to_number(a) == to_number(b)


def compare(op: str, a, b) -> bool:
    if op == "==":
        return loose_equal(a, b)
    if op == "!=":
        return not loose_equal(a, b)
    if isinstance(a, str) and isinstance(b, str):
        x, y = a.lower(), b.lower()
    else:
        x, y = to_number(a), to_number(b)
    return {"<": x < y, ">": x > y, "<=": x <= y, ">=": x >= y}[op]


class Evaluator:
    """GitHub Actions expressions over a context dict (github, env, vars, secrets, needs, steps, matrix, inputs,
    runner, job) and the status functions the caller provides."""

    STATUS = ("success", "failure", "always", "cancelled")

    def __init__(self, context: dict, status: dict | None = None, workspace: str | None = None):
        self.context = context
        self.status = status or {"success": True, "failure": False, "always": True, "cancelled": False}
        self.workspace = workspace

    def evaluate(self, text: str):
        self.tokens = tokenize(text)
        self.pos = 0
        value = self.parse_or()
        if self.pos != len(self.tokens):
            raise ExpressionError(f"unexpected {self.tokens[self.pos][1]!r} in {text!r}")
        return value

    def peek(self):
        return self.tokens[self.pos] if self.pos < len(self.tokens) else (None, None)

    def take(self, op=None):
        token = self.peek()
        if op is not None and token != ("op", op):
            raise ExpressionError(f"expected {op!r}, found {token[1]!r}")
        self.pos += 1
        return token

    def parse_or(self):
        left = self.parse_and()
        while self.peek() == ("op", "||"):
            self.take()
            right = self.parse_and()
            left = left if truthy(left) else right
        return left

    def parse_and(self):
        left = self.parse_compare()
        while self.peek() == ("op", "&&"):
            self.take()
            right = self.parse_compare()
            left = right if truthy(left) else left
        return left

    def parse_compare(self):
        left = self.parse_unary()
        while self.peek()[0] == "op" and self.peek()[1] in ("==", "!=", "<", ">", "<=", ">="):
            op = self.take()[1]
            left = compare(op, left, self.parse_unary())
        return left

    def parse_unary(self):
        if self.peek() == ("op", "!"):
            self.take()
            return not truthy(self.parse_unary())
        return self.parse_postfix()

    def parse_postfix(self):
        value = self.parse_primary()
        while True:
            token = self.peek()
            if token == ("op", "."):
                self.take()
                kind, name = self.take()
                if kind != "ident" and token != ("op", "*"):
                    raise ExpressionError(f"bad property {name!r}")
                value = self.index(value, name)
            elif token == ("op", "["):
                self.take()
                key = self.parse_or()
                self.take("]")
                value = self.index(value, key)
            else:
                return value

    @staticmethod
    def index(value, key):
        if isinstance(value, dict):
            if isinstance(key, str):
                for k, v in value.items():
                    if k.lower() == key.lower():
                        return v
            return None
        if isinstance(value, list) and isinstance(key, (int, float)) and not isinstance(key, bool):
            i = int(key)
            return value[i] if 0 <= i < len(value) else None
        return None

    def parse_primary(self):
        kind, value = self.take()
        if kind in ("str", "num"):
            return value
        if kind == "op" and value == "(":
            inner = self.parse_or()
            self.take(")")
            return inner
        if kind == "ident":
            lowered = value.lower()
            if lowered in ("true", "false"):
                return lowered == "true"
            if lowered == "null":
                return None
            if self.peek() == ("op", "("):
                self.take()
                args = []
                if self.peek() != ("op", ")"):
                    args.append(self.parse_or())
                    while self.peek() == ("op", ","):
                        self.take()
                        args.append(self.parse_or())
                self.take(")")
                return self.call(lowered, args)
            return self.index(self.context, value)
        raise ExpressionError(f"unexpected {value!r}")

    def call(self, name: str, args: list):
        if name in self.STATUS:
            return self.status[name]
        if name == "contains":
            haystack, needle = args
            if isinstance(haystack, list):
                return any(loose_equal(item, needle) for item in haystack)
            return to_string(needle).lower() in to_string(haystack).lower()
        if name == "startswith":
            return to_string(args[0]).lower().startswith(to_string(args[1]).lower())
        if name == "endswith":
            return to_string(args[0]).lower().endswith(to_string(args[1]).lower())
        if name == "format":
            template, rest = to_string(args[0]), args[1:]
            out = re.sub(r"\{(\d+)\}", lambda m: to_string(rest[int(m.group(1))]), template.replace("{{", "\0").replace("}}", "\1"))
            return out.replace("\0", "{").replace("\1", "}")
        if name == "join":
            items = args[0] if isinstance(args[0], list) else [args[0]]
            return (to_string(args[1]) if len(args) > 1 else ",").join(to_string(i) for i in items)
        if name == "tojson":
            return json.dumps(args[0], indent=2)
        if name == "fromjson":
            return json.loads(to_string(args[0]))
        if name == "hashfiles":
            return hash_files(self.workspace or ".", [to_string(a) for a in args])
        raise ExpressionError(f"unknown function {name}()")


def hash_files(workspace: str, patterns: list[str]) -> str:
    include, exclude = [], []
    for pattern in patterns:
        (exclude if pattern.startswith("!") else include).append(pattern.lstrip("!"))
    files = set()
    for pattern in include:
        for path in glob.glob(os.path.join(workspace, pattern), recursive=True):
            if os.path.isfile(path):
                files.add(path)
    files = sorted(p for p in files if not any(fnmatch.fnmatch(os.path.relpath(p, workspace), e) for e in exclude))
    if not files:
        return ""
    outer = hashlib.sha256()
    for path in files:
        with open(path, "rb") as handle:
            outer.update(hashlib.sha256(handle.read()).digest())
    return outer.hexdigest()


INTERPOLATION = re.compile(r"\$\{\{(.*?)\}\}", re.S)


def interpolate(value, evaluator: Evaluator):
    """A workflow value with every ${{ }} replaced; a value that is one whole expression keeps its type."""
    if not isinstance(value, str):
        return value
    whole = INTERPOLATION.fullmatch(value.strip())
    if whole and "}}" not in whole.group(1):
        return evaluator.evaluate(whole.group(1))
    return INTERPOLATION.sub(lambda m: to_string(evaluator.evaluate(m.group(1))), value)


def condition(text, evaluator: Evaluator) -> bool:
    """An `if:` value: implicit expression, implicit success() unless it names a status function."""
    if text is None or text == "":
        return bool(evaluator.status["success"])
    if isinstance(text, bool):
        return text
    text = str(text).strip()
    whole = INTERPOLATION.fullmatch(text)
    expression = whole.group(1) if whole and "}}" not in whole.group(1) else text
    if not re.search(r"\b(success|failure|always|cancelled)\s*\(", expression):
        expression = f"success() && ({expression})"
    return truthy(evaluator.evaluate(expression))


# ------------------------------------------------------------------------------------------------ workflow reading

def load_workflow(text: str) -> dict:
    import yaml  # PyYAML: on every fleet Mac and in CI

    data = yaml.safe_load(text)
    if not isinstance(data, dict) or "jobs" not in data:
        raise SystemExit(f"{WORKFLOW} has no jobs")
    return data


SCRIPT = re.compile(r"(?:^|[\s\"'=(/])((?:\.publish-tooling/|\.nightly-signing-control/|\$PUBLISH_TOOLING/|"
                    r"\$\{PUBLISH_TOOLING\}/)?(?:scripts|cmux-next)/[\w./-]+\.(?:sh|py|mjs|js))")


def step_scripts(step: dict) -> list[str]:
    """The repository scripts a step's run body calls, normalized to repo-relative paths."""
    body = step.get("run") or ""
    found = set()
    for match in SCRIPT.finditer(body):
        path = match.group(1)
        for prefix in (".publish-tooling/", ".nightly-signing-control/", "$PUBLISH_TOOLING/", "${PUBLISH_TOOLING}/"):
            if path.startswith(prefix):
                path = path[len(prefix):]
                if prefix.startswith(("$", "${")):
                    path = "scripts/" + path  # PUBLISH_TOOLING is <workspace>/.publish-tooling/scripts
        if path.startswith("scripts/") or path.startswith("cmux-next/"):
            found.add(path)
    return sorted(found)


def step_name(step: dict) -> str:
    return step.get("name") or step.get("uses") or (step.get("run") or "").strip().splitlines()[0]


def references(value, kind: str) -> set[str]:
    """Names of `kind` (secrets, vars, needs.decide.outputs) any expression in value reads."""
    found = set()
    pattern = {"secrets": r"\bsecrets\.(\w+)", "vars": r"\bvars\.(\w+)",
               "decide": r"\bneeds\.decide\.outputs\.(\w+)"}[kind]

    def walk(node):
        if isinstance(node, dict):
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)
        elif isinstance(node, str):
            found.update(re.findall(pattern, node))
    walk(value)
    return found


def drift(workflow: dict, mirrored: tuple[str, ...] = MIRRORED_JOBS) -> list[str]:
    """Why the fallback's tables no longer cover this nightly.yml (empty: they do). MIRRORED: the jobs a run executes
    (a candidate run checks only CANDIDATE_JOBS, so drift in the signing and publishing jobs it never runs does not
    stop it)."""
    problems = []
    jobs = workflow["jobs"]
    seen_skips = set()
    for job in mirrored:
        if job not in jobs:
            problems.append(f"nightly.yml has no job {job}")
            continue
        for need in as_list(jobs[job].get("needs")):
            if need not in mirrored and need not in SYNTHETIC_JOBS and need not in JOB_ALIASES:
                problems.append(f"{job} needs {need}, which the fallback neither runs nor stands in for")
        reviewed = set(REVIEWED_SCRIPTS.get(job, ()))
        for step in jobs[job].get("steps", []):
            name = step_name(step)
            if (job, name) in SKIPPED_STEPS:
                seen_skips.add((job, name))
                continue
            uses = step.get("uses")
            if uses and action_kind(uses) is None:
                problems.append(f"{job}: step {name!r} uses {uses}, which the fallback cannot stand in for")
            for script in step_scripts(step):
                if script not in reviewed:
                    problems.append(f"{job}: step {name!r} calls {script}, which the fallback has not reviewed "
                                    "(REVIEWED_SCRIPTS) or skipped (SKIPPED_STEPS)")
            for secret in references(step, "secrets"):
                if secret not in REQUIRED_CREDENTIALS and secret not in OPTIONAL_CREDENTIALS:
                    problems.append(f"{job}: step {name!r} reads secrets.{secret}, which the fallback does not know")
        for var in references({k: v for k, v in jobs[job].items() if k != "runs-on"}, "vars"):
            if var not in KNOWN_VARS:
                problems.append(f"{job} reads vars.{var}, which the fallback does not know")
        for output in references(jobs[job], "decide"):
            if output not in DECIDE_OUTPUT_NAMES:
                problems.append(f"{job} reads needs.decide.outputs.{output}, which decide_outputs() does not give")
    for job, name in sorted(set(SKIPPED_STEPS) - seen_skips):
        if job not in mirrored:
            continue
        problems.append(f"SKIPPED_STEPS names {job}: {name!r}, which nightly.yml no longer has")
    return problems


def as_list(value) -> list:
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


# ------------------------------------------------------------------------------------------------ synthetic needs

DECIDE_OUTPUT_NAMES = (
    "early_mini_runner", "early_mini_jobs", "early_attempt", "should_build", "head_sha", "short_sha",
    "published_sha", "should_publish", "pipeline", "notary_paused", "import_paused", "notary_test",
    "notary_test_browser_data", "no_publish", "continue_only", "republish_run", "republish_attempt",
    "import_variant", "swift_import_flags", "empty_browser_sources", "password_readers_out", "notary_probe",
    "sign_channel", "profile_channel", "variants", "compile_archs", "feeds", "legacy_variant", "fast_build",
    "build_only", "force", "cold_cache", "channel", "channel_upper", "track", "environment", "bundle_id",
    "app_name", "url_scheme", "dmg_prefix", "release_tag", "release_name", "feed_base", "entitlements", "icon_name",
)


def decide_outputs(sha: str, published_sha: str, workflow_env: dict, variables: dict) -> dict:
    """decide's outputs for a plain nightly-next push run (NIGHTLY_NEXT_PIPELINE off: one run builds and publishes).

    Mirrors decide's script in nightly.yml for track nightly-next; the notary pauses come from the variables
    snapshot (the caller stands down on either before building)."""
    compiled_out = workflow_env.get("NIGHTLY_NEXT_BROWSER_DATA_IMPORT") == "compiled-out"
    outputs = {
        "early_mini_runner": "", "early_mini_jobs": "", "early_attempt": "",
        "should_build": "true", "head_sha": sha, "short_sha": sha[:7], "published_sha": published_sha,
        "should_publish": "true", "pipeline": "false", "notary_paused": "false", "import_paused": "false",
        "notary_test": "false", "notary_test_browser_data": "true" if compiled_out else "false",
        "no_publish": "false", "continue_only": "false", "republish_run": "", "republish_attempt": "",
        "import_variant": "no-browser-data" if compiled_out else "full",
        "swift_import_flags": "-DCMUX_NO_PASSWORD_IMPORT -DCMUX_NO_BROWSER_DATA_IMPORT" if compiled_out else "",
        "empty_browser_sources": "true" if compiled_out else "false",
        "password_readers_out": "true" if compiled_out else "false",
        "notary_probe": "false", "sign_channel": "nightly", "profile_channel": "NIGHTLY",
        "variants": '["arm64"]', "compile_archs": "arm64", "feeds": FEED, "legacy_variant": "universal",
        "fast_build": "false", "build_only": "false", "force": "false", "cold_cache": "false",
        "channel": "nightly", "channel_upper": "NIGHTLY", "track": "nightly-next", "environment": "release-next",
        "bundle_id": "com.cmuxterm.app.nightly", "app_name": "cmux NIGHTLY", "url_scheme": "cmux-nightly",
        "dmg_prefix": "cmux-nightly-next-macos", "release_tag": "nightly-next",
        "release_name": "Nightly (cmux-next)", "feed_base": workflow_env.get("NIGHTLY_NEXT_FEED_BASE", ""),
        "entitlements": "cmux.nightly.entitlements", "icon_name": "AppIcon-Nightly",
    }
    assert set(outputs) == set(DECIDE_OUTPUT_NAMES)
    return outputs


def synthetic_needs(sha: str, published_sha: str, workflow_env: dict, variables: dict, build: int) -> dict:
    run_attempt = str(build % 100)
    needs = {job: {"result": result, "outputs": {}} for job, result in SYNTHETIC_JOBS.items()}
    needs["decide"]["outputs"] = decide_outputs(sha, published_sha, workflow_env, variables)
    # The pickers chose this run's attempt's runners; their labels do not matter here (runs-on is ignored).
    for picker in ("pick-nightly-build-runner", "pick-nightly-sign-runner"):
        needs[picker]["outputs"] = {"attempt": run_attempt}
    needs["resolve-nightly-ghostty-cli-helper"]["outputs"] = {"hit": "false"}
    return needs


# ------------------------------------------------------------------------------------------------ actions

def action_kind(uses: str) -> str | None:
    name = uses.split("@", 1)[0]
    if name == "actions/checkout":
        return "checkout"
    if name == "actions/upload-artifact":
        return "upload"
    if name == "actions/download-artifact":
        return "download"
    if name in ("actions/cache", "actions/cache/restore", "actions/cache/save", "./.github/actions/cache-restore",
                "./.github/actions/cache-save", "Swatinem/rust-cache"):
        return "cache"
    if name in ("actions/setup-node", "oven-sh/setup-bun", "actions/setup-go", "dtolnay/rust-toolchain"):
        return "toolchain"
    if name == "actions/create-github-app-token":
        return "app-token"
    if name == "actions/github-script":
        return "github-script"
    return None


class StepFailed(Exception):
    pass


class Artifacts:
    """upload-artifact/download-artifact through a local directory, one subdirectory per artifact name."""

    def __init__(self, root: Path):
        self.root = root
        root.mkdir(parents=True, exist_ok=True)

    def upload(self, workspace: Path, name: str, paths: str, if_missing: str, overwrite: bool) -> int:
        include, exclude = [], []
        for line in str(paths).splitlines():
            line = line.strip()
            if line:
                (exclude if line.startswith("!") else include).append(line.lstrip("!"))
        matched: list[Path] = []
        for pattern in include:
            full = pattern if os.path.isabs(pattern) else str(workspace / pattern)
            for path in glob.glob(full, recursive=True):
                p = Path(path)
                if p.is_dir():
                    matched.extend(q for q in p.rglob("*") if q.is_file() or q.is_symlink())
                elif p.exists() or p.is_symlink():
                    matched.append(p)
        matched = [p for p in matched if not any(fnmatch.fnmatch(str(p), e if os.path.isabs(e) else str(workspace / e))
                                                 for e in exclude)]
        if not matched:
            message = f"artifact {name}: no files match {include}"
            if if_missing == "error":
                raise StepFailed(message)
            print(f"warning: {message}" if if_missing != "ignore" else message)
            return 0
        base = Path(os.path.commonpath([str(p.parent) for p in matched]))
        dest = self.root / name
        if dest.exists():
            if not overwrite:
                raise StepFailed(f"artifact {name} already exists")
            shutil.rmtree(dest)
        for p in matched:
            target = dest / p.relative_to(base)
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(p, target, follow_symlinks=False)
        return len(matched)

    def download(self, workspace: Path, name: str | None, pattern: str | None, path: str | None,
                 merge: bool) -> int:
        dest = Path(path) if path and os.path.isabs(path) else workspace / (path or ".")
        names = sorted(p.name for p in self.root.iterdir()) if self.root.exists() else []
        if name:
            if name not in names:
                raise StepFailed(f"artifact {name} does not exist (no earlier fallback job uploaded it)")
            chosen, nested = [name], False
        else:
            chosen = [n for n in names if fnmatch.fnmatch(n, pattern or "*")]
            nested = not merge and len(chosen) > 0
        count = 0
        for n in chosen:
            target = dest / n if nested else dest
            shutil.copytree(self.root / n, target, dirs_exist_ok=True, symlinks=True)
            count += sum(1 for _ in (self.root / n).rglob("*"))
        return count


# ------------------------------------------------------------------------------------------------ the interpreter

def parse_file_commands(path: Path) -> dict:
    """GITHUB_OUTPUT / GITHUB_ENV: name=value lines and name<<DELIMITER blocks."""
    values = {}
    if not path.exists():
        return values
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        heredoc = re.match(r"^([^=<\s]+)<<(.+)$", line)
        if heredoc:
            name, delimiter, body = heredoc.group(1), heredoc.group(2), []
            i += 1
            while i < len(lines) and lines[i] != delimiter:
                body.append(lines[i])
                i += 1
            values[name] = "\n".join(body)
        elif "=" in line:
            name, value = line.split("=", 1)
            values[name] = value
        i += 1
    return values


class Interpreter:
    def __init__(self, workflow: dict, *, sha: str, build: int, workdir: Path, git_dir: str, variables: dict,
                 credentials: dict, base_env: dict, needs: dict, shim_dir: Path, log=print):
        self.workflow = workflow
        self.sha = sha
        self.build = build
        self.workdir = workdir
        self.git_dir = git_dir
        self.variables = variables
        self.credentials = credentials
        self.base_env = base_env
        self.needs = needs
        self.shim_dir = shim_dir
        self.artifacts = Artifacts(workdir / "artifacts")
        self.record: list[dict] = []
        self.log = log

    # A test replaces these two to stub every external command.
    def run_shell(self, job: str, name: str, body: str, shell: str | None, env: dict, cwd: Path,
                  timeout: float | None) -> int:
        script = Path(env["RUNNER_TEMP"]) / f"step-{len(self.record)}.sh"
        script.write_text(body, encoding="utf-8")
        argv = ["bash", "--noprofile", "--norc", "-eo", "pipefail", str(script)] if shell == "bash" \
            else ["bash", "-e", str(script)]
        try:
            return subprocess.run(argv, cwd=cwd, env=env, timeout=timeout).returncode
        except subprocess.TimeoutExpired:
            self.log(f"::error::{job}: {name}: timed out after {timeout:.0f} s")
            return 124

    def checkout(self, workspace: Path, ref: str, path: str | None, submodules) -> None:
        dest = workspace / (path or ".")
        dest.mkdir(parents=True, exist_ok=True)
        git = ["git", "-C", str(dest)]
        if not (dest / ".git").exists():
            subprocess.run(git + ["init", "-q"], check=True)
            alternates = dest / ".git" / "objects" / "info" / "alternates"
            alternates.parent.mkdir(parents=True, exist_ok=True)
            alternates.write_text(os.path.join(os.path.abspath(self.git_dir), "objects") + "\n")
            # origin is the mirror's own upstream when it has one, as actions/checkout's origin is GitHub: a step
            # that asks origin for a ref the mirror does not fetch (tags: the notices step's cmux-rbh-src-* check)
            # sees what the nightly sees, instead of a false red. Objects still come from the mirror (alternates).
            subprocess.run(git + ["remote", "add", "origin", self.origin_url()], check=True)
        subprocess.run(git + ["-c", "advice.detachedHead=false", "checkout", "-q", "--force", "--detach", ref],
                       check=True)
        if submodules in (True, "true", "recursive"):
            command = git + ["submodule", "update", "--init"]
            if submodules == "recursive":
                command.append("--recursive")
            subprocess.run(command, check=True)

    def origin_url(self) -> str:
        """The mirror's remote.origin.url when it is a network address, else the mirror's own path."""
        upstream = subprocess.run(["git", "--git-dir", self.git_dir, "config", "--get", "remote.origin.url"],
                                  capture_output=True, text=True).stdout.strip()
        if re.match(r"^(https://|ssh://|git@)", upstream):
            return upstream
        return os.path.abspath(self.git_dir)

    def setup_node(self, version: str) -> str:
        """The bin directory of node VERSION, put there by ensure-setup-node.sh in a tool cache kept across runs."""
        cache = Path(self.base_env.get("NIGHTLY_FALLBACK_TOOL_CACHE")
                     or Path(self.base_env.get("HOME", str(Path.home()))) / "Library/Caches/nightly-fleet-fallback/tool-cache")
        cache.mkdir(parents=True, exist_ok=True)
        path_file = cache / f".path-{os.getpid()}"
        path_file.write_text("")
        try:
            subprocess.run(["bash", str(HERE / "ensure-setup-node.sh"), version], check=True, timeout=900,
                           env={**self.base_env, "RUNNER_TOOL_CACHE": str(cache), "GITHUB_PATH": str(path_file)})
            lines = [line.strip() for line in path_file.read_text().splitlines() if line.strip()]
        except subprocess.CalledProcessError as error:
            raise StepFailed(f"node {version}: ensure-setup-node.sh exit {error.returncode}") from error
        finally:
            path_file.unlink(missing_ok=True)
        return lines[-1] if lines else ""

    def run_action(self, job: str, step: dict, evaluator: Evaluator, workspace: Path, outputs: dict) -> None:
        kind = action_kind(step["uses"])
        given = {k: interpolate(v, evaluator) for k, v in (step.get("with") or {}).items()}
        if kind == "checkout":
            self.checkout(workspace, to_string(given.get("ref")) or self.sha, given.get("path"),
                          given.get("submodules", False))
        elif kind == "upload":
            count = self.artifacts.upload(workspace, to_string(given.get("name") or "artifact"),
                                          to_string(given.get("path")), to_string(given.get("if-no-files-found") or "warn"),
                                          truthy(given.get("overwrite")))
            self.log(f"  artifact {given.get('name')}: {count} files")
        elif kind == "download":
            count = self.artifacts.download(workspace, to_string(given.get("name")) or None,
                                            to_string(given.get("pattern")) or None, to_string(given.get("path")) or None,
                                            truthy(given.get("merge-multiple")))
            self.log(f"  downloaded {count} entries")
        elif kind == "cache":
            outputs["cache-hit"] = "false"
        elif kind == "toolchain":
            # The host keeps its own toolchains, except node: a fleet Mac has none on PATH outside a runner's tool
            # cache, and the web bundle build refuses without it ("needs node 22.18 or newer on PATH (found: none)",
            # the tip loop's first run on 2026-11-12). setup-node's stand-in is nightly.yml's own ensure-setup-node.sh
            # (its "Check node is on PATH" step): node-version from RUNNER_TOOL_CACHE, else nodejs.org, checked.
            if step["uses"].split("@", 1)[0] == "actions/setup-node" and to_string(given.get("node-version")):
                outputs["__path__"] = self.setup_node(to_string(given.get("node-version")))
        elif kind == "app-token":
            outputs["token"] = APP_TOKEN_PLACEHOLDER
        else:
            raise StepFailed(f"{step['uses']} needs GitHub Actions; the fallback cannot run it")

    def context(self, job: str, workspace: Path, temp: Path, env: dict, steps: dict) -> dict:
        github = {
            "repository": REPOSITORY, "repository_owner": REPOSITORY.split("/")[0], "ref": "refs/heads/nightly-next",
            "ref_name": "nightly-next", "sha": self.sha, "run_id": str(self.build // 100),
            "run_attempt": str(self.build % 100), "run_number": "0", "event_name": "push", "event": {},
            "workspace": str(workspace), "job": job, "token": "", "server_url": "https://github.com",
            "api_url": "https://api.github.com", "actor": "nightly-fleet-fallback", "workflow": "Nightly",
        }
        return {
            "github": github, "env": env, "vars": self.variables, "secrets": self.credentials,
            "needs": self.needs, "steps": steps, "matrix": {"variant": "arm64"}, "inputs": {},
            "runner": {"os": "macOS", "arch": "ARM64", "temp": str(temp), "name": "nightly-fleet-fallback",
                       "environment": "github-hosted", "tool_cache": str(temp / "tool-cache")},
            "job": {"status": "success"},
        }

    def run_job(self, job: str) -> str:
        spec = self.workflow["jobs"][job]
        root = self.workdir / "jobs" / job
        if root.exists():
            shutil.rmtree(root)
        workspace, temp = root / "ws", root / "tmp"
        workspace.mkdir(parents=True)
        temp.mkdir(parents=True)
        steps: dict = {}
        job_env: dict = {}
        failed = False
        workflow_env_template = self.workflow.get("env") or {}
        base = self.context(job, workspace, temp, {}, steps)
        evaluator = Evaluator(base, workspace=str(workspace))
        if not condition(spec.get("if"), evaluator):
            self.log(f"== {job}: skipped (its if: is false)")
            self.needs[job] = {"result": "skipped", "outputs": {}}
            self.record.append({"job": job, "step": "(job)", "outcome": "skipped"})
            return "skipped"
        self.log(f"== {job}")
        workflow_env = {k: to_string(interpolate(v, evaluator)) for k, v in workflow_env_template.items()}
        base["env"] = dict(workflow_env)
        job_env = {k: to_string(interpolate(v, evaluator)) for k, v in (spec.get("env") or {}).items()}
        extra_env: dict = {}
        extra_path: list[str] = []
        for index, step in enumerate(spec.get("steps", [])):
            name = step_name(step)
            sid = step.get("id") or f"__{index}"
            status = {"success": not failed, "failure": failed, "always": True, "cancelled": False}
            env_now = {**workflow_env, **job_env, **extra_env}
            evaluator = Evaluator({**base, "env": env_now}, status, str(workspace))
            if (job, name) in SKIPPED_STEPS:
                steps[sid] = {"outputs": {}, "outcome": "skipped", "conclusion": "skipped"}
                self.record.append({"job": job, "step": name, "outcome": "skipped-fallback",
                                    "why": SKIPPED_STEPS[(job, name)]})
                continue
            if not condition(step.get("if"), evaluator):
                steps[sid] = {"outputs": {}, "outcome": "skipped", "conclusion": "skipped"}
                continue
            step_env = {k: to_string(interpolate(v, evaluator)) for k, v in (step.get("env") or {}).items()}
            env_now = {**env_now, **step_env}
            evaluator = Evaluator({**base, "env": env_now}, status, str(workspace))
            outputs: dict = {}
            continue_on_error = truthy(interpolate(step.get("continue-on-error", False), evaluator))
            minutes = interpolate(step.get("timeout-minutes"), evaluator)
            timeout = float(to_number(minutes)) * 60 if minutes not in (None, "") else None
            self.log(f"-- {job}: {name}")
            started = time.monotonic()
            try:
                if "uses" in step:
                    self.run_action(job, step, evaluator, workspace, outputs)
                    added = outputs.pop("__path__", "")
                    if added:
                        extra_path.append(added)
                    code = 0
                else:
                    files = {kind: temp / f"_{kind}-{index}" for kind in ("output", "env", "path", "summary")}
                    for f in files.values():
                        f.write_text("")
                    env = {
                        **self.base_env,
                        "PATH": os.pathsep.join([*reversed(extra_path), str(self.shim_dir), self.base_env.get("PATH", "")]),
                        "GITHUB_REPOSITORY": REPOSITORY, "GITHUB_REPOSITORY_OWNER": REPOSITORY.split("/")[0],
                        "GITHUB_SHA": self.sha, "GITHUB_REF": "refs/heads/nightly-next", "GITHUB_REF_NAME": "nightly-next",
                        "GITHUB_RUN_ID": str(self.build // 100), "GITHUB_RUN_ATTEMPT": str(self.build % 100),
                        "GITHUB_RUN_NUMBER": "0", "GITHUB_EVENT_NAME": "push", "GITHUB_JOB": job,
                        "GITHUB_WORKFLOW": "Nightly", "GITHUB_WORKSPACE": str(workspace),
                        "GITHUB_SERVER_URL": "https://github.com", "GITHUB_API_URL": "https://api.github.com",
                        "GITHUB_ACTIONS": "true", "CI": "true", "GITHUB_OUTPUT": str(files["output"]),
                        "GITHUB_ENV": str(files["env"]), "GITHUB_PATH": str(files["path"]),
                        "GITHUB_STEP_SUMMARY": str(files["summary"]), "RUNNER_TEMP": str(temp),
                        "RUNNER_OS": "macOS", "RUNNER_ARCH": "ARM64", "RUNNER_NAME": "nightly-fleet-fallback",
                        "RUNNER_ENVIRONMENT": "github-hosted", "RUNNER_TOOL_CACHE": str(temp / "tool-cache"),
                        **env_now,
                    }
                    cwd = workspace / step["working-directory"] if step.get("working-directory") else workspace
                    body = to_string(interpolate(step["run"], evaluator))
                    code = self.run_shell(job, name, body, step.get("shell"), env, cwd, timeout)
                    outputs.update(parse_file_commands(files["output"]))
                    extra_env.update(parse_file_commands(files["env"]))
                    extra_path.extend(line.strip() for line in files["path"].read_text().splitlines() if line.strip())
            except (StepFailed, subprocess.CalledProcessError, OSError, ExpressionError) as error:
                self.log(f"::error::{job}: {name}: {error}")
                code = 1
            outcome = "success" if code == 0 else "failure"
            conclusion = "success" if code == 0 or continue_on_error else "failure"
            steps[sid] = {"outputs": outputs, "outcome": outcome, "conclusion": conclusion}
            self.record.append({"job": job, "step": name, "outcome": outcome,
                                "seconds": round(time.monotonic() - started, 1)})
            if conclusion == "failure":
                failed = True
        result = "failure" if failed else "success"
        final = Evaluator({**base, "env": {**workflow_env, **job_env}},
                          {"success": not failed, "failure": failed, "always": True, "cancelled": False},
                          str(workspace))
        job_outputs = {}
        for key, template in (spec.get("outputs") or {}).items():
            try:
                job_outputs[key] = to_string(interpolate(template, final))
            except ExpressionError as error:
                self.log(f"::warning::{job} output {key}: {error}")
                job_outputs[key] = ""
        self.needs[job] = {"result": result, "outputs": job_outputs}
        for alias, target in JOB_ALIASES.items():
            if target == job:
                self.needs[alias] = self.needs[job]
        self.log(f"== {job}: {result}")
        return result


# ------------------------------------------------------------------------------------------------ the live feed

def _r2():
    import importlib.util

    spec = importlib.util.spec_from_file_location("publish_nightly_next_r2", HERE / "publish-nightly-next-r2.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read_public_feed(url: str) -> bytes | None:
    if url.startswith("file://"):
        path = Path(url[len("file://"):])
        return path.read_bytes() if path.exists() else None
    request = urllib.request.Request(f"{url}?fleet-fallback={int(time.time())}",
                                     headers={"User-Agent": "cmux-nightly-fleet-fallback/1", "Cache-Control": "no-cache"})
    sys.path.insert(0, str(HERE))
    import deadline_http  # every call's transport: nothing is sent past its bound

    status, body, _ = deadline_http.request(request, 30)
    if status == 404:
        return None
    if status >= 400:
        raise urllib.error.HTTPError(request.full_url, status, f"feed answered {status}", None, None)
    return body


def live_state(feed: bytes | None) -> tuple[int, str | None]:
    if feed is None:
        return 0, None
    r2 = _r2()
    build = r2.newest_build(feed)
    return build, r2.item_source(feed, build)


def is_ancestor(git_dir: str, older: str, newer: str) -> bool:
    for sha in (older, newer):
        if subprocess.run(["git", "--git-dir", git_dir, "cat-file", "-e", f"{sha}^{{commit}}"],
                          capture_output=True).returncode != 0:
            raise RuntimeError(f"{git_dir} lacks commit {sha}; refusing, not guessing")
    code = subprocess.run(["git", "--git-dir", git_dir, "merge-base", "--is-ancestor", older, newer],
                          capture_output=True).returncode
    if code not in (0, 1):
        raise RuntimeError(f"git merge-base failed on {older} {newer}")
    return code == 0


# ------------------------------------------------------------------------------------------------ the gh shim

def gh_shim(argv: list[str]) -> int:
    """`gh` for the fallback's steps: answers from the git mirror and the variables snapshot, refuses the rest."""
    git_dir = os.environ.get("NIGHTLY_NEXT_SOURCE_GIT_DIR", "")
    variables_file = os.environ.get("NIGHTLY_FALLBACK_VARS_FILE", "")
    args = [a for a in argv]
    if not args or args[0] != "api":
        print(f"gh {' '.join(argv)}: the nightly fleet fallback makes no GitHub API calls (Actions starts no runs)",
              file=sys.stderr)
        return 1
    jq, path, headers = None, None, []
    i = 1
    while i < len(args):
        if args[i] in ("--jq", "-q"):
            jq = args[i + 1]
            i += 2
        elif args[i] in ("-H", "--header"):
            headers.append(args[i + 1])
            i += 2
        elif args[i].startswith("-"):
            i += 2 if i + 1 < len(args) and not args[i + 1].startswith("-") and args[i] in ("-X", "--method", "-f", "-F") else 1
        else:
            path = path or args[i]
            i += 1
    path = (path or "").lstrip("/")
    variable = re.fullmatch(r"repos/[^/]+/[^/]+/actions/variables/(\w+)", path)
    if variable:
        if not variables_file or not Path(variables_file).is_file():
            print(f"gh: {variable.group(1)}: no variables snapshot (NIGHTLY_FALLBACK_VARS_FILE); "
                  "the fleet fallback cannot read repository variables", file=sys.stderr)
            return 1
        snapshot = json.loads(Path(variables_file).read_text())
        if variable.group(1) not in snapshot:
            print("gh: HTTP 404: Not Found", file=sys.stderr)
            return 1
        value = str(snapshot[variable.group(1)])
        print(value if jq == ".value" else json.dumps({"name": variable.group(1), "value": value}))
        return 0
    compare = re.fullmatch(r"repos/[^/]+/[^/]+/compare/([0-9a-f]{7,40})\.\.\.([0-9a-f]{7,40})", path)
    if compare and git_dir and jq in (".status", None):
        base, head = compare.groups()
        try:
            behind = is_ancestor(git_dir, head, base)
            ahead = is_ancestor(git_dir, base, head)
        except RuntimeError as error:
            print(f"gh: {error}", file=sys.stderr)
            return 1
        status = "identical" if ahead and behind else "ahead" if ahead else "behind" if behind else "diverged"
        print(status if jq == ".status" else json.dumps({"status": status}))
        return 0
    contents = re.fullmatch(r"repos/[^/]+/[^/]+/contents/([^?]+)\?ref=([\w./-]+)", path)
    if contents and git_dir and any("raw" in h for h in headers):
        file_path, ref = contents.groups()
        for candidate in (ref, f"refs/heads/{ref}", f"refs/remotes/origin/{ref}"):
            shown = subprocess.run(["git", "--git-dir", git_dir, "show", f"{candidate}:{file_path}"],
                                   capture_output=True)
            if shown.returncode == 0:
                sys.stdout.buffer.write(shown.stdout)
                return 0
        print(f"gh: HTTP 404: {file_path} at {ref} is not in the mirror", file=sys.stderr)
        return 1
    print(f"gh api {path}: the nightly fleet fallback makes no GitHub API calls (Actions starts no runs)",
          file=sys.stderr)
    return 1


def install_shim(directory: Path) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    shim = directory / "gh"
    shim.write_text(f'#!/bin/sh\nexec "{sys.executable}" -I "{Path(__file__).resolve()}" gh-shim "$@"\n')
    shim.chmod(0o755)
    return directory


# ------------------------------------------------------------------------------------------------ the run

def missing_credentials(environ: dict) -> list[str]:
    return [name for name in REQUIRED_CREDENTIALS if not environ.get(name, "").strip()]


def git_show(git_dir: str, sha: str, path: str) -> str:
    shown = subprocess.run(["git", "--git-dir", git_dir, "show", f"{sha}:{path}"], capture_output=True, text=True)
    if shown.returncode != 0:
        raise RuntimeError(f"{git_dir} has no {path} at {sha}: {shown.stderr.strip()}")
    return shown.stdout


def resolve_build(requested: str, live_build: int) -> int:
    sys.path.insert(0, str(HERE))
    import nightly_version  # noqa: E402

    if requested == "auto":
        return nightly_version.fallback_build(live_build)
    if not re.fullmatch(r"\d+", requested):
        raise RuntimeError(f"--build {requested!r} is not a number or auto")
    build = int(requested)
    if not nightly_version.is_fallback_build(build):
        raise RuntimeError(f"build {build} is not a fallback build (attempt {build % 100:02d} < 50): "
                           "it could collide with an Actions run's number; use nightly_version.py fallback-build")
    if build <= live_build:
        raise RuntimeError(f"build {build} is not above the live build {live_build}; "
                           f"nightly_version.py fallback-build --live {live_build} gives the next one")
    return build


class Result:
    def __init__(self, sha: str, requested_build: str):
        self.data = {"sha": sha, "build": requested_build, "outcome": "failed", "feed_build_before": None,
                     "feed_build_after": None, "github_names": "pending", "steps": [], "detail": ""}

    def finish(self, code: int, outcome: str, detail: str = "") -> int:
        self.data["outcome"] = outcome
        if detail:
            self.data["detail"] = detail
            print(detail, file=sys.stderr if code not in (EXIT_PUBLISHED, EXIT_STOOD_DOWN) else sys.stdout)
        print(RESULT_PREFIX + json.dumps(self.data, sort_keys=True), flush=True)
        return code


def load_variables(path: str | None) -> tuple[dict, str | None]:
    candidates = [path, os.environ.get("NIGHTLY_FALLBACK_VARS"),
                  os.path.expanduser("~/.cache/actions-stall/cmux-vars.json")]
    for candidate in candidates:
        if candidate and Path(candidate).is_file():
            data = json.loads(Path(candidate).read_text())
            if not isinstance(data, dict):
                raise RuntimeError(f"{candidate} is not a JSON object")
            return {str(k): str(v) for k, v in data.items()}, str(candidate)
        if candidate == path and path:
            raise RuntimeError(f"variables snapshot {path} does not exist")
    return {}, None


def run(args, environ: dict | None = None, interpreter_class=Interpreter) -> int:
    environ = dict(os.environ if environ is None else environ)
    result = Result(args.sha, args.build)
    if not re.fullmatch(r"[0-9a-f]{40}", args.sha or ""):
        return result.finish(EXIT_FAILED, "failed", f"--sha {args.sha!r} is not a full commit SHA")
    if getattr(args, "candidate_out", None):
        return run_candidate(args, environ, interpreter_class)
    missing = missing_credentials(environ)
    if missing:
        return result.finish(EXIT_NO_CREDENTIALS, "no-credentials",
                             "missing credentials (set them under the workflow's secret names, e.g. op run "
                             f"--env-file): {', '.join(missing)}; nothing built")
    fleet_owned = Path(environ.get("CMUX_FLEET_DIR", "/Users/Shared/cmux-build-fleet")).is_dir()
    if fleet_owned and environ.get("NIGHTLY_FALLBACK_HOST_CLAIM") != "exclusive" and not args.dry_run:
        return result.finish(EXIT_FAILED, "refused",
                             "this owned Mac is not held for the fallback (NIGHTLY_FALLBACK_HOST_CLAIM=exclusive is "
                             "the dispatcher's word that no glaeda job shares it); a signing job never runs beside "
                             "another job")
    git_dir = args.git_dir
    if subprocess.run(["git", "--git-dir", git_dir, "cat-file", "-e", f"{args.sha}^{{commit}}"],
                      capture_output=True).returncode != 0:
        subprocess.run(["git", "--git-dir", git_dir, "fetch", "--quiet", "origin", args.sha], capture_output=True)
        if subprocess.run(["git", "--git-dir", git_dir, "cat-file", "-e", f"{args.sha}^{{commit}}"],
                          capture_output=True).returncode != 0:
            return result.finish(EXIT_FAILED, "failed", f"{git_dir} does not have {args.sha}")
    try:
        variables, variables_file = load_variables(args.vars)
        workflow_text = git_show(git_dir, args.sha, WORKFLOW)
        workflow = load_workflow(workflow_text)
    except RuntimeError as error:
        return result.finish(EXIT_FAILED, "failed", str(error))
    problems = drift(workflow)
    if problems:
        return result.finish(EXIT_FAILED, "failed", "the fallback does not cover nightly.yml at "
                             f"{args.sha} (update scripts/ci/nightly_next_fleet_fallback.py):\n  " + "\n  ".join(problems))
    workflow_env = {k: str(v) for k, v in (workflow.get("env") or {}).items() if "${{" not in str(v)}
    feed_base = environ.get("NIGHTLY_FALLBACK_FEED_BASE") or workflow_env["NIGHTLY_NEXT_FEED_BASE"]
    try:
        live_build, live_source = live_state(read_public_feed(f"{feed_base.rstrip('/')}/{FEED}"))
    except Exception as error:  # noqa: BLE001 - an unreadable feed: decide nothing
        return result.finish(EXIT_FAILED, "failed", f"could not read the live feed: {error}")
    result.data["feed_build_before"] = live_build
    result.data["feed_build_after"] = live_build
    if variables.get("NIGHTLY_NEXT_NOTARY_PAUSED") == "1" or variables.get("NIGHTLY_NEXT_SUBMISSIONS_PAUSED") == "1":
        return result.finish(EXIT_STOOD_DOWN, "stood-down", "nightly-next notarization is paused (variables "
                             "snapshot); a paused pipeline publishes nothing, so neither does the fallback")
    if live_source == args.sha:
        return result.finish(EXIT_STOOD_DOWN, "already-live",
                             f"the live feed's build {live_build} already serves {args.sha}; nothing built")
    if live_source:
        try:
            if not is_ancestor(git_dir, live_source, args.sha):
                return result.finish(EXIT_STOOD_DOWN, "superseded",
                                     f"the live feed serves {live_source} (build {live_build}), which {args.sha} does "
                                     "not descend from; nothing built")
        except RuntimeError as error:
            return result.finish(EXIT_FAILED, "failed", str(error))
    try:
        build = resolve_build(args.build, live_build)
    except Exception as error:  # noqa: BLE001
        return result.finish(EXIT_FAILED, "failed", str(error))
    result.data["build"] = build
    if args.dry_run:
        plan = plan_steps(workflow)
        result.data["steps"] = [{"job": s["job"], "step": s["step"], "outcome": "planned" if s["runs"] else
                                 "skipped-fallback"} for s in plan]
        return result.finish(EXIT_PUBLISHED, "dry-run", f"would build {args.sha} as {build} above live {live_build}")
    workdir = Path(args.workdir).resolve()
    workdir.mkdir(parents=True, exist_ok=True)
    shim = install_shim(workdir / "bin")
    snapshot_file = workdir / "vars.json"
    if variables_file:
        snapshot_file.write_text(json.dumps(variables))
    base_env = {k: v for k, v in environ.items() if k not in REQUIRED_CREDENTIALS and k not in OPTIONAL_CREDENTIALS
                and not k.startswith(("GITHUB_", "RUNNER_", "OP_"))}
    base_env["NIGHTLY_NEXT_SOURCE_GIT_DIR"] = os.path.abspath(git_dir)
    # ensure-cef.sh: the Chromium engine from R2 only, never its GitHub release fallback (API).
    base_env["CMUX_CEF_NO_GITHUB"] = "1"
    base_env["NIGHTLY_FALLBACK_VARS_FILE"] = str(snapshot_file) if variables_file else ""
    known = {name: variables.get(name, "") for name in KNOWN_VARS}
    needs = synthetic_needs(args.sha, live_source or "", workflow_env, variables, build)
    interpreter = interpreter_class(workflow, sha=args.sha, build=build, workdir=workdir, git_dir=git_dir,
                                    variables={**known, **variables}, credentials={k: environ.get(k, "") for k in
                                    (*REQUIRED_CREDENTIALS, *OPTIONAL_CREDENTIALS)}, base_env=base_env, needs=needs,
                                    shim_dir=shim)
    try:
        for job in MIRRORED_JOBS:
            outcome = interpreter.run_job(job)
            if outcome == "failure" and job != "publish-nightly":
                # Later jobs would skip on their own `needs`; stop here, the way their `if:` would.
                result.data["steps"] = interpreter.record
                return result.finish(EXIT_FAILED, "failed", f"{job} failed; nothing published")
    finally:
        result.data["steps"] = interpreter.record
    publish = interpreter.needs.get("publish-nightly", {"result": "skipped", "outputs": {}})
    return conclude(result, publish, feed_base)


def conclude(result: Result, publish: dict, feed_base: str) -> int:
    outputs = publish.get("outputs", {})
    try:
        after, _ = live_state(read_public_feed(f"{feed_base.rstrip('/')}/{FEED}"))
        result.data["feed_build_after"] = after
    except Exception:  # noqa: BLE001 - the read-back is reported, not decided on
        pass
    if publish.get("result") == "skipped":
        return result.finish(EXIT_STOOD_DOWN, "stood-down", "publish-nightly did not run (its if: is false)")
    if outputs.get("feed_written") == "true" and publish.get("result") == "success":
        return result.finish(EXIT_PUBLISHED, "published", f"build {result.data['build']} is live")
    if outputs.get("refusal_reason"):
        return result.finish(EXIT_FAILED, "refused", f"the publication gate refused: {outputs['refusal_reason']}")
    if outputs.get("refused") == "true" or outputs.get("already_published") == "true":
        return result.finish(EXIT_STOOD_DOWN, "superseded", "write-feed or the gate stood down: another build or "
                             "publisher is already live or newer; nothing published")
    return result.finish(EXIT_FAILED, "failed", f"publish-nightly ended {publish.get('result')}; feed_written="
                         f"{outputs.get('feed_written')!r}")


# ------------------------------------------------------------------------------------------------ candidate

# A candidate run (`run --candidate-out DIR`): the nightly's own build of SHA, unsigned, on any owned Mac with no
# credentials, for the continuous tip loop (cmuxterm-hq build-fleet/tip-loop). Leo, 2026-11-11: "we still want to
# ensure that things work. there is the fallback simple route of "this one just keeps building that s***"". It runs
# the jobs up to the prepared (unsigned, thinned, helper-injected) app, the same steps as above, then a fresh-home
# launch smoke of that app (fresh_home_launch_smoke.py, nightly.yml's own harness). It never signs, notarizes or
# publishes, reads no credential and moves nothing. The app is kept in DIR as the ready candidate.
#
# Exit: 0 green (built, webview checks passed, the smoke passed or could not run here), 1 red (a job failed, or the
# app crashed at launch twice), 75 no verdict (drift, no commit, an unreadable feed for --build auto, no app to
# smoke). The result line carries `failed: {job, step}`, `build_sha` (the commit the resolver built, which can be
# older than SHA while a newer cmux-tui tree publishes), `candidate_app` and `smoke`.
CANDIDATE_JOBS = MIRRORED_JOBS[:MIRRORED_JOBS.index("prepare-nightly-variant-primary") + 1]
EXIT_NO_VERDICT = 75
PREPARED_APP = "*-prepared-app-arm64-*/cmux-prepared-app.tar.gz"
SMOKE_SECONDS = 300


def first_failure(record: list[dict]) -> dict:
    """The first failed step of a run's record: {job, step} (step "(job)" when the job failed with no step)."""
    for row in record:
        if row.get("outcome") == "failure":
            return {"job": row.get("job"), "step": row.get("step")}
    return {}


def smoke_candidate(app: Path, out: Path, timeout: float = SMOKE_SECONDS, log=print) -> dict:
    """nightly.yml's launch smoke of APP from a fresh and a seeded home, two attempts on a crash, as
    launch-smoke-gate.sh runs it: {verdict: pass|crash|cannot-run, attempts: [exit codes], out}."""
    harness = HERE / "fresh_home_launch_smoke.py"
    attempts: list[int] = []
    for attempt in (1, 2):
        where = out / f"attempt-{attempt}"
        where.mkdir(parents=True, exist_ok=True)
        try:
            code = subprocess.run([sys.executable, "-I", str(harness), "--app", str(app), "--out", str(where),
                                   "--arms", "empty,seeded"], timeout=timeout).returncode
        except subprocess.TimeoutExpired:
            code = 124
        except OSError as error:
            log(f"launch smoke attempt {attempt}: could not run: {error}")
            code = 3
        attempts.append(code)
        log(f"launch smoke attempt {attempt}: exit {code}")
        if code != 1:
            break
    verdict = "pass" if attempts[-1] == 0 else "crash" if attempts[-1] == 1 else "cannot-run"
    return {"verdict": verdict, "attempts": attempts, "out": str(out)}


def unpack_candidate(artifacts: Path, dest: Path) -> Path | None:
    """The prepared app's tarball from the run's artifact store, unpacked into DEST: the .app, or None."""
    found = sorted(artifacts.glob(PREPARED_APP))
    if not found:
        return None
    if dest.exists():
        shutil.rmtree(dest)
    dest.mkdir(parents=True)
    subprocess.run(["tar", "-xzf", str(found[-1]), "-C", str(dest)], check=True)
    apps = sorted(dest.glob("*.app"))
    return apps[0] if apps else None


def run_candidate(args, environ: dict, interpreter_class=Interpreter, smoke=None) -> int:
    result = Result(args.sha, args.build)
    result.data.update(mode="candidate", github_names="none", failed={}, build_sha=None, candidate_app=None,
                       smoke=None)
    git_dir = args.git_dir
    if subprocess.run(["git", "--git-dir", git_dir, "cat-file", "-e", f"{args.sha}^{{commit}}"],
                      capture_output=True).returncode != 0:
        return result.finish(EXIT_NO_VERDICT, "no-verdict", f"{git_dir} does not have {args.sha}")
    try:
        variables, variables_file = load_variables(args.vars)
        workflow = load_workflow(git_show(git_dir, args.sha, WORKFLOW))
    except RuntimeError as error:
        return result.finish(EXIT_NO_VERDICT, "no-verdict", str(error))
    problems = drift(workflow, CANDIDATE_JOBS)
    if problems:
        return result.finish(EXIT_NO_VERDICT, "no-verdict", "the fallback does not cover nightly.yml's build jobs at "
                             f"{args.sha} (update scripts/ci/nightly_next_fleet_fallback.py):\n  " + "\n  ".join(problems))
    workflow_env = {k: str(v) for k, v in (workflow.get("env") or {}).items() if "${{" not in str(v)}
    feed_base = environ.get("NIGHTLY_FALLBACK_FEED_BASE") or workflow_env.get("NIGHTLY_NEXT_FEED_BASE", "")
    live_build, live_source = 0, None
    try:
        live_build, live_source = live_state(read_public_feed(f"{feed_base.rstrip('/')}/{FEED}"))
    except Exception as error:  # noqa: BLE001 - only --build auto needs it
        if args.build == "auto":
            return result.finish(EXIT_NO_VERDICT, "no-verdict", f"could not read the live feed for --build auto: {error}")
    result.data["feed_build_before"] = live_build
    try:
        build = resolve_build(args.build, live_build)
    except Exception as error:  # noqa: BLE001
        return result.finish(EXIT_NO_VERDICT, "no-verdict", str(error))
    result.data["build"] = build
    workdir = Path(args.workdir).resolve()
    if workdir.exists():
        shutil.rmtree(workdir)  # a candidate starts clean: no artifact of an older SHA can stand in for this one's
    workdir.mkdir(parents=True)
    shim = install_shim(workdir / "bin")
    snapshot_file = workdir / "vars.json"
    if variables_file:
        snapshot_file.write_text(json.dumps(variables))
    secrets = (*REQUIRED_CREDENTIALS, *OPTIONAL_CREDENTIALS)
    base_env = {k: v for k, v in environ.items() if k not in secrets and not k.startswith(("GITHUB_", "RUNNER_", "OP_"))}
    base_env["NIGHTLY_NEXT_SOURCE_GIT_DIR"] = os.path.abspath(git_dir)
    base_env["CMUX_CEF_NO_GITHUB"] = "1"
    base_env["NIGHTLY_FALLBACK_VARS_FILE"] = str(snapshot_file) if variables_file else ""
    known = {name: variables.get(name, "") for name in KNOWN_VARS}
    needs = synthetic_needs(args.sha, live_source or "", workflow_env, variables, build)
    # Only the read-only Chromium engine key reaches a step, when the host has it; nothing signs or publishes.
    credentials = {k: (environ.get(k, "") if k.startswith("CMUX_CEF_R2_") else "") for k in secrets}
    interpreter = interpreter_class(workflow, sha=args.sha, build=build, workdir=workdir, git_dir=git_dir,
                                    variables={**known, **variables}, credentials=credentials, base_env=base_env,
                                    needs=needs, shim_dir=shim)
    try:
        for job in CANDIDATE_JOBS:
            outcome = interpreter.run_job(job)
            if job == "resolve-nightly-cmux-tui-client":
                result.data["build_sha"] = (interpreter.needs.get(job, {}).get("outputs") or {}).get("build_sha") or None
            if outcome == "failure":
                result.data["failed"] = first_failure(interpreter.record) or {"job": job, "step": "(job)"}
                return result.finish(EXIT_FAILED, "red", f"{job} failed; no candidate")
    finally:
        result.data["steps"] = interpreter.record
    dest = Path(args.candidate_out) / f"{args.sha[:12]}-{build}"
    app = unpack_candidate(workdir / "artifacts", dest)
    if app is None:
        return result.finish(EXIT_NO_VERDICT, "no-verdict", "the build jobs passed but left no prepared app "
                             f"({PREPARED_APP} in {workdir / 'artifacts'})")
    result.data["candidate_app"] = str(app)
    if getattr(args, "no_smoke", False):
        result.data["smoke"] = {"verdict": "not-run"}
    else:
        result.data["smoke"] = (smoke or smoke_candidate)(app, dest / "launch-smoke")
        if result.data["smoke"]["verdict"] == "crash":
            result.data["failed"] = {"job": "launch smoke", "step": "Launch smoke from a fresh home"}
            return result.finish(EXIT_FAILED, "red", f"the candidate {app} crashed at launch on both attempts")
    return result.finish(EXIT_PUBLISHED, "green", f"candidate {app} (build {build}, smoke "
                         f"{result.data['smoke']['verdict']})")


def plan_steps(workflow: dict) -> list[dict]:
    plan = []
    for job in MIRRORED_JOBS:
        for step in workflow["jobs"][job].get("steps", []):
            name = step_name(step)
            skipped = (job, name) in SKIPPED_STEPS
            plan.append({"job": job, "step": name, "runs": not skipped, "uses": step.get("uses"),
                         "scripts": step_scripts(step), "why": SKIPPED_STEPS.get((job, name), "")})
    return plan


REVIEWED_SCRIPTS_JSON = "nightly_next_fleet_fallback_scripts.json"


def load_reviewed_scripts() -> None:
    path = HERE / REVIEWED_SCRIPTS_JSON
    data = json.loads(path.read_text(encoding="utf-8"))
    REVIEWED_SCRIPTS.clear()
    REVIEWED_SCRIPTS.update({job: tuple(scripts) for job, scripts in data["jobs"].items()})


def main(argv: list[str]) -> int:
    if argv[:1] == ["gh-shim"]:
        return gh_shim(argv[1:])
    load_reviewed_scripts()
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    r = sub.add_parser("run")
    r.add_argument("--sha", required=True)
    r.add_argument("--build", required=True, help="a fallback build number (attempt 50..99) or auto")
    r.add_argument("--workdir", default=os.path.expanduser("~/.cache/nightly-next-fleet-fallback"))
    r.add_argument("--git-dir", default=DEFAULT_GIT_DIR)
    r.add_argument("--vars", help="the repository variables snapshot (JSON object)")
    r.add_argument("--dry-run", action="store_true", help="check credentials, the live feed and the plan; build nothing")
    r.add_argument("--candidate-out", help="a candidate run: build the unsigned app, smoke it, keep it in this "
                   "directory; no credentials, no signing, no publishing (see run_candidate)")
    r.add_argument("--no-smoke", action="store_true", help="with --candidate-out: skip the launch smoke")
    p = sub.add_parser("plan")
    p.add_argument("--workflow", default=str(HERE.parent.parent / WORKFLOW))
    args = parser.parse_args(argv)
    if args.command == "plan":
        workflow = load_workflow(Path(args.workflow).read_text(encoding="utf-8"))
        print(json.dumps({"drift": drift(workflow), "steps": plan_steps(workflow)}, indent=2))
        return 0
    return run(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
