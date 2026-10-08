#!/usr/bin/env python3
"""Every job that reads signing material runs in a protected environment.

Repository-level secrets reach any workflow on any branch a writer can push.
The signing material (Developer ID and iOS distribution certificates,
provisioning profiles, App Store Connect keys, Sparkle EdDSA keys, the
release App key and the content-signing key) therefore lives only in GitHub
environments whose deployment policy admits the refs that really release:

- `release`: branch main and tags v*
- `release-next`: branch nightly-next
- `content-signing`: the content-signing key only

A job without such an environment would read nothing once the repository-level
copies are deleted, so this guard fails before that breaks a release. It also
refuses workflow-level `env:` that names a signing secret, because that leaks
it into every job of the workflow.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"

RELEASE_ENVIRONMENTS = {"release", "release-next"}
CONTENT_SIGNING_ENVIRONMENTS = {"content-signing"}

SIGNING_SECRET = re.compile(
    r"^(APPLE_[A-Z0-9_]+"
    r"|ASC_API_[A-Z0-9_]+"
    r"|IOS_[A-Z0-9_]+"
    r"|(NIGHTLY_)?SPARKLE_(NEXT_)?PRIVATE_KEY"
    r"|CMUX_RELEASE_APP_KEY"
    r"|CONTENT_SIGNING_[A-Z0-9_]+)$"
)
SECRET_REFERENCE = re.compile(r"secrets\.([A-Za-z0-9_]+)|secrets\[\s*['\"]([A-Za-z0-9_]+)['\"]\s*\]")
DYNAMIC_REFERENCE = re.compile(r"secrets\[\s*(?!['\"])")
QUOTED = re.compile(r"'([^']*)'")
# In `cond && 'a' || 'b'` the results are the literals after && or ||; the
# literals inside the condition ('refs/heads/main') are not environment names.
RESULT_LITERAL = re.compile(r"(?:&&|\|\|)\s*'([^']*)'")
NEEDS_ENVIRONMENT = re.compile(r"^\$\{\{\s*needs\.([A-Za-z0-9_-]+)\.outputs\.environment\s*\}\}$")
SET_ENVIRONMENT = re.compile(r"setOutput\(\s*['\"]environment['\"]\s*,\s*([^;\n]+)\)")


def allowed_for(secret: str) -> set[str]:
    if secret.startswith("CONTENT_SIGNING_"):
        return CONTENT_SIGNING_ENVIRONMENTS
    return RELEASE_ENVIRONMENTS


def referenced_secrets(node: object) -> tuple[set[str], bool]:
    text = json.dumps(node)
    names = {a or b for a, b in SECRET_REFERENCE.findall(text)}
    return {name for name in names if SIGNING_SECRET.match(name)}, bool(DYNAMIC_REFERENCE.search(text))


def environment_values(document: dict, job: dict) -> set[str] | None:
    """The environment names a job can enter, or None when it cannot be resolved."""
    environment = job.get("environment")
    if isinstance(environment, dict):
        environment = environment.get("name")
    if environment is None:
        return {""}
    environment = str(environment).strip()
    if "${{" not in environment:
        return {environment}
    needs = NEEDS_ENVIRONMENT.match(environment)
    if needs:
        # The value comes from a decision step: read every literal it can set.
        source = (document.get("jobs") or {}).get(needs.group(1))
        if not isinstance(source, dict):
            return None
        values: set[str] = set()
        for step in source.get("steps") or []:
            script = str((step.get("with") or {}).get("script", "")) + str(step.get("run", ""))
            for expression in SET_ENVIRONMENT.findall(script):
                literals = QUOTED.findall(expression)
                if not literals:
                    return None
                values.update(literals)
        return values or None
    # An inline expression: every literal result is a possible value.
    return set(RESULT_LITERAL.findall(environment)) or None


def main() -> int:
    failures: list[str] = []
    signing_jobs = 0
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        document = yaml.safe_load(path.read_text(encoding="utf-8"))
        if not isinstance(document, dict):
            continue
        top_level, top_dynamic = referenced_secrets(document.get("env") or {})
        if top_level or top_dynamic:
            failures.append(
                f"{path.name}: workflow-level env names signing secrets {sorted(top_level)}; "
                "move them to the job that runs in the release environment"
            )
        for job_name, job in (document.get("jobs") or {}).items():
            if not isinstance(job, dict):
                continue
            secrets, dynamic = referenced_secrets(job)
            if not secrets and not dynamic:
                continue
            if dynamic and not secrets:
                # A computed secrets[...] lookup may pick any name, signing included.
                secrets = {"<dynamic secrets[...] lookup>"}
            signing_jobs += 1
            where = f"{path.name} {job_name}"
            if "uses" in job:
                failures.append(
                    f"{where}: passes signing secrets {sorted(secrets)} into a reusable workflow; "
                    "the called job must read them from its own release environment"
                )
                continue
            values = environment_values(document, job)
            if values is None:
                failures.append(f"{where}: environment {job.get('environment')!r} cannot be resolved to literal names")
                continue
            entered = values - {""}
            for secret in sorted(secrets):
                allowed = allowed_for(secret)
                if not entered:
                    failures.append(
                        f"{where}: reads {secret} without a protected environment; "
                        f"declare environment: one of {sorted(allowed)}"
                    )
                elif not entered <= allowed:
                    failures.append(
                        f"{where}: reads {secret} in environment {sorted(entered)}; "
                        f"it lives only in {sorted(allowed)}"
                    )
    if signing_jobs < 5:
        failures.append(f"found only {signing_jobs} signing jobs; this guard is reading the wrong tree")
    if failures:
        print("Signing secrets must be read only inside a protected environment:")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print(f"OK: {signing_jobs} jobs read signing secrets, each inside a protected environment")
    return 0


if __name__ == "__main__":
    sys.exit(main())
