#!/usr/bin/env python3
"""Small CLI for the persistent-machine prototype.

``allocate --dry-run`` emits a GCP command and receipt without making a provider
call. ``demo`` exercises allocate, acpmux attach, detach, idle-stop and metering.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from decimal import Decimal

from machine_runtime import MachineManager, MachineSpec, gcloud_command


def parse_time(value: str | None) -> datetime | None:
    if not value:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00")).astimezone(timezone.utc)


def spec_from(args: argparse.Namespace) -> MachineSpec:
    return MachineSpec(
        project=args.project,
        region=args.region,
        zone=args.zone,
        shape=args.shape,
        vcpu=args.vcpu,
        memory_gib=args.memory_gib,
        disk_gib=args.disk_gib,
        owner=args.owner,
        purpose=args.purpose,
        ttl_hours=args.ttl_hours,
        idle_minutes=args.idle_minutes,
        hourly_vcpu_rate=Decimal(args.vcpu_rate),
        hourly_memory_rate=Decimal(args.memory_rate),
        hourly_disk_rate=Decimal(args.disk_rate),
    )


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="machinectl")
    sub = p.add_subparsers(dest="command", required=True)
    a = sub.add_parser("allocate", help="emit a machine receipt and optional GCP command")
    a.add_argument("--project", default=os.environ.get("GOOGLE_CLOUD_PROJECT", "example-project"))
    a.add_argument("--region", default=os.environ.get("CMUX_MACHINE_REGION", "us-central1"))
    a.add_argument("--zone", default=os.environ.get("CMUX_MACHINE_ZONE", "us-central1-a"))
    a.add_argument("--shape", default="e2-standard-2")
    a.add_argument("--vcpu", type=int, default=2)
    a.add_argument("--memory-gib", type=int, default=8)
    a.add_argument("--disk-gib", type=int, default=40)
    a.add_argument("--owner", default=os.environ.get("CMUX_MACHINE_OWNER", "machine-owner"))
    a.add_argument("--purpose", default=os.environ.get("CMUX_MACHINE_PURPOSE", "persistent-machine"))
    a.add_argument("--ttl-hours", type=int, default=24)
    a.add_argument("--idle-minutes", type=int, default=30)
    a.add_argument("--vcpu-rate", default="0.05")
    a.add_argument("--memory-rate", default="0.01")
    a.add_argument("--disk-rate", default="0.0001")
    a.add_argument("--machine-id", default="cmux-machine-demo")
    a.add_argument("--at", help="UTC ISO timestamp for deterministic receipts")
    a.add_argument("--dry-run", action="store_true", help="emit command only; never calls GCP")

    d = sub.add_parser("demo", help="run a deterministic local lifecycle demo")
    d.add_argument("--at", default="2026-10-24T00:00:00Z")

    args = p.parse_args(argv)
    if args.command == "demo":
        manager = MachineManager()
        start = parse_time(args.at)
        spec = MachineSpec(ttl_hours=4, idle_minutes=15)
        machine = manager.allocate(spec, start, "cmux-machine-demo")
        allocated = machine.receipt()
        attached = manager.attach(machine.machine_id, "acpmux-session-1", start)
        manager.detach(machine.machine_id, "acpmux-session-1", start.replace(minute=10))
        stopped = manager.stop_idle(start.replace(minute=30))
        print(json.dumps({"allocated": allocated, "attached": attached, "stopped": stopped}, indent=2, sort_keys=True))
        return 0

    spec = spec_from(args)
    manager = MachineManager()
    machine = manager.allocate(spec, parse_time(args.at), args.machine_id)
    output = {"receipt": machine.receipt(), "gcloud_command": gcloud_command(machine)}
    if not args.dry_run:
        output["warning"] = "This prototype does not execute provider commands; review and run the emitted command explicitly."
    print(json.dumps(output, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
