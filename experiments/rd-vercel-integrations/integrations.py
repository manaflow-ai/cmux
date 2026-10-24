#!/usr/bin/env python3
"""Provider-neutral outbound integration events for cmux NEXT and acpmux.

The adapter turns one redacted cmux event into provider-shaped requests without
requiring a provider SDK or storing credentials.  ``DryRunTransport`` is the
safe default for local development and tests; a production transport can consume
``Request`` objects after authenticating them outside this package.
"""
from __future__ import annotations

import dataclasses
import hashlib
import json
import re
import time
from collections.abc import Iterable, Mapping
from typing import Any, Protocol

_SECRET_KEY = re.compile(r"(?:token|secret|password|authorization|api[_-]?key|private[_-]?key)", re.I)


def _redact(value: Any) -> Any:
    """Copy JSON-like data while replacing credential-shaped values."""
    if isinstance(value, Mapping):
        return {str(k): ("[redacted]" if _SECRET_KEY.search(str(k)) else _redact(v)) for k, v in value.items()}
    if isinstance(value, list):
        return [_redact(v) for v in value]
    if isinstance(value, tuple):
        return [_redact(v) for v in value]
    return value


@dataclasses.dataclass(frozen=True)
class IntegrationEvent:
    """A stable event shared by cmux NEXT, acpmux, and external adapters."""

    kind: str
    source: str
    subject: str
    payload: Mapping[str, Any]
    event_id: str = ""
    occurred_at: int = 0

    def __post_init__(self) -> None:
        if not self.kind or not self.source or not self.subject:
            raise ValueError("kind, source, and subject are required")
        safe_payload = _redact(self.payload)
        object.__setattr__(self, "payload", safe_payload)
        when = self.occurred_at or int(time.time())
        object.__setattr__(self, "occurred_at", when)
        if not self.event_id:
            material = json.dumps({"kind": self.kind, "source": self.source, "subject": self.subject, "payload": safe_payload, "occurred_at": when}, sort_keys=True, separators=(",", ":"))
            object.__setattr__(self, "event_id", "evt_" + hashlib.sha256(material.encode()).hexdigest()[:20])

    @classmethod
    def from_json(cls, value: Mapping[str, Any]) -> "IntegrationEvent":
        return cls(kind=str(value["kind"]), source=str(value["source"]), subject=str(value["subject"]), payload=value.get("payload", {}), event_id=str(value.get("event_id", "")), occurred_at=int(value.get("occurred_at", 0)))

    def as_json(self) -> dict[str, Any]:
        return dataclasses.asdict(self)


@dataclasses.dataclass(frozen=True)
class Request:
    target: str
    method: str
    path: str
    body: Mapping[str, Any]
    headers: Mapping[str, str] = dataclasses.field(default_factory=dict)


class Transport(Protocol):
    def send(self, request: Request) -> None: ...


class DryRunTransport:
    """Capture requests for review; never performs network I/O."""

    def __init__(self) -> None:
        self.requests: list[Request] = []

    def send(self, request: Request) -> None:
        self.requests.append(request)


class Adapter(Protocol):
    name: str

    def request(self, event: IntegrationEvent) -> Request | None: ...


class GitHubAdapter:
    name = "github"

    def request(self, event: IntegrationEvent) -> Request | None:
        if event.kind == "preview.ready":
            body = {
                "event_type": "deployment_status",
                "state": "success",
                "environment": "preview",
                "target_url": event.payload.get("url"),
                "deployment_id": event.payload.get("preview_id", event.subject),
                "sha": event.payload.get("commit"),
                "description": f"cmux preview ready for {event.subject}",
            }
            return Request(self.name, "POST", "/repos/{owner}/{repo}/deployments/statuses", body)
        if event.kind == "agent.completed":
            return Request(self.name, "POST", "/repos/{owner}/{repo}/issues/comments", {"body": f"cmux agent `{event.subject}` completed; preview: {event.payload.get('url', 'none')}", "event_id": event.event_id})
        return None


class LinearAdapter:
    name = "linear"

    def request(self, event: IntegrationEvent) -> Request | None:
        if event.kind not in {"preview.ready", "agent.completed", "preview.failed"}:
            return None
        body = {"event_id": event.event_id, "subject": event.subject, "state": event.kind.rsplit(".", 1)[-1], "url": event.payload.get("url"), "commit": event.payload.get("commit"), "workspace_id": event.payload.get("workspace_id")}
        return Request(self.name, "POST", "/graphql", {"operation": "cmuxIntegrationEvent", "input": body})


class SlackAdapter:
    name = "slack"

    def request(self, event: IntegrationEvent) -> Request | None:
        if event.kind not in {"preview.ready", "preview.failed", "agent.completed", "machine.suspended"}:
            return None
        status = event.kind.rsplit(".", 1)[-1].replace("_", " ")
        text = f"cmux {status}: {event.subject}"
        if event.payload.get("url"):
            text += f" — {event.payload['url']}"
        return Request(self.name, "POST", "/api/chat.postMessage", {"text": text, "event_id": event.event_id, "source": event.source})


class PreviewAdapter:
    """Vercel-style immutable deployment plus moving aliases."""

    name = "preview"

    def request(self, event: IntegrationEvent) -> Request | None:
        if not event.kind.startswith("preview."):
            return None
        body = {"event_id": event.event_id, "deployment_id": event.payload.get("preview_id", event.subject), "state": event.kind.split(".", 1)[1], "url": event.payload.get("url"), "branch_alias": event.payload.get("branch_alias"), "agent_alias": event.payload.get("agent_alias"), "commit": event.payload.get("commit"), "source": event.source}
        return Request(self.name, "POST", "/v1/deployments/events", body)


class CloudAdapter:
    """Provider-neutral cloud receipt adapter (GCP/Freestyle/etc.)."""

    name = "cloud"

    def request(self, event: IntegrationEvent) -> Request | None:
        if not event.kind.startswith("machine."):
            return None
        body = {"event_id": event.event_id, "operation": event.kind.split(".", 1)[1], "machine_id": event.payload.get("machine_id", event.subject), "provider": event.payload.get("provider", "unknown"), "generation": event.payload.get("generation"), "receipt": event.payload.get("receipt"), "ttl": event.payload.get("expires_at")}
        return Request(self.name, "POST", "/v1/machine-events", body)


DEFAULT_ADAPTERS: tuple[Adapter, ...] = (GitHubAdapter(), LinearAdapter(), SlackAdapter(), PreviewAdapter(), CloudAdapter())


class IntegrationRouter:
    def __init__(self, transport: Transport, adapters: Iterable[Adapter] = DEFAULT_ADAPTERS) -> None:
        self.transport = transport
        self.adapters = tuple(adapters)

    def dispatch(self, event: IntegrationEvent) -> list[Request]:
        requests: list[Request] = []
        for adapter in self.adapters:
            request = adapter.request(event)
            if request is not None:
                self.transport.send(request)
                requests.append(request)
        return requests
