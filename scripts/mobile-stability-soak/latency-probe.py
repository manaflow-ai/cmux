#!/usr/bin/env python3
"""
Latency probe for the mobile attach wire that iOS uses.

For each iteration: pick a fresh nonce, send it as terminal input via the
same JSON-RPC the iOS app uses (mobile.terminal.input), then tight-poll
mobile.terminal.snapshot until the nonce appears in the visible terminal
text. Records the wall-clock elapsed time per nonce and prints
min/p50/p95/p99/max/mean.

This measures Python -> Mac host -> PTY echo -> Python wire RTT. iOS on
the same Mac (simulator) goes over the same loopback socket, so this is
representative. A physical iPhone adds local Wi-Fi/Tailscale RTT
(typically a few ms) plus iOS render latency on top.

Usage:
  CMUX_TAG=swmob ./scripts/mobile-stability-soak/latency-probe.py \
      [--iterations N] [--workspace-id <uuid>] [--route debug_loopback] \
      [--poll-interval-ms 2] [--warmup 3] [--json /tmp/latency.json]
"""

from __future__ import annotations

import argparse
import json
import os
import socket
import statistics
import struct
import subprocess
import sys
import time
import uuid
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]


def cmux_debug_rpc(tag: str, method: str, params: dict) -> dict:
    env = {**os.environ, "CMUX_TAG": tag}
    out = subprocess.check_output(
        [str(REPO / "scripts/cmux-debug-cli.sh"), "rpc", method, json.dumps(params)],
        env=env,
        text=True,
    )
    return json.loads(out)


def select_route(routes: list, prefer: str | None) -> dict:
    if prefer:
        for r in routes:
            if r.get("id") == prefer or r.get("kind") == prefer:
                return r
    if routes:
        return routes[0]
    raise RuntimeError("attach ticket has no routes")


def create_attach_ticket(tag: str, prefer_route: str, workspace_id: str | None) -> dict:
    params = {"ttl_seconds": 600}
    if workspace_id:
        params["workspace_id"] = workspace_id
    payload = cmux_debug_rpc(tag, "mobile.attach_ticket.create", params)
    ticket = payload["ticket"]
    route = select_route(ticket["routes"], prefer_route)
    return {
        "token": ticket["auth_token"],
        "workspace_id": ticket["workspaceID"],
        "host": route["endpoint"]["host"],
        "port": int(route["endpoint"]["port"]),
    }


def framed_rpc(ticket: dict, method: str, params: dict, *, timeout: float = 10.0) -> dict:
    request = {
        "id": f"{method}-{uuid.uuid4().hex[:8]}",
        "method": method,
        "params": params,
        "auth": {"attach_token": ticket["token"]},
    }
    data = json.dumps(request, separators=(",", ":")).encode()
    with socket.create_connection((ticket["host"], ticket["port"]), timeout=timeout) as conn:
        conn.settimeout(timeout)
        conn.sendall(struct.pack(">I", len(data)) + data)
        header = conn.recv(4)
        if len(header) != 4:
            raise RuntimeError(f"{method}: short framed header")
        length = struct.unpack(">I", header)[0]
        body = bytearray()
        while len(body) < length:
            chunk = conn.recv(length - len(body))
            if not chunk:
                raise RuntimeError(f"{method}: short framed body")
            body.extend(chunk)
    response = json.loads(body)
    if not response.get("ok"):
        raise RuntimeError(f"{method} failed: {response}")
    return response["result"]


def visible_text(snapshot: dict) -> str:
    payload = snapshot.get("snapshot", {})
    rows = payload.get("scrollbackRows", []) + payload.get("visibleRows", [])
    return "\n".join(
        "".join(cell.get("text", "") for cell in row.get("cells", []))
        for row in rows
    )


def pick_terminal(ticket: dict, *, create_if_missing: bool) -> str:
    workspaces = framed_rpc(ticket, "mobile.workspace.list", {})
    ws_list = workspaces.get("workspaces", [])
    if not ws_list:
        raise RuntimeError("tagged host has no workspaces; create one in cmux first")
    for ws in ws_list:
        if ws.get("id") == ticket["workspace_id"]:
            terms = ws.get("terminals", [])
            if terms:
                return terms[-1]["id"]
            break
    if not create_if_missing:
        raise RuntimeError("no terminal found in workspace and --no-create set")
    result = framed_rpc(
        ticket,
        "mobile.terminal.create",
        {"workspace_id": ticket["workspace_id"]},
    )
    created = result.get("createdTerminalID") or result.get("created_terminal_id")
    if not created:
        for ws in result.get("workspaces", []):
            if ws.get("id") == ticket["workspace_id"]:
                terms = ws.get("terminals", [])
                if terms:
                    return terms[-1]["id"]
    if not created:
        raise RuntimeError(f"mobile.terminal.create did not return a terminal id: {result}")
    return created


def measure_one(ticket: dict, terminal_id: str, poll_interval_s: float, deadline_s: float) -> tuple[float, int]:
    """Send a fresh nonce, poll snapshot until it appears. Returns (elapsed_ms, poll_count)."""
    nonce = f"LP{uuid.uuid4().hex[:10].upper()}"
    sent_at = time.monotonic()
    framed_rpc(
        ticket,
        "mobile.terminal.input",
        {
            "workspace_id": ticket["workspace_id"],
            "terminal_id": terminal_id,
            "text": nonce,
        },
    )
    polls = 0
    while time.monotonic() - sent_at < deadline_s:
        polls += 1
        snap = framed_rpc(
            ticket,
            "mobile.terminal.snapshot",
            {
                "workspace_id": ticket["workspace_id"],
                "terminal_id": terminal_id,
                "client_id": "latency-probe",
                "viewport_columns": 80,
                "viewport_rows": 24,
                "max_scrollback_rows": 0,
            },
        )
        if nonce in visible_text(snap):
            elapsed_ms = (time.monotonic() - sent_at) * 1000.0
            return elapsed_ms, polls
        if poll_interval_s > 0:
            time.sleep(poll_interval_s)
    raise TimeoutError(f"nonce {nonce} never appeared after {deadline_s}s ({polls} polls)")


def pct(samples: list[float], p: float) -> float:
    if not samples:
        return float("nan")
    s = sorted(samples)
    k = (len(s) - 1) * p
    f = int(k)
    c = min(f + 1, len(s) - 1)
    if f == c:
        return s[f]
    return s[f] + (s[c] - s[f]) * (k - f)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--iterations", type=int, default=100)
    ap.add_argument("--warmup", type=int, default=3, help="discarded iterations before timing")
    ap.add_argument("--workspace-id", default=None)
    ap.add_argument("--route", default="debug_loopback", help="route id/kind to use")
    ap.add_argument("--poll-interval-ms", type=float, default=2.0)
    ap.add_argument("--per-sample-timeout-s", type=float, default=5.0)
    ap.add_argument("--no-create", action="store_true", help="reuse existing terminal instead of creating one")
    ap.add_argument("--json", type=Path, default=None, help="write results to this JSON path")
    ap.add_argument("--tag", default=os.environ.get("CMUX_TAG", "swmob"))
    args = ap.parse_args()

    if not args.tag:
        print("error: pass --tag or set CMUX_TAG", file=sys.stderr)
        return 2

    print(f"[latency-probe] tag={args.tag} route={args.route} iterations={args.iterations} warmup={args.warmup} poll_interval_ms={args.poll_interval_ms}")
    ticket = create_attach_ticket(args.tag, args.route, args.workspace_id)
    print(f"[latency-probe] attached workspace={ticket['workspace_id'][:8]} via {ticket['host']}:{ticket['port']}")

    terminal_id = pick_terminal(ticket, create_if_missing=not args.no_create)
    print(f"[latency-probe] terminal={terminal_id[:8]}")

    # let the shell prompt settle
    time.sleep(0.5)

    poll_interval_s = args.poll_interval_ms / 1000.0
    samples: list[float] = []
    poll_counts: list[int] = []
    errors = 0

    total = args.iterations + args.warmup
    for i in range(total):
        try:
            elapsed_ms, polls = measure_one(ticket, terminal_id, poll_interval_s, args.per_sample_timeout_s)
        except Exception as exc:
            errors += 1
            print(f"  iter {i:3d}: ERROR {exc}", file=sys.stderr)
            continue
        tag = "warmup" if i < args.warmup else "sample"
        print(f"  iter {i:3d} {tag}: {elapsed_ms:7.2f} ms ({polls} polls)")
        if tag == "sample":
            samples.append(elapsed_ms)
            poll_counts.append(polls)
        # Wipe the just-typed nonce + a little headroom so the next iteration starts on a
        # clean prompt. A single \b only erases one char; the nonce is 12 chars and other
        # noise (prompt redraws) can creep in, so send a generous backspace run. Without
        # this the line wraps after ~7 iterations and a wrapped nonce gets split across two
        # snapshot rows, making the find-in-text check spuriously fail.
        try:
            framed_rpc(
                ticket,
                "mobile.terminal.input",
                {"workspace_id": ticket["workspace_id"], "terminal_id": terminal_id, "text": "\b" * 40},
            )
        except Exception:
            pass

    if not samples:
        print("error: no successful samples", file=sys.stderr)
        return 1

    stats = {
        "tag": args.tag,
        "route": args.route,
        "workspace_id": ticket["workspace_id"],
        "terminal_id": terminal_id,
        "iterations_requested": args.iterations,
        "iterations_recorded": len(samples),
        "errors": errors,
        "min_ms": min(samples),
        "max_ms": max(samples),
        "mean_ms": statistics.fmean(samples),
        "stdev_ms": statistics.pstdev(samples) if len(samples) > 1 else 0.0,
        "p50_ms": pct(samples, 0.50),
        "p95_ms": pct(samples, 0.95),
        "p99_ms": pct(samples, 0.99),
        "median_poll_count": statistics.median(poll_counts),
        "poll_interval_ms": args.poll_interval_ms,
        "samples_ms": samples,
    }

    print()
    print(f"=== latency stats (n={len(samples)}, errors={errors}) ===")
    print(f"  min:    {stats['min_ms']:7.2f} ms")
    print(f"  p50:    {stats['p50_ms']:7.2f} ms")
    print(f"  p95:    {stats['p95_ms']:7.2f} ms")
    print(f"  p99:    {stats['p99_ms']:7.2f} ms")
    print(f"  max:    {stats['max_ms']:7.2f} ms")
    print(f"  mean:   {stats['mean_ms']:7.2f} ms (sd {stats['stdev_ms']:.2f})")
    print(f"  median poll count: {stats['median_poll_count']}")

    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(stats, indent=2))
        print(f"  json -> {args.json}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
