#!/usr/bin/env python3
"""Read-only preflight for the v3 staging control service and relay directory.

The command deliberately inspects only public health responses, Azure resource
metadata, and read-only PlanetScale queries. It never reads or prints a secret,
and it does not mutate Azure, Stack, or PlanetScale.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path


REQUIRED_TABLES = {
    "transport_v3_devices",
    "transport_v3_events",
    "transport_v3_nonces",
    "transport_v3_relays",
    "transport_v3_teams",
}
REQUIRED_ENV = {
    "DATABASE_URL",
    "STACK_PROJECT_ID",
    "STACK_PUBLISHABLE_CLIENT_KEY",
    "STACK_SECRET_SERVER_KEY",
    "CMUX_V3_SIGNER_SEED_B64",
    "CMUX_V3_RELAY_OPERATOR_TEAM",
    "CMUX_V3_SIGNER_KEY_ID",
    "CMUX_V3_AUDIENCE",
    "CMUX_V3_CONTROL_HTTP",
}


def run_json(command: list[str]) -> object:
    return json.loads(subprocess.check_output(command, text=True))


def probe(url: str) -> dict[str, object]:
    request = urllib.request.Request(url, headers={"Cache-Control": "no-store"})
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            body = response.read(4096).decode("utf-8", "replace")
            return {"status": response.status, "body": body[:256]}
    except urllib.error.HTTPError as error:
        return {"status": error.code, "body": error.read(4096).decode("utf-8", "replace")[:256]}
    except (OSError, urllib.error.URLError) as error:
        return {"status": None, "error": str(error)}


def pscale_query(database: str, branch: str, org: str, query: str) -> dict[str, object]:
    return run_json(
        [
            "pscale",
            "sql",
            database,
            branch,
            "--org",
            org,
            "--format",
            "json",
            "--query",
            query,
        ]
    )  # type: ignore[return-value]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--control-url", required=True, help="HTTPS control service origin")
    parser.add_argument("--subscription", required=True)
    parser.add_argument("--resource-group", default="cmux-v3-staging-shared")
    parser.add_argument("--container-app", default="cmux-v3-control")
    parser.add_argument("--database", default="cmux-prod")
    parser.add_argument("--branch", default="staging")
    parser.add_argument("--org", default="cmux")
    parser.add_argument("--receipt", type=Path)
    parser.add_argument(
        "--require-device",
        action="store_true",
        help="fail until at least one device is enrolled (the default allows setup preflight)",
    )
    args = parser.parse_args()

    base = args.control_url.rstrip("/")
    result: dict[str, object] = {
        "control_url": base,
        "database": args.database,
        "branch": args.branch,
        "control": {"readyz": probe(base + "/readyz"), "healthz": probe(base + "/healthz")},
    }

    app = run_json(
        [
            "az",
            "containerapp",
            "show",
            "--subscription",
            args.subscription,
            "--resource-group",
            args.resource_group,
            "--name",
            args.container_app,
            "--query",
            "{provisioningState:properties.provisioningState,latestRevision:properties.latestRevisionName,env:properties.template.containers[0].env[].name,secretNames:properties.configuration.secrets[].name,image:properties.template.containers[0].image}",
            "-o",
            "json",
        ]
    )
    app = app if isinstance(app, dict) else {}
    env = set(app.get("env") or [])
    secrets = set(app.get("secretNames") or [])
    result["control_app"] = {
        "provisioningState": app.get("provisioningState"),
        "latestRevision": app.get("latestRevision"),
        "image": app.get("image"),
        "env_names": sorted(env),
        "secret_names": sorted(secrets),
        "missing_env": sorted(REQUIRED_ENV - env),
    }

    table_query = (
        "SELECT table_name FROM information_schema.tables "
        "WHERE table_schema = 'public' AND table_name LIKE 'transport_v3%' "
        "ORDER BY table_name"
    )
    tables = pscale_query(args.database, args.branch, args.org, table_query)
    table_rows = tables.get("rows", []) if isinstance(tables, dict) else []
    table_names = {row.get("table_name") for row in table_rows if isinstance(row, dict)}
    relays = pscale_query(
        args.database,
        args.branch,
        args.org,
        "SELECT region, active, length(feed_token_hash) AS feed_hash_length FROM transport_v3_relays ORDER BY region",
    )
    devices = pscale_query(
        args.database,
        args.branch,
        args.org,
        "SELECT COUNT(*) AS devices FROM transport_v3_devices",
    )
    relay_rows = relays.get("rows", []) if isinstance(relays, dict) else []
    device_rows = devices.get("rows", []) if isinstance(devices, dict) else []
    device_count = int(device_rows[0].get("devices", 0)) if device_rows and isinstance(device_rows[0], dict) else 0
    result["database_state"] = {
        "tables": sorted(table_names),
        "missing_tables": sorted(REQUIRED_TABLES - table_names),
        "relays": [
            {"region": row.get("region"), "active": row.get("active"), "feed_hash_length": row.get("feed_hash_length")}
            for row in relay_rows
            if isinstance(row, dict)
        ],
        "device_count": device_count,
    }

    control = result["control"]
    control_ok = isinstance(control, dict) and all(
        isinstance(value, dict) and value.get("status") == 200 for value in control.values()
    )
    app_ok = app.get("provisioningState") == "Succeeded" and not (REQUIRED_ENV - env)
    db_ok = REQUIRED_TABLES <= table_names and len(relay_rows) >= 2
    blockers = []
    if not control_ok:
        blockers.append("control health/readiness is not HTTP 200")
    if not app_ok:
        blockers.append("control app is not provisioned with the complete environment contract")
    if not db_ok:
        blockers.append("staging database is missing v3 tables or two active relay registrations")
    if args.require_device and device_count == 0:
        blockers.append("no device is enrolled")
    result["status"] = "blocked" if blockers else ("ready_for_device_enrollment" if device_count == 0 else "ready")
    result["blockers"] = blockers

    encoded = json.dumps(result, indent=2, sort_keys=True) + "\n"
    if args.receipt:
        args.receipt.parent.mkdir(parents=True, exist_ok=True)
        args.receipt.write_text(encoded)
    print(encoded, end="")
    return 2 if blockers else 0


if __name__ == "__main__":
    sys.exit(main())
