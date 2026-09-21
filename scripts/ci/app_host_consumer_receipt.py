#!/usr/bin/env python3
"""Auditable per-consumer app-host artifact transfer and runner receipt."""
from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import tempfile
import time

from app_host_layer_consumers import required_layers
from app_host_layered_products import LAYERS

SCHEMA = "cmux.app-host-consumer-receipt"
VERSION = 1


def receipt_path() -> Path | None:
    value = os.environ.get("CMUX_APP_HOST_CONSUMER_RECEIPT", "")
    return Path(value) if value else None


def _read() -> dict | None:
    path = receipt_path()
    if path is None or not path.is_file():
        return None
    value = json.loads(path.read_text())
    if value.get("schema") != SCHEMA or value.get("version") != VERSION:
        raise ValueError("unsupported app-host consumer receipt")
    return value


def _write(value: dict) -> None:
    path = receipt_path()
    if path is None:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as output:
            json.dump(value, output, indent=2, sort_keys=True)
            output.write("\n")
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def _nonnegative_int(value, label: str) -> int:
    if isinstance(value, bool):
        raise ValueError(f"{label} must be a nonnegative integer")
    result = int(value)
    if result < 0:
        raise ValueError(f"{label} must be a nonnegative integer")
    return result


def _seconds(value, label: str) -> float:
    result = float(value)
    if not math.isfinite(result) or result < 0:
        raise ValueError(f"{label} must be a nonnegative finite number")
    return result


def start(consumer: str, *, layer_index_id: str = "") -> None:
    layers = list(required_layers(consumer))
    started = os.environ.get("CMUX_APP_HOST_RUNNER_STARTED_NS", "")
    started_ns = int(started) if started.isdecimal() and int(started) > 0 else time.monotonic_ns()
    value = {
        "schema": SCHEMA,
        "version": VERSION,
        "consumer": consumer,
        "layers_requested": layers,
        "layers_restored": [],
        "attempted_routes": [],
        "route": None,
        "bytes_requested": 0,
        "bytes_transferred": 0,
        "transfer_duration_seconds": 0.0,
        "assembly_duration_seconds": 0.0,
        "restore_duration_seconds": 0.0,
        "restore_outcome": None,
        "fallback_reasons": [],
        "runner_started_ns": started_ns,
    }
    if not layer_index_id:
        value["fallback_reasons"].append("layer-index-unavailable")
    _write(value)


def add_transfer(route: str, requested: int, transferred: int, seconds: float) -> None:
    value = _read()
    if value is None:
        return
    requested = _nonnegative_int(requested, "requested bytes")
    transferred = _nonnegative_int(transferred, "transferred bytes")
    seconds = _seconds(seconds, "transfer duration")
    if route not in value["attempted_routes"]:
        value["attempted_routes"].append(route)
    value["bytes_requested"] += requested
    value["bytes_transferred"] += transferred
    value["transfer_duration_seconds"] = round(value["transfer_duration_seconds"] + seconds, 3)
    _write(value)


def append_fallback(reason: str) -> None:
    value = _read()
    if value is None:
        return
    reason = " ".join(str(reason).split())
    if not reason:
        raise ValueError("fallback reason must be nonempty")
    if reason not in value["fallback_reasons"]:
        value["fallback_reasons"].append(reason[:1024])
    _write(value)


def layer_hit(layers: tuple[str, ...], seconds: float) -> None:
    value = _read()
    if value is None:
        return
    if tuple(value["layers_requested"]) != tuple(layers):
        raise ValueError("restored layers differ from authorized consumer layers")
    value["layers_restored"] = list(layers)
    value["assembly_duration_seconds"] = round(_seconds(seconds, "assembly duration"), 3)
    value["route"] = "github-layers"
    _write(value)


def aggregate_hit(route: str) -> None:
    value = _read()
    if value is None:
        return
    if route not in {"r2-aggregate", "github-aggregate"}:
        raise ValueError("unknown aggregate artifact route")
    value["layers_restored"] = list(LAYERS)
    value["route"] = route
    _write(value)


def restore_result(seconds: float, outcome: str) -> None:
    value = _read()
    if value is None:
        return
    if outcome not in {"success", "failure"}:
        raise ValueError("restore outcome must be success or failure")
    value["restore_duration_seconds"] = round(_seconds(seconds, "restore duration"), 3)
    value["restore_outcome"] = outcome
    _write(value)


def finish() -> dict | None:
    value = _read()
    if value is None:
        return None
    elapsed = max(0, time.monotonic_ns() - int(value.pop("runner_started_ns")))
    value["overall_runner_time_seconds"] = round(elapsed / 1_000_000_000, 3)
    value["restore_assembly_duration_seconds"] = round(
        value["assembly_duration_seconds"] + value["restore_duration_seconds"], 3)
    value["fallback_reason"] = "; ".join(value.pop("fallback_reasons")) or None
    _write(value)
    print("CMUX_APP_HOST_CONSUMER_RECEIPT " + json.dumps(value, sort_keys=True))
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a") as output:
            output.write("### App-host product consumer receipt\n\n```json\n")
            output.write(json.dumps(value, indent=2, sort_keys=True))
            output.write("\n```\n")
    return value


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)

    command = sub.add_parser("start")
    command.add_argument("consumer")
    command.add_argument("--layer-index-id", default="")

    command = sub.add_parser("transfer")
    command.add_argument("--route", required=True)
    command.add_argument("--requested", type=int, required=True)
    command.add_argument("--transferred", type=int, required=True)
    command.add_argument("--seconds", type=float, required=True)

    command = sub.add_parser("fallback")
    command.add_argument("reason")

    command = sub.add_parser("layer-hit")
    command.add_argument("--layers", required=True)
    command.add_argument("--seconds", type=float, required=True)

    command = sub.add_parser("aggregate-hit")
    command.add_argument("--route", required=True)

    command = sub.add_parser("restore")
    command.add_argument("--seconds", type=float, required=True)
    command.add_argument("--outcome", required=True)

    sub.add_parser("finish")
    args = parser.parse_args()

    if args.command == "start":
        start(args.consumer, layer_index_id=args.layer_index_id)
    elif args.command == "transfer":
        add_transfer(args.route, args.requested, args.transferred, args.seconds)
    elif args.command == "fallback":
        append_fallback(args.reason)
    elif args.command == "layer-hit":
        layer_hit(tuple(x for x in args.layers.split(",") if x), args.seconds)
    elif args.command == "aggregate-hit":
        aggregate_hit(args.route)
    elif args.command == "restore":
        restore_result(args.seconds, args.outcome)
    else:
        finish()


if __name__ == "__main__":
    main()
