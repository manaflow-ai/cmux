#!/usr/bin/env python3
"""Provider-neutral persistent machine lifecycle for cmux R&D.

The in-memory provider is intentionally deterministic so lifecycle and billing can
be tested without a cloud account.  ``gcloud_command`` emits an inspectable GCP
create command; callers must run it explicitly after reviewing labels and TTL.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from decimal import Decimal
import re
import secrets
from typing import Any, Protocol


STATES = {"allocating", "running", "attached", "stopped", "deleted"}
LABEL = re.compile(r"[^a-z0-9_-]+")


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def iso(value: datetime) -> str:
    return value.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def safe_label(value: str, fallback: str) -> str:
    result = LABEL.sub("-", value.strip().lower()).strip("-")[:63]
    return result or fallback


@dataclass(frozen=True)
class MachineSpec:
    project: str = "example-project"
    region: str = "us-central1"
    zone: str = "us-central1-a"
    shape: str = "e2-standard-2"
    vcpu: int = 2
    memory_gib: int = 8
    disk_gib: int = 40
    owner: str = "machine-owner"
    purpose: str = "persistent-machine"
    ttl_hours: int = 24
    idle_minutes: int = 30
    hourly_vcpu_rate: Decimal = Decimal("0.05")
    hourly_memory_rate: Decimal = Decimal("0.01")
    hourly_disk_rate: Decimal = Decimal("0.0001")

    def labels(self, expires_at: datetime) -> dict[str, str]:
        return {
            "owner": safe_label(self.owner, "machine-owner"),
            "purpose": safe_label(self.purpose, "persistent-machine"),
            "ttl": safe_label(iso(expires_at), "ttl-unknown"),
            "idle-autostop": "true",
        }

    def hourly_rate(self) -> Decimal:
        return self.hourly_vcpu_rate * self.vcpu + self.hourly_memory_rate * self.memory_gib


@dataclass
class Attachment:
    session_id: str
    attached_at: datetime
    last_seen: datetime


@dataclass
class Machine:
    machine_id: str
    spec: MachineSpec
    created_at: datetime
    expires_at: datetime
    state: str = "allocating"
    provider_id: str | None = None
    last_activity: datetime | None = None
    running_since: datetime | None = None
    running_seconds: int = 0
    attachments: dict[str, Attachment] = field(default_factory=dict)
    billed_compute: Decimal = Decimal("0")
    billed_disk: Decimal = Decimal("0")

    def receipt(self) -> dict[str, Any]:
        return {
            "schema": "cmux.machine/0",
            "machine_id": self.machine_id,
            "provider_id": self.provider_id,
            "project": self.spec.project,
            "region": self.spec.region,
            "shape": self.spec.shape,
            "state": self.state,
            "expires_at": iso(self.expires_at),
            "labels": self.spec.labels(self.expires_at),
            "attach": {
                "cmux": f"cmux://machine/{self.machine_id}",
                "acpmux": f"acpmux://machine/{self.machine_id}",
            },
            "attachments": sorted(self.attachments),
            "billing": {
                "compute": str(self.billed_compute.quantize(Decimal("0.000001"))),
                "disk": str(self.billed_disk.quantize(Decimal("0.000001"))),
                "total": str((self.billed_compute + self.billed_disk).quantize(Decimal("0.000001"))),
                "running_seconds": self.running_seconds,
            },
        }


class Provider(Protocol):
    def allocate(self, machine: Machine) -> str: ...
    def attach(self, machine: Machine, session_id: str) -> None: ...
    def stop(self, machine: Machine) -> None: ...


class FakeProvider:
    """Deterministic provider used by tests and local demos."""

    def __init__(self) -> None:
        self.calls: list[tuple[str, str, str | None]] = []

    def allocate(self, machine: Machine) -> str:
        provider_id = "fake-" + secrets.token_hex(6)
        self.calls.append(("allocate", provider_id, None))
        return provider_id

    def attach(self, machine: Machine, session_id: str) -> None:
        self.calls.append(("attach", machine.provider_id or "", session_id))

    def stop(self, machine: Machine) -> None:
        self.calls.append(("stop", machine.provider_id or "", None))


def gcloud_command(machine: Machine) -> list[str]:
    """Return a GCP create command; this function never executes it."""
    labels = ",".join(f"{k}={v}" for k, v in machine.spec.labels(machine.expires_at).items())
    return [
        "gcloud", "compute", "instances", "create", machine.machine_id,
        f"--project={machine.spec.project}", f"--zone={machine.spec.zone}",
        f"--machine-type={machine.spec.shape}", f"--boot-disk-size={machine.spec.disk_gib}GB",
        f"--labels={labels}", "--quiet",
    ]


class MachineManager:
    """Lifecycle controller with one idempotent record per machine."""

    def __init__(self, provider: Provider | None = None) -> None:
        self.provider = provider or FakeProvider()
        self.machines: dict[str, Machine] = {}

    def allocate(self, spec: MachineSpec, at: datetime | None = None, machine_id: str | None = None) -> Machine:
        created = at or now_utc()
        if spec.ttl_hours < 1 or spec.idle_minutes < 1:
            raise ValueError("ttl_hours and idle_minutes must be positive")
        ident = machine_id or "cmux-machine-" + secrets.token_hex(6)
        if ident in self.machines:
            return self.machines[ident]
        machine = Machine(ident, spec, created, created.replace(microsecond=0) + timedelta(hours=spec.ttl_hours))
        machine.state = "allocating"
        machine.provider_id = self.provider.allocate(machine)
        machine.state = "running"
        machine.running_since = created
        machine.last_activity = created
        self.machines[ident] = machine
        return machine

    def _get(self, machine_id: str) -> Machine:
        try:
            machine = self.machines[machine_id]
        except KeyError as exc:
            raise KeyError(f"unknown machine: {machine_id}") from exc
        if machine.state == "deleted":
            raise ValueError(f"machine is deleted: {machine_id}")
        return machine

    def attach(self, machine_id: str, session_id: str, at: datetime | None = None) -> dict[str, Any]:
        machine = self._get(machine_id)
        when = at or now_utc()
        if machine.state == "stopped":
            machine.state = "running"
            machine.running_since = when
        if not session_id.strip():
            raise ValueError("session_id is required")
        self.provider.attach(machine, session_id)
        machine.attachments[session_id] = Attachment(session_id, when, when)
        machine.state = "attached"
        machine.last_activity = when
        return machine.receipt()

    def heartbeat(self, machine_id: str, session_id: str, at: datetime | None = None) -> dict[str, Any]:
        machine = self._get(machine_id)
        attachment = machine.attachments.get(session_id)
        if not attachment:
            raise KeyError(f"session is not attached: {session_id}")
        when = at or now_utc()
        attachment.last_seen = when
        machine.last_activity = when
        return machine.receipt()

    def detach(self, machine_id: str, session_id: str, at: datetime | None = None) -> dict[str, Any]:
        machine = self._get(machine_id)
        machine.attachments.pop(session_id, None)
        when = at or now_utc()
        machine.last_activity = when
        if not machine.attachments and machine.state == "attached":
            machine.state = "running"
        return machine.receipt()

    def meter(self, machine_id: str, at: datetime | None = None) -> dict[str, Any]:
        machine = self._get(machine_id)
        when = at or now_utc()
        if machine.state in {"running", "attached"} and machine.running_since:
            elapsed = max(0, int((when - machine.running_since).total_seconds()))
            machine.running_seconds += elapsed
            machine.billed_compute += machine.spec.hourly_rate() * Decimal(elapsed) / Decimal(3600)
            machine.billed_disk += machine.spec.hourly_disk_rate * machine.spec.disk_gib * Decimal(elapsed) / Decimal(3600)
            machine.running_since = when
        return machine.receipt()

    def stop_idle(self, at: datetime | None = None) -> list[dict[str, Any]]:
        when = at or now_utc()
        stopped: list[dict[str, Any]] = []
        for machine in self.machines.values():
            if machine.state not in {"running", "attached"} or machine.attachments or not machine.last_activity:
                continue
            idle = (when - machine.last_activity).total_seconds() / 60
            expired = when >= machine.expires_at
            if idle >= machine.spec.idle_minutes or expired:
                self.meter(machine.machine_id, when)
                self.provider.stop(machine)
                machine.state = "stopped"
                machine.running_since = None
                stopped.append(machine.receipt())
        return stopped

    def delete(self, machine_id: str, at: datetime | None = None) -> dict[str, Any]:
        machine = self._get(machine_id)
        self.meter(machine_id, at)
        machine.state = "deleted"
        machine.attachments.clear()
        return machine.receipt()
