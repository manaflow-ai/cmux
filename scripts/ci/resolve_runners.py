#!/usr/bin/env python3
"""Resolve CI runner capabilities to the labels that answer them today.

A job says what it needs (``macos_26_ios``); this resolver says which label
serves that need on whichever repository the workflow is running in. The map
lives in ``.github/runners.json`` so it is reviewed, diffable and -- the point
-- present in every fork.

Fleet selection:

1. ``--fleet`` / ``CMUX_CI_RUNNER_FLEET``, when non-empty, wins. This is the
   operator escape hatch: routing changes without a merge.
2. Otherwise the repository owner is looked up in ``owners``.
3. An owner that is not listed -- which is every fork, because a fork lives on
   a personal account -- gets ``default_fleet``. That is what makes a fork run
   CI with zero configuration. Blacksmith is an organization-level GitHub App;
   a ``blacksmith-*`` label on a personal account does not error, it queues
   forever and wedges the workflow's concurrency group.

Per-capability overrides come in as ``--overrides`` / ``CMUX_CI_RUNNER_OVERRIDES``
holding a JSON *object as a string*. They are read here, in Python, and never
with ``fromJSON(vars.X)`` in a workflow expression: ``fromJSON()`` on an unset
repository variable is an empty string, and ``fromJSON('')`` fails the whole
workflow at expression evaluation. An unset variable expands to ``''`` for this
script, which treats it as "no override".

Everything else fails loudly. A malformed map, an unknown fleet, an unknown
capability key in an override, or a fleet that is missing a capability another
fleet defines all abort before anything is printed. Emitting a partial map
would produce ``runs-on: ''``, and an empty or unrecognised label is the one
failure mode GitHub does not report: the job queues forever.

Pure stdlib, Python 3.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MAP = ROOT / ".github" / "runners.json"

FLEET_ENV = "CMUX_CI_RUNNER_FLEET"
OVERRIDES_ENV = "CMUX_CI_RUNNER_OVERRIDES"
OWNER_ENV = "GITHUB_REPOSITORY_OWNER"


class ResolveError(Exception):
    """The map, the override or the request cannot produce a complete answer."""


def _require_mapping(value: Any, what: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ResolveError(f"{what} must be a JSON object, got {type(value).__name__}")
    for key in value:
        if not isinstance(key, str) or not key.strip():
            raise ResolveError(f"{what} has a key that is not a non-empty string: {key!r}")
    return value


def _require_labels(value: Any, what: str) -> dict[str, str]:
    mapping = _require_mapping(value, what)
    for key, label in mapping.items():
        if not isinstance(label, str) or not label.strip():
            raise ResolveError(f"{what}.{key} must be a non-empty string label, got {label!r}")
    return dict(mapping)


def load_map(path: Path) -> dict[str, Any]:
    """Read and fully validate the capability map."""
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as error:
        raise ResolveError(f"cannot read runner map {path}: {error}") from error
    try:
        document = json.loads(raw)
    except json.JSONDecodeError as error:
        raise ResolveError(f"{path} is not valid JSON: {error}") from error

    document = _require_mapping(document, str(path))
    for field in ("capabilities", "fleets", "owners", "default_fleet"):
        if field not in document:
            raise ResolveError(f"{path} is missing required field {field!r}")

    capabilities = _require_mapping(document["capabilities"], "capabilities")
    if not capabilities:
        raise ResolveError("capabilities must declare at least one capability")
    for key, description in capabilities.items():
        if not isinstance(description, str) or not description.strip():
            raise ResolveError(f"capabilities.{key} must describe the capability in prose")

    fleets = _require_mapping(document["fleets"], "fleets")
    if not fleets:
        raise ResolveError("fleets must declare at least one fleet")

    declared = set(capabilities)
    for name, labels in fleets.items():
        provided = set(_require_labels(labels, f"fleets.{name}"))
        missing = sorted(declared - provided)
        if missing:
            raise ResolveError(
                f"fleet {name!r} is missing capability keys: {', '.join(missing)}. "
                "A capability with no label renders as an empty runs-on, which GitHub "
                "queues forever instead of failing."
            )
        extra = sorted(provided - declared)
        if extra:
            raise ResolveError(
                f"fleet {name!r} defines undeclared capability keys: {', '.join(extra)}. "
                "Add them to `capabilities` (and to every fleet) or remove them."
            )

    default_fleet = document["default_fleet"]
    if not isinstance(default_fleet, str) or default_fleet not in fleets:
        raise ResolveError(f"default_fleet {default_fleet!r} is not a declared fleet")

    owners = _require_mapping(document["owners"], "owners")
    for owner, fleet in owners.items():
        if not isinstance(fleet, str) or fleet not in fleets:
            raise ResolveError(f"owners.{owner} names undeclared fleet {fleet!r}")

    return document


def parse_overrides(text: str | None, capabilities: set[str]) -> dict[str, str]:
    """Read the override variable defensively; unset or blank means none."""
    if text is None or not text.strip():
        return {}
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError as error:
        raise ResolveError(
            f"{OVERRIDES_ENV} is not valid JSON: {error}. "
            'Expected an object of capability -> label, e.g. {"macos_26": "macos-15"}.'
        ) from error
    overrides = _require_labels(parsed, OVERRIDES_ENV)
    unknown = sorted(set(overrides) - capabilities)
    if unknown:
        raise ResolveError(
            f"{OVERRIDES_ENV} names unknown capability keys: {', '.join(unknown)}. "
            "A typo here would silently change nothing."
        )
    return overrides


def choose_fleet(document: dict[str, Any], owner: str, forced: str | None) -> tuple[str, str]:
    """Return the fleet name and the one-line reason it was chosen."""
    fleets: dict[str, Any] = document["fleets"]
    if forced is not None and forced.strip():
        name = forced.strip()
        if name not in fleets:
            raise ResolveError(
                f"fleet override {name!r} is not a declared fleet "
                f"({', '.join(sorted(fleets))})"
            )
        return name, f"fleet override {FLEET_ENV}={name}"

    owners: dict[str, Any] = document["owners"]
    if owner in owners:
        return owners[owner], f"owner {owner} is mapped to this fleet"
    default_fleet: str = document["default_fleet"]
    return default_fleet, f"owner {owner or '(unset)'} is not a mapped owner; using default_fleet"


def resolve(
    *,
    map_path: Path,
    owner: str,
    forced_fleet: str | None = None,
    overrides_text: str | None = None,
) -> tuple[str, str, dict[str, str]]:
    document = load_map(map_path)
    capabilities = set(document["capabilities"])
    fleet, reason = choose_fleet(document, owner, forced_fleet)
    labels = dict(document["fleets"][fleet])
    labels.update(parse_overrides(overrides_text, capabilities))

    missing = sorted(capabilities - set(labels))
    if missing:  # pragma: no cover - load_map already rejects this
        raise ResolveError(f"resolved map is missing capability keys: {', '.join(missing)}")
    return fleet, reason, labels


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Resolve CI runner capabilities to labels.")
    parser.add_argument("--map", type=Path, default=DEFAULT_MAP, help="path to runners.json")
    parser.add_argument(
        "--owner",
        default=None,
        help=f"repository owner (default: ${OWNER_ENV})",
    )
    parser.add_argument(
        "--fleet",
        default=None,
        help=f"force a fleet (default: ${FLEET_ENV})",
    )
    parser.add_argument(
        "--overrides",
        default=None,
        help=f"JSON object of capability -> label (default: ${OVERRIDES_ENV})",
    )
    parser.add_argument(
        "--github-output",
        type=Path,
        default=None,
        help="append map=/fleet= to this file (default: $GITHUB_OUTPUT when set)",
    )
    args = parser.parse_args(argv)

    owner = args.owner if args.owner is not None else os.environ.get(OWNER_ENV, "")
    forced = args.fleet if args.fleet is not None else os.environ.get(FLEET_ENV)
    overrides = args.overrides if args.overrides is not None else os.environ.get(OVERRIDES_ENV)

    try:
        fleet, reason, labels = resolve(
            map_path=args.map,
            owner=owner,
            forced_fleet=forced,
            overrides_text=overrides,
        )
    except ResolveError as error:
        print(f"resolve_runners: {error}", file=sys.stderr)
        return 1

    payload = json.dumps(labels, sort_keys=True, separators=(",", ":"))
    print(payload)
    print(f"resolve_runners: fleet={fleet} ({reason})", file=sys.stderr)

    output = args.github_output
    if output is None:
        env_output = os.environ.get("GITHUB_OUTPUT", "")
        output = Path(env_output) if env_output else None
    if output is not None:
        with output.open("a", encoding="utf-8") as handle:
            handle.write(f"map={payload}\n")
            handle.write(f"fleet={fleet}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
