#!/usr/bin/env python3
"""Dry-run CLI for provider-neutral cmux integration events."""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from integrations import DryRunTransport, IntegrationEvent, IntegrationRouter


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="fan out a cmux event to integration adapters")
    parser.add_argument("event", type=Path, help="JSON event file")
    args = parser.parse_args(argv)
    event = IntegrationEvent.from_json(json.loads(args.event.read_text()))
    transport = DryRunTransport()
    requests = IntegrationRouter(transport).dispatch(event)
    print(json.dumps({"event": event.as_json(), "requests": [r.__dict__ for r in requests]}, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
