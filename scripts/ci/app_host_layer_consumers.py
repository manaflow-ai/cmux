#!/usr/bin/env python3
"""Versioned authorization map from CI consumers to canonical app-host layers."""
from __future__ import annotations

import json
from pathlib import Path
import re

from app_host_layered_products import LAYERS

SCHEMA = "cmux.app-host-layer-consumers"
VERSION = 1
POLICY = Path(__file__).with_name("app-host-layer-consumers.json")


def load_policy(path: Path = POLICY) -> dict:
    value = json.loads(path.read_text())
    if not isinstance(value, dict) or set(value) != {"schema", "version", "consumers"}:
        raise ValueError("consumer layer policy must contain schema, version and consumers")
    if value.get("schema") != SCHEMA or type(value.get("version")) is not int or value["version"] != VERSION:
        raise ValueError("unsupported consumer layer policy")
    consumers = value.get("consumers")
    if not isinstance(consumers, dict) or not consumers:
        raise ValueError("consumer layer policy must declare consumers")
    for name, layers in consumers.items():
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9/_-]*", name):
            raise ValueError(f"invalid app-host consumer identity: {name!r}")
        if not isinstance(layers, list) or not layers or any(not isinstance(layer, str) for layer in layers):
            raise ValueError(f"invalid layer selection for consumer: {name}")
        selected = tuple(layers)
        if len(set(selected)) != len(selected) or any(layer not in LAYERS for layer in selected):
            raise ValueError(f"unknown or duplicate layer in consumer policy: {name}")
        if selected != tuple(layer for layer in LAYERS if layer in selected):
            raise ValueError(f"consumer layers must follow canonical order: {name}")
    return value


def required_layers(consumer: str, policy: dict | None = None) -> tuple[str, ...]:
    value = load_policy() if policy is None else policy
    consumers = value["consumers"]
    if consumer not in consumers:
        raise ValueError(f"unknown app-host product consumer: {consumer}")
    return tuple(consumers[consumer])


def main() -> None:
    import argparse
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("consumer")
    args = parser.parse_args()
    print(",".join(required_layers(args.consumer)))


if __name__ == "__main__":
    main()
