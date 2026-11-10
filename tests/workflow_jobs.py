"""A workflow's jobs, read with a YAML loader instead of by matching job header lines.

Guards that derive a job list from a workflow (which jobs hold secrets, which jobs gate a
merge) must see every job GitHub sees. A hand-written header regex such as
`\\n  ([A-Za-z0-9_-]+):\\n` misses `  deploy-x: # note`, folds that job's body into the job
before it, and the job escapes the guard. The loader reads headers the way GitHub does.

PyYAML reads the `on:` key as the boolean True; nothing here reads it. A guard that needs
the triggers reads `document.get("on", document.get(True))`.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import yaml


class _UniqueKeyLoader(yaml.SafeLoader):
    """SafeLoader that refuses a repeated mapping key: PyYAML keeps the last one silently, so a
    second job with an existing name would hide the first from the guard."""


def _unique_mapping(loader: yaml.SafeLoader, node: yaml.MappingNode, deep: bool = False) -> dict:
    loader.flatten_mapping(node)
    seen = set()
    for key_node, _ in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in seen:
            raise ValueError(f"line {key_node.start_mark.line + 1}: repeated key {key!r}")
        seen.add(key)
    return loader.construct_mapping(node, deep=deep)


_UniqueKeyLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _unique_mapping)


def document(source: str | Path) -> dict[str, Any]:
    """The whole workflow, from a path or from its text."""
    text = source.read_text(encoding="utf-8") if isinstance(source, Path) else source
    loaded = yaml.load(text, Loader=_UniqueKeyLoader)
    if not isinstance(loaded, dict):
        raise ValueError(f"workflow is not a mapping: {type(loaded).__name__}")
    return loaded


def jobs(source: str | Path) -> dict[str, dict[str, Any]]:
    """Each job's name and body. Fails on a workflow without a jobs mapping or a job that is not
    a mapping, so a malformed file cannot come back as an empty, passing job set."""
    found = document(source).get("jobs")
    if not isinstance(found, dict) or not found:
        raise ValueError("workflow has no jobs mapping")
    for name, job in found.items():
        if not isinstance(job, dict):
            raise ValueError(f"job {name!r} is not a mapping")
    return found


def holds_secret(job: dict[str, Any]) -> bool:
    """A job holds secrets if it reads secrets.* anywhere (steps, env, with, runs-on), passes
    them all on with `secrets: inherit`, or runs under a deployment environment, which carries
    its own secrets."""
    return ("secrets." in yaml.safe_dump(job)
            or job.get("secrets") == "inherit"
            or bool(job.get("environment")))


def runs_on(job: dict[str, Any]) -> str:
    """The job's runs-on as written ("" when it has none, as a reusable-workflow call does)."""
    value = job.get("runs-on", "")
    return value if isinstance(value, str) else yaml.safe_dump(value, default_flow_style=True).strip()
