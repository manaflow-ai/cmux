#!/usr/bin/env python3
"""Deterministic fan-out scheduler simulation.

This is a provider-free prototype for reasoning about warm pools, leases,
quotas, spot interruption and per-agent cost. It makes no cloud API calls.
Run ``python3 scripts/agent_scale_sim.py --demo`` for a small JSON report.
"""
from __future__ import annotations

import argparse
import json
import math
from collections import Counter, defaultdict
from dataclasses import asdict, dataclass, field
from typing import Iterable


RUN_STATES = {"queued", "provisioning", "running", "succeeded", "failed", "interrupted"}
TERMINAL_STATES = {"succeeded", "failed"}


@dataclass(frozen=True)
class Shape:
    cpu: int
    memory_gb: int


@dataclass(frozen=True)
class RunRequest:
    run_id: str
    tenant: str
    image_digest: str
    shape: Shape
    regions: tuple[str, ...] = ()
    budget_usd: float = 1.0
    max_lifetime_s: int = 3600
    allow_preemptible: bool = True
    checkpointable: bool = True
    max_retries: int = 1
    idempotency_key: str | None = None


@dataclass(frozen=True)
class Offer:
    """Normalized capacity from a provider adapter."""

    provider: str
    region: str
    host: str
    shape: Shape
    image_digest: str
    price_per_hour: float
    startup_s: int
    preemptible: bool = False
    interruption_risk: float = 0.0
    capacity: int = 1

    @property
    def pool_key(self) -> tuple[str, str, str, Shape]:
        return (self.provider, self.region, self.image_digest, self.shape)


@dataclass
class WarmSlot:
    slot_id: str
    offer: Offer
    generation: int = 0
    run_id: str | None = None
    token: int = 0


@dataclass
class Lease:
    run_id: str
    token: int
    provider: str
    region: str
    host: str
    price_per_hour: float
    preemptible: bool
    issued_at: int
    expires_at: int
    started_at: int | None = None
    ended_at: int | None = None
    offer_key: tuple[object, ...] | None = None


@dataclass
class Run:
    request: RunRequest
    state: str = "queued"
    created_at: int = 0
    ready_at: int | None = None
    finished_at: int | None = None
    retry_count: int = 0
    lease: Lease | None = None
    stale_lease_tokens: set[int] = field(default_factory=set)


@dataclass(frozen=True)
class Event:
    at: int
    kind: str
    run_id: str | None = None
    details: dict[str, object] = field(default_factory=dict)


@dataclass(frozen=True)
class Quota:
    max_active: int = 100
    max_cpu: int = 1000
    max_memory_gb: int = 4000
    spend_usd: float = 100.0


class Scheduler:
    """A small event-driven model of the control-plane contract.

    Provider adapters only contribute normalized offers. The scheduler owns
    intent, leases, fencing tokens, quota checks, and the accounting event
    stream. A real adapter would replace ``offers`` and capacity callbacks.
    """

    def __init__(
        self,
        offers: Iterable[Offer],
        quotas: dict[str, Quota] | None = None,
        global_quota: Quota | None = None,
        lease_ttl_s: int = 30,
    ) -> None:
        self.offers = list(offers)
        self.quotas = defaultdict(Quota, quotas or {})
        self.global_quota = global_quota or Quota()
        self.lease_ttl_s = lease_ttl_s
        self.runs: dict[str, Run] = {}
        self.idempotency: dict[tuple[str, str], str] = {}
        self.warm: list[WarmSlot] = []
        self.events: list[Event] = []
        self._segments: list[tuple[int, int, float, str]] = []
        self._next_slot = 1
        self._now = 0
        self._offer_usage: defaultdict[tuple[object, ...], int] = defaultdict(int)

    def add_warm_slot(self, offer: Offer, count: int = 1) -> None:
        """Register already-booted slots keyed by immutable image and shape."""
        for _ in range(count):
            slot = WarmSlot(f"warm-{self._next_slot}", offer)
            self._next_slot += 1
            self.warm.append(slot)
            self.events.append(Event(self._now, "warm_slot.ready", details={"slot": slot.slot_id, "pool": offer.pool_key}))

    def submit(self, request: RunRequest, now: int = 0) -> Run:
        self._now = now
        if request.run_id in self.runs:
            return self.runs[request.run_id]
        if request.idempotency_key:
            key = (request.tenant, request.idempotency_key)
            existing = self.idempotency.get(key)
            if existing:
                return self.runs[existing]
            self.idempotency[key] = request.run_id
        if request.shape.cpu <= 0 or request.shape.memory_gb <= 0:
            raise ValueError("shape must have positive CPU and memory")
        run = Run(request=request, created_at=now)
        self.runs[request.run_id] = run
        self.events.append(Event(now, "run.queued", request.run_id, {"tenant": request.tenant}))
        return run

    def reconcile(self, now: int) -> None:
        """Advance provisioning, expire leases, and place queued work."""
        if now < self._now:
            raise ValueError("time must be monotonic")
        self._now = now
        for run in self.runs.values():
            if run.state == "provisioning" and run.lease and run.ready_at is not None and run.ready_at <= now:
                run.state = "running"
                run.lease.started_at = run.ready_at
                self.events.append(Event(now, "run.ready", run.request.run_id, {**self._lease_details(run.lease), "ready_at": run.ready_at}))
            if run.state in {"provisioning", "running"} and run.lease:
                if now >= run.lease.expires_at:
                    self._expire_lease(run, now)
                elif self._run_cost(run, now) > run.request.budget_usd:
                    self.finish(run.request.run_id, now, "failed", "budget_exhausted")
                elif now - run.created_at >= run.request.max_lifetime_s:
                    self.finish(run.request.run_id, now, "failed", "lifetime_exceeded")
        for run in sorted(self.runs.values(), key=lambda item: (item.created_at, item.request.run_id)):
            if run.state != "queued":
                continue
            if not self._within_quota(run, now):
                self.events.append(Event(now, "run.held.quota", run.request.run_id))
                continue
            self._place(run, now)

    def heartbeat(self, run_id: str, token: int, now: int) -> bool:
        run = self.runs[run_id]
        lease = run.lease
        if run.state not in {"provisioning", "running"} or lease is None or lease.token != token or now >= lease.expires_at:
            self.events.append(Event(now, "lease.rejected", run_id, {"token": token}))
            return False
        lease.expires_at = max(lease.expires_at, now + self.lease_ttl_s)
        self.events.append(Event(now, "lease.renewed", run_id, {"token": token, "expires_at": lease.expires_at}))
        return True

    def finish(self, run_id: str, now: int, state: str = "succeeded", reason: str | None = None) -> None:
        if state not in TERMINAL_STATES:
            raise ValueError(f"finish state must be terminal, got {state}")
        run = self.runs[run_id]
        if run.state in TERMINAL_STATES:
            return
        self._release(run, now)
        run.state = state
        run.finished_at = now
        details = {"reason": reason} if reason else {}
        self.events.append(Event(now, f"run.{state}", run_id, details))

    def interrupt(self, run_id: str, now: int, reason: str = "provider_preemption") -> None:
        run = self.runs[run_id]
        if run.state not in {"provisioning", "running"} or run.lease is None:
            return
        lease = run.lease
        self._release(run, now)
        run.stale_lease_tokens.add(lease.token)
        run.lease = None
        run.state = "interrupted"
        self.events.append(Event(now, "run.interrupted", run_id, {"reason": reason, "token": lease.token}))
        if run.request.checkpointable and run.retry_count < run.request.max_retries:
            run.retry_count += 1
            run.state = "queued"
            self.events.append(Event(now, "run.requeued", run_id, {"retry": run.retry_count}))
        else:
            run.state = "failed"
            run.finished_at = now
            self.events.append(Event(now, "run.failed", run_id, {"reason": reason}))

    def snapshot(self, run_id: str, now: int, digest: str) -> str:
        run = self.runs[run_id]
        if run.state != "running":
            raise ValueError("only a running run can be snapshotted")
        snapshot_id = f"snap-{run_id}-{digest[:12]}"
        self.events.append(Event(now, "snapshot.ready", run_id, {"snapshot": snapshot_id, "digest": digest}))
        return snapshot_id

    def fork(self, parent_run_id: str, child_id: str, snapshot_id: str, now: int, **overrides: object) -> Run:
        parent = self.runs[parent_run_id]
        request = parent.request
        child = RunRequest(
            run_id=child_id,
            tenant=str(overrides.get("tenant", request.tenant)),
            image_digest=snapshot_id,
            shape=overrides.get("shape", request.shape),
            regions=tuple(overrides.get("regions", request.regions)),
            budget_usd=float(overrides.get("budget_usd", request.budget_usd)),
            max_lifetime_s=int(overrides.get("max_lifetime_s", request.max_lifetime_s)),
            allow_preemptible=bool(overrides.get("allow_preemptible", request.allow_preemptible)),
            checkpointable=bool(overrides.get("checkpointable", request.checkpointable)),
            max_retries=int(overrides.get("max_retries", request.max_retries)),
        )
        self.events.append(Event(now, "run.forked", child_id, {"parent": parent_run_id, "snapshot": snapshot_id}))
        return self.submit(child, now)

    def cost_usd(self, now: int | None = None) -> float:
        at = self._now if now is None else now
        closed = sum((end - start) * rate / 3600 for start, end, rate, _ in self._segments)
        active = sum((at - run.lease.started_at) * run.lease.price_per_hour / 3600 for run in self.runs.values() if run.lease and run.lease.started_at is not None)
        return closed + active

    def metrics(self, now: int | None = None) -> dict[str, object]:
        at = self._now if now is None else now
        starts = [run.ready_at - run.created_at for run in self.runs.values() if run.ready_at is not None]
        active = sum(run.state in {"provisioning", "running"} for run in self.runs.values())
        peak = 0
        historical_active = 0
        for event in self.events:
            if event.kind in {"run.provisioning", "run.claimed.warm"}:
                historical_active += 1
                peak = max(peak, historical_active)
            elif event.kind == "lease.released":
                historical_active = max(0, historical_active - 1)
        return {
            "runs": len(self.runs),
            "states": dict(Counter(run.state for run in self.runs.values())),
            "active": active,
            "active_peak_approx": peak,
            "startup_seconds": _percentiles(starts),
            "interruptions": sum(event.kind == "run.interrupted" for event in self.events),
            "cost_usd": round(self.cost_usd(at), 6),
        }

    def _place(self, run: Run, now: int) -> None:
        slot = next((slot for slot in self.warm if slot.run_id is None and self._matches(run.request, slot.offer)), None)
        if slot:
            slot.run_id = run.request.run_id
            slot.token += 1
            run.lease = self._lease(run, slot.offer, slot.token, now)
            run.ready_at = now
            run.state = "running"
            run.lease.started_at = now
            self.events.append(Event(now, "run.claimed.warm", run.request.run_id, {"slot": slot.slot_id, **self._lease_details(run.lease)}))
            self.events.append(Event(now, "run.ready", run.request.run_id, self._lease_details(run.lease)))
            return
        offer = self._choose_offer(run.request, run.retry_count)
        if offer is None:
            self.events.append(Event(now, "run.held.capacity", run.request.run_id))
            return
        token = run.retry_count + 1
        run.lease = self._lease(run, offer, token, now)
        self._offer_usage[self._offer_key(offer)] += 1
        run.ready_at = now + offer.startup_s
        run.state = "provisioning"
        self.events.append(Event(now, "run.provisioning", run.request.run_id, {"startup_s": offer.startup_s, **self._lease_details(run.lease)}))

    def _choose_offer(self, request: RunRequest, retry_count: int = 0) -> Offer | None:
        candidates = [offer for offer in self.offers if self._matches(request, offer) and (not offer.preemptible or request.allow_preemptible)]
        # A checkpointable retry prefers on-demand capacity after an interruption.
        # It still falls back to spot if no on-demand offer is available.
        if retry_count and any(not offer.preemptible for offer in candidates):
            candidates = [offer for offer in candidates if not offer.preemptible]
        candidates = [offer for offer in candidates if self._offer_usage[self._offer_key(offer)] < offer.capacity]
        if not candidates:
            return None
        # Warm slots win above. Cold placement favors cost, then interruption risk,
        # startup, and stable provider/host ordering for deterministic replays.
        return min(candidates, key=lambda offer: (offer.price_per_hour, offer.interruption_risk, offer.startup_s, offer.provider, offer.region, offer.host))

    def _matches(self, request: RunRequest, offer: Offer) -> bool:
        return offer.image_digest == request.image_digest and offer.shape == request.shape and (not request.regions or offer.region in request.regions)

    def _within_quota(self, run: Run, now: int) -> bool:
        tenant_runs = [item for item in self.runs.values() if item.request.tenant == run.request.tenant and item.state in {"provisioning", "running"}]
        all_runs = [item for item in self.runs.values() if item.state in {"provisioning", "running"}]
        q = self.quotas[run.request.tenant]
        tenant_cpu = sum(item.request.shape.cpu for item in tenant_runs)
        tenant_memory = sum(item.request.shape.memory_gb for item in tenant_runs)
        global_cpu = sum(item.request.shape.cpu for item in all_runs)
        global_memory = sum(item.request.shape.memory_gb for item in all_runs)
        minimum = self._minimum_cost(run)
        if len(tenant_runs) >= q.max_active or tenant_cpu + run.request.shape.cpu > q.max_cpu or tenant_memory + run.request.shape.memory_gb > q.max_memory_gb:
            return False
        if len(all_runs) >= self.global_quota.max_active or global_cpu + run.request.shape.cpu > self.global_quota.max_cpu or global_memory + run.request.shape.memory_gb > self.global_quota.max_memory_gb:
            return False
        if minimum > run.request.budget_usd or self.cost_usd(now) + minimum > min(q.spend_usd, self.global_quota.spend_usd):
            return False
        return True

    def _run_cost(self, run: Run, now: int) -> float:
        lease = run.lease
        if lease is None:
            return 0.0
        start = lease.started_at if lease.started_at is not None else lease.issued_at
        return max(0, now - start) * lease.price_per_hour / 3600

    def _minimum_cost(self, run: Run) -> float:
        offer = self._choose_offer(run.request, run.retry_count)
        rate = offer.price_per_hour if offer else 0.0
        startup = max(1, offer.startup_s) if offer else 1
        return rate * min(run.request.max_lifetime_s, startup) / 3600

    def _offer_key(self, offer: Offer) -> tuple[object, ...]:
        return (offer.provider, offer.region, offer.host, offer.shape, offer.image_digest, offer.price_per_hour, offer.preemptible)

    def _lease(self, run: Run, offer: Offer, token: int, now: int) -> Lease:
        return Lease(run.request.run_id, token, offer.provider, offer.region, offer.host, offer.price_per_hour, offer.preemptible, now, now + max(self.lease_ttl_s, offer.startup_s + self.lease_ttl_s), offer_key=self._offer_key(offer))

    def _lease_details(self, lease: Lease) -> dict[str, object]:
        return {"provider": lease.provider, "region": lease.region, "host": lease.host, "token": lease.token, "preemptible": lease.preemptible}

    def _release(self, run: Run, now: int) -> None:
        lease = run.lease
        if lease is None:
            return
        end = max(now, lease.started_at or lease.issued_at)
        self._segments.append((lease.started_at or lease.issued_at, end, lease.price_per_hour, run.request.run_id))
        if lease.offer_key is not None:
            self._offer_usage[lease.offer_key] = max(0, self._offer_usage[lease.offer_key] - 1)
        self.events.append(Event(now, "lease.released", run.request.run_id, self._lease_details(lease)))
        for slot in self.warm:
            if slot.run_id == run.request.run_id:
                slot.run_id = None
                slot.generation += 1
                slot.token += 1
        run.lease = None

    def _expire_lease(self, run: Run, now: int) -> None:
        token = run.lease.token if run.lease else None
        if token is not None:
            run.stale_lease_tokens.add(token)
        self._release(run, now)
        run.state = "queued"
        self.events.append(Event(now, "lease.expired", run.request.run_id, {"token": token}))


def _percentiles(values: list[int]) -> dict[str, float | None]:
    if not values:
        return {"p50": None, "p95": None, "max": None}
    values = sorted(values)
    def pick(percent: float) -> float:
        return float(values[min(len(values) - 1, math.ceil(percent * len(values)) - 1)])
    return {"p50": pick(0.50), "p95": pick(0.95), "max": float(values[-1])}


def demo() -> dict[str, object]:
    shape = Shape(cpu=2, memory_gb=4)
    image = "sha256:cmux-agent-v1"
    offers = [
        Offer("gcp", "us-central1", "gcp-a", shape, image, 0.20, 45, False, 0.01),
        Offer("gcp", "us-central1", "gcp-spot-a", shape, image, 0.06, 70, True, 0.20),
        Offer("aws", "us-east-1", "aws-spot-a", shape, image, 0.05, 80, True, 0.25),
    ]
    scheduler = Scheduler(offers, {"demo": Quota(max_active=3, max_cpu=6, max_memory_gb=12, spend_usd=5)}, global_quota=Quota(max_active=4, spend_usd=5))
    scheduler.add_warm_slot(offers[0], 1)
    for n in range(4):
        scheduler.submit(RunRequest(f"agent-{n}", "demo", image, shape, budget_usd=1, max_lifetime_s=600, max_retries=1), 0)
    scheduler.reconcile(0)
    for run_id in ("agent-0", "agent-1", "agent-2"):
        run = scheduler.runs[run_id]
        if run.lease:
            scheduler.heartbeat(run_id, run.lease.token, 40)
    scheduler.interrupt("agent-1", 50)
    for run_id in ("agent-0", "agent-2"):
        run = scheduler.runs[run_id]
        if run.lease:
            scheduler.heartbeat(run_id, run.lease.token, 70)
    scheduler.reconcile(80)
    for run_id in ("agent-0", "agent-1", "agent-2"):
        run = scheduler.runs[run_id]
        if run.lease:
            scheduler.heartbeat(run_id, run.lease.token, 90)
    scheduler.finish("agent-0", 100)
    run = scheduler.runs["agent-2"]
    if run.lease:
        scheduler.heartbeat("agent-2", run.lease.token, 111)
    scheduler.reconcile(100)
    scheduler.reconcile(140)
    scheduler.finish("agent-1", 150)
    scheduler.finish("agent-2", 160)
    scheduler.reconcile(160)
    scheduler.finish("agent-3", 200)
    return {"metrics": scheduler.metrics(200), "events": [asdict(event) for event in scheduler.events]}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--demo", action="store_true", help="print a deterministic fan-out simulation")
    args = parser.parse_args()
    if args.demo:
        print(json.dumps(demo(), indent=2, sort_keys=True))
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
